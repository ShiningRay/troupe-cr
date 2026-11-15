module Troupe
  # 持久流（PLAN M5 首项，docs/cluster.md 消息层）：
  # 事件日志（追加写、seq 单调）、per-consumer 持久游标、显式 ack（不 ack 则重放=
  # at-least-once）、保留裁剪（慢消费者代价：被裁事件不可重放）、慢消费者分批拉取。
  # 与 Show realtime 分开：这是持久层，非 fan-out。
  #
  # seq 为全局单调（Provider 保证 per-topic 单调且持久）；游标/ack 按 (consumer, topic)
  # 持久化——进程重启后从未 ack 处重放。
  record StreamEvent,
    topic : String,
    seq : ::UInt64,
    payload : ::JSON::Any,
    created_at : ::Time

  abstract class StreamStore
    # 追加事件；返回持久化 seq（单调递增）。
    abstract def append(topic : String, payload : ::JSON::Any) : ::UInt64

    # 从 from_seq 之后（不含）读取现存事件，至多 limit 条，按 seq 升序。
    abstract def read_from(topic : String, from_seq : ::UInt64, limit : Int32) : Array(::Troupe::StreamEvent)

    # 消费游标持久化（只前进：回退尝试返回 false）。
    abstract def ack(consumer : String, topic : String, seq : ::UInt64) : Bool

    # 消费游标读取；无记录返回 0。
    abstract def cursor(consumer : String, topic : String) : ::UInt64

    # 保留裁剪：丢弃 seq <= min_seq 的事件（慢消费者代价：被裁事件不可重放）。
    abstract def retain_before(topic : String, min_seq : ::UInt64) : Int32

    abstract def event_count(topic : String) : Int32
  end

  # Memory 实现：Rehearsal/单机测试用（语义与 PG 版对齐）。
  class MemoryStreamStore < ::Troupe::StreamStore
    @log = Hash(String, Array(::Troupe::StreamEvent)).new
    @cursors = Hash(String, ::UInt64).new # key: "#{consumer}\u{1}#{topic}"
    @seq : ::UInt64 = 0
    @mutex = Mutex.new

    private def cursor_key(consumer : String, topic : String) : String
      "#{consumer}\u{1}#{topic}"
    end

    def append(topic : String, payload : ::JSON::Any) : ::UInt64
      @mutex.synchronize do
        @seq += 1
        event = StreamEvent.new(topic: topic, seq: @seq, payload: payload, created_at: ::Time.utc)
        (@log[topic] ||= Array(::Troupe::StreamEvent).new) << event
        @seq
      end
    end

    def read_from(topic : String, from_seq : ::UInt64, limit : Int32) : Array(::Troupe::StreamEvent)
      @mutex.synchronize do
        log = @log[topic]?
        return [] of ::Troupe::StreamEvent unless log
        log.select { |e| e.seq > from_seq }.first(limit)
      end
    end

    def ack(consumer : String, topic : String, seq : ::UInt64) : Bool
      key = cursor_key(consumer, topic)
      @mutex.synchronize do
        current = @cursors[key]? || 0_u64
        return false if seq <= current # 只前进：回退拒绝
        @cursors[key] = seq
        true
      end
    end

    def cursor(consumer : String, topic : String) : ::UInt64
      @mutex.synchronize { @cursors[cursor_key(consumer, topic)]? || 0_u64 }
    end

    def retain_before(topic : String, min_seq : ::UInt64) : Int32
      @mutex.synchronize do
        log = @log[topic]?
        return 0 unless log
        before = log.size
        @log[topic] = log.reject { |e| e.seq <= min_seq }
        before - @log[topic].size
      end
    end

    def event_count(topic : String) : Int32
      @mutex.synchronize { @log[topic]?.try(&.size) || 0 }
    end
  end

  # 消费者会话：从持久游标拉取未 ack 事件；显式 ack 推进游标。
  # 不 ack → 下次 poll 重放同一批（at-least-once）。
  class StreamReader
    @store : ::Troupe::StreamStore
    @consumer : String
    @topic : String
    @limit : Int32

    def initialize(@store, @consumer : String, @topic : String, @limit : Int32 = 16)
    end

    # 拉取未 ack 事件（从持久游标之后；慢消费者分批拉取，不阻塞日志与其他消费者）。
    def poll : Array(::Troupe::StreamEvent)
      from = @store.cursor(@consumer, @topic)
      @store.read_from(@topic, from, @limit)
    end

    # 逐条交付回调 + 显式 ack。回调失败 → **停止**：游标停在失败条目之前，
    # 失败条目及其后未处理条目下轮重投（at-least-once 不越过失败点）。
    def poll_each(&handler : ::Troupe::StreamEvent -> Nil) : Int32
      processed = 0
      poll.each do |event|
        begin
          handler.call(event)
        rescue
          break # 失败：游标未越过失败条目，下轮重投（at-least-once）
        end
        @store.ack(@consumer, @topic, event.seq)
        processed += 1
      end
      processed
    end

    # 显式重放：忽略游标，从 from_seq 读取（replay 场景）。
    def replay(from_seq : ::UInt64, limit : Int32 = 1024) : Array(::Troupe::StreamEvent)
      @store.read_from(@topic, from_seq, limit)
    end

    def ack(seq : ::UInt64) : Bool
      @store.ack(@consumer, @topic, seq)
    end

    def cursor : ::UInt64
      @store.cursor(@consumer, @topic)
    end
  end
end
