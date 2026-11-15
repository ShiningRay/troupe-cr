require "./spec_helper"

# PLAN M4 首项：ReadOnly 快照并发 + 显式 Improv 规则（写饥饿/quiesce 反例）。
class RwProps
  include JSON::Serializable
  property count : Int32 = 0

  def initialize
  end
end

class RwActor < Troupe::Actor(RwProps)
  # 缓冲 8 令牌：open! 早于 turn 到达 gate.receive 时令牌可等待（测试稳定性）
  @@gate : Channel(Nil) = Channel(Nil).new(8)
  @@concurrent_peak = 0
  @@in_read_only = 0

  def self.gate
    @@gate
  end

  def self.open!
    @@gate.send(nil)
  rescue
    nil
  end

  def self.reset!
    @@gate = Channel(Nil).new(8) # buffered: open! must not block when no receiver
    @@concurrent_peak = 0
    @@in_read_only = 0
  end

  def self.concurrent_peak
    @@concurrent_peak
  end

  def enter_read_only
    @@in_read_only += 1
    @@concurrent_peak = @@in_read_only if @@in_read_only > @@concurrent_peak
  end

  def leave_read_only
    @@in_read_only -= 1
  end
end

def rw_setup(mode : Troupe::SchedulerMode)
  RwActor.reset!
  stage = Troupe::Stage.new(mode: mode)
  stage.register(Troupe::Manifest(RwProps).define("rw", RwActor) do |m|
    m.schema_version 1
    m.initial { RwProps.new }
    m.turn "slow_read", RwActor, :read_only do |actor, ctx, args|
      actor.enter_read_only
      begin
        RwActor.gate.receive # 阻塞：模拟长只读
      ensure
        actor.leave_read_only
      end
      JSON::Any.new(actor.props.count.to_i64)
    end
    m.turn "quick_write", RwActor do |actor, ctx, args|
      actor.props.count += args["by"].as_i
      actor.save
      JSON::Any.new(actor.props.count.to_i64)
    end
    m.turn "improv_add", RwActor, :improv do |actor, ctx, args|
      RwActor.gate.receive # 等待测试推进 strict（制造确定性 CAS 冲突窗口）
      actor.props.count += args["by"].as_i
      actor.save # improv：以激活时 revision CAS——期间 strict 推进则显式冲突
      JSON::Any.new(actor.props.count.to_i64)
    end
    m.turn "read_count", RwActor, :read_only do |actor, ctx, args|
      JSON::Any.new(actor.props.count.to_i64)
    end
    m.turn "forbidden_write", RwActor, :read_only do |actor, ctx, args|
      actor.props.count += 1
      actor.save # read_only 内写 → 显式拒绝
      JSON::Any.new(actor.props.count.to_i64)
    end
  end)
  stage
end

