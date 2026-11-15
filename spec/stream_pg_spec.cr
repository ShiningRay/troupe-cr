require "./spec_helper"

# PLAN M5 首项：PostgreSQL 持久流 Provider 契约（事件日志/游标/ack/replay/保留）。
# 需要 TROUPE_PG_URL；未设置时 pending。
PG_S_URL = ENV["TROUPE_PG_URL"]?

describe "PostgreSQL stream" do
  if pg_url = PG_S_URL
    it "事件日志保序：全局 seq 单调（跨 topic），读取按 seq 升序" do
      store = Troupe::PostgreSQLStreamStore.open(pg_url)
      begin
        topic = "pg-ord-#{Random.new.next_int}" # 随机 topic：不受跨运行残留影响
        s1 = store.append(topic, JSON.parse(%({"n": 1})))
        s2 = store.append("pg-pay-#{Random.new.next_int}", JSON.parse(%({"n": 9})))
        s3 = store.append(topic, JSON.parse(%({"n": 2})))
        s3.should be > s2
        s2.should be > s1 # 全局 seq 单调

        orders = store.read_from(topic, 0_u64, 10)
        orders.map(&.seq).should eq([s1, s3]) # per-topic 保序（只含本 topic 两事件）
        orders.map(&.payload["n"].as_i).should eq([1, 2])
      ensure
        store.close
      end
    end

    it "游标与 ack：只前进；不 ack 重放（at-least-once）" do
      store = Troupe::PostgreSQLStreamStore.open(pg_url)
      consumer = "pg-w-#{Random.new.next_int}"
      topic = "pg-#{Random.new.next_int}"
      begin
        3.times { |n| store.append(topic, JSON.parse(%({"n": #{n + 1}}))) }
        reader = Troupe::StreamReader.new(store, consumer, topic)

        seqs = reader.poll.map(&.seq)
        seqs.should eq([seqs[0], seqs[0] + 1, seqs[0] + 2]) # 连续三事件（随机 topic 首事件 seq 取决于全局序列）
        reader.ack(seqs[1]).should be_true
        store.cursor(consumer, topic).should eq(seqs[1])
        reader.poll.map(&.seq).should eq([seqs[2]])

        reader.ack(seqs[0]).should be_false # 回退拒绝
        store.cursor(consumer, topic).should eq(seqs[1])

        # 未 ack 重放：新 reader 实例（模拟重启）从游标重放
        Troupe::StreamReader.new(store, consumer, topic).poll.map(&.seq).should eq([seqs[2]])
      ensure
        store.close
      end
    end

    it "保留裁剪：被裁事件不可重放（慢消费者代价显式可见）" do
      store = Troupe::PostgreSQLStreamStore.open(pg_url)
      consumer = "pg-slow-#{Random.new.next_int}"
      topic = "pg-trim-#{Random.new.next_int}"
      begin
        seqs = 4.times.map do |n|
          store.append(topic, JSON.parse(%({"n": #{n + 1}})))
        end.to_a
        base = seqs[0]

        trimmed = store.retain_before(topic, base + 1) # è£ base,base+1 ä¸¤æ¡ # 裁前两条（seq base, base+1）
        trimmed.should eq(2)
        store.event_count(topic).should eq(2)

        reader = Troupe::StreamReader.new(store, consumer, topic)
        reader.poll.map(&.seq).should eq([base + 2, base + 3]) # 从现存最早之后继续
      ensure
        store.close
      end
    end
  else
    pending "PostgreSQL stream：设置 TROUPE_PG_URL 后运行"
  end
end
