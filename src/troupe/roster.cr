module Troupe
  # 成员视图（docs/cluster.md：join/leave、incarnation、探测、死亡与重新入团）。
  # - join：新成员 incarnation=1；死亡成员重新入团 incarnation+1；
  #   携带更低/相同 incarnation 的重加入被拒（StaleIncarnationError，生产协议协商）；
  # - heartbeat：incarnation 不匹配 → 拒绝（false），匹配 → 刷新 last_seen；
  # - sweep：超过 timeout 无心跳的成员判死并移出视图（返回死亡名单，供环更新/漂移）。
  # 时钟可注入；本实现为进程内成员视图，跨节点探测协议（gossip/全互联）留待实验。
  class Roster
    record Member, address : String, incarnation : ::UInt64, last_seen : ::Time

    @members = Hash(String, Member).new
    # 已移除成员的最后 incarnation（死亡/主动离团后重入团必须递增——生产协议协商）
    @last_incarnation = Hash(String, ::UInt64).new
    @mutex = Mutex.new

    def initialize(@timeout : ::Time::Span = 10.seconds, @clock : ::Troupe::Clock = SystemClock.new)
    end

    def join(name : String, address : String, incarnation : ::UInt64? = nil) : ::UInt64
      @mutex.synchronize do
        existing = @members[name]?
        base = existing ? existing.incarnation : (@last_incarnation[name]? || 0_u64)
        offered = incarnation || (base + 1)
        raise StaleIncarnationError.new(
          "成员 #{name} 重加入 incarnation #{offered} 不高于现存 #{base}") if offered <= base
        member = Member.new(address, offered, @clock.now)
        @members[name] = member
        @last_incarnation[name] = offered
        member.incarnation
      end
    end

    # 心跳：incarnation 必须与视图一致；成功刷新 last_seen。
    def heartbeat(name : String, incarnation : ::UInt64) : Bool
      @mutex.synchronize do
        member = @members[name]?
        return false unless member
        return false unless member.incarnation == incarnation
        @members[name] = Member.new(member.address, member.incarnation, @clock.now)
        true
      end
    end

    def leave(name : String) : Bool
      @mutex.synchronize { !@members.delete(name).nil? }
    end

    # 探测：移除超时无心跳成员，返回死亡名单。
    def sweep : Array(String)
      now = @clock.now
      @mutex.synchronize do
        dead = [] of String
        @members.each do |name, member|
          dead << name if (now - member.last_seen) > @timeout
        end
        dead.each { |name| @members.delete(name) }
        dead
      end
    end

    def member_names : Array(String)
      @mutex.synchronize { @members.keys.sort }
    end

    def member(name : String) : Member?
      @mutex.synchronize { @members[name]? }
    end

    def size : Int32
      @mutex.synchronize { @members.size }
    end
  end

  # Roster + HashRing 组合：成员视图变化同步到环（join→加入、sweep 死亡→移除），
  # route 给出 canonical identity 的当前归属节点；节点死亡后键漂移到环上的后继节点
  # （漂移转发：其他节点的键不变——一致性哈希性质）。
  class Router
    @ring : ::Troupe::HashRing
    @roster : ::Troupe::Roster

    def initialize(@ring, @roster)
      sync!
    end

    # 令环节点与成员视图一致；返回本发生了什么漂移（新增/移除名单）。
    def sync! : {added: Array(String), removed: Array(String)}
      members = @roster.member_names
      added = [] of String
      removed = [] of String
      members.each do |name|
        unless @ring.nodes.includes?(name)
          @ring.add_node(name)
          added << name
        end
      end
      @ring.nodes.each do |name|
        unless members.includes?(name)
          @ring.remove_node(name)
          removed << name
        end
      end
      {added: added, removed: removed}
    end

    def route(actor_id : ::Troupe::ActorId) : String?
      @ring.owner_for(actor_id.to_s)
    end

    def route_key(key : String) : String?
      @ring.owner_for(key)
    end
  end
end
