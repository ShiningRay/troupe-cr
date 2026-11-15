module Troupe
  # 持久 Reminder 记录（docs/persistence.md Reminders）：
  # 稳定名称 (actor_id, name)、payload、nextDue(due_at)、claim lease、statusVersion。
  # status_version 每次认领/调度自增——complete/release 必须 fencing 匹配才生效。
  record ReminderRecord,
    actor_id : ::Troupe::ActorId,
    name : String,
    turn : String,
    payload : ::JSON::Any,
    due_at : ::Time,
    claim_holder : String?,
    claim_expires_at : ::Time?,
    status_version : ::UInt64

  # 持久 CueStore 契约（PLAN M3）。
  # - schedule/cancel：稳定键 (actor_id, name) upsert/删除；
  # - claim_due：**先按当前归属过滤（troupe_ownership 持有者），再原子认领**（claim lease），
  #   无所有权记录的 reminder 任何节点可认领（调度先于激活的场景）；
  # - complete：fencing（status_version + claim_holder + 租期有效）匹配才删除；
  #   失配返回 false → 提醒留给当前 owner 重投（至少一次，不丢失）；
  # - release：认领者主动放弃（交付失败），立即变为可重投。
  abstract class ReminderStore
    abstract def schedule(actor_id : ::Troupe::ActorId, name : String, turn : String,
                          payload : ::JSON::Any, due_at : ::Time) : Nil

    abstract def cancel(actor_id : ::Troupe::ActorId, name : String) : Bool

    abstract def claim_due(now : ::Time, owner_instance : String, lease : ::Time::Span,
                           limit : Int32) : Array(::Troupe::ReminderRecord)

    abstract def complete(actor_id : ::Troupe::ActorId, name : String,
                          status_version : ::UInt64, claim_holder : String) : Bool

    abstract def release(actor_id : ::Troupe::ActorId, name : String,
                         status_version : ::UInt64) : Bool

    abstract def find(actor_id : ::Troupe::ActorId, name : String) : ::Troupe::ReminderRecord?
  end

  # Memory 实现：Rehearsal/单机测试用（时钟可注入，语义与 PG 版对齐）。
  class MemoryReminderStore < ::Troupe::ReminderStore
    @records = Hash(::Troupe::ActorId, Hash(String, ::Troupe::ReminderRecord)).new
    @ownership : ::Troupe::OwnershipStore
    @mutex = Mutex.new

    def initialize(@ownership : ::Troupe::OwnershipStore)
    end

    def schedule(actor_id : ::Troupe::ActorId, name : String, turn : String,
                 payload : ::JSON::Any, due_at : ::Time) : Nil
      @mutex.synchronize do
        by_name = @records[actor_id] ||= Hash(String, ::Troupe::ReminderRecord).new
        existing = by_name[name]?
        version = existing ? existing.status_version + 1 : 1_u64
        by_name[name] = ReminderRecord.new(actor_id: actor_id, name: name, turn: turn,
          payload: payload, due_at: due_at,
          claim_holder: nil, claim_expires_at: nil, status_version: version)
      end
    end

    def cancel(actor_id : ::Troupe::ActorId, name : String) : Bool
      @mutex.synchronize do
        by_name = @records[actor_id]?
        deleted = by_name.try(&.delete(name))
        !deleted.nil?
      end
    end

    def claim_due(now : ::Time, owner_instance : String, lease : ::Time::Span,
                  limit : Int32) : Array(::Troupe::ReminderRecord)
      claimed = [] of ::Troupe::ReminderRecord
      @mutex.synchronize do
        @records.each do |actor_id, by_name|
          next if claimed.size >= limit
          # 归属过滤：actor 已有归属标记时仅本节点可认领；无标记（调度先于激活）任何节点可认领
          marked = @owners[actor_id]?
          next unless marked.nil? || marked == owner_instance
          by_name.each do |name, record|
            break if claimed.size >= limit
            next if record.due_at > now
            next if record.claim_holder && record.claim_expires_at.not_nil! > now
            claimed_record = ReminderRecord.new(actor_id: record.actor_id, name: record.name,
              turn: record.turn, payload: record.payload, due_at: record.due_at,
              claim_holder: owner_instance, claim_expires_at: now + lease,
              status_version: record.status_version + 1)
            by_name[name] = claimed_record
            claimed << claimed_record
          end
        end
      end
      claimed
    end

    def complete(actor_id : ::Troupe::ActorId, name : String, status_version : ::UInt64,
                 claim_holder : String) : Bool
      @mutex.synchronize do
        record = @records[actor_id]?.try(&.[name]?)
        return false unless record
        # fencing：status_version 与认领必须同时匹配，否则提醒留给当前 owner 重投
        return false unless record.status_version == status_version
        return false unless record.claim_holder == claim_holder
        @records[actor_id].delete(name)
        true
      end
    end

    def release(actor_id : ::Troupe::ActorId, name : String, status_version : ::UInt64) : Bool
      @mutex.synchronize do
        record = @records[actor_id]?.try(&.[name]?)
        return false unless record
        return false unless record.status_version == status_version
        @records[actor_id][name] = ReminderRecord.new(actor_id: record.actor_id, name: record.name,
          turn: record.turn, payload: record.payload, due_at: record.due_at,
          claim_holder: nil, claim_expires_at: nil, status_version: record.status_version + 1)
        true
      end
    end

    def find(actor_id : ::Troupe::ActorId, name : String) : ::Troupe::ReminderRecord?
      @mutex.synchronize { @records[actor_id]?.try(&.[name]?) }
    end

    private def actor_holder(actor_id : ::Troupe::ActorId) : String
      # Memory ownership 只有 epoch；归属用"最后 acquire 者标记"——由测试/运行时
      # 经 mark_owner 注入（与 PostgreSQL 的 owner_instance 对齐）。
      @owners[actor_id]? || ""
    end

    @owners = Hash(::Troupe::ActorId, String).new

    # Memory 专用：标记 actor 当前归属（模拟 troupe_ownership.owner_instance）。
    def mark_owner(actor_id : ::Troupe::ActorId, owner_instance : String) : Nil
      @mutex.synchronize { @owners[actor_id] = owner_instance }
    end
  end
end
