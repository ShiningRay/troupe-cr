require "./spec_helper"

# PLAN M3：持久 CueStore/Reminder——归属过滤、至少一次重投与幂等（含反例）。
describe "M3 reminders (Memory)" do
  it "schedule/claim/complete 正常路径：到期才认领，fencing complete 删除" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryReminderStore.new(ownership)
    clock = Troupe::VirtualClock.new
    id = Troupe::ActorId.new("app", "order", "r1")

    store.schedule(id, "retry-1", "on_reminder", JSON.parse(%({"attempt": 1})), clock.now + 10.seconds)
    store.claim_due(clock.now, "node-a", 30.seconds, 16).should be_empty # 未到期

    store.mark_owner(id, "node-a")
    claimed = store.claim_due(clock.now + 11.seconds, "node-a", 30.seconds, 16)
    claimed.size.should eq(1)
    record = claimed[0]
    record.turn.should eq("on_reminder")
    record.payload["attempt"].as_i.should eq(1)

    store.complete(id, "retry-1", record.status_version, record.claim_holder.not_nil!).should be_true
    store.find(id, "retry-1").should be_nil # 完成即删除：不再重投
  end

  it "归属过滤：node-b 认领不到 node-a 持有 actor 的 reminder；转移后可认领" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryReminderStore.new(ownership)
    clock = Troupe::VirtualClock.new
    id = Troupe::ActorId.new("app", "order", "owner")

    store.mark_owner(id, "node-a")
    store.schedule(id, "r", "on_reminder", JSON::Any.new(nil), clock.now - 1.seconds)

    store.claim_due(clock.now, "node-b", 30.seconds, 16).should be_empty # 归属 node-a
    claimed = store.claim_due(clock.now, "node-a", 30.seconds, 16)
    claimed.size.should eq(1)

    store.mark_owner(id, "node-b") # 所有权转移（接管）
    store.claim_due(clock.now, "node-a", 30.seconds, 16).should be_empty
    store.claim_due(clock.now, "node-b", 30.seconds, 16).should be_empty # node-a 的认领租期仍有效
    clock.advance(31.seconds)
    store.claim_due(clock.now, "node-a", 30.seconds, 16).should be_empty
    store.claim_due(clock.now, "node-b", 30.seconds, 16).size.should eq(1)
  end

  it "至少一次：交付失败 release 后立即重投；认领者宕机租期过期后他人重投" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryReminderStore.new(ownership)
    clock = Troupe::VirtualClock.new
    id = Troupe::ActorId.new("app", "order", "alo")

    store.mark_owner(id, "node-a")
    store.schedule(id, "r", "on_reminder", JSON::Any.new(nil), clock.now)
    first = store.claim_due(clock.now, "node-a", 5.seconds, 16)[0]

    # 交付失败 → release → 立即可重投（至少一次）
    store.release(id, "r", first.status_version).should be_true
    again = store.claim_due(clock.now, "node-a", 5.seconds, 16)
    again.size.should eq(1)
    # release(+1) 与重投认领(+1) 各自推进 status_version
    again[0].status_version.should eq(first.status_version + 2)

    # 认领者宕机（不再 release/complete）→ 租期过期后他人重投
    sleep_lease = 5.seconds
    store.claim_due(clock.now, "node-b", sleep_lease, 16).should be_empty # node-b 归属不符
    store.mark_owner(id, "node-b")
    store.claim_due(clock.now, "node-b", sleep_lease, 16).should be_empty # 租期未过期
    redelivered = store.claim_due(clock.now + 6.seconds, "node-b", sleep_lease, 16)
    redelivered.size.should eq(1)
    redelivered[0].status_version.should eq(again[0].status_version + 1)
  end

  it "fencing 反例：旧 status_version 的 complete 被拒，提醒不丢" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryReminderStore.new(ownership)
    clock = Troupe::VirtualClock.new
    id = Troupe::ActorId.new("app", "order", "fence")

    store.mark_owner(id, "node-a")
    store.schedule(id, "r", "on_reminder", JSON::Any.new(nil), clock.now)
    first = store.claim_due(clock.now, "node-a", 30.seconds, 16)[0]

    store.release(id, "r", first.status_version) # 重投一轮（version+1）
    second = store.claim_due(clock.now, "node-a", 30.seconds, 16)[0]

    store.complete(id, "r", first.status_version, "node-a").should be_false # 旧版本删除无效
    store.find(id, "r").should_not be_nil                                   # 提醒仍在：不丢
    store.complete(id, "r", second.status_version, second.claim_holder.not_nil!).should be_true
    store.find(id, "r").should be_nil
  end

  it "cancel：已取消的 reminder 不再投递" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryReminderStore.new(ownership)
    clock = Troupe::VirtualClock.new
    id = Troupe::ActorId.new("app", "order", "cxl")

    store.schedule(id, "r", "on_reminder", JSON::Any.new(nil), clock.now)
    store.cancel(id, "r").should be_true
    store.cancel(id, "r").should be_false
    store.mark_owner(id, "node-a")
    store.claim_due(clock.now, "node-a", 30.seconds, 16).should be_empty
  end

  it "Runner：到期交付为普通 Turn，成功 complete 不重投；失败 release 重投（Memory+VirtualClock 确定性）" do
    rehearsal = Troupe::Rehearsal.new
    id = rehearsal.actor("order", "runner")
    runner = Troupe::ReminderRunner.new(rehearsal.stage, rehearsal.reminders, "rehearsal",
      rehearsal.ownership, poll_interval: 1.second, clock: rehearsal.clock, manual_pump: true)
    rehearsal.stage.register(Troupe::Manifest(CounterProps).define("order", CounterActor) do |m|
      m.schema_version 1
      m.initial { CounterProps.new }
      m.turn "on_reminder", CounterActor do |actor, ctx, args|
        # 前两次投递注入失败（类级投递计数），第三次成功——验证 release→重投→complete
        if CounterActor.reminder_deliveries < 2
          CounterActor.bump_reminder_delivery!
          raise Troupe::SerializationError.new("注入交付失败")
        end
        actor.props.count += args["attempt"].as_i
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)
    CounterActor.reset_reminder_deliveries!

    runner.schedule(id, "retry", "on_reminder", JSON.parse(%({"attempt": 1})),
      due_at: rehearsal.clock.now)

    rehearsal.pump_all
    runner.poll_once # 交付：Turn 抛错 → release
    runner.poll_once # 重投：再失败 → release
    runner.poll_once # 重投：成功 → complete
    rehearsal.pump_all

    CounterProps.from_json(rehearsal.stage.store.read(id).not_nil!.data).count.should eq(1)
    runner.poll_once # 已 complete：不再交付
    rehearsal.pump_all
    CounterProps.from_json(rehearsal.stage.store.read(id).not_nil!.data).count.should eq(1) # 无重复投递
  end
end
