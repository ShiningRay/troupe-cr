require "./spec_helper"

describe Troupe do
  it "exposes its development version" do
    Troupe::VERSION.should eq("0.16.0-dev.0")
  end

  it "keeps the public API surface present" do
    Troupe::Stage.should_not be_nil
    Troupe::Agent.should_not be_nil
    Troupe::Rehearsal.should_not be_nil
    Troupe::ActorId.should_not be_nil
    Troupe::MemoryPropStore.should_not be_nil
    Troupe::SQLitePropStore.should_not be_nil
  end
end
