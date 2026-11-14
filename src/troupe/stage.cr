module Troupe
  # 资源上限与默认值（DESIGN §5 背压与资源上限；M1 为单机 Stage 内存预算）。
  record StageConfig,
    max_queue_depth : Int32 = 64,
    max_queue_bytes : Int32 = 262144,
    max_activations : Int32 = 1024,
    default_call_deadline : ::Time::Span = 30.seconds,
    queue_overhead_bytes : Int32 = 256,
    idle_timeout : ::Time::Span? = nil,
    idempotency_retention : ::Time::Span = 7.days

  # Stage：应用内运行时。显式注册 manifest；call 校验角色/方法白名单后
  # 排入有界 CallBoard，激活数受 max_activations 限制（M1 中 slot≈activation）。
  class Stage
    @store : ::Troupe::PropStore
    @ownership : ::Troupe::OwnershipStore
    @mode : ::Troupe::SchedulerMode
    @repertoire = Hash(String, ::Troupe::ManifestBase).new
    @slots = Hash(::Troupe::ActorId, ::Troupe::ActorSlot).new
    @mutex = Mutex.new
    @call_seq : UInt64 = 0
    @closed = false
    @event_handler : Proc(::Troupe::Event, Nil)? = nil

    getter clock : ::Troupe::Clock
    getter config : ::Troupe::StageConfig
    getter name : String

    def initialize(@clock : ::Troupe::Clock = SystemClock.new, store : ::Troupe::PropStore? = nil,
                   ownership : ::Troupe::OwnershipStore? = nil, @mode : ::Troupe::SchedulerMode = SchedulerMode::Fiber,
                   @config : ::Troupe::StageConfig = StageConfig.new, @name : String = "stage")
      @ownership = ownership || MemoryOwnershipStore.new
      @store = store || MemoryPropStore.new(@ownership)
    end

    def store : ::Troupe::PropStore
      @store
    end

    def ownership : ::Troupe::OwnershipStore
      @ownership
    end

    # 事件回调：handler 在持有 slot/stage 锁的路径上同步执行，内部不得回调 Stage。
    def on_event(&handler : ::Troupe::Event -> Nil) : Nil
      @event_handler = handler
    end

    private def emit(event : ::Troupe::Event) : Nil
      if handler = @event_handler
        handler.call(event)
      end
    end

    def register(manifest : ::Troupe::ManifestBase) : Nil
      @mutex.synchronize do
        raise CallRejectedError.new("Stage #{@name} 已停机，拒绝注册", :shutdown, false) if @closed
        raise RoleConflictError.new("角色 #{manifest.role} 已注册") if @repertoire.has_key?(manifest.role)
        manifest.validate!
        @repertoire[manifest.role] = manifest
      end
    end

    def registered_roles : Array(String)
      @mutex.synchronize { @repertoire.keys }
    end

    # 位置透明的本地调用入口（M1 全部本地；远程 transport 复用同一语义管道，见 docs/cluster.md）。
    def call(actor_id : ::Troupe::ActorId, method : String, args : ::JSON::Any = ::JSON::Any.new(nil),
             deadline : ::Time::Span? = nil) : ::Troupe::CallFuture
      @mutex.synchronize do
        raise CallRejectedError.new("Stage #{@name} 已停机，拒收新 Call", :shutdown, false) if @closed
        manifest = @repertoire[actor_id.role]?
        unless manifest
          raise UnknownRoleError.new("角色 #{actor_id.role} 未注册（actor #{actor_id}）")
        end
        unless manifest.turn_names.includes?(method)
          raise CallRejectedError.new("方法 #{method.inspect} 不在角色 #{manifest.role} 的白名单（生命周期/内部方法不可 RPC）", :whitelist, false)
        end
        if @slots.size >= @config.max_activations
          raise CallRejectedError.new("Stage activation 数 #{@slots.size} 达上限 #{@config.max_activations}", :backpressure, true)
        end
        @call_seq += 1
        now = @clock.now
        deadline_at = now + (deadline || @config.default_call_deadline)
        bytes = method.bytesize + args.to_json.bytesize + @config.queue_overhead_bytes
        request = TurnRequest.new(@call_seq, method, args, deadline_at, Channel(CallReply).new(1), bytes, CancelSignal.new)
        slot = @slots[actor_id]?
        unless slot
          slot = ActorSlot.new(actor_id, manifest, @store, @ownership, @clock, @config, @mode, ->(e : ::Troupe::Event) { emit(e) })
          @slots[actor_id] = slot
        end
        begin
          slot.enqueue(request)
        rescue e : CallRejectedError
          emit(Event.new(EventType::CallRejected, actor_id, now, method, e.message))
          raise e
        end
        CallFuture.new(request, @clock, @mode == SchedulerMode::Manual)
      end
    end

    # Manual 模式：处理某 Actor 至多一个 Turn，返回 :executed / :empty。
    def pump(actor_id : ::Troupe::ActorId) : Symbol
      slot = @mutex.synchronize { @slots[actor_id]? }
      return :empty unless slot
      slot.pump
    end

    # Manual 模式：处理所有 slot 直到无待处理 Turn，返回处理（执行+过期）数量。
    def pump_all(max_turns : Int32 = 4096) : Int32
      processed = 0
      loop do
        progressed = false
        slots = @mutex.synchronize { @slots.values }
        slots.each do |slot|
          while processed < max_turns && slot.pump == :executed
            processed += 1
            progressed = true
          end
        end
        break unless progressed
      end
      processed
    end

    # Intermission：将空闲超过 idle_timeout 的 Running slot 下线并移除（下次调用重新激活）。
    # M1 由宿主显式调用；自动巡回调度属 M2 运维增强。
    def sweep : Array(::Troupe::ActorId)
      timeout = @config.idle_timeout
      return [] of ::Troupe::ActorId unless timeout
      now = @clock.now
      targets = [] of ::Troupe::ActorId
      @mutex.synchronize do
        @slots.each do |id, slot|
          next unless slot.state_snapshot == SlotState::Running
          targets << id if (now - slot.last_activity) >= timeout
        end
      end
      passivated = [] of ::Troupe::ActorId
      targets.each do |id|
        slot = @mutex.synchronize { @slots[id]? }
        next unless slot
        slot.close("intermission")
        @mutex.synchronize { @slots.delete(id) }
        passivated << id
      end
      passivated
    end

    def shutdown : Nil
      slots = @mutex.synchronize do
        @closed = true
        @slots.values
      end
      slots.each(&.close("shutdown"))
      @mutex.synchronize { @slots.clear }
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end
  end
end
