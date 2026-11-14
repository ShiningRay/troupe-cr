require "./spec_helper"

describe Troupe::Manifest do
  it "migration_path 逐级构造 v1→v3，缺级与降级返回 nil" do
    manifest = Troupe::Manifest(CartPropsV3).define("cart", CartActor) do |m|
      m.schema_version 3
      m.initial { CartPropsV3.new }
      m.migrate(TroupeFixtures.cart_step_1_2)
      m.migrate(TroupeFixtures.cart_step_2_3)
      m.turn("add_item", CartActor) do |actor, ctx, args|
        JSON::Any.new(actor.add_item(args["item"].as_s).to_i64)
      end
    end

    manifest.migration_path(3).should eq([] of Troupe::MigrationStepBase)
    manifest.migration_path(1).not_nil!.map(&.from_version).should eq([1, 2])
    manifest.migration_path(1).not_nil!.map(&.to_version).should eq([2, 3])
    manifest.migration_path(2).not_nil!.size.should eq(1)
    manifest.migration_path(4).should be_nil # 降级不支持
  end

  it "迁移链断裂/重复起点/缺 schema_version 在注册期 fail fast" do
    expect_raises(ArgumentError, "缺少 schema_version") do
      Troupe::Manifest(CartPropsV3).define("cart", CartActor) do |m|
        m.initial { CartPropsV3.new }
        m.turn("add_item", CartActor) { |a, c, x| JSON::Any.new(nil) }
      end
    end

    expect_raises(ArgumentError, "终点") do
      Troupe::Manifest(CartPropsV3).define("cart", CartActor) do |m|
        m.schema_version 3
        m.initial { CartPropsV3.new }
        m.migrate(TroupeFixtures.cart_step_1_2) # 链只到 v2，终点 ≠ schema_version 3
        m.turn("add_item", CartActor) { |a, c, x| JSON::Any.new(nil) }
      end
    end

    expect_raises(ArgumentError, "重复迁移起点") do
      Troupe::Manifest(CartPropsV3).define("cart", CartActor) do |m|
        m.schema_version 3
        m.initial { CartPropsV3.new }
        m.migrate(TroupeFixtures.cart_step_1_2)
        m.migrate(Troupe::MigrationStep(CartPropsV1, CartPropsV2).new(1, 2) { |v1| CartPropsV2.new })
        m.turn("add_item", CartActor) { |a, c, x| JSON::Any.new(nil) }
      end
    end
  end

  it "保留名不可注册为 Turn，重复方法名冲突报 ArgumentError" do
    expect_raises(ArgumentError, "保留名") do
      Troupe::Manifest(CounterProps).define("counter", CounterActor) do |m|
        m.schema_version 1
        m.initial { CounterProps.new }
        m.turn("save", CounterActor) { |a, c, x| JSON::Any.new(nil) }
      end
    end

    expect_raises(ArgumentError, "冲突") do
      Troupe::Manifest(CounterProps).define("counter", CounterActor) do |m|
        m.schema_version 1
        m.initial { CounterProps.new }
        m.turn("increment", CounterActor) { |a, c, x| JSON::Any.new(nil) }
        m.turn("increment", CounterActor) { |a, c, x| JSON::Any.new(nil) }
      end
    end
  end

  it "actor_class 不继承 Actor(P) 时拒绝注册" do
    expect_raises(ArgumentError, "必须继承") do
      Troupe::Manifest(CartPropsV3).define("cart", CounterActor) do |m|
        m.schema_version 1
        m.initial { CartPropsV3.new }
      end
    end
  end

  it "Stage.register 拒绝重复角色（RoleConflictError）" do
    stage = Troupe::Stage.new(mode: Troupe::SchedulerMode::Manual)
    TroupeFixtures.register_counter(stage)
    expect_raises(Troupe::RoleConflictError, "已注册") do
      TroupeFixtures.register_counter(stage)
    end
  end
end
