# Minimal Cart 示例（PLAN M2 第四项）：宏 manifest + 类型安全 Agent + 参数校验。
# 运行：crystal run examples/cart.cr
require "../src/troupe"

class CartProps
  include JSON::Serializable
  property items : Array(String) = [] of String
  property gift_wrap : Bool = false

  def initialize
  end
end

class CartActor < Troupe::Actor(CartProps)
  troupe_manifest "cart", schema_version: 1 do
    turn add_item, {item: String}, returns: Int32
    turn set_gift, {on: Bool}, returns: Bool
    turn item_count, {} of String => String, returns: Int32
    turn find_item, {keyword: String, limit: Int32?}, returns: JSON::Any
  end

  def add_item(item : String) : Int32
    props.items << item
    save
    props.items.size
  end

  def set_gift(on : Bool) : Bool
    props.gift_wrap = on
    save
    props.gift_wrap
  end

  def item_count : Int32
    props.items.size
  end

  def find_item(keyword : String, limit : Int32?) : JSON::Any
    found = props.items.select(&.includes?(keyword)).first(limit || 10)
    Troupe::Json.any(found)
  end
end

stage = Troupe::Stage.new
stage.register(CartActor.troupe_manifest) # 宏生成的 manifest：与手写 define/turn 等价 + 参数 schema

# Turn 边界 trace 与 lifecycle 事件（核心零 OTel 依赖，on_trace 即桥接钩子）
stage.on_trace { |t| puts "[trace] #{t.method} #{t.outcome} trace=#{t.traceparent[0, 13]}..." }

cart = CartActor::Agent.new(stage) # 类型安全代理：编译期校验参数/返回类型
id = Troupe::ActorId.new("shop", "cart", "demo-1")

puts "add_item: #{cart.add_item(id, "pear")}"      # 1
puts "add_item: #{cart.add_item(id, "pineapple")}" # 2
puts "set_gift: #{cart.set_gift(id, true)}"        # true
puts "item_count: #{cart.item_count(id)}"          # 2
puts "find_item: #{cart.find_item(id, "pin", 5)}"  # ["pineapple"]

# 参数校验反例（排队前拒绝，不占用队列）
begin
  stage.call(id, "add_item", JSON.parse(%({}))).await # 缺 item
rescue e : Troupe::InvalidArgumentError
  puts "参数校验拒绝：#{e.message}"
end

begin
  stage.call(id, "add_item", JSON.parse(%({"item": 42}))).await # 类型不符
rescue e : Troupe::InvalidArgumentError
  puts "参数校验拒绝：#{e.message}"
end

# 白名单反例：生命周期/内部方法不可 RPC
begin
  stage.call(id, "save", JSON.parse(%({}))).await
rescue e : Troupe::CallRejectedError
  puts "白名单拒绝：#{e.message}"
end

puts "metrics: turns_completed=#{stage.metrics.counter("turns_completed")} rejections=#{stage.metrics.role_counter("rejections", "cart")}"

stage.shutdown
puts "Cart 示例完成"