describe "M4 read_only & improv" do
  it "read_only 并发：长只读阻塞期间后续只读经并发通道立即完成（Fiber 模式）" do
    stage = rw_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "rw", "conc")

      # 长只读占住并发通道（gate 阻塞）
      slow_done = Channel(::JSON::Any).new
      spawn do
        begin
          slow_done.send(stage.call(id, "slow_read", JSON.parse(%({})), deadline: 8.seconds).await)
        rescue e : ::Exception
          slow_done.send(JSON::Any.new(-1_i64))
        end
      end
      sleep(150.milliseconds) # slow_read 已执行并阻塞

      # 后续只读经并发通道立即完成（不排在 slow_read 之后——并发性证明）
      second = stage.call(id, "read_count", JSON.parse(%({})), deadline: 2.seconds)
      second.await.as_i.should eq(0)

      # strict 写同样不被只读阻塞（写饥饿反证的对照）
      write = stage.call(id, "quick_write", TroupeFixtures.counter_args(3), deadline: 2.seconds)
      write.await.as_i.should eq(3)

      RwActor.open!                       # 放行 slow_read（其快照 count 仍为旧值——只读不写）
      slow_done.receive.as_i.should eq(0) # 只读快照 = 进入时的已提交状态
      RwProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(3)
      stage.shutdown
    ensure
      RwActor.open!
      stage.shutdown
    end
  end

  it "写饥饿反例：长只读执行期间 strict 写立即完成（不被只读阻塞）" do
    stage = rw_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "rw", "starve")
      read_done = Channel(Nil).new
      spawn do
        stage.call(id, "slow_read", JSON.parse(%({})), deadline: 10.seconds).await
        read_done.send(nil)
      end
      sleep(100.milliseconds) # slow_read 已执行并阻塞在 gate

      # strict 写立即完成：read_only 不占 strict 串行通道（写不饥饿）
      write = stage.call(id, "quick_write", TroupeFixtures.counter_args(5), deadline: 2.seconds)
      write.await.as_i.should eq(5)

      RwProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(5)
      RwActor.open!
      read_done.receive
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "read_only 看到已提交快照：strict 未提交状态不可见" do
    stage = rw_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "rw", "snap")
      # strict 写并提交
      stage.call(id, "quick_write", TroupeFixtures.counter_args(7)).await.as_i.should eq(7)
      read = stage.call(id, "read_count", JSON.parse(%({}))).await
      read.as_i.should eq(7) # 只读快照 = 已提交状态
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "read_only 内 save 显式拒绝（快照只读，InvalidActorStateError）" do
    stage = rw_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "rw", "forbid")
      error = expect_raises(Troupe::InvalidActorStateError) do
        stage.call(id, "forbidden_write", JSON.parse(%({}))).await
      end
      error.message.not_nil!.should contain("read_only")
      # 激活本身会 create Props（revision 1），但 read_only 内 save 被拒 → 未产生任何写入
      RwProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(0)
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "improv 冲突显式拒绝：期间 strict 推进 revision → CAS 失败 → ConflictError 给 improv 调用方，无隐式覆盖" do
    stage = rw_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "rw", "improv")
      stage.call(id, "quick_write", TroupeFixtures.counter_args(1)).await.as_i.should eq(1)

      # improv turn 阻塞在 gate（已读取旧快照 revision）
      improv_done = Channel(::Exception | ::JSON::Any).new
      spawn do
        begin
          improv_done.send(stage.call(id, "improv_add", JSON.parse(%({"by": 10})))
            .await)
        rescue e : ::Exception
          improv_done.send(e)
        end
      end
      sleep(100.milliseconds)

      # 期间 strict 写推进 revision
      stage.call(id, "quick_write", TroupeFixtures.counter_args(5)).await.as_i.should eq(6)

      RwActor.open!
      error = improv_done.receive
      error.should be_a(Troupe::ConflictError)                                 # 显式冲突拒绝（禁止隐式覆盖）
      RwProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(6) # improv 写未生效
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "improv 无冲突：CAS 成功提交（显式规则下的合法并发写）" do
    stage = rw_setup(Troupe::SchedulerMode::Fiber)
    begin
      id = Troupe::ActorId.new("app", "rw", "improv-ok")
      stage.call(id, "quick_write", TroupeFixtures.counter_args(1)).await.as_i.should eq(1)

      result_channel = Channel(::Exception | ::JSON::Any).new
      spawn do
        begin
          result_channel.send(stage.call(id, "improv_add", JSON.parse(%({"by": 4})), deadline: 10.seconds).await)
        rescue e : ::Exception
          result_channel.send(e)
        end
      end
      sleep(100.milliseconds)
      RwActor.open! # 放行 improv：无并发写 → CAS 成功
      result = result_channel.receive
      if result.is_a?(::Exception)
        raise result
      end
      result.as_i.should eq(5)
      RwProps.from_json(stage.store.read(id).not_nil!.data).count.should eq(5)
      stage.shutdown
    ensure
      stage.shutdown
    end
  end

  it "quiesce 反例：drain/idle 等待并发只读在飞完成（Manual 确定性）" do
    stage = rw_setup(Troupe::SchedulerMode::Manual)
    begin
      id = Troupe::ActorId.new("app", "rw", "quiesce")

      # 先入队（Manual：并发 read_only 同步执行，阻塞在 gate=在飞）→ 再 drain
      blocked_read = spawn do
        begin
          stage.call(id, "slow_read", JSON.parse(%({})), deadline: 10.seconds).await
        rescue e : ::Exception
          nil
        end
      end
      sleep(80.milliseconds)
      stage.idle?.should be_false # 并发在飞（quiesce 未达成）

      stage.begin_drain
      stage.idle?.should be_false # drain 等待在飞 read_only（不能立即完成）

      RwActor.open!
      deadline_wait = ::Time.instant + 5.seconds
      while !stage.idle? && ::Time.instant < deadline_wait
        sleep(20.milliseconds)
      end
      stage.idle?.should be_true # 在飞完成后 quiesce 达成
      stage.finish_drain
      stage.closed?.should be_true
    ensure
      RwActor.open!
      stage.shutdown
    end
  end
end
