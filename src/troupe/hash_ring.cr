module Troupe
  # 一致性哈希环（docs/cluster.md 近期路由：canonical identity → HashRing → owner）。
  # - 哈希复用 Transport.crc32（纯 Crystal，进程内一致；跨语言 canonical hash 待 M5 公共协议 ADR）；
  # - 虚拟节点（vnodes）平滑负载；
  # - 节点增删只移动该节点相邻区间的键（一致性性质）——漂移转发的路由基础。
  class HashRing
    @vnodes : Int32
    @positions = Hash(::UInt32, String).new
    @sorted = [] of ::UInt32
    @nodes = Set(String).new

    def initialize(@vnodes : Int32 = 64)
    end

    def nodes : Array(String)
      @nodes.to_a.sort
    end

    def add_node(name : String) : Nil
      return if @nodes.includes?(name)
      @nodes << name
      @vnodes.times do |i|
        pos = hash_key("#{name}\u{1}#{i}")
        @positions[pos] = name
      end
      rebuild
    end

    def remove_node(name : String) : Nil
      return unless @nodes.delete(name)
      @positions.select! { |_, node| node != name }
      rebuild
    end

    # 键的归属节点；环为空返回 nil。
    def owner_for(key : String) : String?
      return nil if @sorted.empty?
      hash = hash_key(key)
      idx = @sorted.bsearch_index { |pos, _| pos >= hash } || 0 # 环绕
      @positions[@sorted[idx]]
    end

    private def rebuild : Nil
      @sorted = @positions.keys.sort
    end

    private def hash_key(key : String) : ::UInt32
      ::Troupe::Transport.crc32(key.to_slice)
    end
  end
end
