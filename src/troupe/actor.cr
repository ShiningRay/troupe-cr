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

    def initialize(@store : ::Troupe::PropStore, @manifest : ::Troupe::ManifestBase,
                   @clock : ::Troupe::Clock, @epoch : UInt64, @revision : UInt64)
    end
  end

  abstract class ActorBase
    getter actor_id : ::Troupe::ActorId

    def initialize(@actor_id : ::Troupe::ActorId, @props : ::JSON::Serializable, @ctx : ::Troupe::ActivationContext)
    end

    # 显式持久化：以 expectedRevision + epoch 原子 CAS 提交当前 Props。
    # 失败（CAS 冲突 / fencing 拒绝）会使实例失效：后续调用从最后已提交快照重新激活。
    def save : Nil
      record = @ctx.store.write(actor_id, @ctx.revision, @ctx.manifest.schema_version, @props.to_json, @ctx.epoch)
      @ctx.revision = record.revision
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
  record CallContext,
    call_id : UInt64,
    actor_id : ::Troupe::ActorId,
    method : ::String,
    deadline : ::Time,
    clock : ::Troupe::Clock
end
