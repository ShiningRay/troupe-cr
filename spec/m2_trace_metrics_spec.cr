require "./spec_helper"

# PLAN M2 第三项：结构化 lifecycle/call metrics、Trace 事件、W3C trace context（OTel 适配可选）。
describe "M2 trace & metrics" do
  it "TraceContext：生成/校验/派生子 span" do
    root = Troupe::TraceContext.new_span
    Troupe::TraceContext.valid?(root).should be_true
    parsed = Troupe::TraceContext.parse(root).not_nil!
    parsed[:trace_id].size.should eq(32)
    parsed[:span_id].size.should eq(16)
    root.should start_with("00-")

    child = Troupe::TraceContext.child_span(root)
    Troupe::TraceContext.trace_id_of(child).should eq(parsed[:trace_id]) # 继承 trace-id
    child.should_not eq(root)                                            # 新 span-id
  end

  it "TraceContext：非法父静默降级为新 span（W3C 容错反例）" do
    bad_parents = [
      "",
      "garbage",
      "00-xyz",
      "00-#{"a" * 31}-#{"b" * 16}-01", # 长度错误
      "00-#{"g" * 32}-#{"a" * 16}-01", # 非 hex
      "00-#{"0" * 32}-#{"a" * 16}-01", # 全零 trace-id（W3C 禁止）
      "00-#{"a" * 32}-#{"0" * 16}-01", # 全零 span-id（W3C 禁止）
      "ff-#{"a" * 32}-#{"b" * 16}-01", # 版本 ff
    ]
    bad_parents.each do |bad|
      Troupe::TraceContext.valid?(bad).should be_false
      Troupe::TraceContext.trace_id_of(bad).should be_nil
      child = Troupe::TraceContext.child_span(bad)
      Troupe::TraceContext.valid?(child).should be_true # 降级为新根 span
    end
  end

  it "无父调用：Turn 生成合法根 span，两次调用 trace-id 相互独立" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    traces = [] of Troupe::TraceEvent
    rehearsal.stage.on_trace { |t| traces << t }
    id = rehearsal.actor("counter", "roots")

    first = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    first.await.as_i.should eq(1)
    second = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    second.await.as_i.should eq(2)

    traces.size.should eq(2)
    first_trace_id = Troupe::TraceContext.trace_id_of(traces[0].traceparent).not_nil!
    second_trace_id = Troupe::TraceContext.trace_id_of(traces[1].traceparent).not_nil!
    first_trace_id.should_not eq(second_trace_id) # 各自新 trace
    traces[0].parent_traceparent.should be_nil
    traces[0].outcome.should eq("completed")
    traces[0].ok.should be_true
    traces[0].duration.total_nanoseconds.should be >= 0
  end

  it "调用链传播：Actor 互调经 ctx.traceparent 显式传父（M2 无隐式传播）" do
    rehearsal = Troupe::Rehearsal.new
    stage = rehearsal.stage
    TroupeFixtures.register_counter(stage, "leaf")
    stage.register(Troupe::Manifest(CounterProps).define("root", CounterActor) do |m|
      m.schema_version 1
      m.initial { CounterProps.new }
      m.turn "hop", CounterActor do |actor, ctx, args|
        # fire-and-forget：入队 leaf，不在 Turn 内 await（manual 模式同 Fiber await 会阻塞）
        stage.call(rehearsal.actor("leaf", "1"), "increment", TroupeFixtures.counter_args(2), nil, ctx.traceparent)
        JSON::Any.new(nil)
      end
    end)
    traces = [] of Troupe::TraceEvent
    stage.on_trace { |t| traces << t }

    rehearsal.agent.call(rehearsal.actor("root", "1"), "hop")
    rehearsal.pump_all # 依次执行 root、leaf

    traces.size.should eq(2)
    root_trace = traces.find { |t| t.method == "hop" }.not_nil!
    leaf_trace = traces.find { |t| t.method == "increment" }.not_nil!

    leaf_trace.parent_traceparent.should eq(root_trace.traceparent) # B 的父 = A 的 span
    Troupe::TraceContext.trace_id_of(leaf_trace.traceparent).should eq(
      Troupe::TraceContext.trace_id_of(root_trace.traceparent))  # 同一 trace
    leaf_trace.traceparent.should_not eq(root_trace.traceparent) # 各自 span
    CounterProps.from_json(rehearsal.store.read(rehearsal.actor("leaf", "1")).not_nil!.data).count.should eq(2)
  end

  it "metrics：lifecycle 与调用计数与事件一致" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "m")

    future = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(2))
    rehearsal.pump_all
    future.await.as_i.should eq(2)

    metrics = rehearsal.stage.metrics
    metrics.counter("activations").should eq(1_u64)
    metrics.counter("activation_failures").should eq(0_u64)
    metrics.counter("turns_started").should eq(1_u64)
    metrics.counter("turns_completed").should eq(1_u64)
    metrics.counter("turns_failed").should eq(0_u64)
    metrics.counter("turns_expired").should eq(0_u64)
    metrics.counter("save_failures").should eq(0_u64)
  end

  it "metrics：激活失败/业务失败/过期/拒绝计数反例" do
    rehearsal = Troupe::Rehearsal.new
    FlakyActor.fail_on_stage!
    rehearsal.stage.register(Troupe::Manifest(FlakyProps).define("flaky", FlakyActor) do |m|
      m.schema_version 1
      m.initial { FlakyProps.new }
      m.turn("bump", FlakyActor) { |actor, ctx, args| JSON::Any.new(nil) }
    end)
    TroupeFixtures.register_counter(rehearsal.stage)
    TroupeFixtures.register_idem(rehearsal.stage)
    flaky_id = rehearsal.actor("flaky", "1")
    counter_id = rehearsal.actor("counter", "r")
    order_id = rehearsal.actor("order", "f")
    id = rehearsal.actor("counter", "expired")

    # 激活失败
    failed_activation = rehearsal.agent.call(flaky_id, "bump")
    rehearsal.pump_all
    expect_raises(Troupe::ActivationError) { failed_activation.await }

    # 业务失败（非保存失败）
    failed_turn = rehearsal.agent.call(order_id, "charge", JSON.parse(%({"order_id": "o", "amount": 1, "fail": true})))
    rehearsal.pump_all
    expect_raises(Troupe::SerializationError) { failed_turn.await }

    # 排队过期
    expired = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1), deadline: 2.seconds)
    rehearsal.advance(5.seconds)
    rehearsal.pump_all
    expect_raises(Troupe::CallTimeoutError) { expired.await }

    # 白名单拒绝
    expect_raises(Troupe::CallRejectedError) { rehearsal.agent.call(counter_id, "on_stage") }

    metrics = rehearsal.stage.metrics
    metrics.counter("activation_failures").should eq(1_u64)
    metrics.counter("turns_failed").should eq(1_u64)
    metrics.counter("turns_expired").should eq(1_u64)
    metrics.role_counter("rejections", "counter").should eq(1_u64)
    metrics.counter("turns_completed").should eq(0_u64)
    metrics.counter("save_failures").should eq(0_u64)
  end

  it "metrics：保存失败（fencing）计入 save_failures 与 turns_failed" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    id = rehearsal.actor("counter", "sf")

    first = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    first.await.as_i.should eq(1)

    # 模拟另一 owner 提交新状态 → 旧实例 save 被拒并失效
    record = rehearsal.store.read(id).not_nil!
    new_epoch = rehearsal.ownership.acquire(id)
    rehearsal.store.write(id, record.revision, record.schema_version, %({"count":50}), new_epoch)

    stale = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1))
    rehearsal.pump_all
    expect_raises(Troupe::CallRejectedError) { stale.await }

    metrics = rehearsal.stage.metrics
    metrics.counter("save_failures").should eq(1_u64)
    metrics.counter("turns_failed").should eq(1_u64)
  end

  it "trace：过期 Turn 产出 outcome=expired 事件" do
    rehearsal = Troupe::Rehearsal.new
    TroupeFixtures.register_counter(rehearsal.stage)
    traces = [] of Troupe::TraceEvent
    rehearsal.stage.on_trace { |t| traces << t }
    id = rehearsal.actor("counter", "expired-trace")

    future = rehearsal.agent.call(id, "increment", TroupeFixtures.counter_args(1), deadline: 2.seconds)
    rehearsal.advance(5.seconds)
    rehearsal.pump_all
    expect_raises(Troupe::CallTimeoutError) { future.await }

    traces.size.should eq(1)
    traces[0].outcome.should eq("expired")
    traces[0].ok.should be_false
    traces[0].duration.should eq(Time::Span.zero)
  end
end
