module Troupe
  # 错误分类（对齐 troupe-planning DESIGN §6.1：业务异常 / 请求拒绝 / 结果未知 / 存储冲突）。
  # 业务异常不经过本层包装：Turn 内用户异常原样送达调用方。
  abstract class Error < ::Exception
    def initialize(message : String? = nil, cause : ::Exception? = nil)
      super(message, cause)
    end
  end

  # ActorId 规范形式或组成部分非法。
  class InvalidActorIdError < Error; end

  # 存储冲突（DESIGN §7.2 CAS 合同）。
  # kind=Exists：create 时记录已存在；kind=Revision：write 时期望 revision 不匹配或记录缺失。
  enum ConflictKind
    Exists
    Revision
  end

  class ConflictError < Error
    getter kind : ConflictKind

    def initialize(message : String, @kind : ConflictKind, cause : ::Exception? = nil)
      super(message, cause)
    end
  end

  # 调用超时（DESIGN §5.1 响应期限与执行占用分离）。
  # Queued：排队过期，未开始执行、无副作用、可安全重试；
  # Executing：执行中超时/迟归，结果未知；执行占用保持到原执行 settle，后续 strict Turn 不放行。
  enum CallTimeoutPhase
    Queued
    Executing
  end

  class CallTimeoutError < Error
    getter phase : CallTimeoutPhase

    def initialize(message : String, @phase : CallTimeoutPhase, cause : ::Exception? = nil)
      super(message, cause)
    end
  end

  # 请求拒绝（非业务异常）：Backpressure / Whitelist / Shutdown / Draining / Ownership / Invalidated。
  enum RejectReason
    Backpressure
    Whitelist
    Shutdown
    Draining
    Ownership
    Invalidated
  end

  class CallRejectedError < Error
    getter reason : RejectReason
    getter retryable : Bool

    def initialize(message : String, @reason : RejectReason, @retryable : Bool, cause : ::Exception? = nil)
      super(message, cause)
    end
  end

  # 执行结果未知（超时/连接断开/对端停机）：勿假定失败，按幂等键重试。
  class UnknownOutcomeError < Error; end

  # 幂等键冲突：同键不同参数指纹（docs/persistence.md 失败语义）。
  class IdempotencyConflictError < Error; end

  # Roster 重加入 incarnation 不高于现存（生产协议协商）。
  class StaleIncarnationError < Error; end

  # 调用了未注册的角色。
  class UnknownRoleError < Error; end

  # 角色名冲突：同一 Stage 内两个 manifest 使用相同 role，注册时 fail fast。
  class RoleConflictError < Error; end

  # 对已失效实例的操作（保存等，DESIGN §7.3）。
  class InvalidActorStateError < Error; end

  # Props 无法通过序列化边界。
  class SerializationError < Error; end

  # 激活失败：加载、迁移或 on_stage 抛错（DESIGN §5.2 状态机）。
  class ActivationError < Error; end

  # 请求参数校验失败（缺参/类型不符）：排队前拒绝，不可重试原样重发。
  class InvalidArgumentError < Error; end
end
