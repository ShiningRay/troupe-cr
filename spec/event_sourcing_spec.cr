require "./spec_helper"

# PLAN M6：事件溯源扩展点——重放重建/快照加速一致性/失败事件不产生副作用。
class BankState
  include JSON::Serializable
  property balance : Int32 = 0
  property ops : Int32 = 0

  def initialize
  end
end

class BankConcreteActor < Troupe::Actor(BankState)
end

describe "M6 事件溯源扩展点" do
  apply = ->(state : BankState, event : Troupe::StreamEvent) do
    t = event.payload["type"].as_s
    if t == "deposit"
      state.balance += event.payload["data"]["amount"].as_i
    elsif t == "withdraw"
      state.balance -= event.payload["data"]["amount"].as_i
    end
    state.ops += 1
    state
  end

  it "全量重放：初始状态顺序折叠事件（保序）" do
    store = Troupe::MemoryStreamStore.new
    Troupe::EventSourcing.append_event(store, "bank", "deposit", JSON.parse(%({"amount": 100})))
    Troupe::EventSourcing.append_event(store, "bank", "withdraw", JSON.parse(%({"amount": 30})))
    Troupe::EventSourcing.append_event(store, "bank", "deposit", JSON.parse(%({"amount": 5})))

    events = store.read_from("bank", 0_u64, 100)
    state = Troupe::EventSourcing.rebuild(BankState.new, events, &apply)
    state.balance.should eq(75)
    state.ops.should eq(3)
  end

  it "空事件流：返回初始状态（无可折叠）" do
    store = Troupe::MemoryStreamStore.new
    events = store.read_from("bank", 0_u64, 100)
    state = Troupe::EventSourcing.rebuild(BankState.new, events, &apply)
    state.balance.should eq(0)
    state.ops.should eq(0)
  end

  it "快照加速一致性反例：快照+增量 == 全量重放（错位即测试失败）" do
    store = Troupe::MemoryStreamStore.new
    6.times do |n|
      t = n % 2 == 0 ? "deposit" : "withdraw"
      Troupe::EventSourcing.append_event(store, "bank", t, JSON.parse(%({"amount": #{(n + 1) * 10}})))
    end

    all_events = store.read_from("bank", 0_u64, 100)
    full = Troupe::EventSourcing.rebuild(BankState.new, all_events, &apply)

    # 快照：前 4 条事件之后的状态
    snapshot_events = all_events.first(4)
    snapshot = Troupe::EventSourcing.rebuild(BankState.new, snapshot_events, &apply)
    incremental = all_events.skip(4)

    from_snapshot = Troupe::EventSourcing.rebuild_from_snapshot(snapshot, incremental, &apply)
    from_snapshot.balance.should eq(full.balance) # 一致性契约
    from_snapshot.ops.should eq(full.ops)
    from_snapshot.balance.should_not eq(0) # 快照窗口非空（非平凡断言）
  end

  it "append_event：payload 编码 {type, data}（事件溯源信封）" do
    store = Troupe::MemoryStreamStore.new
    seq = Troupe::EventSourcing.append_event(store, "bank", "deposit",
      ::JSON::Any.new({"amount" => ::JSON::Any.new(50_i64)} of ::String => ::JSON::Any))
    seq.should eq(1_u64)

    event = store.read_from("bank", 0_u64, 1).first
    event.payload["type"].as_s.should eq("deposit")
    event.payload["data"]["amount"].as_i.should eq(50)
  end

  it "持久流集成：Turn 产生事件 → 独立重建者得到一致状态（事件为真相源）" do
    store = Troupe::MemoryStreamStore.new
    stage = Troupe::Stage.new(mode: Troupe::SchedulerMode::Fiber)
    stage.register(Troupe::Manifest(BankState).define("bank", BankConcreteActor) do |m|
      m.schema_version 1
      m.initial { BankState.new }
      m.turn "deposit", BankConcreteActor do |actor, ctx, args|
        # 事件溯源模式：真相源是事件流，Props 仅作本地缓存
        Troupe::EventSourcing.append_event(store, "bank-es", "deposit",
          ::JSON::Any.new({"amount" => args["amount"]} of ::String => ::JSON::Any))
        actor.props.balance += args["amount"].as_i
        actor.save
        JSON::Any.new(actor.props.balance.to_i64)
      end
    end)

    id = Troupe::ActorId.new("app", "bank", "es")
    stage.call(id, "deposit", JSON.parse(%({"amount": 40}))).await.as_i.should eq(40)
    stage.call(id, "deposit", JSON.parse(%({"amount": 2}))).await.as_i.should eq(42)

    # 独立重建者：仅从事件流重建（不读 Props）→ 状态一致
    events = store.read_from("bank-es", 0_u64, 100)
    rebuilder = Troupe::EventSourcing.rebuild(BankState.new, events) do |state, event|
      state.balance += event.payload["data"]["amount"].as_i
      state
    end
    rebuilder.balance.should eq(42)
    stage.shutdown
  end
end
