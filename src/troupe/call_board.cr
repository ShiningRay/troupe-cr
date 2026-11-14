module Troupe
  # 有界 FIFO CallBoard：每 activation 一个，仅由其单一调度通道消费（DESIGN §4.5）。
  # 背压在入队时显式拒绝（CallRejectedError(:backpressure)，可重试）；
  # 排队过期在出队时判定：不执行、零副作用、回复 CallTimeoutError(:queued)。
  class CallBoard
    @queue = Deque(::Troupe::TurnRequest).new
    @bytes = 0

    def initialize(@max_depth : Int32, @max_bytes : Int32)
    end

    def depth : Int32
      @queue.size
    end

    def bytes : Int32
      @bytes
    end

    def push(request : ::Troupe::TurnRequest) : Nil
      if @queue.size >= @max_depth
        raise CallRejectedError.new("Actor 队列深度 #{@queue.size} 达上限 #{@max_depth}", :backpressure, true)
      end
      if @bytes + request.bytes > @max_bytes
        raise CallRejectedError.new("Actor 队列字节 #{@bytes}+#{request.bytes} 超上限 #{@max_bytes}", :backpressure, true)
      end
      @queue.push(request)
      @bytes += request.bytes
    end

    # 弹出并上报队首所有已过期请求，返回第一个未过期请求或 nil。
    def take_ready(now : ::Time, &expired : ::Troupe::TurnRequest -> Nil) : ::Troupe::TurnRequest?
      while (first = @queue.first?)
        if first.deadline <= now
          yield pop_front
        else
          return pop_front
        end
      end
      nil
    end

    # 清空队列（停机时逐个上报拒绝）。
    def drain(&rejected : ::Troupe::TurnRequest -> Nil) : Nil
      while (first = @queue.first?)
        yield pop_front
      end
    end

    def empty? : Bool
      @queue.empty?
    end

    private def pop_front : ::Troupe::TurnRequest
      request = @queue.shift
      @bytes -= request.bytes
      request
    end
  end
end
