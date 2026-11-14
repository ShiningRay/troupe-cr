require "db"
require "pg"

module Troupe
  # PostgreSQL 生产 Provider 的所有权 store（PLAN M3 第一项，docs/persistence.md）。
  #
  # 多节点语义：
  # - 每个进程持独立 owner_instance（构造时给定）；
  # - acquire：其他实例的有效租期内不可取得（显式拒绝）；同实例重入或租期已过期
  #   则单调 epoch+1 取得并续租——epoch 单调递增，fencing 以 troupe_ownership 行为准；
  # - renew：同 epoch 续租（长激活心跳用，M3 后续接入调度循环）；
  # - 租期校验/过期判定全部用数据库服务器时钟（now()），避免客户端时钟漂移。
  class PostgreSQLOwnershipStore < ::Troupe::OwnershipStore
    @db : ::DB::Database
    @owner_instance : String
    @lease_ms : Int64
    @mutex = Mutex.new

    def initialize(@db : ::DB::Database, @owner_instance : String, @lease_ms : Int64)
    end

    private ACQUIRE_SQL = <<-SQL
      INSERT INTO troupe_ownership (actor_id, epoch, owner_instance, lease_expires_at)
      VALUES ($1, 1, $2, now() + ($3 * interval '1 millisecond'))
      ON CONFLICT (actor_id) DO UPDATE SET
        epoch = troupe_ownership.epoch + 1,
        owner_instance = EXCLUDED.owner_instance,
        lease_expires_at = EXCLUDED.lease_expires_at
      WHERE troupe_ownership.lease_expires_at <= now()
         OR troupe_ownership.owner_instance = EXCLUDED.owner_instance
      RETURNING epoch
    SQL

    def acquire(actor_id : ::Troupe::ActorId) : UInt64
      @mutex.synchronize do
        # ON CONFLICT 的 WHERE 守卫不满足时 RETURNING 无行 → query_one? 返回 nil
        epoch = @db.query_one?(ACQUIRE_SQL, actor_id.to_s, @owner_instance, @lease_ms) { |rs| rs.read(Int64) }
        raise CallRejectedError.new(
          "Actor #{actor_id} 的有效租期被其他实例（#{current_holder(actor_id)}）持有，无法取得所有权",
          :ownership, true
        ) if epoch.nil?
        epoch.to_u64
      end
    end

    def current(actor_id : ::Troupe::ActorId) : UInt64
      @mutex.synchronize do
        value = @db.scalar("SELECT epoch FROM troupe_ownership WHERE actor_id = $1", actor_id.to_s)
        value.nil? ? 0_u64 : value.as(Int64).to_u64
      end
    end

    # 同 epoch 续租：租期过期或 epoch 已被取代返回 false（fencing 失效）。
    def renew(actor_id : ::Troupe::ActorId, epoch : UInt64) : Bool
      @mutex.synchronize do
        rows = @db.exec(
          "UPDATE troupe_ownership SET lease_expires_at = now() + ($1 * interval '1 millisecond') " \
          "WHERE actor_id = $2 AND epoch = $3 AND owner_instance = $4",
          @lease_ms, actor_id.to_s, epoch.to_i64, @owner_instance
        ).rows_affected
        rows > 0
      end
    end

    private def current_holder(actor_id : ::Troupe::ActorId) : String
      @db.scalar("SELECT owner_instance FROM troupe_ownership WHERE actor_id = $1", actor_id.to_s).as(String)
    end
  end

  # PostgreSQL 生产 Provider（PLAN M3 第一项，docs/persistence.md Provider 层级）：
  # - **跨节点安全**（cross_node_safe? = true）：Props/所有权/幂等记录共库事务，
  #   CAS 与 fencing 在单条 SQL 内原子完成，租期用数据库时钟；
  # - write 单事务：Props CAS（expectedRevision + epoch + 租期有效）+ 幂等记录 + 过期清理，
  #   任一失败整体回滚；无应用层先读后写；
  # - 旧 epoch 写一律拒绝（fencing 优先），写结果未知由调用方按 UnknownOutcome 语义处理。
  class PostgreSQLPropStore < ::Troupe::PropStore
    @db : ::DB::Database
    @mutex = Mutex.new

    def self.open(url : String, owner_instance : String? = nil, lease_ms : Int64 = 30_000) : ::Troupe::PostgreSQLPropStore
      db = ::DB.open(url)
      SCHEMA_SQL.each { |sql| db.exec(sql) }
      instance = owner_instance || "#{System.hostname}-#{Process.pid}-#{Random::Secure.hex(4)}"
      ownership = PostgreSQLOwnershipStore.new(db, instance, lease_ms)
      new(db, ownership)
    end

    def initialize(@db : ::DB::Database, ownership : ::Troupe::OwnershipStore)
      super(ownership)
    end

    def cross_node_safe? : Bool
      true
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
          "INSERT INTO troupe_props (actor_id, revision, schema_version, data, epoch) " \
          "SELECT $1, 1, $2, $3, $4 " \
          "WHERE (SELECT epoch FROM troupe_ownership WHERE actor_id = $1) = $4 " \
          "  AND (SELECT lease_expires_at FROM troupe_ownership WHERE actor_id = $1) > now() " \
          "ON CONFLICT (actor_id) DO NOTHING",
          actor_id.to_s, schema_version.to_i64, data, epoch.to_i64
        )
        diagnose(@db, actor_id, epoch, creating: true) if result.rows_affected == 0
        read_unlocked(actor_id).not_nil!
      end
    end

    # Props CAS + 幂等记录单事务原子提交（docs/persistence.md 失败语义）。
    # fencing：epoch 与租期有效期都在 UPDATE 的 WHERE 中，旧 epoch / 租期过期一律拒绝。
    def write(actor_id : ::Troupe::ActorId, expected_revision : UInt64, schema_version : Int32, data : String,
              epoch : UInt64, idempotency : Array(::Troupe::IdempotencyRecord) = [] of ::Troupe::IdempotencyRecord) : ::Troupe::PropRecord
      @mutex.synchronize do
        @db.transaction do |tx|
          conn = tx.connection
          result = conn.exec(
            "UPDATE troupe_props SET revision = revision + 1, schema_version = $1, data = $2, epoch = $3 " \
            "WHERE actor_id = $4 AND revision = $5 " \
            "AND (SELECT epoch FROM troupe_ownership WHERE actor_id = troupe_props.actor_id) = $3 " \
            "AND (SELECT lease_expires_at FROM troupe_ownership WHERE actor_id = troupe_props.actor_id) > now()",
            schema_version.to_i64, data, epoch.to_i64, actor_id.to_s, expected_revision.to_i64
          )
          diagnose(conn, actor_id, epoch, creating: false, expected_revision: expected_revision) if result.rows_affected == 0
          idempotency.each do |entry|
            conn.exec(IDEMPOTENCY_UPSERT, actor_id.to_s, entry.key, entry.fingerprint,
              entry.ok, entry.value, entry.error_class, entry.error_message, entry.expires_at)
          end
          conn.exec("DELETE FROM troupe_idempotency WHERE expires_at <= extract(epoch from now())")
        end
        read_unlocked(actor_id).not_nil!
      end
    end

    def idempotency(actor_id : ::Troupe::ActorId, now : ::Time) : Array(::Troupe::IdempotencyRecord)
      @mutex.synchronize do
        @db.query_all(
          "SELECT key, fingerprint, ok, value, error_class, error_message, expires_at " \
          "FROM troupe_idempotency WHERE actor_id = $1 AND expires_at > $2",
          actor_id.to_s, now.to_unix
        ) do |rs|
          key = rs.read(String)
          fingerprint = rs.read(String)
          ok = rs.read(Bool)
          value = rs.read(::String?)
          error_class = rs.read(::String?)
          error_message = rs.read(::String?)
          expires_at = rs.read(Int64)
          IdempotencyRecord.new(key: key, fingerprint: fingerprint, ok: ok, expires_at: expires_at,
            value: value, error_class: error_class, error_message: error_message)
        end
      end
    end

    private SCHEMA_SQL = [
      "CREATE TABLE IF NOT EXISTS troupe_ownership " \
      "(actor_id TEXT PRIMARY KEY, epoch BIGINT NOT NULL, owner_instance TEXT NOT NULL, " \
      "lease_expires_at TIMESTAMPTZ NOT NULL)",
      "CREATE TABLE IF NOT EXISTS troupe_props " \
      "(actor_id TEXT PRIMARY KEY, revision BIGINT NOT NULL, schema_version INTEGER NOT NULL, " \
      "data TEXT NOT NULL, epoch BIGINT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS troupe_idempotency " \
      "(actor_id TEXT NOT NULL, key TEXT NOT NULL, fingerprint TEXT NOT NULL, ok BOOLEAN NOT NULL, " \
      "value TEXT, error_class TEXT, error_message TEXT, expires_at BIGINT NOT NULL, " \
      "PRIMARY KEY (actor_id, key))",
    ]

    private IDEMPOTENCY_UPSERT = <<-SQL
      INSERT INTO troupe_idempotency
        (actor_id, key, fingerprint, ok, value, error_class, error_message, expires_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      ON CONFLICT (actor_id, key) DO UPDATE SET
        fingerprint = EXCLUDED.fingerprint, ok = EXCLUDED.ok, value = EXCLUDED.value,
        error_class = EXCLUDED.error_class, error_message = EXCLUDED.error_message,
        expires_at = EXCLUDED.expires_at
    SQL

    private def read_unlocked(actor_id : ::Troupe::ActorId) : ::Troupe::PropRecord?
      @db.query_one?(
        "SELECT revision, schema_version, data, epoch FROM troupe_props WHERE actor_id = $1",
        actor_id.to_s
      ) do |rs|
        revision, schema_version, data, epoch = rs.read(Int64, Int32, String, Int64)
        PropRecord.new(revision.to_u64, schema_version, data, epoch.to_u64)
      end
    end

    # 0 行受影响后的精确诊断：fencing（epoch/租期）优先于 CAS（docs/persistence.md）。
    private def diagnose(q : ::DB::Database | ::DB::Connection, actor_id : ::Troupe::ActorId, epoch : UInt64,
                         creating : Bool, expected_revision : UInt64 = 0_u64) : NoReturn
      state = q.query_one?(
        "SELECT o.epoch, o.owner_instance, o.lease_expires_at > now(), p.revision " \
        "FROM troupe_ownership o LEFT JOIN troupe_props p ON p.actor_id = o.actor_id " \
        "WHERE o.actor_id = $1",
        actor_id.to_s
      ) do |rs|
        held_epoch = rs.read(Int64)
        holder = rs.read(String)
        lease_valid = rs.read(Bool)
        revision = rs.read(::Int64?)
        {held_epoch, holder, lease_valid, revision}
      end
      if state.nil?
        raise CallRejectedError.new("Actor #{actor_id} 无所有权记录（epoch #{epoch} 未取得），拒绝写入", :ownership, true)
      end
      held_epoch, holder, lease_valid, revision = state
      if held_epoch.to_u64 != epoch
        raise CallRejectedError.new(
          "epoch #{epoch} 已被 epoch #{held_epoch}（#{holder}）取代，拒绝写 Actor #{actor_id}", :ownership, false
        )
      end
      unless lease_valid
        raise CallRejectedError.new("租期已过期（epoch #{epoch}），拒绝写 Actor #{actor_id}，需重新 acquire", :ownership, true)
      end
      if revision.nil?
        raise ConflictError.new("Actor #{actor_id} 的 Props 不存在", :revision)
      end
      if creating
        raise ConflictError.new("Actor #{actor_id} 的 Props 已存在", :exists)
      end
      if revision.to_u64 != expected_revision
        raise ConflictError.new("revision 冲突：期望 #{expected_revision}，实际 #{revision}（Actor #{actor_id}）", :revision)
      end
      raise ConflictError.new("Actor #{actor_id} 的写入未能生效（未知原因）", :revision)
    end
  end
end
