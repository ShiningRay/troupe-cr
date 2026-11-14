require "./spec_helper"

# PLAN M3 第一项：PostgreSQL Props/Ownership Provider（事务、CAS、lease、单调 epoch 与 fencing）。
# 需要 TROUPE_PG_URL（本机 troupe-pg 容器：postgres://troupe:troupe@127.0.0.1:55444/troupe；
# 或 CI postgres service）。未设置时标记 pending，不伪造绿灯。
PG_URL = ENV["TROUPE_PG_URL"]?

describe "PostgreSQL Provider" do
  if pg_url = PG_URL
    it "契约：create/CAS 与 Memory 一致，cross_node_safe? = true" do
      store = Troupe::PostgreSQLPropStore.open(pg_url, "spec-a-#{Random.new.next_int}")
      id = Troupe::ActorId.new("spec", "r", "1-#{Random.new.next_int}")
      epoch = store.ownership.acquire(id)

      store.create(id, 1, %({"count":0}), epoch).revision.should eq(1_u64)
      expect_raises(Troupe::ConflictError, "已存在") do
        store.create(id, 1, %({"count":0}), epoch)
      end
      store.write(id, 1_u64, 1, %({"count":1}), epoch).revision.should eq(2_u64)
      expect_raises(Troupe::ConflictError, "revision 冲突") do
        store.write(id, 1_u64, 1, %({"count":2}), epoch)
      end
      store.cross_node_safe?.should be_true
      store.close
    end

    it "旧 epoch 写拒绝（fencing 优先，即使 revision 匹配）" do
      store = Troupe::PostgreSQLPropStore.open(pg_url, "spec-a-#{Random.new.next_int}")
      id = Troupe::ActorId.new("spec", "r", "fence-#{Random.new.next_int}")
      old_epoch = store.ownership.acquire(id)
      store.create(id, 1, %({"count":0}), old_epoch)
      new_epoch = store.ownership.acquire(id) # 同实例重入：epoch 单调 +1

      error = expect_raises(Troupe::CallRejectedError) do
        store.write(id, 1_u64, 1, %({"count":99}), old_epoch)
      end
      error.reason.ownership?.should be_true
      store.write(id, 1_u64, 1, %({"count":1}), new_epoch).revision.should eq(2_u64)
      store.close
    end

    it "lease：其他实例有效租期内 acquire 被拒；过期后可取得且 epoch 单调" do
      store_a = Troupe::PostgreSQLPropStore.open(pg_url, "spec-node-a", lease_ms: 800)
      store_b = Troupe::PostgreSQLPropStore.open(pg_url, "spec-node-b", lease_ms: 800)
      id = Troupe::ActorId.new("spec", "r", "lease-#{Random.new.next_int}")

      epoch_a = store_a.ownership.acquire(id)
      store_a.create(id, 1, %({"count":0}), epoch_a)
      error = expect_raises(Troupe::CallRejectedError) do
        store_b.ownership.acquire(id) # A 的租期仍有效
      end
      error.retryable.should be_true
      store_a.ownership.renew(id, epoch_a).should be_true # 同 epoch 续租
      store_b.ownership.current(id).should eq(epoch_a)    # epoch 未被 B 改动

      sleep(1.seconds) # 租期过期（数据库时钟判定）
      epoch_b = store_b.ownership.acquire(id)
      epoch_b.should be > epoch_a                          # 单调递增
      store_b.ownership.renew(id, epoch_a).should be_false # 旧 epoch 续租失败

      error = expect_raises(Troupe::CallRejectedError) do
        store_a.write(id, 1_u64, 1, %({"count":99}), epoch_a) # 旧 epoch 写拒绝
      end
      error.reason.ownership?.should be_true
      store_b.write(id, 1_u64, 1, %({"count":1}), epoch_b).revision.should eq(2_u64)
      store_a.close
      store_b.close
    end

    it "幂等记录与 Props 单事务原子提交（PG）" do
      store = Troupe::PostgreSQLPropStore.open(pg_url, "spec-a-#{Random.new.next_int}")
      id = Troupe::ActorId.new("spec", "r", "atomic-#{Random.new.next_int}")
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
    end

    it "Stage 端到端：真实 PG 快照 + fencing 失效后从已提交快照恢复" do
      store = Troupe::PostgreSQLPropStore.open(pg_url, "spec-a-#{Random.new.next_int}", lease_ms: 600)
      stage = Troupe::Stage.new(store: store, ownership: store.ownership)
      TroupeFixtures.register_counter(stage)
      id = Troupe::ActorId.new("spec", "counter", "e2e-#{Random.new.next_int}")

      first = stage.call(id, "increment", TroupeFixtures.counter_args(1))
      first.await.as_i.should eq(1)

      # 等 A 节点租期过期，模拟另一节点取得所有权并提交新状态
      sleep(1.seconds)
      record = store.read(id).not_nil!
      other = Troupe::PostgreSQLPropStore.open(pg_url, "spec-node-other", lease_ms: 600)
      new_epoch = other.ownership.acquire(id)
      other.write(id, record.revision, record.schema_version, %({"count":50}), new_epoch)

      stale = stage.call(id, "increment", TroupeFixtures.counter_args(1))
      error = expect_raises(Troupe::CallRejectedError) { stale.await }
      error.reason.ownership?.should be_true # 旧 epoch（且租期失效）写被拒 → 实例失效

      sleep(1.seconds) # 等 other 节点租期过期，本节点才能重新取得所有权
      fresh = stage.call(id, "increment", TroupeFixtures.counter_args(1))
      fresh.await.as_i.should eq(51) # 重新激活，从 PG 已提交快照继续
      stage.shutdown
      store.close
      other.close
    end
  else
    pending "PostgreSQL 验收：设置 TROUPE_PG_URL（本机 troupe-pg 容器或 CI service）后运行"
  end
end
