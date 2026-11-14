require "./spec_helper"

describe Troupe::ActorId do
  it "joins namespace/role/key into the canonical form" do
    id = Troupe::ActorId.new("app", "counter", "cart-1")
    id.to_s.should eq("app/counter/cart-1")
  end

  it "round-trips components containing separators and percent signs" do
    id = Troupe::ActorId.new("ns", "ro/le", "a%b/c")
    canonical = id.to_s
    canonical.should eq("ns/ro%2Fle/a%25b%2Fc")
    Troupe::ActorId.parse(canonical).should eq(id)
  end

  it "does not double-decode literal %2F" do
    id = Troupe::ActorId.new("ns", "role", "%2F")
    Troupe::ActorId.parse(id.to_s).key.should eq("%2F")
  end

  it "preserves unicode without normalization" do
    composed = Troupe::ActorId.new("ns", "role", "é")           # U+00E9
    decomposed = Troupe::ActorId.new("ns", "role", "e\u{0301}") # e + U+0301
    composed.should_not eq(decomposed)
    Troupe::ActorId.parse(composed.to_s).should eq(composed)
    Troupe::ActorId.parse(decomposed.to_s).should eq(decomposed)
  end

  it "rejects empty components and control characters" do
    expect_raises(Troupe::InvalidActorIdError, "不能为空") do
      Troupe::ActorId.new("ns", "", "key")
    end
    expect_raises(Troupe::InvalidActorIdError, "控制字符") do
      Troupe::ActorId.new("ns", "ro\nle", "key")
    end
  end

  it "rejects malformed canonical strings" do
    expect_raises(Troupe::InvalidActorIdError) do
      Troupe::ActorId.parse("ns/role")
    end
    expect_raises(Troupe::InvalidActorIdError) do
      Troupe::ActorId.parse("ns/role/key/extra")
    end
  end

  it "is usable as a hash key" do
    table = Hash(Troupe::ActorId, String).new
    table[Troupe::ActorId.new("ns", "role", "a")] = "x"
    table[Troupe::ActorId.new("ns", "role", "a")]?.should eq("x")
    table[Troupe::ActorId.new("ns", "role", "b")]?.should be_nil
  end
end
