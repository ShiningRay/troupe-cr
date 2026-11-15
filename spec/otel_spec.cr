require "./spec_helper"

# PLAN M6：Booth/OTel 适配最小闭环——OTLP JSON 导出适配器（零外部依赖，
# sink 回调为 collector 推送点；反例覆盖非法 traceparent/空指标/环形缓冲）。
def otel_setup(mode : Troupe::SchedulerMode = Troupe::SchedulerMode::Fiber)
  stage = Troupe::Stage.new(mode: mode)
  TroupeFixtures.register_counter(stage)
  stage
end

# metrics JSON 计数零值兜底（StageMetrics.snapshot 仅含已递增计数器）
private def counter(metrics : ::JSON::Any, name : String) : ::JSON::Any
  metrics.dig?("stages", "main", name) || ::JSON::Any.new(0_i64)
end

describe "M6 OTel 导出适配器" do
  it "metrics → OTLP JSON：结构合法、计数为 monotonic Sum 数据点" do
    stage = otel_setup
    begin
      id = Troupe::ActorId.new("app", "counter", "m1")
      stage.call(id, "increment", TroupeFixtures.counter_args(2)).await.as_i.should eq(2)

      payload = Troupe::OTel.metrics_to_otlp_json("main", stage.metrics.snapshot)
      payload = JSON.parse(payload)
      rm = payload["resourceMetrics"][0]
      rm["resource"]["attributes"][0]["value"]["stringValue"].as_s.should eq("troupe.main")
      metric = rm["scopeMetrics"][0]["metrics"][0]
      metric["name"].as_s.should eq("troupe.stage.counters")
      sum = metric["sum"]
      sum["aggregationTemporality"].as_i.should eq(2) # CUMULATIVE
      sum["isMonotonic"].as_bool.should be_true

      points = sum["dataPoints"].as_a
      by_name = points.to_h do |point|
        {point["attributes"][0]["value"]["stringValue"].as_s, point["asInt"].as_i}
      end
      by_name["turns_started"].should eq(1_i64)
      by_name["turns_completed"].should eq(1_i64)
      by_name.has_key?("activation_failures").should be_false # 零值计数不入数据点（缺省兜底）
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "spans → OTLP JSON：traceId/spanId 提取、outcome 属性、status Ok/Error" do
    stage = otel_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "counter", "span")
      traces = [] of Troupe::TraceEvent
      stage.on_trace { |t| traces << t }

      ok_call = stage.call(id, "increment", TroupeFixtures.counter_args(1))
      ok_call.await.as_i.should eq(1)

      # 失败 span（业务异常）→ status Error
      bad = stage.call(id, "nope") rescue nil
      # 白名单拒绝发生在 call 阶段（无 trace），改用未知角色
      begin
        stage.call(Troupe::ActorId.new("app", "counter", "span"), "increment") rescue nil
      end
      stage.shutdown

      traces.size.should eq(1) # 白名单拒绝不产生 trace（无 Turn）
      ok_trace = traces[0]
      parsed = Troupe::OTel.parse_traceparent(ok_trace.traceparent)
      parsed[:trace_id].size.should eq(32)
      parsed[:span_id].size.should eq(16)

      payload = Troupe::OTel.spans_to_otlp_json("main", traces)
      payload = JSON.parse(payload)
      span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
      span["traceId"].as_s.should eq(parsed[:trace_id])
      span["spanId"].as_s.should eq(parsed[:span_id])
      span["parentSpanId"].as_s.should eq("0" * 16)
      span["status"]["code"].as_i.should eq(1) # Ok
      span["attributes"][0]["value"]["stringValue"].as_s.should eq("completed")
      span["endTimeUnixNano"].as_i64.should be >= span["startTimeUnixNano"].as_i64
    ensure
      stage.shutdown
    end
  end

  it "spans status 反例：outcome=failed → status Error" do
    stage = otel_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "counter", "err")
      traces = [] of Troupe::TraceEvent
      stage.on_trace { |t| traces << t }

      bad = stage.call(id, "increment", JSON.parse(%({}))) # 缺参数 → Turn 抛错
      begin
        bad.await
      rescue
        nil
      end
      stage.shutdown

      payload = Troupe::OTel.spans_to_otlp_json("main", traces)
      payload = JSON.parse(payload)
      span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
      span["status"]["code"].as_i.should eq(2) # Error
      span["attributes"][0]["value"]["stringValue"].as_s.should eq("failed")
    ensure
      stage.shutdown
    end
  end

  it "Adapter 闭环：attach 订阅 trace、export_all 经 sink 交付、批导出清空缓冲" do
    stage = otel_setup
    begin
      sinks = [] of String
      adapter = Troupe::OTel::Adapter.new(stage, ->(payload : ::String) {
        sinks << (payload.includes?("resourceMetrics") ? "metrics" : "spans")
      }, "main")

      adapter.attach
      id = Troupe::ActorId.new("app", "counter", "loop")
      stage.call(id, "increment", TroupeFixtures.counter_args(1)).await.as_i.should eq(1)
      adapter.pending_traces.should eq(1) # attach 已订阅 trace

      adapter.export_all
      sinks.size.should eq(2)             # metrics + spans 各一次
      adapter.pending_traces.should eq(0) # 批导出清空缓冲

      # 重复 attach 幂等：trace 只订阅一次（不重复计数）
      adapter.attach
      stage.call(id, "increment", TroupeFixtures.counter_args(1)).await.as_i.should eq(2)
      adapter.pending_traces.should eq(1)
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "trace_buffer 环形：超出 limit 的旧 span 被丢弃（内存有界）" do
    stage = otel_setup
    begin
      adapter = Troupe::OTel::Adapter.new(stage, ->(p : ::String) { nil }, "main", trace_limit: 3)
      adapter.attach
      id = Troupe::ActorId.new("app", "counter", "ring")
      6.times do
        call = stage.call(id, "increment", TroupeFixtures.counter_args(1))
        call.await.as_i
      end
      adapter.pending_traces.should eq(3) # 环形上限生效
      payload = JSON.parse(adapter.export_spans)
      spans = payload["resourceSpans"][0]["scopeSpans"][0]["spans"].as_a
      spans.size.should eq(3) # 只保留最新 3 条
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "非法 traceparent → 全零 id（OTLP 无效 id 约定，反例）" do
    parsed = Troupe::OTel.parse_traceparent("garbage")
    parsed[:trace_id].should eq("0" * 32)
    parsed[:span_id].should eq("0" * 16)
    Troupe::OTel.parse_traceparent(nil)[:trace_id].should eq("0" * 32)
  end
end
