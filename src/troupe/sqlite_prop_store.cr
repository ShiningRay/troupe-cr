require "db"
require "sqlite3"

module Troupe
  # SQLite 开发 Provider 的所有权 store（PLAN M2）。
  # acquire 用单条 INSERT ... ON CONFLICT DO UPDATE RETURNING 保证单调递增并持久化；
  # 与 SQLitePropStore 共享同一 DB 文件，fencing 的真值来源为 troupe_ownership 表。
  class SQLiteOwnershipStore < ::Troupe::OwnershipStore
    @db : ::DB::Database
    @mutex = Mutex.new

    private ACQUIRE_SQL = <<-SQL
      INSERT INTO troupe_ownership (actor_id, epoch) VALUES (?, 1)
      ON CONFLICT(actor_id) DO UPDATE SET epoch = epoch + 1
      RETURNING epoch
    SQL

    def initialize(@db : ::DB::Database)
    end

    def acquire(actor_id : ::Troupe::ActorId) : UInt64
      @mutex.synchronize do
        @db.scalar(ACQUIRE_SQL, actor_id.to_s).as(Int64).to_u64
      end
    end

    def current(actor_id : ::Troupe::ActorId) : UInt64
      @mutex.synchronize do
        value = @db.scalar("SELECT epoch FROM troupe_ownership WHERE actor_id = ?", actor_id.to_s)
        value.nil? ? 0_u64 : value.as(Int64).to_u64
      end
    end

    def renew(actor_id : ::Troupe::ActorId, epoch : UInt64) : Bool
      @mutex.synchronize do
        value = @db.scalar("SELECT epoch FROM troupe_ownership WHERE actor_id = ?", actor_id.to_s)
        !value.nil? && value.as(Int64) == epoch.to_i64
      end
    end
  end

  # SQLite 开发 Provider（PLAN M2，docs/persistence.md Provider 层级）：
  # - 进程/单机持久；**不能跨节点恢复**（cross_node_safe? = false），接管/双活语义必须由 M3
  #   的 PostgreSQL 等 cross_node_safe Provider 证明。
  # - create 为带所有权守卫的原子 INSERT；write 在单事务内完成 Props CAS + 幂等记录
  #   原子提交（任一失败整体回滚）；无应用层先读后写。
  # - WAL 模式 + busy_timeout；失败后按当前行状态诊断并抛出精确错误。
  class SQLitePropStore < ::Troupe::PropStore
    @db : ::DB::Database
    @mutex = Mutex.new

    # 打开（或创建）SQLite 文件数据库并初始化 schema。
    # Windows 绝对路径以三斜杠 URI 形式表达（sqlite3:///C:/x.db，经验证可用）。
    def self.open(path : String, journal_mode : String = "WAL", busy_timeout_ms : String = "5000") : ::Troupe::SQLitePropStore
      uri = "sqlite3:///" + Path.new(path).to_posix.to_s +
            "?journal_mode=#{journal_mode}&busy_timeout=#{busy_timeout_ms}"
      db = ::DB.open(uri)
      SCHEMA_SQL.each { |sql| db.exec(sql) }
      ownership = SQLiteOwnershipStore.new(db)
      new(db, ownership)
    end

    def initialize(@db : ::DB::Database, ownership : ::Troupe::OwnershipStore)
      super(ownership)
    end

    def cross_node_safe? : Bool
      false
    end

    def close : Nil
      @mutex.synchronize { @db.close }
    end

    def read(actor_id : ::Troupe::ActorId) : ::Troupe::PropRecord?
      @mutex.synchronize { read_unlocked(actor_id) }
    end

    def create(actor_id : ::Troupe::ActorId, schema_version : Int32, data : String, epoch : UInt64) : ::Troupe::PropRecord
      @mutex.synchronize do
        result = @db.exec(
          "INSERT OR IGNORE INTO troupe_props (actor_id, revision, schema_version, data, epoch) " \
          "SELECT ?, 1, ?, ?, ? " \
          "WHERE (SELECT epoch FROM troupe_ownership WHERE actor_id = ?) = ?",
          actor_id.to_s, schema_version.to_i64, data, epoch.to_i64, actor_id.to_s, epoch.to_i64
        )
        diagnose(@db, actor_id, epoch, creating: true) if result.rows_affected == 0
        read_unlocked(actor_id).not_nil!
      end
    end

    # Props CAS + 幂等记录 + Outbox 单事务原子提交（docs/persistence.md 失败语义）。
    def write(actor_id : ::Troupe::ActorId, expected_revision : UInt64, schema_version : Int32, data : String,
              epoch : UInt64, idempotency : Array(::Troupe::IdempotencyRecord) = [] of ::Troupe::IdempotencyRecord,
              outbox : Array(::Troupe::OutboxRecord) = [] of ::Troupe::OutboxRecord) : ::Troupe::PropRecord
      @mutex.synchronize do
        @db.transaction do |tx|
          conn = tx.connection
          result = conn.exec(
            "UPDATE troupe_props SET revision = revision + 1, schema_version = ?, data = ?, epoch = ? " \
            "WHERE actor_id = ? AND revision = ? " \
            "AND (SELECT epoch FROM troupe_ownership WHERE actor_id = ?) = ?",
            schema_version.to_i64, data, epoch.to_i64, actor_id.to_s, expected_revision.to_i64, actor_id.to_s, epoch.to_i64
          )
          diagnose(conn, actor_id, epoch, creating: false, expected_revision: expected_revision) if result.rows_affected == 0
          idempotency.each do |entry|
            conn.exec(IDEMPOTENCY_UPSERT, actor_id.to_s, entry.key, entry.fingerprint,
              entry.ok ? 1_i64 : 0_i64, entry.value, entry.error_class, entry.error_message, entry.expires_at)
          end
          outbox.each do |entry|
            conn.exec(OUTBOX_UPSERT, actor_id.to_s, entry.event_id, entry.topic,
              entry.payload.to_json, entry.created_at.to_unix)
          end
          conn.exec("DELETE FROM troupe_idempotency WHERE expires_at <= strftime('%s','now')")
        end
        read_unlocked(actor_id).not_nil!
      end
    end

    def poll_outbox(actor_id : ::Troupe::ActorId, limit : Int32) : Array(::Troupe::OutboxRecord)
      @mutex.synchronize do
        @db.query_all(
          "SELECT event_id, topic, payload, created_at FROM troupe_outbox " \
          "WHERE actor_id = ? AND sent_at IS NULL ORDER BY created_at LIMIT ?",
          actor_id.to_s, limit
        ) do |rs|
          event_id, topic, payload, created_at = rs.read(String, String, String, Int64)
          OutboxRecord.new(actor_id: actor_id, event_id: event_id, topic: topic,
            payload: ::JSON.parse(payload), created_at: ::Time.unix(created_at))
        end
      end
    end

    def mark_sent(actor_id : ::Troupe::ActorId, event_id : String) : Bool
      @mutex.synchronize do
        @db.exec(
          "UPDATE troupe_outbox SET sent_at = strftime('%s','now') " \
          "WHERE actor_id = ? AND event_id = ? AND sent_at IS NULL",
          actor_id.to_s, event_id
        ).rows_affected > 0
      end
    end

    def idempotency(actor_id : ::Troupe::ActorId, now : ::Time) : Array(::Troupe::IdempotencyRecord)
      @mutex.synchronize do
        @db.query_all(
          "SELECT key, fingerprint, ok, value, error_class, error_message, expires_at " \
          "FROM troupe_idempotency WHERE actor_id = ? AND expires_at > ?",
          actor_id.to_s, now.to_unix
        ) do |rs|
          key = rs.read(String)
          fingerprint = rs.read(String)
          ok = rs.read(Int64) != 0
          value = rs.read(String?)
          error_class = rs.read(String?)
          error_message = rs.read(String?)
          expires_at = rs.read(Int64)
          IdempotencyRecord.new(key: key, fingerprint: fingerprint, ok: ok, expires_at: expires_at,
            value: value, error_class: error_class, error_message: error_message)
        end
      end
    end

    private SCHEMA_SQL = [
      "CREATE TABLE IF NOT EXISTS troupe_ownership (actor_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS troupe_props " \
      "(actor_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, schema_version INTEGER NOT NULL, " \
      "data TEXT NOT NULL, epoch INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS troupe_idempotency " \
      "(actor_id TEXT NOT NULL, key TEXT NOT NULL, fingerprint TEXT NOT NULL, ok INTEGER NOT NULL, " \
      "value TEXT, error_class TEXT, error_message TEXT, expires_at INTEGER NOT NULL, " \
      "PRIMARY KEY (actor_id, key))",
      "CREATE TABLE IF NOT EXISTS troupe_outbox " \
      "(actor_id TEXT NOT NULL, event_id TEXT NOT NULL, topic TEXT NOT NULL, payload TEXT NOT NULL, " \
      "created_at INTEGER NOT NULL, sent_at INTEGER, " \
      "PRIMARY KEY (actor_id, event_id))",
    ]

    private IDEMPOTENCY_UPSERT = <<-SQL
      INSERT INTO troupe_idempotency
        (actor_id, key, fingerprint, ok, value, error_class, error_message, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(actor_id, key) DO UPDATE SET
        fingerprint = excluded.fingerprint, ok = excluded.ok, value = excluded.value,
        error_class = excluded.error_class, error_message = excluded.error_message,
        expires_at = excluded.expires_at
    SQL

    private OUTBOX_UPSERT = <<-SQL
      INSERT INTO troupe_outbox
        (actor_id, event_id, topic, payload, created_at, sent_at)
      VALUES (?, ?, ?, ?, ?, NULL)
      ON CONFLICT(actor_id, event_id) DO UPDATE SET
        topic = excluded.topic, payload = excluded.payload, sent_at = NULL,
        created_at = excluded.created_at
    SQL

    private def read_unlocked(actor_id : ::Troupe::ActorId) : ::Troupe::PropRecord?
      @db.query_one?(
        "SELECT revision, schema_version, data, epoch FROM troupe_props WHERE actor_id = ?",
        actor_id.to_s
      ) do |rs|
        revision, schema_version, data, epoch = rs.read(Int64, Int64, String, Int64)
        PropRecord.new(revision.to_u64, schema_version.to_i32, data, epoch.to_u64)
      end
    end

    # 0 行受影响后的精确诊断：fencing 优先于 CAS（docs/persistence.md）。
    private def diagnose(q : ::DB::Database | ::DB::Connection, actor_id : ::Troupe::ActorId, epoch : UInt64,
                         creating : Bool, expected_revision : UInt64 = 0_u64) : NoReturn
      current = q.scalar("SELECT epoch FROM troupe_ownership WHERE actor_id = ?", actor_id.to_s)
      if current.nil? || current.as(Int64) != epoch.to_i64
        shown = current.nil? ? "无所有权记录" : "epoch #{current.as(Int64)}"
        raise CallRejectedError.new("epoch #{epoch} 未取得或已被取代（当前 #{shown}），拒绝写 Actor #{actor_id}", :ownership, false)
      end
      record = q.query_one?("SELECT revision FROM troupe_props WHERE actor_id = ?", actor_id.to_s) { |rs| rs.read(Int64) }
      if record.nil?
        raise ConflictError.new("Actor #{actor_id} 的 Props 不存在", :revision)
      end
      if creating
        raise ConflictError.new("Actor #{actor_id} 的 Props 已存在", :exists)
      end
      if record.to_u64 != expected_revision
        raise ConflictError.new("revision 冲突：期望 #{expected_revision}，实际 #{record}（Actor #{actor_id}）", :revision)
      end
      raise ConflictError.new("Actor #{actor_id} 的写入未能生效（未知原因）", :revision)
    end
  end
end
