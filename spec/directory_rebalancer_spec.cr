require "./spec_helper"

# PLAN M5 第二项：版本化 directory、capabilities/resource placement、
# handoff/recovery 与 activation rebalancing（含反例）。
describe "M5 directory & placement & rebalancing" do
  it "版本化 directory：register 单调 version、view_version 全局递增、lookup/unregister" do
    directory = Troupe::VersionedDirectory.new
    id = Troupe::ActorId.new("app", "order", "1")

    v1, view1 = directory.register(id, "node-a")
    v1.should eq(1_u64)
    lookup = directory.lookup(id).not_nil!
    lookup.node.should eq("node-a")
    lookup.version.should eq(1_u64)

    v2, view2 = directory.register(id, "node-b") # 重新注册：version 单调 +1
    v2.should eq(2_u64)
    directory.lookup(id).not_nil!.node.should eq("node-b")
    directory.view_version.should be > view1 # 视图版本随变更递增

    directory.unregister(id).should be_true
    directory.lookup(id).should be_nil
    directory.unregister(id).should be_false # 幂等
    view_after_unregister = directory.view_version
    view_after_unregister.should be > view2 # 注销亦推进视图版本
  end

  it "reassign version 保护反例：旧节点复活以旧 expected_version 抢注册被拒" do
    directory = Troupe::VersionedDirectory.new
    id = Troupe::ActorId.new("app", "order", "fence")

    v1, _ = directory.register(id, "node-a")
    directory.reassign(id, "node-b", v1).should be_true # 正常改派 → version 2
    directory.lookup(id).not_nil!.node.should eq("node-b")

    # 旧节点 A 复活，以其旧版本 (1) 抢注册 → version 保护拒绝
    directory.reassign(id, "node-a", v1).should be_false
    directory.lookup(id).not_nil!.node.should eq("node-b") # 归属未被覆盖
  end

  it "capabilities placement：满足需求子集且负载最少者入选；无匹配显式拒绝" do
    directory = Troupe::VersionedDirectory.new
    placer = Troupe::Placer.new(directory)
    placer.set_capabilities("big-a", ["orders", "mem:big"])
    placer.set_capabilities("gpu-1", ["gpu"])
    placer.set_capabilities("small-b", ["orders"])

    placer.place(["orders", "mem:big"]).should eq("big-a")
    placer.place(["gpu"]).should eq("gpu-1")

    id1 = Troupe::ActorId.new("app", "order", "1")
    id2 = Troupe::ActorId.new("app", "order", "2")
    directory.register(id1, "big-a")
    directory.register(id2, "big-a")
    placer.place(["orders"]).should eq("small-b") # 负载最少者

    placer.place(["quantum"]).should be_nil # 无匹配显式拒绝
  end

  it "handoff：死亡节点的 entries 迁移到环后继，其他节点 entries 不动" do
    ring = Troupe::HashRing.new(vnodes: 128)
    directory = Troupe::VersionedDirectory.new
    rebalancer = Troupe::Rebalancer.new(ring, directory)

    %w[a b c].each { |n| ring.add_node(n) }
    entries = {} of ::Troupe::ActorId => String
    20.times do |i|
      id = Troupe::ActorId.new("app", "order", "h#{i}")
      node = ring.owner_for(id.to_s).not_nil!
      directory.register(id, node)
      entries[id] = node
    end
    owned_by_c = entries.select { |_, node| node == "c" }
    owned_by_c.size.should be > 0

    plan = rebalancer.handoff_plan(["c"])
    plan.all? { |h| h.from == "c" }.should be_true
    plan.all? { |h| h.to == "a" || h.to == "b" }.should be_true

    rebalancer.apply(plan).should eq(owned_by_c.size)
    owned_by_c.each_key do |actor_id|
      directory.lookup(actor_id).not_nil!.node.should_not eq("c")
    end
    # 其他节点的 entries 不动（一致性）
    entries.select { |_, node| node != "c" }.each do |actor_id, node|
      directory.lookup(actor_id).not_nil!.node.should eq(node)
    end
  end

  it "activation rebalancing：新节点加入 → overflow entries 迁移；旧计划重放被 version 保护拒绝" do
    ring = Troupe::HashRing.new(vnodes: 128)
    directory = Troupe::VersionedDirectory.new
    rebalancer = Troupe::Rebalancer.new(ring, directory)
    ring.add_node("a")

    6.times do |i|
      id = Troupe::ActorId.new("app", "order", "r#{i}")
      directory.register(id, "a")
    end
    directory.entries_for_node("a").size.should eq(6)

    plan = rebalancer.rebalance_plan("a", "b", 3)
    plan.size.should eq(3)
    rebalancer.apply(plan).should eq(3)
    directory.entries_for_node("a").size.should eq(3)
    directory.entries_for_node("b").size.should eq(3)

    # version 保护：旧计划重放（version 已推进）全部被拒
    rebalancer.apply(plan).should eq(0)
  end

  it "handoff recovery 反例：entry 同期被 unregister → 计划条目安全跳过" do
    ring = Troupe::HashRing.new(vnodes: 128)
    directory = Troupe::VersionedDirectory.new
    rebalancer = Troupe::Rebalancer.new(ring, directory)
    ring.add_node("a")

    id = Troupe::ActorId.new("app", "order", "gone")
    directory.register(id, "a")
    plan = rebalancer.rebalance_plan("a", "b", 1)

    directory.unregister(id) # 期间被注销（activation 已在他处结束）

    rebalancer.apply(plan).should eq(0) # 安全跳过：lookup nil
    directory.lookup(id).should be_nil
  end
end
