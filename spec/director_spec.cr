require "./spec_helper"

# PLAN M4 第四项：Director/健康与指标端点——故障与未知结果可见（含反例）。
def director_setup(mode : Troupe::SchedulerMode = Troupe::SchedulerMode::Manual,
                   event_limit : Int32 = 200)
  stage = Troupe::Stage.new(mode: mode, name: "main")
  TroupeFixtures.register_counter(stage)
  director = Troupe::Director.new(event_limit: event_limit)
  director.add_stage("main", stage)
  {stage, director}
end

describe "M4 Director/健康与指标端点" do
  it "health：生命周期状态可见（running/draining/closed）" do
    stage, director = director_setup
    begin
      health = director.health
      health["ok"].as_bool.should be_true
      health["stages"]["main"]["status"].as_s.should eq("running")

      stage.begin_drain
      director.health["stages"]["main"]["status"].as_s.should eq("draining")

      stage.shutdown
      director.health["stages"]["main"]["status"].as_s.should eq("closed")
      director.health["ok"].as_bool.should be_false # 全部关闭 → 不健康
    ensure
      stage.shutdown
    end
  end

  it "故障可见：激活失败/保存失败/排队过期计数与最近事件可查" do
    stage, director = director_setup
    begin
      # 激活失败（FlakyActor on_stage 注入）
      FlakyActor.fail_on_stage!
      stage.register(Troupe::Manifest(FlakyProps).define("flaky", FlakyActor) do |m|
        m.schema_version 1
        m.initial { FlakyProps.new }
        m.turn("bump", FlakyActor) { |a, c, x| JSON::Any.new(nil) }
      end)
      bad = stage.call(Troupe::ActorId.new("app", "flaky", "1"), "bump")
      stage.pump(Troupe::ActorId.new("app", "flaky", "1")) # Manual：激活在 pump 执行
      expect_raises(Troupe::ActivationError) { bad.await }

      # 保存失败（CAS 冲突）
      cid = Troupe::ActorId.new("app", "counter", "f")
      ok_call = stage.call(cid, "increment", TroupeFixtures.counter_args(1))
      stage.pump(cid) # Manual：Turn 在 pump 执行
      ok_call.await.as_i.should eq(1)
      record = stage.store.read(cid).not_nil!
      store = stage.store.as(Troupe::MemoryPropStore)
      store.write(cid, record.revision, record.schema_version, %({"count":100}), record.epoch)

      stale = stage.call(cid, "increment", TroupeFixtures.counter_args(1))
      stage.pump(cid)
      expect_raises(Troupe::ConflictError) { stale.await }

      # 排队过期（Manual：排队过期在 pump 时判定）
      expired = stage.call(cid, "increment", TroupeFixtures.counter_args(1), deadline: 1.milliseconds)
      sleep(5.milliseconds)
      stage.pump(cid) # pump 触发排队过期判定 → 回复 :queued
      expect_raises(Troupe::CallTimeoutError) { expired.await }

      metrics = director.metrics["stages"]["main"]
      metrics["activation_failures"].as_i.should eq(1)
      metrics["save_failures"].as_i.should eq(1)
      metrics["turns_expired"].as_i.should eq(1)
      metrics["turns_failed"].as_i.should eq(1)
      metrics["turns_completed"].as_i.should eq(1)

      # 最近事件可见：SaveFailed/ActivationFailed/TurnExpired 均在样本中
      events = director.recent_events(50)
      events.map(&.type).should contain(Troupe::EventType::SaveFailed)
      events.map(&.type).should contain(Troupe::EventType::ActivationFailed)
      events.map(&.type).should contain(Troupe::EventType::TurnExpired)

      # 事件 JSON 可构建（HTTP /events 的载荷形态）；类型为 CamelCase 枚举名
      director.events_json(50).should contain("SaveFailed")
    ensure
      stage.shutdown
    end
  end

  it "管理操作：drain_stage/shutdown_stage 生效" do
    stage, director = director_setup
    begin
      director.drain_stage("main")
      stage.draining?.should be_true
      director.shutdown_stage("main")
      stage.closed?.should be_true
      director.stage("missing").should be_nil
    ensure
      stage.shutdown
    end
  end

  it "HTTP 端点：/health 与 /metrics 返回 200 JSON；未知路径 404" do
    stage, director = director_setup(Troupe::SchedulerMode::Fiber)
    begin
      endpoint = Troupe::HTTPEndpoint.new(director, "127.0.0.1", 0)
      port = endpoint.listen
      id = Troupe::ActorId.new("app", "counter", "http")
      stage.call(id, "increment", TroupeFixtures.counter_args(2)).await.as_i.should eq(2)

      health = HTTP::Client.get("http://127.0.0.1:#{port}/health")
      health.status_code.should eq(200)
      body = JSON.parse(health.body)
      body["ok"].as_bool.should be_true
      body["stages"]["main"]["status"].as_s.should eq("running")

      metrics = HTTP::Client.get("http://127.0.0.1:#{port}/metrics")
      metrics.status_code.should eq(200)
      JSON.parse(metrics.body)["stages"]["main"]["turns_completed"].as_i.should eq(1)

      events = HTTP::Client.get("http://127.0.0.1:#{port}/events?limit=10")
      events.status_code.should eq(200)
      JSON.parse(events.body).as_a.size.should be > 0

      not_found = HTTP::Client.get("http://127.0.0.1:#{port}/nope")
      not_found.status_code.should eq(404)
      endpoint.close
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "事件环形上限：超出 limit 的旧事件被丢弃（内存有界）" do
    stage, director = director_setup(Troupe::SchedulerMode::Fiber, event_limit: 5)
    begin
      id = Troupe::ActorId.new("app", "counter", "ring")
      10.times do
        stage.call(id, "increment", TroupeFixtures.counter_args(1)).await.as_i
      end
      director.recent_events(50).size.should eq(5) # 环形上限生效
    ensure
      stage.shutdown
    end
  end
end
