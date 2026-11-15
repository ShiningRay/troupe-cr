require "json"

module Troupe
  # OTLP JSON 导出适配器（PLAN M6：Booth/OTel 适配最小闭环）。
  #
  # 零外部依赖：将 Director 指标与 Stage trace 事件转换为 **OTLP JSON v1 导出格式**
  # （resourceMetrics/spans 结构，OTLP/JSON Protobuf JSON 映射），经 sink 回调交付
  # ——推送至 collector 的传输（HTTP/gRPC/文件）是 sink 的宿主实现，框架不做网络 IO。
  #
  # 映射：
  # - StageMetrics 计数 → monotonic Sum 指标（累计，aggregationTemporality=2）；
  # - TraceEvent → span（traceId/spanId 十六进制、unix nano 时间、outcome → status）；
  # - Stage 名 → resource 属性 service.name。
  module OTel
    # traceparent → {trace_id, span_id}；非法/nil → 全零（OTLP 全零为无效 id 约定）。
    def self.parse_traceparent(tp : String?) : {trace_id: String, span_id: String}
      if tp && tp.size == 55 && tp.starts_with?("00-")
        parts = tp.split('-')
        if parts.size == 4 && parts[1].size == 32 && parts[2].size == 16
          return {trace_id: parts[1], span_id: parts[2]}
        end
      end
      {trace_id: "0" * 32, span_id: "0" * 16}
    end

    # JSON::Any 数组包装（OTLP 结构构造辅助；Any.new 不接受数组字面量）。
    private def self.arr(items : Array(::JSON::Any)) : ::JSON::Any
      ::JSON::Any.new(items)
    end

    private def self.arr(items : Array(::JSON::Any)) : ::JSON::Any
      ::JSON::Any.new(items)
    end

    # 指标 → OTLP JSON 字符串（单 resource 单 scope，counter → monotonic Sum）。
    def self.metrics_to_otlp_json(stage_name : String, counters : Hash(String, ::UInt64)) : String
      ::JSON.build do |json|
        json.object do
          json.field "resourceMetrics" do
            json.array do
              json.object do
                json.field "resource" do
                  json.object do
                    json.field "attributes" do
                      json.array do
                        json.object do
                          json.field "key", "service.name"
                          json.field "value" do
                            json.object { json.field "stringValue", "troupe.#{stage_name}" }
                          end
                        end
                      end
                    end
                  end
                end
                json.field "scopeMetrics" do
                  json.array do
                    json.object do
                      json.field "scope" do
                        json.object { json.field "name", "troupe.cr" }
                      end
                      json.field "metrics" do
                        json.array do
                          json.object do
                            json.field "name", "troupe.stage.counters"
                            json.field "sum" do
                              json.object do
                                json.field "aggregationTemporality", 2
                                json.field "isMonotonic", true
                                json.field "dataPoints" do
                                  json.array do
                                    counters.each do |name, value|
                                      json.object do
                                        json.field "attributes" do
                                          json.array do
                                            json.object do
                                              json.field "key", "troupe.counter"
                                              json.field "value" do
                                                json.object { json.field "stringValue", name }
                                              end
                                            end
                                          end
                                        end
                                        json.field "asInt", value.to_i64
                                        json.field "isMonotonic", true
                                      end
                                    end
                                  end
                                end
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # trace 事件 → OTLP spans JSON 字符串（outcome → status code：1=Ok 2=Error）。
    def self.spans_to_otlp_json(stage_name : String, events : Array(::Troupe::TraceEvent)) : String
      ::JSON.build do |json|
        json.object do
          json.field "resourceSpans" do
            json.array do
              json.object do
                json.field "resource" do
                  json.object do
                    json.field "attributes" do
                      json.array do
                        json.object do
                          json.field "key", "service.name"
                          json.field "value" do
                            json.object { json.field "stringValue", "troupe.#{stage_name}" }
                          end
                        end
                      end
                    end
                  end
                end
                json.field "scopeSpans" do
                  json.array do
                    json.object do
                      json.field "scope" do
                        json.object { json.field "name", "troupe.cr" }
                      end
                      json.field "spans" do
                        json.array do
                          events.each do |event|
                            parsed = parse_traceparent(event.traceparent)
                            parent_span = event.parent_traceparent.try do |p|
                              parse_traceparent(p)[:span_id]
                            end || "0" * 16
                            status_code = event.ok ? 1 : 2 # 1=Ok 2=Error
                            json.object do
                              json.field "traceId", parsed[:trace_id]
                              json.field "spanId", parsed[:span_id]
                              json.field "parentSpanId", parent_span
                              json.field "name", "#{event.actor_id}/#{event.method}"
                              json.field "kind", 1 # INTERNAL
                              json.field "startTimeUnixNano", (event.at - ::Time.unix(0) - event.duration).total_nanoseconds.to_i64
                              json.field "endTimeUnixNano", (event.at - ::Time.unix(0)).total_nanoseconds.to_i64
                              json.field "attributes" do
                                json.array do
                                  json.object do
                                    json.field "key", "troupe.outcome"
                                    json.field "value" do
                                      json.object { json.field "stringValue", event.outcome }
                                    end
                                  end
                                end
                              end
                              json.field "status" do
                                json.object { json.field "code", status_code }
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # 导出适配器：attach 订阅 Stage trace（缓冲环形），export 产出 OTLP JSON，
    # sink 回调为 collector 推送点（框架不做网络 IO）。
    class Adapter
      @stage : ::Troupe::Stage
      @sink : Proc(::String, Nil)
      @stage_name : String
      @trace_buffer : Array(::Troupe::TraceEvent) = [] of ::Troupe::TraceEvent
      @trace_limit : Int32
      @mutex = Mutex.new
      @attached = false

      def initialize(@stage, @sink : Proc(::String, Nil),
                     @stage_name : String = "stage", @trace_limit : Int32 = 200)
      end

      # 订阅 Stage trace（幂等；重复调用不重复订阅）。
      def attach : Nil
        @mutex.synchronize do
          return if @attached
          @stage.on_trace do |event|
            @mutex.synchronize do
              @trace_buffer << event
              @trace_buffer.shift if @trace_buffer.size > @trace_limit
            end
          end
          @attached = true
        end
      end

      # 导出当前指标 OTLP JSON（快照，不消耗）。
      def export_metrics : ::String
        OTel.metrics_to_otlp_json(@stage_name, @stage.metrics.snapshot)
      end

      # 导出缓冲 trace span OTLP JSON 并清空缓冲（批导出）。
      def export_spans : ::String
        events = @mutex.synchronize do
          copy = @trace_buffer.dup
          @trace_buffer.clear
          copy
        end
        OTel.spans_to_otlp_json(@stage_name, events)
      end

      # 闭环导出：metrics + spans 依次经 sink 交付（宿主在此推送 collector）。
      def export_all : Nil
        attach
        @sink.call(export_metrics)
        @sink.call(export_spans)
      end

      def pending_traces : Int32
        @mutex.synchronize { @trace_buffer.size }
      end
    end
  end
end
