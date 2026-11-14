module Troupe
  # Props 存储记录。三个独立版本维度（docs/persistence.md）：
  # revision = 乐观并发 CAS；schema_version = 状态结构版本；epoch = 最后写入者的所有权 fencing token。
  # data 为 JSON 字符串：Memory Provider 同样走完整序列化边界，read 返回独立快照。
  record PropRecord,
    revision : UInt64,
    schema_version : Int32,
    data : String,
    epoch : UInt64

  # 所有权 store：为每个 ActorId 发放单调递增 epoch（fencing token）。
  abstract class OwnershipStore
    abstract def acquire(actor_id : ::Troupe::ActorId) : UInt64

    abstract def current(actor_id : ::Troupe::ActorId) : UInt64
  end

  class MemoryOwnershipStore < ::Troupe::OwnershipStore
    @epochs = Hash(::Troupe::ActorId, UInt64).new(0_u64)
    @mutex = Mutex.new

    def acquire(actor_id : ::Troupe::ActorId) : UInt64
      @mutex.synchronize { @epochs[actor_id] += 1 }
    end

    def current(actor_id : ::Troupe::ActorId) : UInt64
      @mutex.synchronize { @epochs[actor_id] }
    end
  end

  # PropStore 契约（docs/persistence.md）：
  # - create 原子存在检查；已存在即 ConflictError(:exists)。
  # - write 以 expectedRevision + epoch 原子 CAS；fencing 必须在 Provider 层校验，
  #   epoch != current 一律拒绝（CallRejectedError(:ownership)），不允许应用层先读后写。
  abstract class PropStore
    def initialize(@ownership : ::Troupe::OwnershipStore)
    end

    abstract def read(actor_id : ::Troupe::ActorId) : ::Troupe::PropRecord?

    abstract def create(actor_id : ::Troupe::ActorId, schema_version : Int32, data : String, epoch : UInt64) : ::Troupe::PropRecord

    abstract def write(actor_id : ::Troupe::ActorId, expected_revision : UInt64, schema_version : Int32, data : String, epoch : UInt64) : ::Troupe::PropRecord

    private def assert_fencing(actor_id : ::Troupe::ActorId, epoch : UInt64) : Nil
      current = @ownership.current(actor_id)
      unless current == epoch
        raise CallRejectedError.new("epoch #{epoch} 已被 epoch #{current} 取代，拒绝写入 Actor #{actor_id}", :ownership, false)
      end
    end
  end

  # Memory Provider：Rehearsal/单机用。模拟 CAS 与 fencing，真实接管语义在 M3 由共享 Provider 验证。
  class MemoryPropStore < ::Troupe::PropStore
    @records = Hash(::Troupe::ActorId, ::Troupe::PropRecord).new
    @mutex = Mutex.new

    def read(actor_id : ::Troupe::ActorId) : ::Troupe::PropRecord?
      @mutex.synchronize { @records[actor_id]? }
    end

    def create(actor_id : ::Troupe::ActorId, schema_version : Int32, data : String, epoch : UInt64) : ::Troupe::PropRecord
      @mutex.synchronize do
        if @records.has_key?(actor_id)
          raise ConflictError.new("Actor #{actor_id} 的 Props 已存在", :exists)
        end
        assert_fencing(actor_id, epoch)
        record = PropRecord.new(revision: 1_u64, schema_version: schema_version, data: data, epoch: epoch)
        @records[actor_id] = record
        record
      end
    end

    def write(actor_id : ::Troupe::ActorId, expected_revision : UInt64, schema_version : Int32, data : String, epoch : UInt64) : ::Troupe::PropRecord
      @mutex.synchronize do
        record = @records[actor_id]?
        unless record
          raise ConflictError.new("Actor #{actor_id} 的 Props 不存在", :revision)
        end
        # fencing 优先于 CAS：旧 epoch 一律拒绝，即使 revision 恰好匹配
        # （docs/persistence.md：旧 epoch 的 create/write/migrate 必须失败）。
        assert_fencing(actor_id, epoch)
        unless record.revision == expected_revision
          raise ConflictError.new("revision 冲突：期望 #{expected_revision}，实际 #{record.revision}（Actor #{actor_id}）", :revision)
        end
        updated = PropRecord.new(revision: record.revision + 1, schema_version: schema_version, data: data, epoch: epoch)
        @records[actor_id] = updated
        updated
      end
    end
  end
end
