require "./spec_helper"
require "json"

# PLAN M5 第三项：golden fixtures 契约测试——troupe.cr 行为必须与 golden/*.json
# 跨语言对齐向量一致（其他 Troupe 实现以同一组文件为对齐锚点）。
# fixtures 由 examples/generate_golden.cr 生成并入库；本 spec 是对齐锚点。
GOLDEN_DIR = File.join(__DIR__, "..", "golden")

def golden_cases(filename : String, field : String) : Array(::JSON::Any)
  raw = File.read(File.join(GOLDEN_DIR, filename))
  ::JSON.parse(raw)[field].as_a
end

describe "golden fixtures 契约" do
  it "identity.json：有效案例 canonical 往返一致；无效案例被拒且原因匹配" do
    golden_cases("identity.json", "cases").each do |case_|
      canonical = case_["canonical"].as_s
      if case_["valid"].as_bool
        id = Troupe::ActorId.parse(canonical)
        id.to_s.should eq(canonical)
        id.namespace.should eq(case_["namespace"].as_s) if case_.as_h.has_key?("namespace")
      else
        expect_raises(Troupe::InvalidActorIdError) do
          Troupe::ActorId.parse(canonical)
        end
      end
    end
  end

  it "hash.json：CRC32 向量与实现一致（跨语言指纹锚点）" do
    golden_cases("hash.json", "cases").each do |case_|
      key = case_["key"].as_s
      expected = case_["crc32"].as_s
      Troupe::Transport.crc32(key.to_slice).to_s(16, precision: 8, upcase: false).should eq(expected)
    end
  end

  it "errors.json：错误分类码表覆盖本实现公开错误类" do
    codes = golden_cases("errors.json", "codes").map { |c| c["code"].as_s }
    codes.should contain("CONFLICT")
    codes.should contain("CALL_TIMEOUT")
    codes.should contain("CALL_REJECTED")
    codes.should contain("UNKNOWN_OUTCOME")
    codes.should contain("IDEMPOTENCY_CONFLICT")
    codes.should contain("UNKNOWN_ROLE")
    codes.should contain("INVALID_ARGUMENT")
    codes.should contain("ACTIVATION")

    # 分类细节契约：Conflict 的 kinds、CallTimeout 的 phases、CallRejected 的 reasons
    conflict = golden_cases("errors.json", "codes").find { |c| c["code"].as_s == "CONFLICT" }.not_nil!
    conflict["kinds"].as_a.map(&.as_s).sort.should eq(["exists", "revision"].sort)
  end

  it "envelope.json：sample_request 可被本实现解析且字段语义一致" do
    sample = ::JSON.parse(File.read(File.join(GOLDEN_DIR, "envelope.json")))["sample_request"].as_a
    sample.each do |env_json|
      envelope = Troupe::Transport::Envelope.from_json(env_json.to_json)
      envelope.t.should eq("req")
      envelope.actor.not_nil!.should start_with("app/order/")
      envelope.tp.not_nil!.size.should eq(55) # 00-32hex-16hex-01
    end
  end

  it "fixtures 与实现同源：再生成的向量与入库文件一致（防漂移）" do
    # identity：再计算全部有效案例的 canonical，与文件值一致
    golden_cases("identity.json", "cases").each do |case_|
      next unless case_["valid"].as_bool
      id = Troupe::ActorId.new(case_["namespace"].as_s, case_["role"].as_s, case_["key"].as_s)
      id.to_s.should eq(case_["canonical"].as_s)
    end
    # hash：重算 CRC32 与文件一致
    golden_cases("hash.json", "cases").each do |case_|
      Troupe::Transport.crc32(case_["key"].as_s.to_slice).to_s(16, precision: 8).should eq(case_["crc32"].as_s)
    end
  end
end
