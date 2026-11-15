require "socket"

module Troupe
  # TCP transport 服务端/客户端（PLAN M3 transport 实验）。
  #
  # 服务端：包一层既有 Stage——白名单/参数校验/背压/超时/取消语义全部复用 Stage 管道
  # （docs/cluster.md：远程调用经同一语义管道，不新增调用语义）。
  # - 每 accept 一个处理 Fiber；协议违规（魔数/长度上限/CRC）断连；
  # - in-flight 上限按连接计，超限回 CallRejectedError(:backpressure, retryable)；
  # - cancel 信封 → 既有 CallFuture#cancel（协作取消跨网络传播）。
  #
  # 客户端：单连接复用（call_id 多路分发）；deadline 超时 → CallTimeoutError(:executing)
  # （结果未知，执行占用语义不变）；连接断开 → 在途调用按 UnknownOutcomeError 处理。
  #
  # 认证/TLS 不在本实验范围（PLAN M3 认证项另行迭代）。
  module Transport
    class TCPServer
      @stage : ::Troupe::Stage
      @host : String
      @port : Int32
      @max_frame : Int32
      @max_inflight : Int32
      @auth : ::Troupe::Transport::Authenticator?
      @listener : ::TCPServer? = nil
      @sockets = Set(::TCPSocket).new
      @sockets_mutex = Mutex.new
      @closed = false

      def initialize(@stage, @host = "127.0.0.1", @port = 0,
                     @max_frame = 1_048_576, @max_inflight = 256,
                     @auth : ::Troupe::Transport::Authenticator? = nil)
      end

      # 绑定并开始 accept 循环（后台 Fiber）；返回实际端口。
      def listen : Int32
        listener = ::TCPServer.new(@host, @port)
        @listener = listener
        spawn(name: "troupe-tcp-accept") do
          accept_loop(listener)
        end
        listener.local_address.port
      end

      def close : Nil
        @closed = true
        @listener.try(&.close)
        @sockets_mutex.synchronize do
          @sockets.each(&.close) # 关闭已接受连接：客户端在途调用按断连处理
          @sockets.clear
        end
      end

      private def accept_loop(listener : ::TCPServer) : Nil
        until @closed
          begin
            sock = listener.accept
            sock.sync = false
            @sockets_mutex.synchronize { @sockets << sock }
          rescue ::IO::Error
            break
          end
          spawn(name: "troupe-tcp-conn") do
            begin
              handle_connection(sock)
            ensure
              @sockets_mutex.synchronize { @sockets.delete(sock) }
            end
          end
        end
      end

      private class ConnState
        property in_flight : Int32 = 0
        getter pending = Hash(::UInt64, ::Troupe::CallFuture).new
        getter mutex = Mutex.new

        def register(id : ::UInt64, future : ::Troupe::CallFuture) : Nil
          mutex.synchronize { pending[id] = future }
        end

        def unregister(id : ::UInt64) : Nil
          mutex.synchronize { pending.delete(id) }
        end

        def cancel(id : ::UInt64) : Bool
          future = mutex.synchronize { pending[id]? }
          future.nil? ? false : future.cancel
        end

        def fail_all : Nil
          mutex.synchronize do
            pending.each_value(&.cancel) # 断连后协作取消在途 Turn（Turn 仍可能完成并提交）
            pending.clear
          end
        end
      end

      private def handle_connection(sock : ::TCPSocket) : Nil
        state = ConnState.new
        write_mutex = Mutex.new
        authed = @auth.nil? # 未启用认证即视为已认证
        begin
          loop do
            payload = Transport.read_frame(sock, @max_frame)
            break if payload.nil?
            envelope = Envelope.from_json(String.new(payload))
            unless authed
              # 认证握手：第一帧必须 auth；token 校验失败回 ok:false 后断连
              raise AuthError.new("未认证即发送 #{envelope.t} 信封") unless envelope.t == "auth"
              ok = @auth.try(&.verify?(envelope.tk.not_nil!))
              write_mutex.synchronize do
                Transport.write_frame_json(sock, Envelope.new("rep", 0_i64, ok: ok,
                  ec: ok ? nil : "AuthError", em: ok ? nil : "token 无效"))
              end
              raise AuthError.new("token 无效") unless ok
              authed = true
              next
            end
            case envelope.t
            when "cancel"
              state.cancel(envelope.id.to_u64)
            when "req"
              if state.in_flight >= @max_inflight
                write_mutex.synchronize do
                  Transport.write_frame_json(sock, Envelope.new(
                    "rep", envelope.id, ok: false,
                    ec: "Troupe::CallRejectedError",
                    em: "连接 in-flight #{state.in_flight} 达上限 #{@max_inflight}",
                    ek: "Backpressure", ert: true
                  ))
                end
                next
              end
              state.in_flight += 1
              spawn(name: "troupe-tcp-req") do
                begin
                  dispatch(sock, write_mutex, envelope, state)
                ensure
                  state.in_flight -= 1
                  state.unregister(envelope.id.to_u64)
                end
              end
            end
          end
        rescue e : Transport::ProtocolError | Transport::AuthError | ::IO::Error | ::Socket::Error
          # 协议违规/认证失败/断连：关闭连接；在途 Turn 协作取消（调用方按未知处理）
        end
        state.fail_all
        begin
          sock.close
        rescue
          nil
        end
      end

      private def dispatch(sock : ::TCPSocket, write_mutex : Mutex, envelope : Envelope, state : ConnState) : Nil
        reply : Envelope
        begin
          actor_id = ::Troupe::ActorId.parse(envelope.actor.not_nil!)
          deadline_at = ::Time.unix_ms(envelope.dl.not_nil!)
          remaining = deadline_at - ::Time.utc
          # JSON null 参数在 nilable 字段反序列化为 nil（JSON null ≠ JSON::Any.new(nil)）
          args = envelope.a || ::JSON::Any.new(nil)
          method = envelope.m || ""
          future = @stage.call(actor_id, method, args,
            remaining < Time::Span.zero ? Time::Span.zero : remaining, envelope.tp)
          state.register(envelope.id.to_u64, future)
          value = future.await
          reply = Envelope.new("rep", envelope.id, ok: true, v: value)
        rescue e : ::Exception
          ec, em, ek, ert = Transport.error_fields(e)
          reply = Envelope.new("rep", envelope.id, ok: false, ec: ec, em: em, ek: ek, ert: ert)
        end
        write_mutex.synchronize do
          Transport.write_frame_json(sock, reply)
        end
      rescue e : ::IO::Error | ::Socket::Error
        # 连接已断开：回复不可达，调用方按 UnknownOutcome 处理
        nil
      rescue e : ::Exception
        # 请求信封本身非法（如 actor 解析失败）：按 InvalidArgument 分类回包
        ec, em, ek, ert = Transport.error_fields(
          InvalidArgumentError.new("请求信封非法：#{e.message}"))
        begin
          write_mutex.synchronize do
            Transport.write_frame_json(sock, Envelope.new("rep", envelope.id, ok: false,
              ec: ec, em: em, ek: ek, ert: ert))
          end
        rescue
          nil
        end
      end
    end

    class TCPClient
      @host : String
      @port : Int32
      @max_frame : Int32
      @max_inflight : Int32
      @token : String?
      @mutex = Mutex.new
      @sock : ::TCPSocket? = nil
      @pending = Hash(::UInt64, ::Channel(::Troupe::CallReply)).new
      @call_seq : ::UInt64 = 0
      @closed = false

      def initialize(@host, @port, @max_frame = 1_048_576, @max_inflight = 256,
                     @token : ::String? = nil)
      end

      def close : Nil
        @mutex.synchronize do
          @closed = true
          fail_pending_locked("客户端关闭")
          @sock.try(&.close)
          @sock = nil
        end
      end

      # 发起远程调用；服务端错误分类原样重建。
      # 调用方 deadline 先到 → CallTimeoutError(:executing)（结果未知，勿假定失败）。
      def call(actor_id : ::Troupe::ActorId, method : String, args : ::JSON::Any = ::JSON::Any.new(nil),
               deadline : ::Time::Span = 30.seconds, traceparent : ::String? = nil) : ::JSON::Any
        # 先连接+认证（握手失败不遗留 pending 条目），成功后才注册
        sock = @mutex.synchronize { ensure_connected_locked }
        call_id : ::UInt64 = 0
        reply_channel : ::Channel(::Troupe::CallReply)? = nil
        @mutex.synchronize do
          raise UnknownOutcomeError.new("客户端已关闭") if @closed
          raise CallRejectedError.new("客户端 in-flight #{@pending.size} 达上限 #{@max_inflight}",
            :backpressure, true) if @pending.size >= @max_inflight
          @call_seq += 1
          call_id = @call_seq
          reply_channel = ::Channel(::Troupe::CallReply).new
          @pending[call_id] = reply_channel.not_nil!
        end

        deadline_at = ::Time.utc + deadline
        envelope = Envelope.new("req", call_id.to_i64, actor: actor_id.to_s, m: method,
          a: args, dl: deadline_at.to_unix_ms, tp: traceparent)
        begin
          @mutex.synchronize { Transport.write_frame_json(sock.not_nil!, envelope) }
        rescue e : ::Exception
          fail_call(call_id, UnknownOutcomeError.new("发送失败，结果未知：#{e.message}"))
          raise CallRejectedError.new("发送失败，连接已重置，可重试", :backpressure, true)
        end

        result = select
        when reply = reply_channel.not_nil!.receive
          reply
        when timeout(deadline)
          nil
        end
        if result.nil?
          @mutex.synchronize { @pending.delete(call_id) }
          raise CallTimeoutError.new("等待远端回复超过 deadline：结果未知（#{method}）", :executing)
        end
        settle(result)
      end

      # 协作取消传播：服务端置位对应 Turn 的 CancelSignal（Turn 自行决定收束）。
      def cancel(call_id : ::UInt64) : Bool
        begin
          @mutex.synchronize do
            sock = ensure_connected_locked
            Transport.write_frame_json(sock, Envelope.new("cancel", call_id.to_i64))
          end
          true
        rescue
          false
        end
      end

      private def settle(reply : ::Troupe::CallReply) : ::JSON::Any
        raise reply.error.not_nil! if reply.error
        reply.value.not_nil!
      end

      private def ensure_connected_locked : ::TCPSocket
        sock = @sock
        return sock if sock && !sock.closed?
        sock = ::TCPSocket.new(@host, @port)
        sock.sync = false
        if token = @token
          # 认证握手在 reader 启动前同步完成（无竞争）；失败断连并抛 AuthError。
          # ack 读取带超时：服务端拒绝后立即断连，Windows 下读侧可能表现为
          # IO::Error/EOF/阻塞，统一归一为 AuthError。
          Transport.write_frame_json(sock, Envelope.new("auth", 0_i64, tk: token))
          ack_channel = Channel(::Bytes?).new
          spawn(name: "troupe-tcp-auth-ack") do
            begin
              ack_channel.send(Transport.read_frame(sock, @max_frame))
            rescue e : ::Exception
              ack_channel.send(nil)
            end
          end
          ack_payload = select
          when payload = ack_channel.receive
            payload
          when timeout(3.seconds)
            nil
          end
          raise AuthError.new("认证握手失败：连接被关闭或超时") if ack_payload.nil?
          ack = Envelope.from_json(String.new(ack_payload))
          unless ack.ok
            raise AuthError.new("认证被拒绝：#{ack.em || "token 无效"}")
          end
        end
        @sock = sock
        spawn(name: "troupe-tcp-client-read") do
          reader_loop(sock)
        end
        sock
      end

      private def reader_loop(sock : ::TCPSocket) : Nil
        loop do
          payload = Transport.read_frame(sock, @max_frame)
          break if payload.nil?
          envelope = Envelope.from_json(String.new(payload))
          next unless envelope.t == "rep"
          channel = @mutex.synchronize { @pending.delete(envelope.id.to_u64) }
          next unless channel
          if envelope.ok
            channel.send(CallReply.value(envelope.v.not_nil!, ::Time.utc))
          else
            channel.send(CallReply.error(
              Transport.error_from(envelope.ec.not_nil!, envelope.em.not_nil!, envelope.ek, envelope.ert),
              ::Time.utc))
          end
        end
      rescue e : Transport::ProtocolError | Transport::AuthError | ::IO::Error | ::Socket::Error
        @mutex.synchronize do
          # 仅当仍指向旧连接时才失败在途调用（新连接的 pending 不受影响）
          if @sock.same?(sock)
            @sock = nil
            fail_pending_locked("连接断开")
          end
        end
      end

      private def fail_call(call_id : ::UInt64, e : ::Exception) : Nil
        channel = @mutex.synchronize { @pending.delete(call_id) }
        channel.try(&.send(CallReply.error(e, ::Time.utc)))
      end

      private def fail_pending_locked(cause : String) : Nil
        error = UnknownOutcomeError.new("#{cause}：在途调用结果未知，勿假定失败，按幂等键重试")
        @pending.each_value do |channel|
          # 无接收者（调用方已超时/异常退出）时直接丢弃——send 会永久阻塞
          select
          when channel.send(CallReply.error(error, ::Time.utc))
          else
          end
        end
        @pending.clear
      end
    end
  end
end
