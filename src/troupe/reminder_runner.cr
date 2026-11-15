require "./reminders"

module Troupe
  # 交付调度器（PLAN M3）：claim_due → 作为普通 Actor Turn 交付 → 成功 complete（fencing）
  # / 失败 release（立即重投）→ 至少一次语义（交付失败或认领者宕机，租期过期后重投；
  # 重复投递由业务幂等键兜底，docs/persistence.md）。
  # poll_once 供测试/宿主确定性驱动；start/stop 为生产轮询循环。
  class ReminderRunner
    @stage : ::Troupe::Stage
    @store : ::Troupe::ReminderStore
    @owner_instance : String
    @poll_interval : ::Time::Span
    @lease : ::Time::Span
    @delivery_deadline : ::Time::Span
    @batch : Int32
    @manual_pump : Bool
    @clock : ::Troupe::Clock
    @stop_channel : Channel(Nil)? = nil
    @stopped = Channel(Nil).new

    delegate :clock, to: @stage

    def initialize(@stage, @store, @owner_instance : String, @owner_store : ::Troupe::OwnershipStore,
                   @poll_interval : ::Time::Span = 1.second, @lease : ::Time::Span = 30.seconds,
                   @delivery_deadline : ::Time::Span = 30.seconds, @batch : Int32 = 16,
                   @manual_pump : Bool = false, @clock : ::Troupe::Clock = SystemClock.new)
    end

    def start : Nil
      @mutex.synchronize do
        return if @stop_channel
        stop_channel = Channel(Nil).new
        @stop_channel = stop_channel
        spawn(name: "troupe-reminder-runner") do
          loop do
            select
            when stop_channel.receive
              @stopped.send(nil)
              return
            when timeout(@poll_interval)
              begin
                poll_once
              rescue e : ::Exception
                # 轮询失败不终止循环：下一轮重试（至少一次语义由 claim/lease 保证）
              end
            end
          end
        end
      end
    end

    def stop : Nil
      stop_channel = @mutex.synchronize do
        channel = @stop_channel
        @stop_channel = nil
        channel
      end
      if stop_channel
        stop_channel.send(nil)
        @stopped.receive
      end
    end

    @mutex = Mutex.new

    # 单次轮询：认领 → 逐条交付。返回本轮交付成功的条数。
    def poll_once : Int32
      now = @clock.now
      claimed = @store.claim_due(now, @owner_instance, @lease, @batch)
      succeeded = 0
      claimed.each do |record|
        succeeded += 1 if deliver(record)
      end
      succeeded
    end

    private def deliver(record : ::Troupe::ReminderRecord) : Bool
      begin
        future = @stage.call(record.actor_id, record.turn, record.payload,
          @delivery_deadline, nil)
        @stage.pump(record.actor_id) if @manual_pump # Rehearsal/Manual 模式：同步执行后回复已入通道
        future.await
      rescue e : ::Exception
        # 交付失败（Turn 异常/超时）：release 立即重投（至少一次）
        @store.release(record.actor_id, record.name, record.status_version)
        return false
      end
      # fencing complete：认领期间所有权/租期丢失 → false（提醒由当前 owner 重投，不丢失）
      holder = record.claim_holder
      holder ? @store.complete(record.actor_id, record.name, record.status_version, holder) : false
    end

    # 便捷调度入口。
    def schedule(actor_id : ::Troupe::ActorId, name : String, turn : String,
                 payload : ::JSON::Any = ::JSON::Any.new(nil), due_at : ::Time? = nil) : Nil
      @store.schedule(actor_id, name, turn, payload, due_at || (@clock.now + @poll_interval))
    end

    def cancel(actor_id : ::Troupe::ActorId, name : String) : Bool
      @store.cancel(actor_id, name)
    end
  end
end
