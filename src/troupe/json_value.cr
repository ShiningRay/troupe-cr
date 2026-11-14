module Troupe
  # JSON::Any 构造助手：任意 JSON 可序列化值 → JSON::Any（经完整序列化边界，
  # 与 PropStore/Call 边界一致；宏生成的 Turn 闭包也可使用）。
  module Json
    def self.any(value) : ::JSON::Any
      ::JSON.parse(value.to_json)
    end
  end
end
