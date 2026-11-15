require "json"

module Troupe
  # TCP transport 帧协议与信封（PLAN M3 transport 实验，docs/cluster.md Transport 规格）。
  #
  # 帧格式：`[magic u32 LE][length u32 LE][crc32 u32 LE][payload]`。
  # - 魔数不符 / 帧长超上限 / CRC 校验失败 = 协议违规：立即断开连接（不做部分解析），
  #   该连接上所有在途调用按 UnknownOutcome 处理；
  # - length 上限（max_frame）在读 payload **之前**校验，超限不分配内存。
  module Transport
    # 纯 Crystal CRC32（IEEE 802.3，多项式 0xEDB88320）——帧校验用，零外部依赖
    # （Windows 构建无 zlib）。
    private CRC32_TABLE = begin
      table = ::StaticArray(::UInt32, 256).new(0_u32)
      256.times do |i|
        c = i.to_u32
        8.times do
          c = (c & 1 == 1) ? 0xEDB88320_u32 ^ (c >> 1) : c >> 1
        end
        table[i] = c
      end
      table
    end

    def self.crc32(data : ::Bytes) : ::UInt32
      crc = 0xFFFFFFFF_u32
      data.each do |byte|
        crc = CRC32_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
      end
      crc ^ 0xFFFFFFFF_u32
    end

    MAGIC = 0x54525031_u32 # "TRP1"

    HEADER_BYTES = 12

    # 协议违规（魔数/长度上限/CRC）：transport 内部用，连接断开，不跨网络传播。
    class ProtocolError < ::Exception; end

    # 信封：请求/回复/取消共用。字段全部 nilable 按类型取用。
    class Envelope
      include JSON::Serializable

      property t : String       # "req" | "rep" | "cancel"
      property id : Int64       # call_id（复用连接多路分发）
      property actor : String?  # 请求：ActorId 规范形式
      property m : String?      # 请求：方法名
      property a : ::JSON::Any? # 请求：参数
      property dl : Int64?      # 请求：deadline（Unix 毫秒；RFC3339 会截断毫秒）
      property tp : String?     # 请求：调用方 W3C traceparent
      property ok : Bool?       # 回复：是否成功
      property v : ::JSON::Any? # 回复：结果
      property ec : String?     # 回复：错误类别（Troupe::Error 子类全名）
      property em : String?     # 回复：错误消息
      property ek : String?     # 回复：ConflictKind / CallTimeoutPhase / RejectReason
      property ert : Bool?      # 回复：CallRejectedError#retryable

      def initialize(@t, @id, @actor = nil, @m = nil, @a = nil, @dl = nil, @tp = nil,
                     @ok = nil, @v = nil, @ec = nil, @em = nil, @ek = nil, @ert = nil)
      end
    end

    # 读一帧；连接关闭返回 nil；协议违规抛 ProtocolError（调用方须断开连接）。
    def self.read_frame(io : ::IO, max_frame : Int32) : ::Bytes?
      header = ::Bytes.new(HEADER_BYTES)
      io.read_fully(header)
      magic = ::IO::ByteFormat::LittleEndian.decode(::UInt32, header[0, 4])
      raise ProtocolError.new("magic 不符：#{magic}") unless magic == MAGIC
      length = ::IO::ByteFormat::LittleEndian.decode(::UInt32, header[4, 4])
      if length > max_frame.to_u32
        raise ProtocolError.new("帧长 #{length} 超上限 #{max_frame}（长度上限，未分配内存）")
      end
      expected_crc = ::IO::ByteFormat::LittleEndian.decode(::UInt32, header[8, 4])
      payload = ::Bytes.new(length.to_i)
      io.read_fully(payload)
      unless crc32(payload) == expected_crc
        raise ProtocolError.new("CRC 校验失败（帧校验）")
      end
      payload
    end

    def self.write_frame(io : ::IO, payload : ::Bytes) : Nil
      header = ::IO::Memory.new
      ::IO::ByteFormat::LittleEndian.encode(MAGIC, header)
      ::IO::ByteFormat::LittleEndian.encode(payload.size.to_u32, header)
      ::IO::ByteFormat::LittleEndian.encode(crc32(payload), header)
      io.write(header.to_slice)
      io.write(payload)
      io.flush
    end

    def self.write_frame_json(io : ::IO, envelope : Envelope) : Nil
      write_frame(io, envelope.to_json.to_slice)
    end

    # 服务端错误 → 信封错误字段（错误分类过线：Troupe 错误带结构化字段，业务异常降级为类别名）。
    def self.error_fields(e : ::Exception) : {String, String, String?, Bool?}
      case e
      when ConflictError
        {e.class.name, e.message.not_nil!(""), e.kind.to_s, nil}
      when CallTimeoutError
        {e.class.name, e.message.not_nil!(""), e.phase.to_s, nil}
      when CallRejectedError
        {e.class.name, e.message.not_nil!(""), e.reason.to_s, e.retryable}
      when Error
        {e.class.name, e.message.not_nil!(""), nil, nil}
      else
        {"::Exception", "#{e.class.name}: #{e.message}", nil, nil}
      end
    end

    # 信封错误字段 → 客户端重建（错误分类保持；未知类别降级为普通 Exception）。
    def self.error_from(ec : String, em : String, ek : String?, ert : Bool?) : ::Exception
      case ec
      when "Troupe::ConflictError"
        kind = ek.try { |s| ConflictKind.parse?(s) } || ConflictKind::Revision
        ConflictError.new(em, kind)
      when "Troupe::CallTimeoutError"
        phase = ek.try { |s| CallTimeoutPhase.parse?(s) } || CallTimeoutPhase::Executing
        CallTimeoutError.new(em, phase)
      when "Troupe::CallRejectedError"
        reason = ek.try { |s| RejectReason.parse?(s) } || RejectReason::Backpressure
        CallRejectedError.new(em, reason, ert || false)
      when "Troupe::UnknownRoleError"
        UnknownRoleError.new(em)
      when "Troupe::InvalidArgumentError"
        InvalidArgumentError.new(em)
      when "Troupe::IdempotencyConflictError"
        IdempotencyConflictError.new(em)
      when "Troupe::InvalidActorStateError"
        InvalidActorStateError.new(em)
      else
        # 未知 Troupe::Error 子类与业务异常：类别名保留、降级为普通 Exception
        ::Exception.new("远端错误 #{ec}: #{em}")
      end
    end
  end
end
