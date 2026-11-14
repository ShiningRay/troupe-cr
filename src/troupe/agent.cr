module Troupe
  # Agent：位置透明调用入口。M1 全部为本地调用；M3 远程调用经同一语义管道
  # （白名单、deadline、错误分类），不新增调用语义。
  class Agent
    def initialize(@stage : ::Troupe::Stage)
    end

    def call(actor_id : ::Troupe::ActorId, method : String, args : ::JSON::Any = ::JSON::Any.new(nil),
             deadline : ::Time::Span? = nil, traceparent : String? = nil) : ::Troupe::CallFuture
      @stage.call(actor_id, method, args, deadline, traceparent)
    end

    # 阻塞直至结果；错误原样抛出（含 Troupe::Error 与业务异常）。
    def call!(actor_id : ::Troupe::ActorId, method : String, args : ::JSON::Any = ::JSON::Any.new(nil),
              deadline : ::Time::Span? = nil, traceparent : String? = nil) : ::JSON::Any
      call(actor_id, method, args, deadline, traceparent).await
    end
  end
end
