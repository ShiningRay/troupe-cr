require "./spec_helper"

# PLAN M5 首项：持久流——事件日志/游标/ack/replay/保留/慢消费者（Memory 契约套件）。
describe "M5 stream (Memory)" do
  it "事件日志保序：seq 单调、读取按 seq 升序" do
    store = Troupe::MemoryStreamStore.new
    seqs = [1, 2, 3].map { |n| store.append("orders", JSON.parse(%({"n": #{n}}))) }
    seqs.should eq([1_u64, 2_u64, 3_u64])

    events = store.read_from("orders", 0_u64, 10)
    events.map(&.seq).should eq([1_u64, 2_u64, 3_u64])
    events.map(&.payload["n"].as_i).should eq([1, 2, 3]) # 保序
  end

  it "ack 游标推进持久化：ack 后 poll 从游标之后开始" do
    store = Troupe::MemoryStreamStore.new
    4.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }
    reader = Troupe::StreamReader.new(store, "worker-1", "orders")

    batch = reader.poll
    batch.map(&.seq).should eq([1_u64, 2_u64, 3_u64, 4_u64]) # 初始游标 0

    reader.ack(2_u64).should be_true # 游标推进到 2
    store.cursor("worker-1", "orders").should eq(2)
    reader.poll.map(&.seq).should eq([3_u64, 4_u64]) # 从游标之后开始

    reader.ack(1_u64).should be_false                # 回退拒绝（只前进）
    reader.poll.map(&.seq).should eq([3_u64, 4_u64]) # 游标未被回退
  end

  it "at-least-once 反例：不 ack → 重放同一批（崩溃/重启后亦然）" do
    store = Troupe::MemoryStreamStore.new
    3.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }
    reader = Troupe::StreamReader.new(store, "worker-1", "orders")

    first = reader.poll.map(&.seq)
    first.should eq([1_u64, 2_u64, 3_u64])
    # 模拟处理崩溃：不 ack，直接再 poll
    reader.poll.map(&.seq).should eq(first) # 重放同一批（at-least-once）
    # 新"进程"（新 reader 实例，同一 consumer 标识）同样重放
    Troupe::StreamReader.new(store, "worker-1", "orders").poll.map(&.seq).should eq(first)
  end

  it "两消费者独立游标：互不影响" do
    store = Troupe::MemoryStreamStore.new
    3.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }
    a = Troupe::StreamReader.new(store, "a", "orders")
    b = Troupe::StreamReader.new(store, "b", "orders")

    a.poll.map(&.seq).should eq([1_u64, 2_u64, 3_u64])
    a.ack(3_u64)

    b.poll.map(&.seq).should eq([1_u64, 2_u64, 3_u64]) # b 游标独立，仍从头
    a.poll.should be_empty                             # a 已 ack 全部
    b.cursor.should eq(0_u64)
    a.cursor.should eq(3_u64)
  end

  it "保留裁剪：keep-last 之外的事件不可重放；慢消费者代价可见" do
    store = Troupe::MemoryStreamStore.new
    6.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }

    # 慢消费者停在 seq=2（长时间未处理）
    slow = Troupe::StreamReader.new(store, "slow", "orders")
    slow.poll

    trimmed = store.retain_before("orders", 4_u64) # 保留 seq>=5
    trimmed.should eq(4)                           # seq 1..4 被裁

    store.event_count("orders").should eq(2)
    slow.poll.map(&.seq).should eq([5_u64, 6_u64]) # 从现存最早之后继续（seq4 已被裁——慢消费者代价：中间事件丢失可见）

    # 已 ack 消费者不受影响（游标 6，无积压）
    fast_reader = Troupe::StreamReader.new(store, "fast", "orders")
    fast_reader.ack(6_u64)
    fast_reader.poll.should be_empty
  end

  it "慢消费者分批：poll limit 生效，append 不被消费阻塞" do
    store = Troupe::MemoryStreamStore.new
    reader = Troupe::StreamReader.new(store, "worker", "orders", limit: 2)
    5.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }

    batch1 = reader.poll
    batch1.map(&.seq).should eq([1_u64, 2_u64]) # limit=2 分批
    batch1.each { |e| reader.ack(e.seq) }

    batch2 = reader.poll
    batch2.map(&.seq).should eq([3_u64, 4_u64])
    batch2.each { |e| reader.ack(e.seq) }

    # append 与消费解耦：消费期间仍可持续追加
    store.append("orders", JSON.parse(%({"n": 6})))
    batch3 = reader.poll
    batch3.map(&.seq).should eq([5_u64, 6_u64])
  end

  it "replay：显式从指定 seq 重放（游标无关）" do
    store = Troupe::MemoryStreamStore.new
    4.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }
    reader = Troupe::StreamReader.new(store, "worker", "orders")
    reader.poll
    reader.ack(4_u64)

    reader.replay(2_u64, 16).map(&.seq).should eq([3_u64, 4_u64]) # 游标无关重放
    reader.replay(0_u64, 16).map(&.seq).should eq([1_u64, 2_u64, 3_u64, 4_u64])
  end

  it "topic 隔离：不同 topic 日志与游标互不影响" do
    store = Troupe::MemoryStreamStore.new
    store.append("orders", JSON.parse(%({"n": 1})))
    store.append("payments", JSON.parse(%({"n": 9})))

    orders = Troupe::StreamReader.new(store, "w", "orders")
    payments = Troupe::StreamReader.new(store, "w", "payments")
    orders.poll.map(&.seq).should eq([1_u64])
    payments.poll.map(&.seq).should eq([2_u64]) # 全局 seq 单调，per-topic 保序
    orders.ack(1_u64)
    payments.cursor.should eq(0_u64) # 游标按 topic 隔离
  end

  it "poll_each：交付回调 + 显式 ack；失败条目不 ack（下轮重投）" do
    store = Troupe::MemoryStreamStore.new
    3.times { |n| store.append("orders", JSON.parse(%({"n": #{n + 1}}))) }
    reader = Troupe::StreamReader.new(store, "w", "orders")

    attempts = 0
    processed = reader.poll_each do |event|
      attempts += 1
      raise Troupe::SerializationError.new("注入失败") if event.seq == 2 # seq2 失败
    end
    processed.should eq(1) # seq1 成功；seq2 失败 → 停止（不越过失败点）

    # 失败条目及其后未处理条目下轮重投（at-least-once）
    reader.poll.map(&.seq).should eq([2_u64, 3_u64])
    processed = reader.poll_each do |event|
      attempts += 1
      processed
    end
    processed.should eq(2) # 二次全成功
  end
end
