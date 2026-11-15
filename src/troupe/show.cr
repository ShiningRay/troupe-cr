module Troupe
  # Show realtime（PLAN M4，DESIGN：实时通知与持久流分开——不把 fan-out 称为持久流）。
  #
  # 两类订阅，**边界回调与 Actor 订阅分离**：
  # - **Actor Audience**（actor_subscribe）：事件作为**普通 Actor Turn** 交付
  #   （经同一 Stage 管道：白名单/背压/超时/串行语义不变，DESIGN"经完整 Turn"）；
  # - **边界回调**（external_subscribe）：非 Actor 观察者的直接回调，立即通知，
  #   与 Actor Turn 交付互不影响（分离）。
  #
  # 语义：**在线尽力通知，离线不保证**——交付失败（Turn 异常/超时/背压/实例不可达）
  # 即放弃该次通知，**不重投**（持久化诉求走 Reminder/Outbox，M3/M5）。
  # publish 同步 fan-out，返回 PublishReport（交付计数可断言）。
  record PublishReport, actors_ok : Int32, actors_failed : Int32, external_ok : Int32, external_failed : Int32

  record ActorSubscription, stage : ::Troupe::Stage, actor_id : ::Troupe::ActorId, turn : String

  class Show
    @stage : ::Troupe::Stage
    @topic : String
    @actor_subs = Hash(::Troupe::ActorId, ActorSubscription).new
    @external_subs = Hash(::UInt64, Proc(::JSON::Any, Nil)).new
    @external_seq : ::UInt64 = 0
    @delivery_deadline : ::Time::Span
    @mutex = Mutex.new

    def initialize(@stage, @topic, @delivery_deadline : ::Time::Span = 10.seconds)
    end

    # Actor Audience：事件作为普通 Turn 交付到 (actor_id, turn)。
    # stage 缺省为 Hub 默认 Stage；显式传入可实现**跨 Stage** Audience
    # （同一 topic 的订阅者可来自不同 Stage，交付按各自订阅的 Stage 进行）。
    def actor_subscribe(actor_id : ::Troupe::ActorId, turn : String,
                        stage : ::Troupe::Stage = @stage) : Nil
      @mutex.synchronize { @actor_subs[actor_id] = ActorSubscription.new(stage, actor_id, turn) }
    end

    def actor_unsubscribe(actor_id : ::Troupe::ActorId) : Bool
      deleted = @mutex.synchronize { @actor_subs.delete(actor_id) }
      !deleted.nil?
    end

    # 边界回调：返回句柄用于退订。
    def external_subscribe(&callback : ::JSON::Any -> Nil) : ::UInt64
      @mutex.synchronize do
        @external_seq += 1
        @external_subs[@external_seq] = callback
        @external_seq
      end
    end

    def external_unsubscribe(handle : ::UInt64) : Bool
      deleted = @mutex.synchronize { @external_subs.delete(handle) }
      !deleted.nil?
    end

    def actor_subscriber_count : Int32
      @mutex.synchronize { @actor_subs.size }
    end

    def external_subscriber_count : Int32
      @mutex.synchronize { @external_subs.size }
    end

    # 同步 fan-out：Actor 经完整 Turn（在线尽力，失败放弃不重投）；边界回调隔离。
    def publish(payload : ::JSON::Any) : ::Troupe::PublishReport
      subs, externals = @mutex.synchronize do
        {@actor_subs.values.dup, @external_subs.values.dup}
      end
      envelope = ::JSON::Any.new({"topic" => ::JSON::Any.new(@topic), "payload" => payload} of ::String => ::JSON::Any)

      actors_ok = 0
      actors_failed = 0
      subs.each do |sub|
        begin
          sub.stage.call(sub.actor_id, sub.turn, envelope, @delivery_deadline).await
          actors_ok += 1
        rescue e : ::Exception
          # 在线尽力：放弃该次通知，不重投（实时语义）。
          # Stage 停机/排空(:shutdown/:draining)与背压/超时同样计入 failed——离线不保证。
          actors_failed += 1
        end
      end

      external_ok = 0
      external_failed = 0
      externals.each do |callback|
        begin
          callback.call(payload)
          external_ok += 1
        rescue e : ::Exception
          external_failed += 1 # 边界回调异常隔离：不影响其他订阅者
        end
      end

      PublishReport.new(actors_ok, actors_failed, external_ok, external_failed)
    end
  end

  # 多 topic 的 Show 集合管理。默认 Stage 供一般订阅；跨 Stage Audience
  # 经 `show(topic).actor_subscribe(id, turn, other_stage)` 显式绑定。
  class ShowHub
    @stage : ::Troupe::Stage
    @shows = Hash(String, ::Troupe::Show).new
    @delivery_deadline : ::Time::Span
    @mutex = Mutex.new

    def initialize(@stage, @delivery_deadline : ::Time::Span = 10.seconds)
    end

    def show(topic : String) : ::Troupe::Show
      @mutex.synchronize do
        @shows[topic] ||= Show.new(@stage, topic, @delivery_deadline)
      end
    end

    def actor_subscribe(topic : String, actor_id : ::Troupe::ActorId, turn : String,
                        stage : ::Troupe::Stage? = nil) : Nil
      show(topic).actor_subscribe(actor_id, turn, stage || @stage)
    end

    def publish(topic : String, payload : ::JSON::Any) : ::Troupe::PublishReport
      show(topic).publish(payload)
    end
  end
end
