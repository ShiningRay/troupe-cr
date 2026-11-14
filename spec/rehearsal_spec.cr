require "./spec_helper"

# Rehearsal（Manual 调度 + VirtualClock）下的确定性验收与反例。
describe Troupe::Rehearsal do
  it "首次 pump 激活一次，后续 Turn 复用同一激活" do
    CounterActor.reset_log!
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "reuse")

    rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all

    CounterActor.log.select(&.starts_with?("on:")).size.should eq(1)
  end

  it "排队过期：不执行、零副作用，回复 CallTimeoutError(:queued)（PLAN M1 验收）" do
    CounterActor.reset_log!
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "expire")

    future = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1), deadline: 5.seconds)
    rehearsal.advance(10.seconds)
    rehearsal.pump(id).should eq(:empty) # 只清过期，不执行

    CounterActor.log.should be_empty
    rehearsal.store.read(id).should be_nil # 连 Props 都未创建：零副作用

    error = expect_raises(Troupe::CallTimeoutError) { future.await }
    error.phase.queued?.should be_true
    rehearsal.events_of(Troupe::EventType::TurnExpired).size.should eq(1)
  end

  it "执行超时：调用方得 :executing 未知结果，旧 Turn 占用串行通道直到 settle（PLAN M1 验收）" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_slow(rehearsal.stage)
    id = rehearsal.actor("slow", "1")

    first = rehearsal.agent.call(id, "slow_increment")
    rehearsal.pump(id).should eq(:executed)
    error = expect_raises(Troupe::CallTimeoutError) { first.await }
    error.phase.executing?.should be_true

    # 下一个 Turn 严格在旧 Turn settle 之后执行，不交错、不丢其副作用
    second = rehearsal.agent.call(id, "bump")
    rehearsal.pump(id).should eq(:executed)
    second.await.as_i.should eq(2)
    SlowProps.from_json(rehearsal.store.read(id).not_nil!.data).count.should eq(2)

    started = rehearsal.events_of(Troupe::EventType::TurnStarted).map(&.method)
    started.should eq(["slow_increment", "bump"])
  end

  it "CAS revision 冲突使实例失效，后续调用从最后已提交快照恢复（PLAN M1 验收）" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "cas")

    first = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    first.await.as_i.should eq(1)

    # 模拟外部写推进 revision（epoch 不变）
    record = rehearsal.store.read(id).not_nil!
    rehearsal.store.write(id, record.revision, record.schema_version, %({"count":100}), record.epoch)

    stale = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump(id).should eq(:executed)
    error = expect_raises(Troupe::ConflictError) { stale.await }
    error.kind.revision?.should be_true

    # 失效后重新激活：基于外部提交的快照继续
    fresh = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump(id).should eq(:executed)
    fresh.await.as_i.should eq(101)
    CounterProps.from_json(rehearsal.store.read(id).not_nil!.data).count.should eq(101)
    rehearsal.events_of(Troupe::EventType::SaveFailed).size.should eq(1)
  end

  it "fencing：旧 epoch 的 save 被拒并失效，从新 owner 提交的快照恢复" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "fence")

    first = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    first.await.as_i.should eq(1)

    # 模拟另一个 owner 取得所有权并提交新状态
    record = rehearsal.store.read(id).not_nil!
    new_epoch = rehearsal.ownership.acquire(id)
    rehearsal.store.write(id, record.revision, record.schema_version, %({"count":50}), new_epoch)

    stale = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump(id).should eq(:executed)
    error = expect_raises(Troupe::CallRejectedError) { stale.await }
    error.reason.ownership?.should be_true

    fresh = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump(id).should eq(:executed)
    fresh.await.as_i.should eq(51)
  end

  it "存量 v1 数据逐级迁移 v1→v2→v3 后正常服务（PLAN M1 验收）" do
    rehearsal = Troupe::Rehearsal.new
    id = rehearsal.actor("cart", "migrate")
    TroupeFixtures.seed_v1_cart(rehearsal, id, ["apple"])
    TroupeFixtures.register_cart(rehearsal.stage)

    call = rehearsal.agent.call(id, "add_item", JSON.parse(%({"item": "pear"})))
    rehearsal.pump_all
    call.await.as_i.should eq(2)

    record = rehearsal.store.read(id).not_nil!
    record.schema_version.should eq(3)
    record.revision.should eq(3_u64) # v1 种子(1) + 迁移提交(2) + add_item save(3)
    props = CartPropsV3.from_json(record.data)
    props.items.should eq(["apple", "pear"])
    props.currency.should eq("USD")
  end

  it "迁移失败不写：store 保持 v1 原样，调用方得 ActivationError（PLAN M1 验收）" do
    rehearsal = Troupe::Rehearsal.new
    id = rehearsal.actor("cart", "broken")
    TroupeFixtures.seed_v1_cart(rehearsal, id, ["apple"])

    bad_step = Troupe::MigrationStep(CartPropsV1, CartPropsV2).new(1, 2) do |_v1|
      raise Troupe::SerializationError.new("迁移注入失败")
    end
    TroupeFixtures.register_cart(rehearsal.stage, steps: [bad_step, TroupeFixtures.cart_step_2_3])

    call = rehearsal.agent.call(id, "add_item", JSON.parse(%({"item": "pear"})))
    rehearsal.pump_all
    expect_raises(Troupe::ActivationError, "迁移 1→2 失败") { call.await }

    record = rehearsal.store.read(id).not_nil!
    record.schema_version.should eq(1)
    record.revision.should eq(1_u64) # 零写入
    CartPropsV1.from_json(record.data).items.should eq(["apple"])
    rehearsal.events_of(Troupe::EventType::ActivationFailed).size.should eq(1)
  end

  it "不同 namespace 的 Rehearsal 状态隔离、行为一致（PLAN M1 验收）" do
    alpha = Troupe::Rehearsal.new("alpha")
    beta = Troupe::Rehearsal.new("beta")
    [alpha, beta].each { |r| TroupeFixtures.register_counter(r.stage) }

    id_a = alpha.actor("counter", "shared-key")
    id_b = beta.actor("counter", "shared-key")
    id_a.should_not eq(id_b) # namespace 参与 identity

    call_a = alpha.agent.call(id_a, "increment", TroupeFixtures.counter_args(3))
    alpha.pump_all
    call_a.await.as_i.should eq(3)

    call_b = beta.agent.call(id_b, "increment", TroupeFixtures.counter_args(1))
    beta.pump_all
    call_b.await.as_i.should eq(1)

    CounterProps.from_json(beta.store.read(id_b).not_nil!.data).count.should eq(1)
    CounterProps.from_json(alpha.store.read(id_a).not_nil!.data).count.should eq(3)
  end

  it "队列深度达上限显式拒绝（CallRejectedError(:backpressure)，可重试）" do
    rehearsal = Troupe::Rehearsal.new("rehearsal", config: Troupe::StageConfig.new(max_queue_depth: 2))
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "bp")

    rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    error = expect_raises(Troupe::CallRejectedError) do
      rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    end
    error.reason.backpressure?.should be_true
    error.retryable.should be_true
  end

  it "队列字节预算超限显式拒绝" do
    rehearsal = Troupe::Rehearsal.new("rehearsal", config: Troupe::StageConfig.new(max_queue_bytes: 400))
    TroupeFixtures.register_slow(rehearsal.stage)
    id = rehearsal.actor("slow", "bytes")

    rehearsal.agent.call(id, "bump")
    error = expect_raises(Troupe::CallRejectedError) do
      rehearsal.agent.call(id, "bump")
    end
    error.reason.backpressure?.should be_true
    error.message.not_nil!.should contain("字节")
  end

  it "Intermission：空闲超时下线，下次调用重新激活并保留已提交 Props" do
    rehearsal = Troupe::Rehearsal.new("rehearsal", config: Troupe::StageConfig.new(idle_timeout: 5.seconds))
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "idle")

    CounterActor.reset_log!
    first = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(2))
    rehearsal.pump_all
    first.await.as_i.should eq(2)

    rehearsal.advance(10.seconds)
    rehearsal.sweep.should eq([id])
    rehearsal.events_of(Troupe::EventType::Deactivated).size.should eq(1)
    CounterActor.log.select(&.starts_with?("off:")).size.should eq(1)

    second = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(3))
    rehearsal.pump_all
    second.await.as_i.should eq(5) # 从已提交快照恢复：2 + 3
    rehearsal.events_of(Troupe::EventType::Activated).size.should eq(2)
  end

  it "白名单拒绝生命周期/未知方法；未注册角色报 UnknownRoleError" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "wl")

    error = expect_raises(Troupe::CallRejectedError) { rehearsal.agent.call(id, "on_stage") }
    error.reason.whitelist?.should be_true
    expect_raises(Troupe::CallRejectedError) { rehearsal.agent.call(id, "nope") }
    expect_raises(Troupe::UnknownRoleError) { rehearsal.agent.call(rehearsal.actor("ghost", "1"), "increment") }
  end

  it "停机后清空队列并拒收新 Call；排队的调用收到 Shutdown 拒绝" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "sh")

    queued = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1)) # 未 pump
    rehearsal.stage.shutdown
    error = expect_raises(Troupe::CallRejectedError) { queued.await }
    error.reason.shutdown?.should be_true

    error = expect_raises(Troupe::CallRejectedError) do
      rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    end
    error.reason.shutdown?.should be_true
  end
end
