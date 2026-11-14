require "./spec_helper"

# PLAN M2 第四项：类型安全 Agent/宏 manifest、参数校验（含反例）。
class TypedCartProps
  include JSON::Serializable
  property items : Array(String) = [] of String
  property gift_wrap : Bool = false

  def initialize
  end
end

class TypedCartActor < Troupe::Actor(TypedCartProps)
  troupe_manifest "typed-cart", schema_version: 1 do
    turn add_item, {item: String, qty: Int32?}, returns: Int32
    turn set_gift, {on: Bool}, returns: Bool
    turn count_items, {} of String => String, returns: Int32
    turn find_items, {keyword: String}, returns: JSON::Any
  end

  def add_item(item : String, qty : Int32?) : Int32
    n = qty || 1
    n.times { props.items << item }
    save
    props.items.size
  end

  def set_gift(on : Bool) : Bool
    props.gift_wrap = on
    save
    props.gift_wrap
  end

  def count_items : Int32
    props.items.size
  end

  def find_items(keyword : String) : JSON::Any
    Troupe::Json.any(props.items.select(&.includes?(keyword)))
  end
end

describe "M2 typed agent & macro manifest" do
  it "宏 manifest 注册：typed/raw 双路径行为一致；重复注册 RoleConflictError" do
    stage = Troupe::Stage.new
    stage.register(TypedCartActor.troupe_manifest)
    expect_raises(Troupe::RoleConflictError) { stage.register(TypedCartActor.troupe_manifest) }

    id = Troupe::ActorId.new("app", "typed-cart", "1")
    cart = TypedCartActor::Agent.new(stage)

    cart.add_item(id, "pear").should eq(1)    # 可选参数缺省
    cart.add_item(id, "pear", 2).should eq(3) # 显式数量
    cart.set_gift(id, true).should be_true
    cart.count_items(id).should eq(3)
    cart.find_items(id, "ear").as_a.size.should eq(3)

    # raw JSON 路径与 typed 路径语义一致
    raw = stage.call(id, "count_items", JSON.parse(%({})))
    raw.await.as_i.should eq(3)
    stage.registered_roles.should eq(["typed-cart"])
  end

  it "参数校验：缺参/类型不符在排队前拒绝，零副作用" do
    stage = Troupe::Stage.new
    stage.register(TypedCartActor.troupe_manifest)
    id = Troupe::ActorId.new("app", "typed-cart", "v")

    error = expect_raises(Troupe::InvalidArgumentError) do
      stage.call(id, "add_item", JSON.parse(%({}))) # 缺 item
    end
    error.message.not_nil!.should contain("缺少参数")
    stage.store.read(id).should be_nil # 未激活、未入队

    expect_raises(Troupe::InvalidArgumentError) do
      stage.call(id, "add_item", JSON.parse(%({"item": 42}))) # String 位置给了数字
    end

    expect_raises(Troupe::InvalidArgumentError) do
      stage.call(id, "add_item", JSON.parse(%({"item": "x", "qty": "many"}))) # 可选参数类型不符
    end

    # 非对象参数
    expect_raises(Troupe::InvalidArgumentError) do
      stage.call(id, "count_items", JSON.parse(%(3)))
    end
  end

  it "参数校验：可缺省参数缺省通过、出现须匹配；拒绝计入 rejections 指标" do
    stage = Troupe::Stage.new
    stage.register(TypedCartActor.troupe_manifest)
    id = Troupe::ActorId.new("app", "typed-cart", "opt")

    ok = stage.call(id, "add_item", JSON.parse(%({"item": "pear"})))
    ok.await.as_i.should eq(1) # qty 缺省

    error = expect_raises(Troupe::CallRejectedError) do
      stage.call(id, "save") # 生命周期方法先被白名单拒绝（校验顺序：白名单 → 参数）
    end
    error.reason.whitelist?.should be_true
    stage.metrics.role_counter("rejections", "typed-cart").should eq(1_u64)
  end

  it "typed agent：traceparent 透传到 Turn trace 事件" do
    stage = Troupe::Stage.new
    stage.register(TypedCartActor.troupe_manifest)
    traces = [] of Troupe::TraceEvent
    stage.on_trace { |t| traces << t }
    id = Troupe::ActorId.new("app", "typed-cart", "trace")

    parent = Troupe::TraceContext.new_span
    cart = TypedCartActor::Agent.new(stage)
    cart.add_item(id, "pear", nil, nil, parent).should eq(1) # deadline/traceparent 走默认占位

    traces.size.should eq(1)
    traces[0].parent_traceparent.should eq(parent)
    Troupe::TraceContext.trace_id_of(traces[0].traceparent).should eq(Troupe::TraceContext.trace_id_of(parent))
  end

  it "Troupe::Json.any：任意可序列化值经完整边界" do
    Troupe::Json.any([1, 2]).as_a.map(&.as_i).should eq([1, 2])
    Troupe::Json.any("x").as_s.should eq("x")
    Troupe::Json.any(nil).raw.should be_nil
    props = TypedCartProps.new
    props.items = ["a"]
    Troupe::Json.any(props).as_h["items"].as_a.size.should eq(1)
  end
end
