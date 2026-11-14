require "./spec_helper"

describe Troupe do
  it "loads the scaffold and exposes its development version" do
    Troupe::VERSION.should eq("0.1.0-dev.0")
  end
end
