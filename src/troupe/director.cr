require "json"
require "http/server"

module Troupe
  # Director：进程内观测/管理入口（PLAN M4，DESIGN"故障与未知结果可见"）。
  # - health：各 Stage 生命周期状态（running/draining/closed）与容量；
  # - metrics：聚合 StageMetrics 计数（含故障类：activation_failures/save_failures/
  #   turns_expired/turns_failed——故障与未知结果在此可见）；
  # - recent_events：最近生命周期/调用事件环形样本（SaveFailed/ActivationFailed/
  #   TurnExpired/CallRejected 等原因随条目可见）；
  # - 管理：drain/shutdown。
  # 事件经 Stage#on_event 采集（环形上限，默认 200 条）。
  class Director
    record StageView, name : String, stage : ::Troupe::Stage

    @views = Array(StageView).new
    @events = Array(::Troupe::Event).new
    @event_limit : Int32
    @mutex = Mutex.new

    def initialize(@event_limit : Int32 = 200)
    end

    # 绑定 Stage 并开始采集事件（每 Stage 一次）。
    def add_stage(name : String, stage : ::Troupe::Stage) : Nil
      @mutex.synchronize do
        @views << StageView.new(name, stage)
        stage.on_event do |event|
          @mutex.synchronize do
            @events << event
            @events.shift if @events.size > @event_limit
          end
        end
      end
    end

    def stage_names : Array(String)
      @mutex.synchronize { @views.map(&.name) }
    end

    def stage(name : String) : ::Troupe::Stage?
      @mutex.synchronize { @views.find(&.name.==(name)).try(&.stage) }
    end

    private def stage_status(stage : ::Troupe::Stage) : String
      return "closed" if stage.closed?
      return "draining" if stage.draining?
      "running"
    end

    # 生命周期健康：ok = 全部 Stage 未关闭。
    def health : ::JSON::Any
      stages = {} of ::String => ::JSON::Any
      all_closed = true
      @mutex.synchronize do
        @views.each do |view|
          status = stage_status(view.stage)
          all_closed = false unless status == "closed"
          stages[view.name] = ::JSON::Any.new({
            "status" => ::JSON::Any.new(status),
            "slots"  => ::JSON::Any.new(view.stage.slot_count.to_i64),
            "actors" => ::JSON::Any.new(view.stage.actor_count.to_i64),
          } of ::String => ::JSON::Any)
        end
      end
      ::JSON::Any.new({
        "ok"     => ::JSON::Any.new(!all_closed),
        "stages" => ::JSON::Any.new(stages),
      } of ::String => ::JSON::Any)
    end

    # 指标：per-stage 计数快照（含故障与未知结果类计数）。
    def metrics : ::JSON::Any
      stages = {} of ::String => ::JSON::Any
      @mutex.synchronize do
        @views.each do |view|
          counters = view.stage.metrics.snapshot
          metrics_json = {} of ::String => ::JSON::Any
          counters.each do |name, value|
            metrics_json[name] = ::JSON::Any.new(value.to_i64)
          end
          stages[view.name] = ::JSON::Any.new(metrics_json)
        end
      end
      ::JSON::Any.new({"stages" => ::JSON::Any.new(stages)} of ::String => ::JSON::Any)
    end

    # 最近事件（故障与未知结果可见：SaveFailed/ActivationFailed/TurnExpired/
    # CallRejected 等原因随条目可见）。倒序（最新在前）。
    def recent_events(limit : Int32 = 50) : Array(::Troupe::Event)
      @mutex.synchronize do
        events = @events.last(Math.min(limit, @events.size))
        events.reverse
      end
    end

    # 管理操作（进程内；HTTP 端点不暴露写操作——生产管理面另行迭代）。
    def drain_stage(name : String) : Nil
      stage(name).try(&.begin_drain)
    end

    def shutdown_stage(name : String) : Nil
      stage(name).try(&.shutdown)
    end

    # 事件 JSON（手工构建：Event record 未含 JSON::Serializable）。
    def events_json(limit : Int32 = 50) : String
      events = recent_events(limit)
      ::JSON.build do |json|
        json.array do
          events.each do |event|
            json.object do
              json.field "type", event.type.to_s
              json.field "actor_id", event.actor_id.to_s
              json.field "method", event.method unless event.method.nil?
              json.field "reason", event.reason unless event.reason.nil?
              json.field "at", event.at.to_rfc3339
            end
          end
        end
      end
    end
  end

  # HTTP 健康与指标端点（stdlib HTTP::Server，零额外依赖）：
  # GET /health → Director#health；GET /metrics → Director#metrics；
  # GET /events?limit=N → 最近事件。管理写操作不经 HTTP（生产管理面另行迭代）。
  class HTTPEndpoint
    @director : ::Troupe::Director
    @host : String
    @port : Int32
    @server : ::HTTP::Server? = nil

    def initialize(@director, @host = "127.0.0.1", @port = 0)
    end

    def listen : Int32
      server = ::HTTP::Server.new do |context|
        handle(context)
      end
      @server = server
      addr = server.bind_tcp(@host, @port)
      spawn(name: "troupe-director-http") do
        server.listen
      end
      addr.port
    end

    def close : Nil
      @server.try(&.close)
    end

    private def handle(context : ::HTTP::Server::Context) : Nil
      path = context.request.path
      case path
      when "/health"
        respond(context, 200, @director.health.to_json)
      when "/metrics"
        respond(context, 200, @director.metrics.to_json)
      when "/events"
        limit = context.request.query_params["limit"]?.try(&.to_i?) || 50
        respond(context, 200, @director.events_json(limit.clamp(1, 200)))
      else
        respond(context, 404, %({"error": "not found"}))
      end
    end

    private def respond(context : ::HTTP::Server::Context, status : Int32, body : String) : Nil
      context.response.content_type = "application/json"
      context.response.status_code = status
      context.response.print(body)
    end
  end
end
