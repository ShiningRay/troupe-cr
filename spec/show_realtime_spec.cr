require "./spec_helper"

# PLAN M4 第二项：Show realtime——Actor Audience 经完整 Turn，边界回调与 Actor 订阅分离
# （在线尽力通知，离线不保证；不重投——持久化诉求走 Reminder/Outbox）。
def show_setup(mode : Troupe::SchedulerMode = Troupe::SchedulerMode::Fiber,
               max_queue_depth : Int32 = 64)
  stage = Troupe::Stage.new(mode: mode, config: Troupe::StageConfig.new(max_queue_depth: max_queue_depth))
  hub = Troupe::ShowHub.new(stage)
  stage.register(Troupe::Manifest(FeedProps).define("feed", FeedActor) do |m|
    m.schema_version 1
    m.initial { FeedProps.new }
    m.turn "on_event", FeedActor do |actor, ctx, args|
      actor.props.received += 1
      actor.props.last_topic = args["topic"].as_s
      actor.save
      JSON::Any.new(actor.props.received.to_i64)
    end
    m.turn "failing_on_event", FeedActor do |actor, ctx, args|
      raise Troupe::SerializationError.new("注入交付失败")
    end
  end)
  {stage, hub}
end

describe "M4 Show realtime" do
  it "Actor Audience 经完整 Turn：publish 交付为普通 Turn（props 经 save 持久化）" do
    stage, hub = show_setup
    begin
      show = hub.show("events")
      id = Troupe::ActorId.new("app", "feed", "a1")
      show.actor_subscribe(id, "on_event")

      report = hub.publish("events", JSON.parse(%({"n": 1})))
      report.actors_ok.should eq(1)
      report.actors_failed.should eq(0)
      report.external_ok.should eq(0)

      props = FeedProps.from_json(stage.store.read(id).not_nil!.data)
      props.received.should eq(1) # Turn 执行并 save
      props.last_topic.should eq("events")
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "边界回调与 Actor 订阅分离：退订互不影响" do
    stage, hub = show_setup
    begin
      show = hub.show("events")
      id = Troupe::ActorId.new("app", "feed", "sep")
      show.actor_subscribe(id, "on_event")

      received = [] of String
      handle = show.external_subscribe { |payload| received << payload["n"].to_s }

      show.external_unsubscribe(handle).should be_true
      show.actor_unsubscribe(id).should be_true

      report = hub.publish("events", JSON.parse(%({"n": 2})))
      report.actors_ok.should eq(0)   # 已退订
      report.external_ok.should eq(0) # 已退订
      received.should be_empty
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "两类订阅并存且互不影响：Actor 经 Turn、边界回调直接通知" do
    stage, hub = show_setup
    begin
      show = hub.show("events")
      id = Troupe::ActorId.new("app", "feed", "both")
      show.actor_subscribe(id, "on_event")

      external_seen = [] of Int32
      show.external_subscribe { |payload| external_seen << payload["n"].as_i }

      hub.publish("events", JSON.parse(%({"n": 3})))

      external_seen.should eq([3])                                                  # 边界回调直接通知
      FeedProps.from_json(stage.store.read(id).not_nil!.data).received.should eq(1) # Actor 经 Turn

      # Actor 退订后：边界回调继续收到（分离）
      show.actor_unsubscribe(id)
      hub.publish("events", JSON.parse(%({"n": 4})))
      external_seen.should eq([3, 4])
      FeedProps.from_json(stage.store.read(id).not_nil!.data).received.should eq(1) # Actor 不再收到
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "在线尽力：Actor Turn 抛错 → 交付失败计入报告且不重投（实时语义，非持久流）" do
    stage, hub = show_setup
    begin
      show = hub.show("events")
      id = Troupe::ActorId.new("app", "feed", "fail")
      show.actor_subscribe(id, "failing_on_event")

      report1 = hub.publish("events", JSON.parse(%({"n": 1})))
      report1.actors_failed.should eq(1)
      report1.actors_ok.should eq(0)

      # 不重投：再次 publish 仍是独立的一次尝试，无累积/补投
      report2 = hub.publish("events", JSON.parse(%({"n": 2})))
      report2.actors_failed.should eq(1)

      # Turn 抛错且未 save → 零持久化副作用（激活创建的 record 保持初始值）
      FeedProps.from_json(stage.store.read(id).not_nil!.data).received.should eq(0)
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "离线不保证：订阅 actor 超过背压上限 → 交付失败计入报告（在线尽力反例）" do
    stage, hub = show_setup(max_queue_depth: 1)
    begin
      show = hub.show("events")
      id = Troupe::ActorId.new("app", "feed", "offline")
      show.actor_subscribe(id, "on_event")

      # 占住队列（深度 1）：主 fiber 的排队调用未消费时，publish 的交付入队 → 背压拒绝
      stage.call(id, "on_event", JSON.parse(%({"topic": "fill"})))

      report = hub.publish("events", JSON.parse(%({"n": 1})))
      report.actors_failed.should eq(1) # 队列满 → 在线尽力放弃
      report.actors_ok.should eq(0)
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "边界回调异常隔离：单个回调抛错不影响其他订阅者" do
    stage, hub = show_setup
    begin
      show = hub.show("events")
      id = Troupe::ActorId.new("app", "feed", "iso")
      show.actor_subscribe(id, "on_event")

      seen = [] of Int32
      show.external_subscribe { |_p| raise Troupe::SerializationError.new("坏回调") }
      show.external_subscribe { |p| seen << p["n"].as_i }

      report = hub.publish("events", JSON.parse(%({"n": 7})))
      report.actors_ok.should eq(1)
      report.external_failed.should eq(1)
      report.external_ok.should eq(1)
      seen.should eq([7]) # 坏回调后的订阅者仍收到
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "未订阅 topic：publish 无收件人（报告全 0）" do
    stage, hub = show_setup
    begin
      report = hub.publish("nobody", JSON.parse(%({"n": 1})))
      report.actors_ok.should eq(0)
      report.actors_failed.should eq(0)
      report.external_ok.should eq(0)
      report.external_failed.should eq(0)
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "同一 Actor 订阅两个 topic：各 topic 独立交付（经完整 Turn 串行）" do
    stage, hub = show_setup(Troupe::SchedulerMode::Fiber)
    begin
      show_a = hub.show("a")
      show_b = hub.show("b")
      id = Troupe::ActorId.new("app", "feed", "multi")
      show_a.actor_subscribe(id, "on_event")
      show_b.actor_subscribe(id, "on_event")

      hub.publish("a", JSON.parse(%({"n": 1})))
      hub.publish("b", JSON.parse(%({"n": 1})))

      props = FeedProps.from_json(stage.store.read(id).not_nil!.data)
      props.received.should eq(2)
      props.last_topic.should eq("b") # 经完整 Turn 串行交付，顺序保持
      stage.shutdown
    ensure
      stage.shutdown
    end
  end
end
