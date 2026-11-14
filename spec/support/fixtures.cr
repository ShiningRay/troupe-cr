# 测试夹具：多个 spec 共享的角色定义与注册助手。
# 所有类位于全局命名空间，spec 间通过 class 级日志隔离测试状态。
class CounterProps
  include JSON::Serializable
  property count : Int32 = 0

  def initialize
  end
end

class CounterActor < Troupe::Actor(CounterProps)
  @@log = [] of String

  def self.log
    @@log
  end

  def self.reset_log!
    @@log = [] of String
  end

  def on_stage : Nil
    @@log << "on:#{actor_id}"
    Fiber.yield # 放宽激活竞争窗口
  end

  def off_stage : Nil
    @@log << "off:#{actor_id}"
  end

  def increment(by : Int32) : Int32
    old = props.count
    Fiber.yield # 放宽读-写窗口：若 strict 串行被破坏，这里会暴露丢失更新
    props.count = old + by
    save
    props.count
  end
end

class SlowProps
  include JSON::Serializable
  property count : Int32 = 0

  def initialize
  end
end

class SlowActor < Troupe::Actor(SlowProps)
end

class FlakyProps
  include JSON::Serializable
  property count : Int32 = 0

  def initialize
  end
end

class FlakyActor < Troupe::Actor(FlakyProps)
  @@fail_on_stage = true

  def self.fail_on_stage!
    @@fail_on_stage = true
  end

  def self.allow_on_stage!
    @@fail_on_stage = false
  end

  def on_stage : Nil
    raise Troupe::SerializationError.new("on_stage 注入失败") if @@fail_on_stage
  end
end

class CartPropsV1
  include JSON::Serializable
  property items : Array(String) = [] of String

  def initialize
  end
end

class CartPropsV2
  include JSON::Serializable
  property items : Array(String) = [] of String
  property gift_wrap : Bool = false

  def initialize
  end
end

class CartPropsV3
  include JSON::Serializable
  property items : Array(String) = [] of String
  property gift_wrap : Bool = false
  property currency : String = "USD"

  def initialize
  end
end

class CartActor < Troupe::Actor(CartPropsV3)
  def add_item(item : String) : Int32
    props.items << item
    save
    props.items.size
  end
end

class IdemProps
  include JSON::Serializable
  property charged : Int32 = 0

  def initialize
  end
end

class IdemActor < Troupe::Actor(IdemProps)
end

class LoopProps
  include JSON::Serializable
  property count : Int32 = 0

  def initialize
  end
end

class LoopActor < Troupe::Actor(LoopProps)
end

class GateProps
  include JSON::Serializable
  property count : Int32 = 0

  def initialize
  end
end

class GateActor < Troupe::Actor(GateProps)
  @@gate : Channel(Nil) = Channel(Nil).new
  @@executions = 0

  def self.gate
    @@gate
  end

  def self.executions
    @@executions
  end

  def self.record_execution
    @@executions += 1
  end

  def self.reset!
    @@gate = Channel(Nil).new
    @@executions = 0
  end
end

