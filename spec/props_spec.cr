require "./spec_helper"

describe Troupe::MemoryPropStore do
  it "create 原子存在检查：重复 create 报 ConflictError(:exists)" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryPropStore.new(ownership)
    id = Troupe::ActorId.new("ns", "r", "1")
    epoch = ownership.acquire(id)

    record = store.create(id, 1, %({"count":0}), epoch)
    record.revision.should eq(1_u64)

    expect_raises(Troupe::ConflictError, "已存在") do
      store.create(id, 1, %({"count":0}), epoch)
    end
  end

  it "write 以 expectedRevision 原子 CAS：不匹配或缺失报 ConflictError(:revision)" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryPropStore.new(ownership)
    id = Troupe::ActorId.new("ns", "r", "1")
    epoch = ownership.acquire(id)
    store.create(id, 1, %({"count":0}), epoch)

    updated = store.write(id, 1_u64, 1, %({"count":1}), epoch)
    updated.revision.should eq(2_u64)

    expect_raises(Troupe::ConflictError, "revision 冲突") do
      store.write(id, 1_u64, 1, %({"count":2}), epoch)
    end

    missing = Troupe::ActorId.new("ns", "r", "missing")
    ownership.acquire(missing)
    expect_raises(Troupe::ConflictError, "不存在") do
      store.write(missing, 1_u64, 1, "{}", ownership.current(missing))
    end
  end

  it "旧 epoch 的写被 fencing 拒绝（CallRejectedError(:ownership)）" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryPropStore.new(ownership)
    id = Troupe::ActorId.new("ns", "r", "1")
    old_epoch = ownership.acquire(id)
    store.create(id, 1, %({"count":0}), old_epoch)
    new_epoch = ownership.acquire(id) # 模拟另一个 owner 取得所有权

    expect_raises(Troupe::CallRejectedError, "取代") do
      store.write(id, 1_u64, 1, %({"count":99}), old_epoch)
    end
    store.write(id, 1_u64, 1, %({"count":1}), new_epoch).revision.should eq(2_u64)
  end

  it "read 返回独立快照：修改解析后的 Props 不影响存储" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryPropStore.new(ownership)
    id = Troupe::ActorId.new("ns", "r", "1")
    epoch = ownership.acquire(id)
    store.create(id, 1, %({"count":7}), epoch)

    first = store.read(id).not_nil!
    parsed = CounterProps.from_json(first.data)
    parsed.count = 100
    parsed.count.should eq(100)

    second = store.read(id).not_nil!
    CounterProps.from_json(second.data).count.should eq(7)
    second.should eq(first)
  end

  it "ownership acquire 单调递增且按 ActorId 隔离" do
    ownership = Troupe::MemoryOwnershipStore.new
    a = Troupe::ActorId.new("ns", "r", "a")
    b = Troupe::ActorId.new("ns", "r", "b")
    ownership.acquire(a).should eq(1_u64)
    ownership.acquire(a).should eq(2_u64)
    ownership.acquire(b).should eq(1_u64)
    ownership.current(a).should eq(2_u64)
  end
end
