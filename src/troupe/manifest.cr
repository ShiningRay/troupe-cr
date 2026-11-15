module Troupe
  # 逐级迁移步骤（PLAN M1：v→v+1，禁止跨级/降级）。
  # apply 在序列化边界上执行：解析 F → 变换 → 序列化 T。任何异常即迁移失败，不得写入。
  abstract class MigrationStepBase
    abstract def from_version : Int32

    abstract def to_version : Int32

    abstract def apply(json : String) : String
  end

  class MigrationStep(F, T) < ::Troupe::MigrationStepBase
    getter from_version : Int32
    getter to_version : Int32

    # F/T 必须是 JSON::Serializable（否则实例化时编译失败）。
    def initialize(@from_version : Int32, @to_version : Int32, &@fn : F -> T)
    end

    def apply(json : String) : String
      @fn.call(F.from_json(json)).to_json
    end
  end

  # 角色 manifest：显式注册、方法白名单、Props schemaVersion 与迁移链。
  abstract class ManifestBase
    getter role : String

    def initialize(@role : String)
    end

    abstract def schema_version : Int32

    abstract def turn_names : Array(String)

    abstract def initial_json : String

    abstract def migrations : Array(::Troupe::MigrationStepBase)

    # 返回从 from_version 逐级迁移到 schema_version 的步骤序列；无法到达（缺级/降级）返回 nil。
    abstract def migration_path(from_version : Int32) : Array(::Troupe::MigrationStepBase)?

    abstract def parse_final(json : String) : ::JSON::Serializable

    abstract def build_actor(actor_id : ::Troupe::ActorId, props : ::JSON::Serializable, ctx : ::Troupe::ActivationContext) : ::Troupe::ActorBase

    abstract def invoke_turn(actor : ::Troupe::ActorBase, ctx : ::Troupe::CallContext, method : String, args : ::JSON::Any) : ::JSON::Any

    abstract def serialize_props(props : ::JSON::Serializable) : String

    # 排队前参数校验：缺参/类型不符抛 InvalidArgumentError；无 schema 的手动 turn 不校验。
    abstract def validate_args(method : ::String, args : ::JSON::Any) : Nil

    abstract def validate! : Nil
  end

  # 生命周期/内部方法不可注册为 Turn，也不可经 RPC 调用（DESIGN §4.2）。
  RESERVED_TURNS = %w[on_stage off_stage save props actor_id]

  class Manifest(P) < ::Troupe::ManifestBase
    @schema_version : Int32 = 0
    @initial : Proc(P)? = nil
    @migrations = [] of ::Troupe::MigrationStepBase
    @turns = Hash(String, Proc(::Troupe::Actor(P), ::Troupe::CallContext, ::JSON::Any, ::JSON::Any)).new
    @turn_modes = Hash(String, ::Symbol).new
    @turn_schemas = Hash(String, Hash(::String, ::String)).new
    @factory : Proc(::Troupe::ActorId, P, ::Troupe::ActivationContext, ::Troupe::ActorBase)

    # 由具体 Actor 类派生工厂：闭包捕获具体类（forall A），
    # 绕开"抽象类元类型不可实例化"的编译限制，且不改运行时语义。
    def self.define(role : String, actor_class : A.class, &) forall A
      unless actor_class <= Actor(P)
        raise ArgumentError.new("#{actor_class} 必须继承 Troupe::Actor(P)")
      end
      factory = ->(id : ::Troupe::ActorId, props : P, ctx : ::Troupe::ActivationContext) { actor_class.new(id, props, ctx).as(::Troupe::ActorBase) }
      manifest = new(role, factory)
      yield manifest
      manifest.validate!
      manifest
    end

    def initialize(@role : String, @factory : Proc(::Troupe::ActorId, P, ::Troupe::ActivationContext, ::Troupe::ActorBase))
    end

    def schema_version(v : Int32) : Nil
      raise ArgumentError.new("角色 #{role} 的 schema_version 必须 >= 1") if v < 1
      @schema_version = v
    end

    def schema_version : Int32
      @schema_version
    end

    def initial(&block : -> P) : Nil
      @initial = block
    end

    def migrate(step : ::Troupe::MigrationStepBase) : Nil
      @migrations << step
    end

    def migrations : Array(::Troupe::MigrationStepBase)
      @migrations
    end

    # 注册 Turn：白名单键即方法名；actor 参数按注册时提供的具体类绑定。
    # mode（PLAN M4）：:strict（默认，串行独占）/ :read_only（并发只读快照，禁写）/
    # :improv（并发可写副本，save 以激活时 revision CAS——冲突显式拒绝，禁止隐式覆盖）。
    def turn(name : String, actor_type : A.class, mode : ::Symbol = :strict,
             &block : A, ::Troupe::CallContext, ::JSON::Any -> ::JSON::Any) forall A
      if RESERVED_TURNS.includes?(name) || @turns.has_key?(name)
        raise ArgumentError.new("turn #{name.inspect} 与保留名或已注册方法冲突（角色 #{role}）")
      end
      unless [:strict, :read_only, :improv].includes?(mode)
        raise ArgumentError.new("turn #{name.inspect} 的 mode #{mode.inspect} 不支持（strict/read_only/improv）")
      end
      @turn_modes[name] = mode
      @turns[name] = ->(actor : ::Troupe::Actor(P), ctx : ::Troupe::CallContext, args : ::JSON::Any) {
        block.call(actor.as(A), ctx, args)
      }
    end

    # 注册带参数 schema 的 Turn（troupe_manifest 宏使用；语义与 turn 完全一致）。
    def turn_with_schema(actor_type : A.class, name : String, schema : Hash(::String, ::String),
                         mode : ::Symbol = :strict,
                         &block : A, ::Troupe::CallContext, ::JSON::Any -> ::JSON::Any) forall A
      if RESERVED_TURNS.includes?(name) || @turns.has_key?(name)
        raise ArgumentError.new("turn #{name.inspect} 与保留名或已注册方法冲突（角色 #{role}）")
      end
      @turn_schemas[name] = schema
      @turn_modes[name] = mode
      @turns[name] = ->(actor : ::Troupe::Actor(P), ctx : ::Troupe::CallContext, args : ::JSON::Any) {
        block.call(actor.as(A), ctx, args)
      }
    end

    def turn_names : Array(String)
      @turns.keys
    end

    # Turn 调度类别（:strict/:read_only/:improv）；未注册方法返回 :strict（白名单先行拒绝）。
    def turn_mode(method : String) : ::Symbol
      @turn_modes[method]? || :strict
    end

    def initial_json : String
      @initial.not_nil!.call.to_json
    end

    def migration_path(from_version : Int32) : Array(::Troupe::MigrationStepBase)?
      return [] of ::Troupe::MigrationStepBase if from_version == @schema_version
      return nil if from_version > @schema_version || from_version < 1
      steps = @migrations.sort_by { |step| step.from_version.as(Int32) }
      path = [] of ::Troupe::MigrationStepBase
      current = from_version
      while current < @schema_version
        step = steps.find { |s| s.from_version.as(Int32) == current }
        return nil unless step
        path << step
        current = step.to_version
      end
      path
    end

    def parse_final(json : String) : ::JSON::Serializable
      P.from_json(json)
    end

    def build_actor(actor_id : ::Troupe::ActorId, props : ::JSON::Serializable, ctx : ::Troupe::ActivationContext) : ::Troupe::ActorBase
      @factory.call(actor_id, props.as(P), ctx)
    end

    def invoke_turn(actor : ::Troupe::ActorBase, ctx : ::Troupe::CallContext, method : String, args : ::JSON::Any) : ::JSON::Any
      handler = @turns[method]?
      unless handler
        raise CallRejectedError.new("方法 #{method.inspect} 不在角色 #{role} 的白名单", :whitelist, false)
      end
      handler.call(actor.as(Actor(P)), ctx, args)
    end

    def serialize_props(props : ::JSON::Serializable) : String
      props.to_json
    end

    def validate_args(method : ::String, args : ::JSON::Any) : Nil
      schema = @turn_schemas[method]?
      return unless schema
      unless args.as_h?
        raise InvalidArgumentError.new("方法 #{method.inspect} 的参数必须是 JSON 对象（角色 #{role}）")
      end
      obj = args.as_h
      schema.each do |param, type|
        value = obj[param]?
        if value.nil? || value.raw.nil?
          unless type.ends_with?("?")
            raise InvalidArgumentError.new("缺少参数 #{param.inspect}（#{type}，角色 #{role}）")
          end
        else
          base = type.ends_with?("?") ? type[0...-1] : type
          unless arg_type_matches?(value.raw, base)
            raise InvalidArgumentError.new("参数 #{param.inspect} 类型不符：期望 #{type}（角色 #{role}）")
          end
        end
      end
    end

    private def arg_type_matches?(raw, base : String) : Bool
      case base
      when "Int32", "Int64"
        raw.is_a?(Int64)
      when "String"
        raw.is_a?(String)
      when "Bool"
        raw.is_a?(Bool)
      when "Float64"
        raw.is_a?(Float64) || raw.is_a?(Int64) # JSON 无整型/浮点区分强制：整数可作浮点
      else
        true # JSON::Any 或未识别类型不限制
      end
    end

    def validate! : Nil
      raise ArgumentError.new("角色 #{role} 缺少 schema_version") if @schema_version < 1
      raise ArgumentError.new("角色 #{role} 缺少 initial Props 工厂") unless @initial
      froms = @migrations.map { |step| step.from_version.as(Int32) }
      if froms.size != froms.uniq.size
        raise ArgumentError.new("角色 #{role} 存在重复迁移起点")
      end
      steps = @migrations.sort_by { |step| step.from_version.as(Int32) }
      steps.each_with_index do |step, i|
        if i > 0 && steps[i - 1].to_version.as(Int32) != step.from_version.as(Int32)
          raise ArgumentError.new("角色 #{role} 迁移链在 #{step.from_version} 处断裂")
        end
      end
      if last = steps.last?
        unless last.to_version == @schema_version
          raise ArgumentError.new("角色 #{role} 迁移链终点 #{last.to_version} 必须等于 schema_version #{@schema_version}")
        end
      end
    end
  end
end
