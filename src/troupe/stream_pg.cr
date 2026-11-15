require "db"
require "pg"
require "./stream"

module Troupe
  # PostgreSQL 持久流 Provider（PLAN M5 首项）。
  # - 事件日志：troupe_stream(topic, seq, payload, created_at)；seq 为全局序列
  #   （PostgreSQL SEQUENCE 单调持久），per-topic 亦单调——保序读取；
  # - 游标：troupe_stream_cursor(consumer, topic, seq)，ack 用 GREATEST 只前进；
  # - 保留：retain_before 单条 DELETE（慢消费者被裁事件不可重放——显式代价）。
  class PostgreSQLStreamStore < ::Troupe::StreamStore
    @db : ::DB::Database
    @mutex = Mutex.new

    def self.open(url : String) : ::Troupe::PostgreSQLStreamStore
      db = ::DB.open(url)
      SCHEMA_SQL.each { |sql| db.exec(sql) }
      new(db)
    end

    def initialize(@db : ::DB::Database)
    end

    def close : Nil
      @mutex.synchronize { @db.close }
    end

    def append(topic : String, payload : ::JSON::Any) : ::UInt64
      @mutex.synchronize do
        @db.scalar(APPEND_SQL, topic, payload.to_json, ::Time.utc).as(Int64).to_u64
      end
    end

    def read_from(topic : String, from_seq : ::UInt64, limit : Int32) : Array(::Troupe::StreamEvent)
      @mutex.synchronize do
        @db.query_all(
          "SELECT seq, payload, created_at FROM troupe_stream " \
          "WHERE topic = $1 AND seq > $2 ORDER BY seq LIMIT $3",
          topic, from_seq.to_i64, limit
        ) do |rs|
          seq, payload, created_at = rs.read(Int64, String, ::Time)
          StreamEvent.new(topic: topic, seq: seq.to_u64, payload: ::JSON.parse(payload), created_at: created_at)
        end
      end
    end

    def ack(consumer : String, topic : String, seq : ::UInt64) : Bool
      @mutex.synchronize do
        rows = @db.exec(CURSOR_ACK_SQL, consumer, topic, seq.to_i64).rows_affected
        rows > 0
      end
    end

    def cursor(consumer : String, topic : String) : ::UInt64
      @mutex.synchronize do
        @db.query_one?("SELECT seq FROM troupe_stream_cursor WHERE consumer = $1 AND topic = $2",
          consumer, topic) { |rs| rs.read(Int64) }.try(&.to_u64) || 0_u64
      end
    end

    def retain_before(topic : String, min_seq : ::UInt64) : Int32
      @mutex.synchronize do
        @db.exec("DELETE FROM troupe_stream WHERE topic = $1 AND seq <= $2",
          topic, min_seq.to_i64).rows_affected.to_i32
      end
    end

    def event_count(topic : String) : Int32
      @mutex.synchronize do
        @db.scalar("SELECT COUNT(*) FROM troupe_stream WHERE topic = $1", topic).as(Int64).to_i32
      end
    end

    private SCHEMA_SQL = [
      "CREATE SEQUENCE IF NOT EXISTS troupe_stream_seq",
      "CREATE TABLE IF NOT EXISTS troupe_stream " \
      "(topic TEXT NOT NULL, seq BIGINT NOT NULL, payload TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL)",
      "CREATE INDEX IF NOT EXISTS troupe_stream_topic_seq_idx ON troupe_stream (topic, seq)",
      "CREATE TABLE IF NOT EXISTS troupe_stream_cursor " \
      "(consumer TEXT NOT NULL, topic TEXT NOT NULL, seq BIGINT NOT NULL, " \
      "PRIMARY KEY (consumer, topic))",
    ]

    private APPEND_SQL = <<-SQL
      INSERT INTO troupe_stream (topic, seq, payload, created_at)
      VALUES ($1, nextval('troupe_stream_seq'), $2, $3)
      RETURNING seq
    SQL

    # GREATEST 只前进：回退 ack 不生效（rows_affected=0 → false）
    private CURSOR_ACK_SQL = <<-SQL
      INSERT INTO troupe_stream_cursor (consumer, topic, seq) VALUES ($1, $2, $3)
      ON CONFLICT (consumer, topic) DO UPDATE SET seq = GREATEST(troupe_stream_cursor.seq, EXCLUDED.seq)
      WHERE EXCLUDED.seq > troupe_stream_cursor.seq
    SQL
  end
end
