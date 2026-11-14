module Troupe
  # 协作取消信号（DESIGN §5 时间与取消）：仅置位标志，Turn 是否/何时响应由 Actor 代码决定。
  # 框架不会强行终止 Turn；取消不改变副作用语义（settle 后正常回复）。
  class CancelSignal
    @requested = false

    def request : Nil
      @requested = true
    end

    def requested? : Bool
      @requested
    end
  end

  # 排入 CallBoard 的一次调用请求。reply 为容量 1 的通道：每个请求恰好收到一次回复。
  # traceparent 为本 Turn 自己的 W3C span（Stage 由调用方传入的父上下文派生）；
  # parent_traceparent 为调用方传入并校验后的上下文（nil 表示新 trace）。
  class TurnRequest
    getter call_id : UInt64
    getter method : String
    getter args : ::JSON::Any
    getter deadline : ::Time
    getter reply : Channel(::Troupe::CallReply)
    getter bytes : Int32
    getter cancel : ::Troupe::CancelSignal
    getter traceparent : String
    getter parent_traceparent : String?

    def initialize(@call_id : UInt64, @method : String, @args : ::JSON::Any, @deadline : ::Time,
                   @reply : Channel(::Troupe::CallReply), @bytes : Int32, @cancel : ::Troupe::CancelSignal,
                   @traceparent : String, @parent_traceparent : String?)
    end
  end

  class CallReply
    getter value : ::JSON::Any?
    getter error : ::Exception?
    getter settled_at : ::Time

    def initialize(@value : ::JSON::Any?, @error : ::Exception?, @settled_at : ::Time)
    end

    def self.value(v : ::JSON::Any, at : ::Time) : ::Troupe::CallReply
      new(v, nil, at)
    end

    def self.error(e : ::Exception, at : ::Time) : ::Troupe::CallReply
      new(nil, e, at)
    end
  end

  # 调用方持有的 Future。
  # Fiber 模式：await 阻塞至回复或 deadline；
  # Manual 模式（Rehearsal）：pump 同步执行后回复已在通道内，await 不需要真实等待。
  # 回复通道容量 1 且 receive 会取走值：Future 以 reply_cache 缓存已取回复，
  # 使 settled?/cancel 在 await 之后仍语义正确。
  class CallFuture
    @request : ::Troupe::TurnRequest
    @clock : ::Troupe::Clock
    @manual : Bool
    @reply_cache : ::Troupe::CallReply? = nil

    def initialize(@request : ::Troupe::TurnRequest, @clock : ::Troupe::Clock, @manual : Bool)
    end

    # 回复是否已抵达（无论成功失败）。
    def settled? : Bool
      !pending_reply.nil?
    end

    # 请求协作取消：仅置位 CancelSignal，Turn 通过 CallContext#cancel_requested? 观察并自行决定
    # 何时/如何收束（可提前 settle 提交部分状态）。不可强行终止；已 settle 的调用无效果。
    def cancel : Bool
      return false if settled?
      @request.cancel.request
      true
    end

    # 等待结果；错误原样抛出（含 Troupe::Error 与业务异常）。
    def await : ::JSON::Any
      if reply = pending_reply
        return settle(reply)
      end
      now = @clock.now
      if now >= @request.deadline
        # 从未开始执行：排队过期，无副作用、可安全重试。
        raise CallTimeoutError.new("调用排队超过 deadline，未执行、无副作用（#{method}）", :queued)
      end
      if @manual
        # Rehearsal：等待 pump 发回回复（测试先 pump 再 await；同 Fiber 未 pump 将阻塞）。
        cache_and_settle(@request.reply.receive)
      else
        remaining = @request.deadline - now
        span = remaining < Time::Span.zero ? Time::Span.zero : remaining
        select
        when reply = @request.reply.receive
          cache_and_settle(reply)
        when timeout(span)
          raise CallTimeoutError.new("等待回复超过 deadline：该 Turn 可能已开始执行，结果未知（#{method}）", :executing)
        end
      end
    end

    private def method : String
      @request.method
    end

    private def pending_reply : ::Troupe::CallReply?
      return @reply_cache if @reply_cache
      if reply = try_receive
        @reply_cache = reply
        return reply
      end
      nil
    end

    private def cache_and_settle(reply : ::Troupe::CallReply) : ::JSON::Any
      @reply_cache = reply
      settle(reply)
    end

    private def try_receive : ::Troupe::CallReply?
      select
      when reply = @request.reply.receive
        reply
      else
        nil
      end
    end

    private def settle(reply : ::Troupe::CallReply) : ::JSON::Any
      # 错误回复原样抛出——排队过期(:queued)自身已说明未执行、无副作用，
      # 不能被迟到的 settle 时间掩盖成 :executing。
      raise reply.error.not_nil! if reply.error
      if reply.settled_at > @request.deadline
        # Turn 实际执行成功但 settle 晚于 deadline：调用方按结果未知处理（执行占用语义，DESIGN §5.1）。
        raise CallTimeoutError.new("Turn 在 deadline 之后才完成：结果未知（#{method}）", :executing)
      end
      reply.value.not_nil!
    end
  end
end
