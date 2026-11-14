module Troupe
  # W3C Trace Context（PLAN M2，DESIGN §11.4；对齐 troupejs trace-context）：
  # 零依赖桥——核心只在 Turn 边界产出 TraceEvent 并经 Stage#on_trace 钩子外送；
  # OTel 适配保持可选（框架自身不依赖 OTel SDK）。
  # 格式 `00-<32hex trace-id>-<16hex span-id>-<2hex flags>`；父非法静默降级为新 span（W3C 容错）。
  module TraceContext
    private FORMAT = /^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/

    # 解析并做 W3C 语义校验：全零 trace-id/span-id 非法（W3C 禁止）。
    def self.parse(traceparent : String?) : NamedTuple(trace_id: String, span_id: String)?
      return nil unless traceparent
      match = FORMAT.match(traceparent)
      return nil unless match
      trace_id = match[1]
      span_id = match[2]
      return nil if trace_id == "0" * 32 || span_id == "0" * 16
      {trace_id: trace_id, span_id: span_id}
    end

    def self.valid?(traceparent : String?) : Bool
      !parse(traceparent).nil?
    end

    # 无父 span：新 trace-id + 新 span-id。
    def self.new_span : String
      "00-#{Random::Secure.hex(16)}-#{Random::Secure.hex(8)}-01"
    end

    # 子 span：继承 trace-id、新 span-id；父非法则生成新 span。
    def self.child_span(parent : String?) : String
      parsed = parse(parent)
      return new_span unless parsed
      "00-#{parsed[:trace_id]}-#{Random::Secure.hex(8)}-01"
    end

    def self.trace_id_of(traceparent : String?) : String?
      parse(traceparent).try &.[:trace_id]
    end
  end

  # Turn 边界产出的结构化追踪事件（duration 不含排队等待；expired 的 duration 为零）。
  record TraceEvent,
    call_id : UInt64,
    actor_id : ::Troupe::ActorId,
    method : String,
    duration : ::Time::Span,
    ok : Bool,
    outcome : String,
    traceparent : String,
    at : ::Time,
    parent_traceparent : String? = nil
end
