require "./spec_helper"

# PLAN M2 第二项：UnknownOutcome、幂等请求记录、迁移、取消、backpressure 语义（含反例）。
describe "M2 semantics" do
  # ---- 幂等（Memory / Rehearsal 确定性） ----
  it "幂等：同键同指纹重放首次结果，不重复执行副作用" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_idem(rehearsal.stage)
    id = rehearsal.actor("order", "replay")
    args = JSON.parse(%({"order_id": "o-1", "amount": 5}))

    first = rehearsal.agent.call(id, "charge", args)
    rehearsal.pump_all
    first.await.as_i.should eq(5)

    second = rehearsal.agent.call(id, "charge", args)
    rehearsal.pump_all
    second.await.as_i.should eq(5) # 重放
    IdemProps.from_json(rehearsal.store.read(id).not_nil!.data).charged.should eq(5)
  end

  it "幂等：同键不同指纹拒绝（IdempotencyConflictError），状态不变" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_idem(rehearsal.stage)
    id = rehearsal.actor("order", "conflict")

    first = rehearsal.agent.call(id, "charge", JSON.parse(%({"order_id": "o-1", "amount": 5})))
    rehearsal.pump_all
    first.await.as_i.should eq(5)

    second = rehearsal.agent.call(id, "charge", JSON.parse(%({"order_id": "o-1", "amount": 9})))
    rehearsal.pump_all
    error = expect_raises(Troupe::IdempotencyConflictError) { second.await }
    error.message.not_nil!.should contain("不同参数指纹")
    IdemProps.from_json(rehearsal.store.read(id).not_nil!.data).charged.should eq(5)
  end

  it "幂等：失败也记录，重放按记录重抛；Props 保持未提交" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_idem(rehearsal.stage)
    id = rehearsal.actor("order", "fail")
    args = JSON.parse(%({"order_id": "o-2", "amount": 3, "fail": true}))

    first = rehearsal.agent.call(id, "charge", args)
    rehearsal.pump_all
    expect_raises(Troupe::SerializationError, "注入扣款失败") { first.await }

    retry_call = rehearsal.agent.call(id, "charge", args)
    rehearsal.pump_all
    error = expect_raises(::Exception) { retry_call.await }
    error.message.not_nil!.should contain("幂等重放")
    IdemProps.from_json(rehearsal.store.read(id).not_nil!.data).charged.should eq(0)
  end

  it "幂等：保留期过期后同键视为新操作" do
    rehearsal = Troupe::Rehearsal.new("rehearsal",
      config: Troupe::StageConfig.new(idempotency_retention: 1.seconds))
    TroupeFixtures.register_idem(rehearsal.stage)
    id = rehearsal.actor("order", "expiry")
    args = JSON.parse(%({"order_id": "o-3", "amount": 5}))

    first = rehearsal.agent.call(id, "charge", args)
    rehearsal.pump_all
    first.await.as_i.should eq(5)

    rehearsal.advance(2.seconds)
    second = rehearsal.agent.call(id, "charge", args)
    rehearsal.pump_all
    second.await.as_i.should eq(10) # 重新执行
    IdemProps.from_json(rehearsal.store.read(id).not_nil!.data).charged.should eq(10)
  end

  it "幂等记录与 Props 原子提交：write 失败时记录不生效（Memory）" do
    store = Troupe::MemoryPropStore.new(Troupe::MemoryOwnershipStore.new)
    id = Troupe::ActorId.new("ns", "r", "atomic")
    epoch = store.ownership.acquire(id)
    store.create(id, 1, %({"count":0}), epoch)
    record = Troupe::IdempotencyRecord.new(key: "k", fingerprint: "f", ok: true,
      expires_at: 9_999_999_999_i64, value: "1")

    # revision 不匹配 → 提交失败 → 幂等记录不落盘（原子性）
    expect_raises(Troupe::ConflictError) do
      store.write(id, 99_u64, 1, "{}", epoch, [record])
    end
    store.idempotency(id, Time.utc).should be_empty

    store.write(id, 1_u64, 1, "{}", epoch, [record])
    store.idempotency(id, Time.utc).size.should eq(1)
  end

  # ---- 取消（协作式，Rehearsal 确定性） ----
  it "取消：Turn 观察到 cancel_requested? 提前收束并提交部分状态" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_loop(rehearsal.stage)
    id = rehearsal.actor("loop", "cooperative")

    future = rehearsal.agent.call(id, "steps", JSON.parse(%({"max": 100})))
    future.cancel.should be_true
    rehearsal.pump(id).should eq(:executed)
    future.await.as_i.should eq(0) # 立即看到取消标志
    LoopProps.from_json(rehearsal.store.read(id).not_nil!.data).count.should eq(0)
  end

  it "取消：不观察信号的 Turn 不可强行终止，完整执行并提交" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_loop(rehearsal.stage)
    id = rehearsal.actor("loop", "ignorant")

    future = rehearsal.agent.call(id, "full", JSON.parse(%({"max": 7})))
    future.cancel.should be_true
    rehearsal.pump(id).should eq(:executed)
    future.await.as_i.should eq(7) # 完整执行
    LoopProps.from_json(rehearsal.store.read(id).not_nil!.data).count.should eq(7)
  end

  it "取消：已 settle 的 future 上 cancel 无效果" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_loop(rehearsal.stage)
    id = rehearsal.actor("loop", "settled")

    future = rehearsal.agent.call(id, "full", JSON.parse(%({"max": 3})))
    rehearsal.pump(id).should eq(:executed)
    future.await
    future.cancel.should be_false
  end

  # ---- backpressure：预算释放与可重试 ----
  it "背压：Turn settle 后队列预算释放，被拒调用可重试成功" do
    rehearsal = Troupe::Rehearsal.new("rehearsal", config: Troupe::StageConfig.new(max_queue_depth: 2))
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "release")

    rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    error = expect_raises(Troupe::CallRejectedError) do
      rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    end
    error.reason.backpressure?.should be_true
    error.retryable.should be_true

    rehearsal.pump(id).should eq(:executed)
    third = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    third.await.as_i.should eq(3) # 重试成功，与被拒的那次内容相同
    CounterProps.from_json(rehearsal.store.read(id).not_nil!.data).count.should eq(3)
  end

  # ---- UnknownOutcome（fiber 模式真实并发） ----
  it "UnknownOutcome：执行超时调用方得 :executing，旧 Turn 占用通道至 settle、效果提交、不自动重试" do
    GateActor.reset!
    stage = Troupe::Stage.new(config: Troupe::StageConfig.new(default_call_deadline: 150.milliseconds))
    stage.register(Troupe::Manifest(GateProps).define("gate", GateActor) do |m|
      m.schema_version 1
      m.initial { GateProps.new }
      m.turn "block_then_count", GateActor do |actor, ctx, args|
        GateActor.gate.receive # 阻塞直到测试放行
        GateActor.record_execution
        old = actor.props.count
        actor.props.count = old + 1
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
      m.turn "count", GateActor do |actor, ctx, args|
        old = actor.props.count
        actor.props.count = old + 1
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)
    id = Troupe::ActorId.new("app", "gate", "uo")

    future = stage.call(id, "block_then_count")
    error = expect_raises(Troupe::CallTimeoutError) { future.await }
    error.phase.executing?.should be_true

    GateActor.gate.send(nil) # 放行原 Turn，使其 settle 并提交
    50.times do
      break if stage.store.read(id).try(&.revision) == 2_u64
      sleep(20.milliseconds)
    end
    record = stage.store.read(id).not_nil!
    record.revision.should eq(2_u64)
    GateProps.from_json(record.data).count.should eq(1) # 结果未知 ≠ 失败：效果已提交
    GateActor.executions.should eq(1)                   # 框架不自动重试

    # 旧 Turn settle 之后，下一 Turn 才执行（执行占用保持）
    next_future = stage.call(id, "count")
    next_future.await.as_i.should eq(2)
  end

  # ---- 迁移 + SQLite 重开 ----
  it "SQLite：重开后 v1 存量逐级迁移到 v3 并持久化" do
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      id = Troupe::ActorId.new("app", "cart", "mig-ok")
      epoch = store.ownership.acquire(id)
      v1 = CartPropsV1.new
      v1.items = ["apple"]
      store.create(id, 1, v1.to_json, epoch)
      store.close

      reopened = Troupe::SQLitePropStore.open(path)
      stage = Troupe::Stage.new(store: reopened, ownership: reopened.ownership)
      TroupeFixtures.register_cart(stage)
      call = stage.call(id, "add_item", JSON.parse(%({"item": "pear"})))
      call.await.as_i.should eq(2)
      stage.shutdown
      reopened.close

      final = Troupe::SQLitePropStore.open(path)
      record = final.read(id).not_nil!
      record.schema_version.should eq(3)
      record.revision.should eq(3_u64) # v1 种子(1) + 迁移提交(2) + add_item(3)
      props = CartPropsV3.from_json(record.data)
      props.items.should eq(["apple", "pear"])
      final.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "SQLite：迁移失败不写，重开后 store 保持 v1 原样" do
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      id = Troupe::ActorId.new("app", "cart", "mig-bad")
      epoch = store.ownership.acquire(id)
      v1 = CartPropsV1.new
      v1.items = ["apple"]
      store.create(id, 1, v1.to_json, epoch)
      store.close

      reopened = Troupe::SQLitePropStore.open(path)
      stage = Troupe::Stage.new(store: reopened, ownership: reopened.ownership)
      bad_step = Troupe::MigrationStep(CartPropsV1, CartPropsV2).new(1, 2) do |_v1|
        raise Troupe::SerializationError.new("迁移注入失败")
      end
      TroupeFixtures.register_cart(stage, steps: [bad_step, TroupeFixtures.cart_step_2_3])

      call = stage.call(id, "add_item", JSON.parse(%({"item": "pear"})))
      expect_raises(Troupe::ActivationError, "迁移 1→2 失败") { call.await }
      stage.shutdown
      reopened.close

      final = Troupe::SQLitePropStore.open(path)
      record = final.read(id).not_nil!
      record.schema_version.should eq(1)
      record.revision.should eq(1_u64) # 零写入
      CartPropsV1.from_json(record.data).items.should eq(["apple"])
      final.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  # ---- SQLite 幂等：事务原子性 + 重开重放 ----
  it "SQLite：幂等记录与 Props 单事务原子提交，失败整体回滚" do
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      id = Troupe::ActorId.new("ns", "r", "atomic-sqlite")
      epoch = store.ownership.acquire(id)
      store.create(id, 1, %({"count":0}), epoch)
      record = Troupe::IdempotencyRecord.new(key: "k", fingerprint: "f", ok: true,
        expires_at: 9_999_999_999_i64, value: "1")

      expect_raises(Troupe::ConflictError) do
        store.write(id, 99_u64, 1, "{}", epoch, [record]) # revision 冲突 → 事务回滚
      end
      store.idempotency(id, Time.utc).should be_empty

      store.write(id, 1_u64, 1, "{}", epoch, [record])
      store.idempotency(id, Time.utc).size.should eq(1)
      store.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "SQLite：重开后幂等键重放（记录持久化）" do
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      stage = Troupe::Stage.new(store: store, ownership: store.ownership)
      TroupeFixtures.register_idem(stage)
      id = Troupe::ActorId.new("app", "order", "persist")
      args = JSON.parse(%({"order_id": "o-9", "amount": 4}))

      first = stage.call(id, "charge", args)
      first.await.as_i.should eq(4)
      stage.shutdown
      store.close

      reopened = Troupe::SQLitePropStore.open(path)
      stage2 = Troupe::Stage.new(store: reopened, ownership: reopened.ownership)
      TroupeFixtures.register_idem(stage2)
      second = stage2.call(id, "charge", args)
      second.await.as_i.should eq(4) # 重开重放，不重复执行
      IdemProps.from_json(reopened.read(id).not_nil!.data).charged.should eq(4)
      stage2.shutdown
      reopened.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
