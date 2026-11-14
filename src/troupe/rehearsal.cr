module Troupe
  # Rehearsal：确定性测试运行时（DESIGN §4.7）。
  # - 固定 namespace：不读环境/工作目录、不落盘，任意目录与进程状态下行为一致；
  # - Memory Provider（Props + ownership fencing）；
  # - 可注入 VirtualClock（固定起始时刻，显式 advance）；
  # - Manual 调度：pump/pump_all 显式驱动，消除 Fiber 竞争。
  class Rehearsal
    getter clock : ::Troupe::VirtualClock
    getter stage : ::Troupe::Stage
    getter namespace : String
    getter store : ::Troupe::MemoryPropStore
    getter ownership : ::Troupe::MemoryOwnershipStore
    getter events : Array(::Troupe::Event)

    def initialize(@namespace : String = "rehearsal", config : ::Troupe::StageConfig = StageConfig.new)
      @clock = VirtualClock.new
      @ownership = MemoryOwnershipStore.new
      @store = MemoryPropStore.new(@ownership)
      @events = [] of ::Troupe::Event
      @stage = Stage.new(clock: @clock, store: @store, ownership: @ownership,
        mode: SchedulerMode::Manual, config: config, name: "rehearsal:#{@namespace}")
      @stage.on_event { |event| @events << event }
    end

    # 在固定 namespace 下构造 ActorId。
    def actor(role : String, key : String) : ::Troupe::ActorId
      ActorId.new(@namespace, role, key)
    end

    def agent : ::Troupe::Agent
      Agent.new(@stage)
    end

    def register(&) : Nil
      yield @stage
    end

    def advance(span : ::Time::Span) : Nil
      @clock.advance(span)
    end

    def pump(actor_id : ::Troupe::ActorId) : Symbol
      @stage.pump(actor_id)
    end

    def pump_all : Int32
      @stage.pump_all
    end

    def sweep : Array(::Troupe::ActorId)
      @stage.sweep
    end

    def events_of(type : ::Troupe::EventType) : Array(::Troupe::Event)
      @events.select { |event| event.type == type }
    end
  end
end
