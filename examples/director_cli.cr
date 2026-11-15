# Director CLI 演示（PLAN M4）：启动 Stage + Director + HTTP 健康端点，
# 演示故障可见（注入激活失败）并通过 HTTP 查询 /health /metrics /events。
# 运行：crystal run examples/director_cli.cr
require "../src/troupe"

class CliProps
  include JSON::Serializable
  property n : Int32 = 0

  def initialize
  end
end

class CliActor < Troupe::Actor(CliProps)
end

stage = Troupe::Stage.new(name: "cli")
stage.register(Troupe::Manifest(CliProps).define("cli", CliActor) do |m|
  m.schema_version 1
  m.initial { CliProps.new }
  m.turn("tick", CliActor) do |actor, ctx, args|
    actor.props.n += 1
    actor.save
    JSON::Any.new(actor.props.n.to_i64)
  end
  m.turn "boom", CliActor do |actor, ctx, args|
    raise Troupe::SerializationError.new("演示故障")
  end
end)

director = Troupe::Director.new
director.add_stage("cli", stage)

endpoint = Troupe::HTTPEndpoint.new(director, "127.0.0.1", 0)
port = endpoint.listen
puts "Director HTTP 端点: http://127.0.0.1:#{port}/health"

id = Troupe::ActorId.new("cli", "cli", "demo")
client_call = stage.call(id, "tick", JSON.parse(%({})))
stage.pump(id)
client_call.await

boom = stage.call(id, "boom", JSON.parse(%({})))
stage.pump(id)
begin
  boom.await
rescue e : ::Exception
  puts "演示故障已发生（Director 可见）：#{e.message}"
end

puts "--- /health"
puts HTTP::Client.get("http://127.0.0.1:#{port}/health").body
puts "--- /metrics"
puts HTTP::Client.get("http://127.0.0.1:#{port}/metrics").body
puts "--- /events"
puts HTTP::Client.get("http://127.0.0.1:#{port}/events?limit=5").body

endpoint.close
stage.shutdown
puts "CLI 演示完成"
