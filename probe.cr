require "./src/troupe"

class RwProps
  include JSON::Serializable
  property count : Int32 = 0
  def initialize; end
end

class RwActor < Troupe::Actor(RwProps)
end

stage = Troupe::Stage.new
manifest = Troupe::Manifest(RwProps).define("rw", RwActor) do |m|
  m.schema_version 1
  m.initial { RwProps.new }
  m.turn "strict_t", RwActor do |a, c, x| JSON::Any.new(nil) end
  m.turn "ro_t", RwActor, :read_only do |a, c, x| JSON::Any.new(nil) end
  m.turn "improv_t", RwActor, :improv do |a, c, x| JSON::Any.new(nil) end
end
puts "strict_t = #{manifest.turn_mode("strict_t")}"
puts "ro_t = #{manifest.turn_mode("ro_t")}"
puts "improv_t = #{manifest.turn_mode("improv_t")}"
