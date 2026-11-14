module Troupe
  # 结构化生命周期/调用计数器（PLAN M2）。Stage#emit 是唯一更新点：
  # Activated/ActivationFailed/TurnStarted/TurnEnded/TurnExpired/SaveFailed/CallRejected/Deactivated。
  # OTel 导出保持可选——外部适配器经 Stage#on_event/#on_trace 消费结构化事件即可，核心无 otel 依赖。
  class StageMetrics
    @mutex = Mutex.new
    @counters = Hash(String, UInt64).new(0_u64)
    @role_counters = Hash(String, Hash(String, UInt64)).new

    def inc(name : String) : Nil
      @mutex.synchronize { @counters[name] = @counters[name] + 1 }
    end

    def inc_role(name : String, role : String) : Nil
      @mutex.synchronize do
        roles = @role_counters[name] ||= Hash(String, UInt64).new(0_u64)
        roles[role] = roles[role] + 1
      end
    end

    def counter(name : String) : UInt64
      @mutex.synchronize { @counters[name] }
    end

    def role_counter(name : String, role : String) : UInt64
      @mutex.synchronize do
        roles = @role_counters[name]?
        roles ? roles[role] : 0_u64
      end
    end

    def snapshot : Hash(String, UInt64)
      @mutex.synchronize { @counters.dup }
    end
  end
end