module TroupeFixtures
  extend self

  # SQLite spec 用临时库文件路径（清理由调用方 ensure 处理，须先 close 释放句柄）。
  def temp_db_path : String
    Path.new(Dir.tempdir, "troupe-sqlite-spec-#{Random.new.next_int}.db").to_posix.to_s
  end

  def counter_args(by : Int32) : JSON::Any
    JSON.parse(%({"by": #{by}}))
  end

  def register_counter(stage : Troupe::Stage, role : String = "counter") : Nil
    stage.register(Troupe::Manifest(CounterProps).define(role, CounterActor) do |m|
      m.schema_version 1
      m.initial { CounterProps.new }
      m.turn "increment", CounterActor do |actor, ctx, args|
        JSON::Any.new(actor.increment(args["by"].as_i).to_i64)
      end
    end)
  end

  def register_slow(stage : Troupe::Stage, role : String = "slow") : Nil
    stage.register(Troupe::Manifest(SlowProps).define(role, SlowActor) do |m|
      m.schema_version 1
      m.initial { SlowProps.new }
      m.turn "slow_increment", SlowActor do |actor, ctx, args|
        # 用虚拟时钟模拟长执行，确定性制造执行超时（该 Turn 需要 VirtualClock 宿主）
        ctx.clock.as(Troupe::VirtualClock).advance(120.seconds)
        old = actor.props.count
        actor.props.count = old + 1
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
      m.turn "bump", SlowActor do |actor, ctx, args|
        old = actor.props.count
        actor.props.count = old + 1
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)
  end

  def cart_step_1_2 : Troupe::MigrationStep(CartPropsV1, CartPropsV2)
    Troupe::MigrationStep(CartPropsV1, CartPropsV2).new(1, 2) do |v1|
      v2 = CartPropsV2.new
      v2.items = v1.items
      v2
    end
  end

  def cart_step_2_3 : Troupe::MigrationStep(CartPropsV2, CartPropsV3)
    Troupe::MigrationStep(CartPropsV2, CartPropsV3).new(2, 3) do |v2|
      v3 = CartPropsV3.new
      v3.items = v2.items
      v3.gift_wrap = v2.gift_wrap
      v3
    end
  end

  def register_cart(stage : Troupe::Stage, role : String = "cart",
                    steps : Array(Troupe::MigrationStepBase)? = nil) : Nil
    stage.register(Troupe::Manifest(CartPropsV3).define(role, CartActor) do |m|
      m.schema_version 3
      m.initial { CartPropsV3.new }
      (steps || [cart_step_1_2, cart_step_2_3]).each { |step| m.migrate(step) }
      m.turn "add_item", CartActor do |actor, ctx, args|
        JSON::Any.new(actor.add_item(args["item"].as_s).to_i64)
      end
    end)
  end

  # 直接在 store 写入一份 v1 Props（模拟旧版本存量数据）。epoch 取自 ownership，保证 fencing 合法。
  def seed_v1_cart(rehearsal : Troupe::Rehearsal, id : Troupe::ActorId, items : Array(String)) : Nil
    epoch = rehearsal.ownership.acquire(id)
    v1 = CartPropsV1.new
    v1.items = items
    rehearsal.store.create(id, 1, v1.to_json, epoch)
  end

  # 幂等扣款：args 全量 JSON 作为参数指纹；fail=true 注入业务失败。
  def register_idem(stage : Troupe::Stage, role : String = "order") : Nil
    stage.register(Troupe::Manifest(IdemProps).define(role, IdemActor) do |m|
      m.schema_version 1
      m.initial { IdemProps.new }
      m.turn "charge", IdemActor do |actor, ctx, args|
        actor.idempotent(args["order_id"].as_s, args.to_json) do
          if args["fail"]? && args["fail"].as_bool
            raise Troupe::SerializationError.new("注入扣款失败")
          end
          actor.props.charged += args["amount"].as_i
          JSON::Any.new(actor.props.charged.to_i64)
        end
      end
    end)
  end

  # 协作取消：steps 轮询 cancel_requested?；full 不观察信号。
  def register_loop(stage : Troupe::Stage, role : String = "loop") : Nil
    stage.register(Troupe::Manifest(LoopProps).define(role, LoopActor) do |m|
      m.schema_version 1
      m.initial { LoopProps.new }
      m.turn "steps", LoopActor do |actor, ctx, args|
        done = 0
        while done < args["max"].as_i
          break if ctx.cancel_requested?
          done += 1
        end
        actor.props.count = done
        actor.save
        JSON::Any.new(done.to_i64)
      end
      m.turn "full", LoopActor do |actor, ctx, args|
        actor.props.count = args["max"].as_i
        actor.save
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)
  end
end
