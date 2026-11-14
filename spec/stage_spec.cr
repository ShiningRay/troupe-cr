require "./spec_helper"

# Fiber 调度模式（真实并发路径）的核心语义验证。
describe Troupe::Stage, tags: "fiber-mode" do
  it "并发首调只激活一次（single-flight，PLAN M1 验收）" do
    CounterActor.reset_log!
    stage = Troupe::Stage.new
    TroupeFixtures.register_counter(stage)
    id = Troupe::ActorId.new("app", "counter", "once")

    results = Channel(Int32).new(32)
    32.times do
      spawn do
        future = stage.call(id, "increment", TroupeFixtures.counter_args(1))
        results.send(future.await.as_i)
      end
    end

    values = 32.times.map { results.receive }.to_a
    values.size.should eq(32)
    CounterActor.log.select(&.starts_with?("on:")).size.should eq(1)
    CounterProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(32)
  end

  it "100 个写 Turn 不交错：strict 串行下无丢失更新（PLAN M1 验收）" do
    CounterActor.reset_log!
    stage = Troupe::Stage.new(config: Troupe::StageConfig.new(max_queue_depth: 128))
    TroupeFixtures.register_counter(stage)
    id = Troupe::ActorId.new("app", "counter", "hot")

    results = Channel(Int32).new(100)
    100.times do
      spawn do
        future = stage.call(id, "increment", TroupeFixtures.counter_args(1))
        results.send(future.await.as_i)
      end
    end

    values = 100.times.map { results.receive }.to_a
    # Turn 内部含 Fiber.yield 读-写窗口；若发生交错，结果将出现重复值
    values.sort.should eq((1..100).to_a)
    CounterProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(100)
  end

  it "Stage activation 数达到上限后显式拒绝（Backpressure 可重试）" do
    stage = Troupe::Stage.new(config: Troupe::StageConfig.new(max_activations: 1))
    TroupeFixtures.register_counter(stage)
    a = Troupe::ActorId.new("app", "counter", "a")
    b = Troupe::ActorId.new("app", "counter", "b")

    stage.call(a, "increment", TroupeFixtures.counter_args(1))
    error = expect_raises(Troupe::CallRejectedError) do
      stage.call(b, "increment", TroupeFixtures.counter_args(1))
    end
    error.reason.backpressure?.should be_true
    error.retryable.should be_true
  end

  it "生命周期/内部方法被白名单拒绝（DESIGN §4.2）" do
    stage = Troupe::Stage.new
    TroupeFixtures.register_counter(stage)
    id = Troupe::ActorId.new("app", "counter", "wl")

    ["on_stage", "off_stage", "save", "props"].each do |name|
      error = expect_raises(Troupe::CallRejectedError) do
        stage.call(id, name)
      end
      error.reason.whitelist?.should be_true
    end

    error = expect_raises(Troupe::CallRejectedError) do
      stage.call(id, "no_such_method")
    end
    error.reason.whitelist?.should be_true
  end

  it "未注册角色报 UnknownRoleError" do
    stage = Troupe::Stage.new
    TroupeFixtures.register_counter(stage)
    expect_raises(Troupe::UnknownRoleError) do
      stage.call(Troupe::ActorId.new("app", "ghost", "1"), "increment")
    end
  end

  it "on_stage 失败报 ActivationError，后续调用从干净状态重试新激活" do
    FlakyActor.fail_on_stage!
    stage = Troupe::Stage.new
    stage.register(Troupe::Manifest(FlakyProps).define("flaky", FlakyActor) do |m|
      m.schema_version 1
      m.initial { FlakyProps.new }
      m.turn("bump", FlakyActor) do |actor, ctx, args|
        old = actor.props.count
        actor.props.count = old + 1
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)
    id = Troupe::ActorId.new("app", "flaky", "1")

    first = stage.call(id, "bump")
    expect_raises(Troupe::ActivationError, "on_stage 注入失败") { first.await }

    FlakyActor.allow_on_stage!
    second = stage.call(id, "bump")
    second.await.as_i.should eq(1)
  end

  it "停机后拒收新 Call（CallRejectedError(:shutdown)）" do
    stage = Troupe::Stage.new
    TroupeFixtures.register_counter(stage)
    id = Troupe::ActorId.new("app", "counter", "sh")

    stage.shutdown
    stage.closed?.should be_true
    error = expect_raises(Troupe::CallRejectedError) do
      stage.call(id, "increment", TroupeFixtures.counter_args(1))
    end
    error.reason.shutdown?.should be_true
  end
end
