module Troupe
  # ActorId = namespace + role + key 的规范标识（troupe-planning 共同语义层）。
  #
  # 规则：
  # - 三个组成部分都必须非空，且不含控制字符（C0、C1 与 DEL）。
  # - 规范字符串形式为 `namespace/role/key`；组成部分内的 `%` 编码为 `%25`、`/` 编码为 `%2F`，
  #   因此未转义的 `/` 只能是分隔符，parse 严格接受规范形式。
  # - 不做 Unicode 归一化：不同码点序列视为不同 ActorId。
  # - #hash 仅保证进程内稳定；跨语言/跨进程 canonical hash 待公共协议 ADR（PLAN M5）。
  struct ActorId
    getter namespace : String
    getter role : String
    getter key : String

    def initialize(@namespace : String, @role : String, @key : String)
      validate_component("namespace", @namespace)
      validate_component("role", @role)
      validate_component("key", @key)
    end

    # 解析规范形式 `namespace/role/key`（严格接受 #to_s 的输出）。
    def self.parse(canonical : String) : ActorId
      parts = canonical.split('/')
      unless parts.size == 3
        raise InvalidActorIdError.new("ActorId 规范形式必须为 namespace/role/key：#{canonical.inspect}")
      end
      new(decode(parts[0]), decode(parts[1]), decode(parts[2]))
    end

    def to_s(io : IO) : Nil
      io << encode(@namespace) << '/' << encode(@role) << '/' << encode(@key)
    end

    def ==(other : self) : Bool
      @namespace == other.namespace && @role == other.role && @key == other.key
    end

    def hash
      {@namespace, @role, @key}.hash
    end

    private def validate_component(field : String, value : String) : Nil
      raise InvalidActorIdError.new("ActorId #{field} 不能为空") if value.empty?
      if value.each_char.any? { |c| c.ord < 0x20 || c.ord == 0x7f }
        raise InvalidActorIdError.new("ActorId #{field} 包含控制字符：#{value.inspect}")
      end
    end

    private def encode(component : String) : String
      component.gsub("%", "%25").gsub("/", "%2F")
    end

    # 仅反转义规范编码；先 %2F 后 %25，保证字面量 `%2F` 不被二次解码。
    private def self.decode(component : String) : String
      component.gsub("%2F", "/").gsub("%25", "%")
    end
  end
end
