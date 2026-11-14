require "./spec_helper"

# SQLite 开发 Provider（PLAN M2 首项）：契约对齐 Memory，另验证重开恢复；
# 明确 cross_node_safe? = false（不能跨节点恢复）。
describe Troupe::SQLitePropStore do
  it "create 原子存在检查与 write CAS：与 Memory Provider 契约一致" do
    path = TroupeFixtures.temp_db_path
    store = Troupe::SQLitePropStore.open(path)
    begin
      id = Troupe::ActorId.new("ns", "r", "1")
      epoch = store.ownership.acquire(id)

      store.create(id, 1, %({"count":0}), epoch).revision.should eq(1_u64)
      expect_raises(Troupe::ConflictError, "已存在") do
        store.create(id, 1, %({"count":0}), epoch)
      end

      store.write(id, 1_u64, 1, %({"count":1}), epoch).revision.should eq(2_u64)
      expect_raises(Troupe::ConflictError, "revision 冲突") do
        store.write(id, 1_u64, 1, %({"count":2}), epoch) # expected 1 已过期
      end
      store.cross_node_safe?.should be_false
    ensure
      store.close
      File.delete(path) if File.exists?(path)
    end
  end

  it "fencing 优先：旧 epoch 写被拒，即使 revision 匹配" do
    path = TroupeFixtures.temp_db_path
    store = Troupe::SQLitePropStore.open(path)
    begin
      id = Troupe::ActorId.new("ns", "r", "fence")
      old_epoch = store.ownership.acquire(id)
      store.create(id, 1, %({"count":0}), old_epoch)
      store.ownership.acquire(id) # 新 epoch 取代

      error = expect_raises(Troupe::CallRejectedError) do
        store.write(id, 1_u64, 1, %({"count":99}), old_epoch)
      end
      error.reason.ownership?.should be_true
    ensure
      store.close
      File.delete(path) if File.exists?(path)
    end
  end

  it "重开恢复：Props 与 ownership epoch 均持久化（PLAN M2 验收）" do
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      id = Troupe::ActorId.new("ns", "r", "reopen")
      epoch = store.ownership.acquire(id)
      store.create(id, 1, %({"count":7}), epoch)
      store.write(id, 1_u64, 1, %({"count":8}), epoch)
      epoch_before = store.ownership.current(id)
      store.close

      reopened = Troupe::SQLitePropStore.open(path)
      record = reopened.read(id)
      record.should_not be_nil
      record.not_nil!.schema_version.should eq(1)
      record.not_nil!.revision.should eq(2_u64)
      CounterProps.from_json(record.not_nil!.data).count.should eq(8)
      reopened.ownership.current(id).should eq(epoch_before)
      reopened.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "Stage 端到端重启恢复：进程内 shutdown 后重开 Stage 从已提交快照继续" do
    CounterActor.reset_log!
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      stage = Troupe::Stage.new(store: store, ownership: store.ownership)
      TroupeFixtures.register_counter(stage)
      id = Troupe::ActorId.new("app", "counter", "restart")

      first = stage.call(id, "increment", TroupeFixtures.counter_args(5))
      first.await.as_i.should eq(5)
      stage.shutdown
      store.close

      reopened = Troupe::SQLitePropStore.open(path)
      stage2 = Troupe::Stage.new(store: reopened, ownership: reopened.ownership)
      TroupeFixtures.register_counter(stage2)
      second = stage2.call(id, "increment", TroupeFixtures.counter_args(3))
      second.await.as_i.should eq(8) # 从 SQLite 已提交快照 5 继续
      stage2.shutdown
      reopened.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
