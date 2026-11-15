# 公共协议 golden fixtures 生成器（PLAN M5 第三项）。
# 生成 golden/*.json 跨语言对齐向量：其他 Troupe 实现可用同一组文件验证
# canonical identity / hash / 错误分类 / 信封语义与本实现一致。
# 运行：crystal run examples/generate_golden.cr（写入 golden/ 目录）
require "file_utils"
require "../src/troupe"

DIR = File.join(__DIR__, "..", "golden")
FileUtils.mkdir_p(DIR)

# ---- identity.json：ActorId 规范形式向量 ----
identity_cases = [] of ::JSON::Any
identity_cases << ::JSON.parse(%({
  "valid": true,
  "namespace": "app", "role": "order", "key": "1",
  "canonical": "app/order/1"
}))
identity_cases << ::JSON.parse(%({
  "valid": true,
  "namespace": "app", "role": "ro/le", "key": "a%b/c",
  "canonical": "app/ro%2Fle/a%25b%2Fc"
}))
identity_cases << ::JSON.parse(%({
  "valid": true,
  "namespace": "ns", "role": "role", "key": "%2F",
  "canonical": "ns/role/%252F"
}))
[
  {"canonical": "app//1", "reason": "empty role"},
  {"canonical": "app/ro\nle/1", "reason": "control character"},
  {"canonical": "app/ro/le/1", "reason": "extra separator"},
  {"canonical": "", "reason": "empty"},
].each do |case_|
  identity_cases << ::JSON.parse(%({"valid": false, "canonical": #{case_["canonical"].inspect}, "reason": #{case_["reason"].inspect}}))
end
File.write(File.join(DIR, "identity.json"), ::JSON.build do |json|
  json.object do
    json.field "protocol", "troupe-identity/1"
    json.field "rules", ::JSON::Any.new(::JSON.parse(%(["components non-empty", "no control chars (C0/DEL)", "% encoded as %25, / as %2F", "no unicode normalization"])).as_a)
    json.field "cases", ::JSON::Any.new(identity_cases)
  end
end)

# ---- hash.json：CRC32 哈希向量（环与指纹共用）----
hash_cases = [] of ::JSON::Any
[
  "app/order/1", "shop/cart/cart-1", "", "a",
  "troupe/ro%2Fle/key", "ns/role/%252F",
].each do |key|
  crc = Troupe::Transport.crc32(key.to_slice)
  hash_cases << ::JSON.parse(%({"key": #{key.inspect}, "crc32": "#{sprintf("%08x", crc)}"}))
end
File.write(File.join(DIR, "hash.json"), ::JSON.build do |json|
  json.object do
    json.field "protocol", "troupe-hash-crc32/1"
    json.field "algorithm", "CRC32 IEEE 802.3 (poly 0xEDB88320), init 0xFFFFFFFF, final xor 0xFFFFFFFF"
    json.field "cases", ::JSON::Any.new(hash_cases)
  end
end)

# ---- errors.json：错误分类码表（跨语言错误映射契约）----
errors = {
  "codes" => [
    {"code": "CONFLICT", "class": "ConflictError", "kinds": ["exists", "revision"]},
    {"code": "CALL_TIMEOUT", "class": "CallTimeoutError", "phases": ["queued", "executing"]},
    {"code": "CALL_REJECTED", "class": "CallRejectedError",
     "reasons": ["backpressure", "whitelist", "shutdown", "draining", "ownership", "invalidated"],
     "retryable_by_reason": {"backpressure": true, "ownership": false, "whitelist": false}},
    {"code": "UNKNOWN_OUTCOME", "class": "UnknownOutcomeError"},
    {"code": "IDEMPOTENCY_CONFLICT", "class": "IdempotencyConflictError"},
    {"code": "UNKNOWN_ROLE", "class": "UnknownRoleError"},
    {"code": "INVALID_ARGUMENT", "class": "InvalidArgumentError"},
    {"code": "ACTIVATION", "class": "ActivationError"},
    {"code": "INVALID_ACTOR_STATE", "class": "InvalidActorStateError"},
    {"code": "STALE_INCARNATION", "class": "StaleIncarnationError"},
    {"code": "AUTH", "transport_only": true},
    {"code": "PROTOCOL", "transport_only": true},
  ],
}
File.write(File.join(DIR, "errors.json"), errors.to_json)

# ---- envelope.json：TCP 信封字段语义向量 ----
envelope_cases = [] of ::JSON::Any
env = Troupe::Transport::Envelope.new("req", 7_i64, actor: "app/order/1", m: "increment",
  a: JSON.parse(%({"by": 1})), dl: Time.utc(2026, 1, 1).to_unix_ms, tp: "00-#{"a" * 32}-#{"b" * 16}-01")
envelope_cases << ::JSON.parse(env.to_json)
File.write(File.join(DIR, "envelope.json"), ::JSON.build do |json|
  json.object do
    json.field "protocol", "troupe-envelope/1"
    json.field "frame", "magic(TRP1 u32 LE) + length(u32 LE) + crc32(u32 LE) + payload(UTF-8 JSON)"
    json.field "limits", ::JSON::Any.new(::JSON.parse(%({"max_frame_default": 1048576, "auth_first_frame": true})).as_h)
    json.field "sample_request", ::JSON::Any.new(envelope_cases)
  end
end)

puts "golden fixtures 写入完成：#{Dir.children(DIR).sort.join(", ")}"
