module Troupe
  # 结构化生命周期/调用事件（M1 最小集；metrics 与 W3C trace 在 M2 扩展）。
  enum EventType
    Activated
    Deactivated
    ActivationFailed
    TurnStarted
    TurnEnded
    TurnExpired
    CallRejected
    SaveFailed
  end

  record Event,
    type : EventType,
    actor_id : ::Troupe::ActorId,
    at : ::Time,
    method : String? = nil,
    reason : String? = nil
end
