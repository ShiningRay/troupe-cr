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
  end

  # SQLite 开发 Provider（PLAN M2 首项，docs/persistence.md Provider 层级）：
  # - 进程/单机持久；**不能跨节点恢复**（cross_node_safe? = false），接管/双活语义必须由 M3
  #   的 PostgreSQL 等 cross_node_safe Provider 证明。
  # - create 为带所有权守卫的原子 INSERT；write 为单条 UPDATE（expectedRevision + epoch
  #   都在 WHERE 内），无应用层先读后写。
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
        diagnose(actor_id, epoch, creating: true) if result.rows_affected == 0
        read_unlocked(actor_id).not_nil!
      end
    end

    def write(actor_id : ::Troupe::ActorId, expected_revision : UInt64, schema_version : Int32, data : String, epoch : UInt64) : ::Troupe::PropRecord
      @mutex.synchronize do
        result = @db.exec(
          "UPDATE troupe_props SET revision = revision + 1, schema_version = ?, data = ?, epoch = ? " \
          "WHERE actor_id = ? AND revision = ? " \
          "AND (SELECT epoch FROM troupe_ownership WHERE actor_id = ?) = ?",
          schema_version.to_i64, data, epoch.to_i64, actor_id.to_s, expected_revision.to_i64, actor_id.to_s, epoch.to_i64
        )
        diagnose(actor_id, epoch, creating: false, expected_revision: expected_revision) if result.rows_affected == 0
        read_unlocked(actor_id).not_nil!
      end
    end

    private SCHEMA_SQL = [
      "CREATE TABLE IF NOT EXISTS troupe_ownership (actor_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS troupe_props " \
      "(actor_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, schema_version INTEGER NOT NULL, " \
      "data TEXT NOT NULL, epoch INTEGER NOT NULL)",
    ]

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
    private def diagnose(actor_id : ::Troupe::ActorId, epoch : UInt64,
                         creating : Bool, expected_revision : UInt64 = 0_u64) : NoReturn
      current = @db.scalar("SELECT epoch FROM troupe_ownership WHERE actor_id = ?", actor_id.to_s)
      if current.nil? || current.as(Int64) != epoch.to_i64
        shown = current.nil? ? "无所有权记录" : "epoch #{current.as(Int64)}"
        raise CallRejectedError.new("epoch #{epoch} 未取得或已被取代（当前 #{shown}），拒绝写 Actor #{actor_id}", :ownership, false)
      end
      record = @db.query_one?("SELECT revision FROM troupe_props WHERE actor_id = ?", actor_id.to_s) { |rs| rs.read(Int64) }
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
