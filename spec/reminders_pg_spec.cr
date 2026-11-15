require "./spec_helper"

# PLAN M3：PostgreSQL 持久 CueStore 契约（归属过滤、至少一次、fencing）。
# 需要 TROUPE_PG_URL；未设置时 pending。
PG_R_URL = ENV["TROUPE_PG_URL"]?

describe "PostgreSQL reminders" do
  if pg_url = PG_R_URL
    it "schedule/claim/complete：到期才认领，fencing complete 删除" do
      prop = Troupe::PostgreSQLPropStore.open(pg_url, "rem-a-#{Random.new.next_int}", lease_ms: 1200)
      ownership = prop.ownership.as(Troupe::PostgreSQLOwnershipStore)
      rem = Troupe::PostgreSQLReminderStore.open(pg_url)
      id = Troupe::ActorId.new("rem", "r", "ok-#{Random.new.next_int}")
      ownership.acquire(id) # 产生归属（owner_instance = 本 store 实例）

      rem.schedule(id, "r", "on_reminder", JSON.parse(%({"a": 1})), ::Time.utc - 1.seconds)
      rem.claim_due(::Time.utc, "other-node", 30.seconds, 16).should be_empty # 归属过滤

      claimed = rem.claim_due(::Time.utc, ownership.instance_name, 30.seconds, 16)
      claimed.size.should eq(1)
      record = claimed[0]

      rem.complete(id, "r", record.status_version, record.claim_holder.not_nil!).should be_true
      rem.find(id, "r").should be_nil
      prop.close
      rem.close
    end

    it "lease：认领租期内他人不可认领；过期后可重投（至少一次）" do
      prop = Troupe::PostgreSQLPropStore.open(pg_url, "rem-a-#{Random.new.next_int}", lease_ms: 1200)
      ownership = prop.ownership.as(Troupe::PostgreSQLOwnershipStore)
      rem = Troupe::PostgreSQLReminderStore.open(pg_url)
      id = Troupe::ActorId.new("rem", "r", "lease-#{Random.new.next_int}")
      ownership.acquire(id)

      rem.schedule(id, "r", "on_reminder", JSON::Any.new(nil), ::Time.utc - 1.seconds)
      first = rem.claim_due(::Time.utc, ownership.instance_name, 800.milliseconds, 16)[0]

      rem.claim_due(::Time.utc, ownership.instance_name, 30.seconds, 16).should be_empty # 租期内不重复认领

      sleep(1.seconds) # 认领租期过期 → 重投（至少一次；认领者未 complete）
      redelivered = rem.claim_due(::Time.utc, ownership.instance_name, 30.seconds, 16)
      redelivered.size.should eq(1)
      redelivered[0].status_version.should eq(first.status_version + 1)

      # 旧 status_version 的 complete 被拒（fencing），提醒不丢
      rem.complete(id, "r", first.status_version, first.claim_holder.not_nil!).should be_false
      rem.find(id, "r").should_not be_nil
      prop.close
      rem.close
    end

    it "cancel：已取消的 reminder 不再认领" do
      prop = Troupe::PostgreSQLPropStore.open(pg_url, "rem-a-#{Random.new.next_int}", lease_ms: 1200)
      ownership = prop.ownership.as(Troupe::PostgreSQLOwnershipStore)
      rem = Troupe::PostgreSQLReminderStore.open(pg_url)
      id = Troupe::ActorId.new("rem", "r", "cxl-#{Random.new.next_int}")
      ownership.acquire(id)
      rem.schedule(id, "r", "on_reminder", JSON::Any.new(nil), ::Time.utc - 1.seconds)
      rem.cancel(id, "r").should be_true
      rem.claim_due(::Time.utc, ownership.instance_name, 30.seconds, 16).should be_empty
      prop.close
      rem.close
    end
  else
    pending "PostgreSQL reminders：设置 TROUPE_PG_URL 后运行"
  end
end
