require "db"
require "pg"
require "./reminders"

module Troupe
  # PostgreSQL 持久 CueStore（PLAN M3，docs/persistence.md Reminders）。
  # - schedule：稳定键 upsert（清认领、status_version+1）；
  # - claim_due：**单条 UPDATE 先按归属过滤（JOIN troupe_ownership.owner_instance）再原子认领**；
  #   无所有权记录的 reminder 任何节点可认领；
  # - complete：fencing 删除（status_version + claim_holder + 租期有效，DB 时钟判定）；
  # - release：认领者放弃（清认领、status_version+1）。
  class PostgreSQLReminderStore < ::Troupe::ReminderStore
    @db : ::DB::Database
    @mutex = Mutex.new

    def self.open(url : String) : ::Troupe::PostgreSQLReminderStore
      db = ::DB.open(url)
      SCHEMA_SQL.each { |sql| db.exec(sql) }
      new(db)
    end

    def initialize(@db : ::DB::Database)
    end

    def close : Nil
      @mutex.synchronize { @db.close }
    end

    def schedule(actor_id : ::Troupe::ActorId, name : String, turn : String,
                 payload : ::JSON::Any, due_at : ::Time) : Nil
      @mutex.synchronize do
        @db.exec(SCHEDULE_SQL, actor_id.to_s, name, turn, payload.to_json, due_at)
      end
    end

    def cancel(actor_id : ::Troupe::ActorId, name : String) : Bool
      @mutex.synchronize do
        @db.exec("DELETE FROM troupe_reminders WHERE actor_id = $1 AND name = $2",
          actor_id.to_s, name).rows_affected > 0
      end
    end

    def claim_due(now : ::Time, owner_instance : String, lease : ::Time::Span,
                  limit : Int32) : Array(::Troupe::ReminderRecord)
      @mutex.synchronize do
        @db.query_all(CLAIM_SQL, owner_instance, lease.total_milliseconds.to_i64, now, limit) do |rs|
          actor_id, name, turn, payload, due_at, claim_holder, claim_expires_at, version =
            rs.read(String, String, String, String, ::Time, ::String?, ::Time?, Int64)
          ReminderRecord.new(actor_id: ::Troupe::ActorId.parse(actor_id), name: name, turn: turn,
            payload: ::JSON.parse(payload), due_at: due_at,
            claim_holder: claim_holder, claim_expires_at: claim_expires_at,
            status_version: version.to_u64)
        end
      end
    end

    def complete(actor_id : ::Troupe::ActorId, name : String, status_version : ::UInt64,
                 claim_holder : String) : Bool
      @mutex.synchronize do
        @db.exec(
          "DELETE FROM troupe_reminders " \
          "WHERE actor_id = $1 AND name = $2 AND status_version = $3 " \
          "AND claim_holder = $4 AND claim_expires_at > now()",
          actor_id.to_s, name, status_version.to_i64, claim_holder
        ).rows_affected > 0
      end
    end

    def release(actor_id : ::Troupe::ActorId, name : String, status_version : ::UInt64) : Bool
      @mutex.synchronize do
        @db.exec(RELEASE_SQL, actor_id.to_s, name, status_version.to_i64).rows_affected > 0
      end
    end

    def find(actor_id : ::Troupe::ActorId, name : String) : ::Troupe::ReminderRecord?
      @mutex.synchronize do
        @db.query_one?(
          "SELECT actor_id, name, turn, payload, due_at, claim_holder, claim_expires_at, status_version " \
          "FROM troupe_reminders WHERE actor_id = $1 AND name = $2",
          actor_id.to_s, name
        ) do |rs|
          aid, name_, turn, payload, due_at, claim_holder, claim_expires_at, version =
            rs.read(String, String, String, String, ::Time, ::String?, ::Time?, Int64)
          ReminderRecord.new(actor_id: ::Troupe::ActorId.parse(aid), name: name_, turn: turn,
            payload: ::JSON.parse(payload), due_at: due_at,
            claim_holder: claim_holder, claim_expires_at: claim_expires_at,
            status_version: version.to_u64)
        end
      end
    end

    private SCHEMA_SQL = [
      "CREATE TABLE IF NOT EXISTS troupe_reminders " \
      "(actor_id TEXT NOT NULL, name TEXT NOT NULL, turn TEXT NOT NULL, payload TEXT NOT NULL, " \
      "due_at TIMESTAMPTZ NOT NULL, claim_holder TEXT, claim_expires_at TIMESTAMPTZ, " \
      "status_version BIGINT NOT NULL DEFAULT 1, PRIMARY KEY (actor_id, name))",
    ]

    private SCHEDULE_SQL = <<-'SQL'
      INSERT INTO troupe_reminders
        (actor_id, name, turn, payload, due_at, claim_holder, claim_expires_at, status_version)
      VALUES ($1, $2, $3, $4, $5, NULL, NULL, 1)
      ON CONFLICT (actor_id, name) DO UPDATE SET
        turn = EXCLUDED.turn, payload = EXCLUDED.payload, due_at = EXCLUDED.due_at,
        claim_holder = NULL, claim_expires_at = NULL,
        status_version = troupe_reminders.status_version + 1
    SQL

    # 归属过滤 + 原子认领：仅认领 troupe_ownership.owner_instance = 本节点的 actor 的到期提醒；
    # 无所有权记录（LEFT JOIN 为空）任何节点可认领。
    private CLAIM_SQL = <<-'SQL'
      UPDATE troupe_reminders r
      SET claim_holder = $1, claim_expires_at = now() + ($2 * interval '1 millisecond'),
          status_version = r.status_version + 1
      WHERE (r.actor_id, r.name) IN (
        SELECT r2.actor_id, r2.name FROM troupe_reminders r2
        LEFT JOIN troupe_ownership o ON o.actor_id = r2.actor_id
        WHERE r2.due_at <= $3
          AND (r2.claim_expires_at IS NULL OR r2.claim_expires_at <= now())
          AND (o.owner_instance = $1 OR o.actor_id IS NULL)
        LIMIT $4
      )
      RETURNING r.actor_id, r.name, r.turn, r.payload, r.due_at, r.claim_holder,
                r.claim_expires_at, r.status_version
    SQL

    private RELEASE_SQL = <<-SQL
      UPDATE troupe_reminders
      SET claim_holder = NULL, claim_expires_at = NULL, status_version = status_version + 1
      WHERE actor_id = $1 AND name = $2 AND status_version = $3
    SQL
  end
end
