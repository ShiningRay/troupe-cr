module Troupe
  # 版本化 directory（PLAN M5，docs/cluster.md 目录组件）：
  # actor_id → 归属节点注册表，per-entry version 单调递增（handoff/recovery 用
  # 版本保护：旧节点复活不得覆盖新归属）；view_version 全局视图版本随每次变更递增
  # （可观测/增量同步用）。
  class VersionedDirectory
    record Entry, node : String, version : ::UInt64

    @entries = Hash(::Troupe::ActorId, Entry).new
    @view_version : ::UInt64 = 0
    @mutex = Mutex.new

    # 注册/重新注册：version 单调 +1；返回 (version, view_version)。
    def register(actor_id : ::Troupe::ActorId, node : String) : ::Tuple(::UInt64, ::UInt64)
      @mutex.synchronize do
        version = (@entries[actor_id]?.try(&.version) || 0_u64) + 1
        @entries[actor_id] = Entry.new(node, version)
        @view_version += 1
        {version, @view_version}
      end
    end

    # handoff/recovery：显式改派（版本保护——仅当现版本与 expected 匹配才改派，
    # 旧节点复活抢注册会被 version 保护拒绝）。
    def reassign(actor_id : ::Troupe::ActorId, new_node : String,
                 expected_version : ::UInt64) : Bool
      @mutex.synchronize do
        entry = @entries[actor_id]?
        return false unless entry
        return false unless entry.version == expected_version
        return false if entry.node == new_node # 同节点改派为 no-op（旧计划重放保护）
        @entries[actor_id] = Entry.new(new_node, entry.version + 1)
        @view_version += 1
        true
      end
    end

    def unregister(actor_id : ::Troupe::ActorId) : Bool
      @mutex.synchronize do
        deleted = @entries.delete(actor_id)
        unless deleted.nil?
          @view_version += 1
          return true
        end
        false
      end
    end

    record Lookup, node : String, version : ::UInt64

    def lookup(actor_id : ::Troupe::ActorId) : Lookup?
      @mutex.synchronize do
        entry = @entries[actor_id]?
        entry ? Lookup.new(entry.node, entry.version) : nil
      end
    end

    def entries_for_node(node : String) : Array(::Troupe::ActorId)
      @mutex.synchronize do
        @entries.select { |_, entry| entry.node == node }.map { |id, _| id }
      end
    end

    def view_version : ::UInt64
      @mutex.synchronize { @view_version }
    end

    def size : Int32
      @mutex.synchronize { @entries.size }
    end
  end

  # capabilities/resource placement（docs/cluster.md：capabilities 与 placement policy）：
  # 节点声明能力集合，actor 声明需求子集；place 返回满足全部需求且当前 entries
  # 负载最少的节点（无匹配 → nil，显式拒绝）。
  class Placer
    @capabilities = Hash(String, Set(String)).new
    @directory : ::Troupe::VersionedDirectory? = nil

    def initialize(@directory : ::Troupe::VersionedDirectory? = nil)
    end

    def set_capabilities(node : String, caps : Enumerable(String)) : Nil
      @capabilities[node] = caps.to_set
    end

    def node_capabilities(node : String) : Set(String)
      @capabilities[node]? || Set(String).new
    end

    # 满足 requires 的节点中选 entries 负载最少者；无 directory 或无匹配 → nil。
    def place(requires : Enumerable(String)) : String?
      required = requires.to_set
      candidates = @capabilities.select { |_, caps| required.all? { |r| caps.includes?(r) } }.keys
      return nil if candidates.empty?
      if directory = @directory
        candidates.min_by { |node| directory.entries_for_node(node).size }
      else
        candidates.first
      end
    end

    def candidates_for(requires : Enumerable(String)) : Array(String)
      required = requires.to_set
      @capabilities.select { |_, caps| required.all? { |r| caps.includes?(r) } }.keys
    end
  end

  # activation rebalancing / handoff 计划（docs/cluster.md：activation rebalancing
  # 与回退到简单策略）：
  # - 死亡节点 → 其 directory entries 迁移到环上后继存活节点（漂移转发一致）；
  # - 新节点加入 → 可再平衡（计划把部分 entries 移到新节点，负载均衡）；
  # - 计划执行用 directory.reassign（version 保护：期间被抢注/改派 → 该条失败可重试）。
  class Rebalancer
    @ring : ::Troupe::HashRing
    @directory : ::Troupe::VersionedDirectory

    record Handoff, actor_id : ::Troupe::ActorId, from : String, to : String

    def initialize(@ring, @directory)
    end

    # 死亡节点 entries 的 handoff 计划：逐 entry 用环计算新归属（先临时移除死亡
    # 节点得到后继）。
    def handoff_plan(dead_nodes : Enumerable(String)) : Array(Handoff)
      dead = dead_nodes.to_a
      plan = [] of Handoff
      dead.each do |dead_node|
        @ring.remove_node(dead_node)
        @directory.entries_for_node(dead_node).each do |actor_id|
          to = @ring.owner_for(actor_id.to_s)
          plan << Handoff.new(actor_id, dead_node, to) if to
        end
      end
      dead.each { |node| @ring.add_node(node) } # 计算后恢复环（调用方决定是否真正移除）
      plan
    end

    # rebalancing 计划：把 overflow_node 的部分 entries 迁到 target（负载均衡，
    # 每次 count 条）。
    def rebalance_plan(overflow_node : String, target : String, count : Int32) : Array(Handoff)
      @directory.entries_for_node(overflow_node).first(count).map do |actor_id|
        Handoff.new(actor_id, overflow_node, target)
      end
    end

    # 执行 handoff/rebalance 计划：逐条 reassign（version 保护）；返回成功条数。
    def apply(plan : Array(Handoff)) : Int32
      applied = 0
      plan.each do |h|
        lookup = @directory.lookup(h.actor_id)
        next unless lookup
        if @directory.reassign(h.actor_id, h.to, lookup.version)
          applied += 1
        end
      end
      applied
    end
  end
end
