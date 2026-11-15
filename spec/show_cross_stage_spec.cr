require "./spec_helper"

# PLAN M4 第三项：Show 跨 Stage、订阅生命周期和背压（在线尽力，离线不保证）。
def feed_register(stage : Troupe::Stage, role : String = "feed")
  stage.register(Troupe::Manifest(FeedProps).define(role, FeedActor) do |m|
    m.schema_version 1
    m.initial { FeedProps.new }
    m.turn "on_event", FeedActor do |actor, ctx, args|
      actor.props.received += 1
      actor.props.last_topic = args["topic"].as_s
      actor.save
      JSON::Any.new(actor.props.received.to_i64)
    end
  end)
end

describe "M4 Show 跨 Stage 与生命周期" do
  it "跨 Stage：同一 topic 的订阅者来自不同 Stage，publish 各自交付" do
    stage_a = Troupe::Stage.new(name: "a")
    stage_b = Troupe::Stage.new(name: "b")
    feed_register(stage_a)
    feed_register(stage_b)
    hub = Troupe::ShowHub.new(stage_a) # 默认 stage = a

    show = hub.show("events")
    id_a = Troupe::ActorId.new("app", "feed", "in-a")
    id_b = Troupe::ActorId.new("app", "feed", "in-b")
    show.actor_subscribe(id_a, "on_event")          # 默认 stage a
    show.actor_subscribe(id_b, "on_event", stage_b) # 显式绑定 stage b（跨 Stage）

    report = hub.publish("events", JSON.parse(%({"n": 1})))
    report.actors_ok.should eq(2) # 两个 Stage 各自交付
    report.actors_failed.should eq(0)

    FeedProps.from_json(stage_a.store.read(id_a).not_nil!.data).received.should eq(1)
    FeedProps.from_json(stage_b.store.read(id_b).not_nil!.data).received.should eq(1)
    stage_a.shutdown
    stage_b.shutdown
  end

  it "订阅生命周期：Stage 停机后其订阅交付失败（离线），其他 Stage 不受影响" do
    stage_a = Troupe::Stage.new(name: "a")
    stage_b = Troupe::Stage.new(name: "b")
    feed_register(stage_a)
    feed_register(stage_b)
    hub = Troupe::ShowHub.new(stage_b) # 默认 stage = b
    show = hub.show("events")

    id_a = Troupe::ActorId.new("app", "feed", "life-a")
    id_b = Troupe::ActorId.new("app", "feed", "life-b")
    show.actor_subscribe(id_a, "on_event", stage_a)
    show.actor_subscribe(id_b, "on_event", stage_b)

    stage_a.shutdown # A 离线（生命周期终结）

    report = hub.publish("events", JSON.parse(%({"n": 1})))
    report.actors_failed.should eq(1) # A 停机 → 离线不保证
    report.actors_ok.should eq(1)     # B 在线照常交付
    FeedProps.from_json(stage_b.store.read(id_b).not_nil!.data).received.should eq(1)
    stage_b.shutdown
  end

  it "背压隔离：慢订阅者（队列满）交付失败，其他订阅者同 publish 照常收到" do
    stage_fast = Troupe::Stage.new(name: "fast")
    # Manual：队列不被自动消费——确定性保持满队（Fiber 消费者会立即排空）
    stage_slow = Troupe::Stage.new(name: "slow", mode: Troupe::SchedulerMode::Manual,
      config: Troupe::StageConfig.new(max_queue_depth: 1))
    feed_register(stage_fast)
    feed_register(stage_slow)
    hub = Troupe::ShowHub.new(stage_fast)
    show = hub.show("events")

    id_fast = Troupe::ActorId.new("app", "feed", "fast")
    id_slow = Troupe::ActorId.new("app", "feed", "slow")
    show.actor_subscribe(id_fast, "on_event", stage_fast)
    show.actor_subscribe(id_slow, "on_event", stage_slow)

    # 占满慢订阅者队列（深度 1）
    stage_slow.call(id_slow, "on_event", JSON.parse(%({"topic": "fill"})))

    report = hub.publish("events", JSON.parse(%({"n": 1})))
    report.actors_ok.should eq(1)     # 快订阅者照常
    report.actors_failed.should eq(1) # 慢订阅者背压 → 在线尽力放弃（不影响他人）

    FeedProps.from_json(stage_fast.store.read(id_fast).not_nil!.data).received.should eq(1)
    stage_fast.shutdown
    stage_slow.shutdown
  end

  it "订阅生命周期：draining Stage 的订阅交付失败（:draining 可转发）" do
    stage_a = Troupe::Stage.new(name: "a")
    stage_b = Troupe::Stage.new(name: "b")
    feed_register(stage_a)
    feed_register(stage_b)
    hub = Troupe::ShowHub.new(stage_b)
    show = hub.show("events")

    id_a = Troupe::ActorId.new("app", "feed", "drain-a")
    id_b = Troupe::ActorId.new("app", "feed", "drain-b")
    show.actor_subscribe(id_a, "on_event", stage_a)
    show.actor_subscribe(id_b, "on_event", stage_b)

    stage_a.begin_drain # A 排空：拒新 Call（可转发）

    report = hub.publish("events", JSON.parse(%({"n": 1})))
    report.actors_failed.should eq(1) # draining 交付失败（调用方可漂移转发）
    report.actors_ok.should eq(1)
    stage_a.finish_drain
    stage_b.shutdown
  end

  it "退订幂等：重复退订返回 false；未知 actor 退订也返回 false" do
    stage = Troupe::Stage.new(mode: Troupe::SchedulerMode::Manual)
    hub = Troupe::ShowHub.new(stage)
    show = hub.show("events")
    id = Troupe::ActorId.new("app", "feed", "unsub")

    show.actor_subscribe(id, "on_event")
    show.actor_unsubscribe(id).should be_true
    show.actor_unsubscribe(id).should be_false # 幂等
    show.external_unsubscribe(999_u64).should be_false
    stage.shutdown
  end
end
