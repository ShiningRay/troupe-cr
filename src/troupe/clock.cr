module Troupe
  # 可注入时钟：deadline、Intermission 与虚拟时间均经由 Clock。
  abstract class Clock
    abstract def now : Time
  end

  class SystemClock < Clock
    def now : Time
      Time.utc
    end
  end

  # 虚拟时钟：Rehearsal 使用固定起始时刻，测试显式推进，保证 deadline/sweep 判定确定性。
  class VirtualClock < Clock
    @now : Time
    @mutex = Mutex.new

    def initialize(start : Time = Time.utc(2026, 1, 1))
      @now = start
    end

    def now : Time
      @mutex.synchronize { @now }
    end

    def advance(span : Time::Span) : Nil
      @mutex.synchronize { @now += span }
    end

    def advance_to(instant : Time) : Nil
      @mutex.synchronize { @now = instant }
    end
  end
end
