module Troupe
  # 激活上下文：一次激活的所有权与存储视图。revision 由 save 原子推进。
  #
  # 注意：本库类型在签名上使用 ::Troupe:: 全限定——用户在模块外继承 Actor(P) 时，
  # 泛型实例化会重解析基类签名，未限定名会落在调用方作用域而解析失败。
  class ActivationContext
    getter store : ::Troupe::PropStore
    getter manifest : ::Troupe::ManifestBase
    getter clock : ::Troupe::Clock
    getter epoch : UInt64
    property revision : UInt64
    getter idempotency : Hash(String, ::Troupe::IdempotencyRecord)
    getter idempotency_retention : ::Time::Span
    getter outbox : Hash(String, ::Troupe::OutboxRecord)

    def initialize(@store : ::Troupe::PropStore, @manifest : ::Troupe::ManifestBase,
                   @clock : ::Troupe::Clock, @epoch : UInt64, @revision : UInt64,
                   @idempotency : Hash(String, ::Troupe::IdempotencyRecord),
                   @idempotency_retention : ::Time::Span,
                   @outbox : Hash(String, ::Troupe::OutboxRecord) = {} of ::String => ::Troupe::OutboxRecord)
    end
  end

  abstract class ActorBase
    getter actor_id : ::Troupe::ActorId

    def initialize(@actor_id : ::Troupe::ActorId, @props : ::JSON::Serializable, @ctx : ::Troupe::ActivationContext)
    end

    # 显式持久化：以 expectedRevision + epoch 原子 CAS 提交当前 Props 与幂等记录。
    # 失败（CAS 冲突 / fencing 拒绝）会使实例失效：后续调用从最后已提交快照重新激活。
    def save : Nil
      record = @ctx.store.write(actor_id, @ctx.revision, @ctx.manifest.schema_version, @props.to_json,
        @ctx.epoch, @ctx.idempotency.values, @ctx.outbox.values)
      @ctx.revision = record.revision
      @ctx.outbox.clear # 事件已随 Props 落盘，交由 OutboxDispatcher 投递
    end

    # 外部副作用 Outbox（docs/outbox.md）：事件记入 journal，save 时与 Props 同原子提交。
    # event_id 缺省随机生成；调度/派发走 OutboxDispatcher（至少一次，接收方幂等）。
    def emit_event(topic : String, payload = ::JSON::Any.new(nil), event_id : ::String? = nil) : ::String
      eid = event_id || ::Random::Secure.hex(16)
      @ctx.outbox[eid] = OutboxRecord.new(actor_id: actor_id, event_id: eid, topic: topic,
        payload: payload, created_at: @ctx.clock.now)
      eid
    end

    # 幂等执行（docs/persistence.md 失败语义；对齐 troupejs DESIGN §6.5）：
    # - 同键同指纹 → 重放首次结果（或重抛首次错误，附带原始错误类别）；
    # - 同键不同指纹 → IdempotencyConflictError；
    # - fn 只修改内存 Props、不要 save：helper 在 fn settle 后把 Props 变更 + 幂等记录
    #   **一次原子提交**（store.write 原子 CAS）；失败也记录，重放时按记录重抛；
    # - 过期（expires_at）后同键视为新操作。保留期默认 7 天（StageConfig）。
    def idempotent(key : String, fingerprint : String, &block : -> ::JSON::Any) : ::JSON::Any
      ctx = @ctx
      existing = ctx.idempotency[key]?
      # 过期（expires_at <= now）后同键视为新操作；激活时装载与 Turn 内查找都做时效判定。
      if existing && existing.expires_at > ctx.clock.now.to_unix
        unless existing.fingerprint == fingerprint
          raise IdempotencyConflictError.new("幂等键 #{key.inspect} 已用于不同参数指纹（#{existing.fingerprint} ≠ #{fingerprint}）")
        end
        if existing.ok
          return ::JSON.parse(existing.value.not_nil!)
        end
        raise ::Exception.new("幂等重放：首次执行失败（#{existing.error_class}: #{existing.error_message}）")
      end
      expires_at = (ctx.clock.now + ctx.idempotency_retention).to_unix
      begin
        value = block.call
      rescue e : ::Exception
        ctx.idempotency[key] = IdempotencyRecord.new(key: key, fingerprint: fingerprint, ok: false,
          expires_at: expires_at, error_class: e.class.name, error_message: e.message)
        save
        raise e
      end
      ctx.idempotency[key] = IdempotencyRecord.new(key: key, fingerprint: fingerprint, ok: true,
        expires_at: expires_at, value: value.to_json)
      save
      value
    end

    # 生命周期钩子（可覆盖）。on_stage 抛错 → ActivationError；off_stage 抛错 → 记录事件仍执行下线。
    def on_stage : Nil
    end

    def off_stage : Nil
    end
  end

  # 类型化 Actor 基类：用户角色继承 `Troupe::Actor(PropsType)`。
  abstract class Actor(P) < ::Troupe::ActorBase
    def props : P
      @props.as(P)
    end
  end

  # 单个 Turn 的调用上下文。clock 可注入：Rehearsal 中 Turn 体内推进虚拟时钟可确定性模拟耗时。
  # cancel 为协作取消信号（CallFuture#cancel 置位，Turn 自行决定是否/如何响应）。
  # traceparent 为本 Turn 的 W3C span：Actor 互调时显式作为父传给 stage.call（M2 无隐式传播）。
  record CallContext,
    call_id : UInt64,
    actor_id : ::Troupe::ActorId,
    method : ::String,
    deadline : ::Time,
    clock : ::Troupe::Clock,
    cancel : ::Troupe::CancelSignal,
    traceparent : ::String do
    def cancel_requested? : Bool
      cancel.requested?
    end
  end
end
