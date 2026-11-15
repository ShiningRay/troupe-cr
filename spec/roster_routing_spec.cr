require "./spec_helper"

# PLAN M3：Roster/HashRing/漂移转发与优雅 drain（含反例）。
describe "M3 roster & routing" do
  it "HashRing：负载大致均衡；节点增删只移动相邻区间（一致性性质）" do
    ring = Troupe::HashRing.new(vnodes: 128)
    %w[a b c].each { |n| ring.add_node(n) }
    counts = Hash(String, Int32).new(0)
    3000.times do |i|
      owner = ring.owner_for("shop/counter/#{i}").not_nil!
      counts[owner] += 1
    end
    counts.size.should eq(3)
    counts.each_value do |n|
      (n.to_f / 3000).should be > 0.1 # 无节点独大
      (n.to_f / 3000).should be < 0.6
    end

    # 一致性：移除 c → a/b 原有键不变，仅 c 的键漂移
    before = Hash(String, String).new
    3000.times { |i| before["shop/counter/#{i}"] = ring.owner_for("shop/counter/#{i}").not_nil! }
    ring.remove_node("c")
    moved_from_ab = 0
    moved_from_c = 0
    3000.times do |i|
      key = "shop/counter/#{i}"
      new_owner = ring.owner_for(key).not_nil!
      old_owner = before[key]
      next if new_owner == old_owner
      if old_owner == "c"
        moved_from_c += 1
      else
        moved_from_ab += 1
      end
    end
    moved_from_ab.should eq(0) # 其他节点的键不受影响（漂移转发基础）
    moved_from_c.should be > 0
  end

  it "Roster：join incarnation 协商、旧 incarnation 重加入被拒、心跳过期判死、死亡重入团 incarnation+1" do
    clock = Troupe::VirtualClock.new
    roster = Troupe::Roster.new(timeout: 5.seconds, clock: clock)

    roster.join("node-a", "host:1").should eq(1_u64)
    roster.heartbeat("node-a", 1_u64).should be_true
    roster.heartbeat("node-a", 2_u64).should be_false # incarnation 不匹配

    expect_raises(Troupe::StaleIncarnationError) do
      roster.join("node-a", "host:1", incarnation: 1_u64) # 现存 incarnation=1，不得回退
    end

    clock.advance(6.seconds)
    roster.sweep.should eq(["node-a"]) # 超时判死
    roster.size.should eq(0)

    roster.join("node-a", "host:1-new").should eq(2_u64) # 死亡重入团 incarnation+1
    roster.heartbeat("node-a", 2_u64).should be_true
  end

  it "Router 漂移转发：节点死亡后仅其键漂移到后继，其他节点键不变" do
    clock = Troupe::VirtualClock.new
    roster = Troupe::Roster.new(timeout: 5.seconds, clock: clock)
    ring = Troupe::HashRing.new(vnodes: 128)
    router = Troupe::Router.new(ring, roster)

    %w[a b c].each { |n| roster.join(n, "host:#{n}") }
    router.sync!
    ring.nodes.size.should eq(3)

    before = Hash(String, String).new
    1000.times { |i| before["shop/counter/#{i}"] = router.route_key("shop/counter/#{i}").not_nil! }

    # c 心跳停止（a/b 持续心跳）→ sweep 判死 → 环同步移除 → 漂移
    clock.advance(2.5.seconds)
    roster.heartbeat("a", 1_u64).should be_true
    roster.heartbeat("b", 1_u64).should be_true
    clock.advance(3.5.seconds)
    dead = roster.sweep
    dead.should eq(["c"])
    drift = router.sync!
    drift[:removed].should eq(["c"])
    drift[:added].empty?.should be_true

    moved_from_c = 0
    moved_other = 0
    1000.times do |i|
      key = "shop/counter/#{i}"
      new_owner = router.route_key(key).not_nil!
      next if new_owner == before[key]
      if before[key] == "c"
        moved_from_c += 1
      else
        moved_other += 1
      end
    end
    moved_from_c.should be > 0
    moved_other.should eq(0) # 漂移转发：非死亡节点的键不迁移

    # join 新节点 → 环同步加入
    roster.join("d", "host:d")
    drift2 = router.sync!
    drift2[:added].should eq(["d"])
  end

  it "Stage drain（Manual）：拒新 :draining（retryable）、排空队列后 finish → :shutdown" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "drain")

    queued = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(2)) # 已入队
    rehearsal.stage.begin_drain

    error = expect_raises(Troupe::CallRejectedError) do
      rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(3))
    end
    error.reason.draining?.should be_true
    error.retryable.should be_true # 可漂移转发到其他节点

    rehearsal.stage.idle?.should be_false # 有排队未完成
    rehearsal.pump_all                    # 排空（执行占用语义不变）
    queued.await.as_i.should eq(2)
    rehearsal.stage.idle?.should be_true

    rehearsal.stage.finish_drain
    rehearsal.stage.closed?.should be_true
    error2 = expect_raises(Troupe::CallRejectedError) do
      rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(4))
    end
    error2.reason.shutdown?.should be_true
  end

  it "Stage drain（Fiber）：在途 Turn 完成后才可 finish；排空中新 Call 被拒" do
    Gate2Actor.reset!
    stage = Troupe::Stage.new
    stage.register(Troupe::Manifest(Gate2Props).define("gatedrain", Gate2Actor) do |m|
      m.schema_version 1
      m.initial { Gate2Props.new }
      m.turn "block_inc", Gate2Actor do |actor, ctx, args|
        Gate2Actor.gate.receive
        old = actor.props.count
        actor.props.count = old + 1
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)
    id = Troupe::ActorId.new("app", "gatedrain", "1")

    in_flight = stage.call(id, "block_inc", JSON.parse(%({})))
    stage.begin_drain
    error = expect_raises(Troupe::CallRejectedError) do
      stage.call(id, "block_inc", JSON.parse(%({})))
    end
    error.reason.draining?.should be_true

    stage.idle?.should be_false # 在途未 settle
    Gate2Actor.open!
    in_flight.await.as_i.should eq(1) # 在途完成（执行占用语义不变）
    stage.idle?.should be_true
    stage.finish_drain
    stage.closed?.should be_true
  end

  it "Roster 拒绝不兼容生产角色（协议协商边界）" do
    clock = Troupe::VirtualClock.new
    roster = Troupe::Roster.new(clock: clock)
    roster.join("legacy", "host:legacy", incarnation: 1_u64).should eq(1_u64)
    expect_raises(Troupe::StaleIncarnationError, "不高于现存") do
      roster.join("legacy", "host:legacy-2", incarnation: 1_u64) # 同 incarnation 重入团被拒
    end
  end
end
