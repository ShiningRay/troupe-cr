module Troupe
  enum SlotState
    # 未激活（初始或失效后），下次消费时重新激活。
    Idle
    Activating
    Running
    Closed
  end

  enum SchedulerMode
    # 每个激活一个调度 Fiber，阻塞等待 CallBoard 唤醒。
    Fiber
    # 无调度 Fiber：由宿主/测试显式 pump（Rehearsal 确定性调度）。
    Manual
  end

  # ActorSlot：单个 virtual actor 的激活生命周期（Casting single-flight）+
  # 有界 CallBoard + 单消费串行执行（strict Turn）+ Intermission/失效下线。
  #
  # 激活顺序（docs/persistence.md，不可颠倒）：
  # acquire epoch → read/create → 逐级迁移（fenced CAS 提交，失败不写）→ on_stage → running。
  class ActorSlot
    @manifest : ::Troupe::ManifestBase
    @store : ::Troupe::PropStore
    @ownership : ::Troupe::OwnershipStore
    @clock : ::Troupe::Clock
    @config : ::Troupe::StageConfig
    @mode : ::Troupe::SchedulerMode
    @emit : Proc(::Troupe::Event, Nil)
    @emit_trace : Proc(::Troupe::TraceEvent, Nil)
    @board : ::Troupe::CallBoard
    @mutex = Mutex.new
    @wakeup = Channel(Nil).new(1)
    @state : ::Troupe::SlotState = SlotState::Idle
    @actor : ::Troupe::ActorBase? = nil
    @ctx : ::Troupe::ActivationContext? = nil
    @last_activity : ::Time
    @executing = false
    @closed = false

    getter actor_id : ::Troupe::ActorId

    def initialize(@actor_id : ::Troupe::ActorId, @manifest : ::Troupe::ManifestBase,
                   @store : ::Troupe::PropStore, @ownership : ::Troupe::OwnershipStore,
                   @clock : ::Troupe::Clock, @config : ::Troupe::StageConfig,
                   @mode : ::Troupe::SchedulerMode, @emit : Proc(::Troupe::Event, Nil),
                   @emit_trace : Proc(::Troupe::TraceEvent, Nil))
      @board = CallBoard.new(@config.max_queue_depth, @config.max_queue_bytes)
      @last_activity = @clock.now
      start_consumer if @mode == SchedulerMode::Fiber
    end

    def enqueue(request : ::Troupe::TurnRequest) : Nil
      @mutex.synchronize do
        raise CallRejectedError.new("Actor #{@actor_id} 已关闭，拒收新 Call", :shutdown, false) if @closed
        @board.push(request)
        @last_activity = @clock.now
      end
      signal
    end

    # Manual 模式：先清队首过期请求，再执行至多一个未过期 Turn。
    # 返回 :executed / :empty；Turn 执行中重入 pump 属于宿主误用，显式报错。
    def pump : Symbol
      request : ::Troupe::TurnRequest? = nil
      @mutex.synchronize do
        raise InvalidActorStateError.new("Turn 执行中不能重入 pump") if @executing
        return :empty if @closed
        request = @board.take_ready(@clock.now) do |expired|
          @last_activity = @clock.now
          reply_error(expired, CallTimeoutError.new("调用排队超过 deadline，未执行、无副作用（#{expired.method}）", :queued))
          @emit.call(Event.new(EventType::TurnExpired, @actor_id, @clock.now, expired.method, "queued"))
          emit_trace_expired(expired)
        end
        @executing = true if request
      end
      return :empty unless request
      execute(request.not_nil!)
      :executed
    end

    def state_snapshot : ::Troupe::SlotState
      @mutex.synchronize { @state }
    end

    def last_activity : ::Time
      @mutex.synchronize { @last_activity }
    end

    # 无排队且无执行中 Turn（drain 完成判定用）。
    def idle? : Bool
      @mutex.synchronize do
        !@executing && @board.empty?
      end
    end

    # 关闭：停收新请求、清空队列（逐个回复 Shutdown 拒绝）、下线实例并停止调度 Fiber。
    # Fiber 模式下 off_stage 由消费 Fiber 在 settle 后执行，避免与执行中 Turn 竞争。
    def close(reason : String) : Nil
      newly_closed = @mutex.synchronize do
        was = @closed
        @closed = true
        !was
      end
      @mutex.synchronize do
        @board.drain do |request|
          request.reply.send(CallReply.error(CallRejectedError.new("Stage 已停机，调用被拒绝（#{request.method}）", :shutdown, false), @clock.now))
        end
      end
      perform_deactivate(reason) if newly_closed && @mode == SchedulerMode::Manual
      signal
    end

    private def closed? : Bool
      @mutex.synchronize { @closed }
    end

    private def start_consumer : Nil
      spawn(name: "troupe:#{@actor_id}") do
        run_loop
      end
    end

    private def run_loop : Nil
      loop do
        @wakeup.receive
        if closed?
          perform_deactivate("shutdown")
          return
        end
        while (request = take_ready)
          execute(request)
          if closed?
            perform_deactivate("shutdown")
            return
          end
        end
      end
    end

    private def take_ready : ::Troupe::TurnRequest?
      request : ::Troupe::TurnRequest? = nil
      @mutex.synchronize do
        request = @board.take_ready(@clock.now) do |expired|
          @last_activity = @clock.now
          reply_error(expired, CallTimeoutError.new("调用排队超过 deadline，未执行、无副作用（#{expired.method}）", :queued))
          @emit.call(Event.new(EventType::TurnExpired, @actor_id, @clock.now, expired.method, "queued"))
          emit_trace_expired(expired)
        end
      end
      request
    end

    private def emit_trace_expired(request : ::Troupe::TurnRequest) : Nil
      @emit_trace.call(TraceEvent.new(call_id: request.call_id, actor_id: @actor_id, method: request.method,
        duration: Time::Span.zero, ok: false, outcome: "expired",
        traceparent: request.traceparent, parent_traceparent: request.parent_traceparent, at: @clock.now))
    end

    private def signal : Nil
      select
      when @wakeup.send(nil)
      else
      end
    end

    private def reply_error(request : ::Troupe::TurnRequest, e : ::Exception) : Nil
      request.reply.send(CallReply.error(e, @clock.now))
    end

    # single-flight：已 Running 直接复用；否则完成激活后再进入 Running。
    # 激活失败统一包装为 ActivationError，槽位回到 Idle 允许后续重试。
    private def ensure_activated : Tuple(::Troupe::ActorBase, ::Troupe::ActivationContext)
      @mutex.synchronize do
        if @state == SlotState::Running && (actor = @actor) && (ctx = @ctx)
          return {actor, ctx}
        end
        raise InvalidActorStateError.new("Actor #{@actor_id} 正在关闭") if @closed
        @state = SlotState::Activating
      end
      begin
        actor, ctx = activate!
      rescue e : ::Exception
        @mutex.synchronize { @state = SlotState::Idle }
        raise e.is_a?(ActivationError) ? e : ActivationError.new("激活失败：#{e.class.name} #{e.message}", e)
      end
      @mutex.synchronize do
        @actor = actor
        @ctx = ctx
        @state = SlotState::Running
        @last_activity = @clock.now
      end
      @emit.call(Event.new(EventType::Activated, @actor_id, @clock.now))
      {actor, ctx}
    end

    private def activate! : Tuple(::Troupe::ActorBase, ::Troupe::ActivationContext)
      epoch = @ownership.acquire(@actor_id)
      record = @store.read(@actor_id)
      if record.nil?
        record = @store.create(@actor_id, @manifest.schema_version, @manifest.initial_json, epoch)
      else
        record = migrate_if_needed(record, epoch)
      end
      props = @manifest.parse_final(record.data)
      journal = Hash(String, ::Troupe::IdempotencyRecord).new
      @store.idempotency(@actor_id, @clock.now).each { |entry| journal[entry.key] = entry }
      ctx = ActivationContext.new(@store, @manifest, @clock, epoch, record.revision, journal, @config.idempotency_retention)
      actor = @manifest.build_actor(@actor_id, props, ctx)
      actor.on_stage
      {actor, ctx}
    end

    # 逐级迁移：任何一步失败即 ActivationError，且不产生任何写入（PLAN M1 验收）。
    private def migrate_if_needed(record : ::Troupe::PropRecord, epoch : UInt64) : ::Troupe::PropRecord
      return record if record.schema_version == @manifest.schema_version
      path = @manifest.migration_path(record.schema_version)
      unless path
        raise ActivationError.new("schema #{record.schema_version} 无法逐级迁移到 #{@manifest.schema_version}（缺级或降级不受支持）")
      end
      data = record.data
      path.each do |step|
        begin
          data = step.apply(data)
        rescue e : ::Exception
          from_v = step.from_version.as(Int32)
          to_v = step.to_version.as(Int32)
          raise ActivationError.new("迁移 #{from_v}→#{to_v} 失败：#{e.class.name} #{e.message}", e)
        end
      end
      begin
        @store.write(@actor_id, record.revision, @manifest.schema_version, data, epoch)
      rescue e : ::Exception
        raise ActivationError.new("迁移提交失败：#{e.class.name} #{e.message}", e)
      end
    end

    private def execute(request : ::Troupe::TurnRequest) : Nil
      begin
        actor, ctx = ensure_activated
      rescue e : ::Exception
        reply_error(request, e)
        clear_executing
        @emit.call(Event.new(EventType::ActivationFailed, @actor_id, @clock.now, request.method, e.message))
        return
      end
      started = @clock.now
      @emit.call(Event.new(EventType::TurnStarted, @actor_id, started, request.method, nil))
      begin
        call_ctx = CallContext.new(request.call_id, actor_id, request.method, request.deadline, @clock, request.cancel, request.traceparent)
        value = @manifest.invoke_turn(actor, call_ctx, request.method, request.args)
        settled = @clock.now
        @mutex.synchronize do
          @last_activity = settled
          @executing = false
        end
        request.reply.send(CallReply.value(value, settled))
        @emit.call(Event.new(EventType::TurnEnded, @actor_id, settled, request.method, "ok"))
        @emit_trace.call(TraceEvent.new(call_id: request.call_id, actor_id: @actor_id, method: request.method,
          duration: settled - started, ok: true, outcome: "completed",
          traceparent: request.traceparent, parent_traceparent: request.parent_traceparent, at: settled))
      rescue e : ::Exception
        settled = @clock.now
        invalidated = invalidating?(e)
        @mutex.synchronize do
          @last_activity = settled
          @executing = false
          if invalidated
            # 保存失败使实例失效（DESIGN §7.3）：丢弃未提交状态，下次调用从最后已提交快照重新激活。
            @actor = nil
            @ctx = nil
            @state = SlotState::Idle
          end
        end
        @emit.call(Event.new(EventType::SaveFailed, @actor_id, settled, request.method, e.class.name)) if invalidated
        request.reply.send(CallReply.error(e, settled))
        @emit.call(Event.new(EventType::TurnEnded, @actor_id, settled, request.method, "error"))
        @emit_trace.call(TraceEvent.new(call_id: request.call_id, actor_id: @actor_id, method: request.method,
          duration: settled - started, ok: false, outcome: "failed",
          traceparent: request.traceparent, parent_traceparent: request.parent_traceparent, at: settled))
      end
    end

    private def clear_executing : Nil
      @mutex.synchronize { @executing = false }
    end

    private def invalidating?(e : ::Exception) : Bool
      case e
      when ConflictError, InvalidActorStateError
        true
      when CallRejectedError
        e.reason.ownership? || e.reason.invalidated?
      else
        false
      end
    end

    private def perform_deactivate(reason : String) : Nil
      actor = @mutex.synchronize do
        a = @actor
        @actor = nil
        @ctx = nil
        @state = SlotState::Closed
        a
      end
      return unless actor
      begin
        actor.off_stage
        @emit.call(Event.new(EventType::Deactivated, @actor_id, @clock.now, reason, nil))
      rescue e : ::Exception
        @emit.call(Event.new(EventType::Deactivated, @actor_id, @clock.now, "off_stage_error:#{e.class.name}", nil))
      end
    end
  end
end
