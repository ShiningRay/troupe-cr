module Troupe
  # 类型安全 Agent 基类：`troupe_manifest` 宏为每个角色生成嵌套 `Agent` 代理类。
  # 代理方法在编译期校验参数/返回类型；运行期仍走同一 JSON 边界与语义管道
  # （白名单、deadline、trace、错误分类不变——DESIGN §6：宏只减少样板，不改变语义）。
  abstract class AgentBase
    getter stage : ::Troupe::Stage

    def initialize(@stage : ::Troupe::Stage)
    end

    private def __call(actor_id : ::Troupe::ActorId, method : String, args : ::JSON::Any,
                       deadline : ::Time::Span?, traceparent : ::String?) : ::JSON::Any
      @stage.call(actor_id, method, args, deadline, traceparent).await
    end
  end
end

# 宏 manifest（PLAN M2 第四项）：在角色类内声明 role/schema/turn 参数 schema，
# 生成与手写等价的 Manifest 注册（`turn_with_schema`：JSON 边界 + 参数校验）
# 以及嵌套的类型安全 `Agent` 代理。
#
# ```
# class CartActor < Troupe::Actor(CartProps)
#   troupe_manifest "cart", schema_version: 1 do
#     turn add_item, {item: String}, returns: Int32
#   end
#
#   def add_item(item : String) : Int32
#     props.items << item
#     save
#     props.items.size
#   end
# end
#
# stage.register(CartActor.troupe_manifest)
# cart = CartActor::Agent.new(stage)
# cart.add_item(id, "pear") # => 1，编译期类型安全；缺参/类型不符在排队前被拒
# ```
#
# 支持参数/返回类型：Int32、Int64、String、Bool、Float64、JSON::Any 及参数 `T?` 可选形
# （可缺省，出现时须类型匹配）。原始 `stage.call` 路径的参数校验在排队前由
# `Manifest#validate_args` 执行（缺参/类型不符 → InvalidArgumentError）。
macro troupe_manifest(role_name, schema_version = 1, &block)
  {% begin %}
    {% raise "troupe_manifest 需要 block" unless block %}
    {% raise "#{@type} 必须继承 Troupe::Actor(P)（泛型）才能使用 troupe_manifest" unless @type.superclass.type_vars.size > 0 %}
    {% props_type = @type.superclass.type_vars[0] %}
    {% stmts = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
    {% for stmt in stmts %}
      {% unless stmt.is_a?(Nop) %}
        {% raise "troupe_manifest 块内仅支持 turn 声明，收到 #{stmt.class_name}" unless stmt.is_a?(Call) && stmt.name == "turn" %}
        {% raise "turn #{stmt.args[0].name} 需要 returns 类型（returns: T）" unless stmt.named_args && stmt.named_args.any? { |na| na.name == "returns" } %}
      {% end %}
    {% end %}

    # ---- Manifest 工厂：与手写 define/turn 等价，仅多参数 schema（validate_args 用） ----
    def self.troupe_manifest : ::Troupe::ManifestBase
      ::Troupe::Manifest({{ props_type.id }}).define({{ role_name.id.stringify }}, {{ @type.name.id }}) do |m|
        m.schema_version {{ schema_version }}
        m.initial { {{ props_type.id }}.new }
        {% for stmt in stmts %}
          {% next if stmt.is_a?(Nop) %}
          {% turn_name = stmt.args[0].name %}
          {% args_node = stmt.args[1] %}
          {% arg_pairs = args_node.is_a?(NamedTupleLiteral) ? args_node.to_a : (args_node.is_a?(HashLiteral) && args_node.empty? ? [] of ASTNode : raise "turn #{turn_name} 的参数须为 {name: Type} 命名字面量或空 {} of String => String") %}
          {% returns_node = stmt.named_args.find { |na| na.name == "returns" }.value %}
          {% mode_node = stmt.named_args.find { |na| na.name == "mode" } %}
          {% mode_src = mode_node ? mode_node.value.stringify : nil %}
          {% schema_pairs = [] of String %}
          {% call_args = [] of String %}
          {% for pair in arg_pairs %}
            {% k = pair.first %}
            {% v = pair.last %}
            {% optional = v.is_a?(Generic) %}
            {% base = optional ? v.type_vars[0] : v %}
            {% t_str = base.id.stringify %}
            {% raise "turn #{turn_name} 参数 #{k.id} 类型 #{t_str} 不支持（Int32/Int64/String/Bool/Float64/JSON::Any 及 T?）" unless ["Int32", "Int64", "String", "Bool", "Float64", "JSON::Any"].includes?(t_str) %}
            {% schema_pairs << "\"" + k.id.stringify + "\" => \"" + t_str + (optional ? "?" : "") + "\"" %}
            {% call_args << "__v_" + k.id.stringify %}
          {% end %}
          m.turn_with_schema({{ @type.name.id }}, {{ turn_name.id.stringify }}, { {{ schema_pairs.join(", ").id }} } of ::String => ::String{% if mode_src %}, {{ mode_src.id }}{% end %}) do |actor, ctx, args|
            {% for pair in args_node.to_a %}
              {% k = pair.first %}
              {% v = pair.last %}
              {% optional = v.is_a?(Generic) %}
              {% base = optional ? v.type_vars[0] : v %}
              {% t_str = base.id.stringify %}
              {% if t_str == "Int32" %}
                {% conv = ".as_i" %}
              {% elsif t_str == "Int64" %}
                {% conv = ".raw.as(::Int64)" %}
              {% elsif t_str == "String" %}
                {% conv = ".as_s" %}
              {% elsif t_str == "Bool" %}
                {% conv = ".as_bool" %}
              {% elsif t_str == "Float64" %}
                {% conv = ".as_f" %}
              {% else %}
                {% conv = "" %}
              {% end %}
              {% if optional %}
                {% if conv == "" %}
                  __v_{{ k.id }} = (tmp = args[{{ k.id.stringify }}]?; tmp && !tmp.raw.nil? ? tmp : nil)
                {% else %}
                  __t_{{ k.id }} = args[{{ k.id.stringify }}]?
                  __v_{{ k.id }} = __t_{{ k.id }} && !__t_{{ k.id }}.raw.nil? ? __t_{{ k.id }}{{ conv.id }} : nil
                {% end %}
              {% else %}
                __v_{{ k.id }} = args[{{ k.id.stringify }}]{{ conv.id }}
              {% end %}
            {% end %}
            value = actor.{{ turn_name.id }}({{ call_args.join(", ").id }})
            {% ret_str = returns_node.id.stringify %}
            {% if ret_str == "Int32" %}
              ::JSON::Any.new(value.to_i64)
            {% elsif ret_str == "Int64" %}
              ::JSON::Any.new(value)
            {% elsif ret_str == "String" || ret_str == "Bool" || ret_str == "Float64" %}
              ::JSON::Any.new(value)
            {% elsif ret_str == "Nil" %}
              ::JSON::Any.new(nil)
            {% elsif ret_str == "JSON::Any" %}
              value
            {% else %}
              {% raise "turn #{turn_name} returns 类型 #{ret_str} 不支持" %}
            {% end %}
          end
        {% end %}
      end
    end

    # ---- 类型安全 Agent 代理：编译期校验参数/返回类型，运行期同一语义管道 ----
    class Agent < ::Troupe::AgentBase
      {% for stmt in stmts %}
        {% next if stmt.is_a?(Nop) %}
        {% turn_name = stmt.args[0].name %}
        {% args_node = stmt.args[1] %}
        {% returns_node = stmt.named_args.find { |na| na.name == "returns" }.value %}
        {% json_pairs = [] of String %}
        {% for pair in args_node.to_a %}
          {% k = pair.first %}
          {% v = pair.last %}
          {% optional = v.is_a?(Generic) %}
          {% base = optional ? v.type_vars[0] : v %}
          {% t_str = base.id.stringify %}
          {% if t_str == "Int32" %}
            {% wrap = "::JSON::Any.new(" + k.id.stringify + ".to_i64)" %}
          {% elsif t_str == "Int64" %}
            {% wrap = "::JSON::Any.new(" + k.id.stringify + ")" %}
          {% elsif t_str == "String" || t_str == "Bool" || t_str == "Float64" %}
            {% wrap = "::JSON::Any.new(" + k.id.stringify + ")" %}
          {% else %}
            {% wrap = k.id.stringify %}
          {% end %}
          {% if optional %}
            {% json_pairs << "\"" + k.id.stringify + "\" => (" + k.id.stringify + ".nil? ? ::JSON::Any.new(nil) : " + wrap + ")" %}
          {% else %}
            {% json_pairs << "\"" + k.id.stringify + "\" => " + wrap %}
          {% end %}
        {% end %}
        def {{ turn_name.id }}(actor_id : ::Troupe::ActorId{% for pair in args_node.to_a %}, {{ pair.first.id }} : {{ pair.last }}{% if pair.last.is_a?(Generic) %} = nil{% end %}{% end %}, deadline : ::Time::Span? = nil, traceparent : ::String? = nil) : {{ returns_node }}
          result = __call(actor_id, {{ turn_name.id.stringify }},
            ::JSON::Any.new({ {{ json_pairs.join(", ").id }} } of ::String => ::JSON::Any), deadline, traceparent)
          {% ret_str = returns_node.id.stringify %}
          {% if ret_str == "Int32" %}
            result.as_i
          {% elsif ret_str == "Int64" %}
            result.raw.as(::Int64)
          {% elsif ret_str == "String" %}
            result.as_s
          {% elsif ret_str == "Bool" %}
            result.as_bool
          {% elsif ret_str == "Float64" %}
            result.as_f
          {% elsif ret_str == "Nil" %}
            nil
          {% elsif ret_str == "JSON::Any" %}
            result
          {% else %}
            {% raise "turn #{turn_name} returns 类型 #{ret_str} 不支持" %}
          {% end %}
        end
      {% end %}
    end
  {% end %}
end
