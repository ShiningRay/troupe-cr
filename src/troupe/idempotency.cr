module Troupe
  # 幂等请求记录（docs/persistence.md 失败语义：幂等记录与 Props 原子提交）。
  # - 同键同指纹 → 重放首次结果（或重抛首次错误）；
  # - 同键不同指纹 → IdempotencyConflictError；
  # - expires_at 为 Unix 秒，过期后同键视为新操作。
  record IdempotencyRecord,
    key : String,
    fingerprint : String,
    ok : Bool,
    expires_at : Int64,
    value : String? = nil,
    error_class : String? = nil,
    error_message : String? = nil
end
