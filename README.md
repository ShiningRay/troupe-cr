# Troupe.cr

面向 Crystal 的 Virtual Actor 框架，语义对标 Orleans，沿用 Troupe 的剧团术语。

> **当前状态：M1 单机核心 + M2 持久化/语义硬化/可观测/基准 + M3 PostgreSQL Provider（dev）。** 已实现 ActorId / Role manifest / Memory 与 SQLite / PostgreSQL PropStore（CAS+fencing，PG 为 `cross_node_safe? = true` 的生产 Provider）/ Stage / Agent / ActorSlot（single-flight）/ 有界 CallBoard / Intermission / Rehearsal / 幂等记录 / 协作取消 / metrics 与 W3C trace 钩子 / 基线基准。TCP transport、集群路由、持久 reminder 与 Show 尚未实现；多进程 kill -9 级故障注入矩阵尚未执行，不要据此宣称 production-ready 或跨语言互操作。

## 文档

- [DESIGN.md](DESIGN.md)：目标架构、Crystal 执行模型和核心契约。
- [PLAN.md](PLAN.md)：分阶段方案、验收门禁和非目标。
- [Orleans 差距](docs/orleans-gap.md)
- [执行模型](docs/execution-model.md)
- [持久化与所有权](docs/persistence.md)
- [集群与协议](docs/cluster.md)
- [当前验证](docs/verification.md)
- [多语言统一规划](https://github.com/ShiningRay/troupe-planning)

## 验证

要求 Crystal >= 1.22。

```sh
crystal spec
crystal tool format --check src spec
crystal build src/troupe.cr --no-codegen
```

`--no-codegen` 只验证库源码可编译，不生成可执行程序。各阶段真实命令、环境与结果记录在 [docs/verification.md](docs/verification.md)。

## 最小用法（单机 Stage）

```crystal
require "troupe"

class CartProps
  include JSON::Serializable
  property items : Array(String) = [] of String

  def initialize
  end
end

class CartActor < Troupe::Actor(CartProps)
  def add(item : String) : Int32
    props.items << item
    save
    props.items.size
  end
end

stage = Troupe::Stage.new
stage.register(Troupe::Manifest(CartProps).define("cart", CartActor) do |m|
  m.schema_version 1
  m.initial { CartProps.new }
  m.turn("add", CartActor) do |actor, ctx, args|
    JSON::Any.new(actor.add(args["item"].as_s).to_i64)
  end
end)

id = Troupe::ActorId.new("app", "cart", "cart-1")
result = Troupe::Agent.new(stage).call!(id, "add", JSON.parse(%({"item": "pear"})))
```

Turn 闭包走 JSON 参数/结果边界；`save` 以 revision CAS + epoch fencing 显式提交。测试请使用 `Troupe::Rehearsal`（固定 namespace、Memory Provider、虚拟时钟、pump 确定性调度）。

## 类型安全 Agent（宏 manifest）

```crystal
class CartActor < Troupe::Actor(CartProps)
  troupe_manifest "cart", schema_version: 1 do
    turn add_item, {item: String}, returns: Int32
  end

  def add_item(item : String) : Int32
    props.items << item
    save
    props.items.size
  end
end

stage.register(CartActor.troupe_manifest)          # 宏生成 manifest（含参数 schema）
cart = CartActor::Agent.new(stage)                 # 类型安全代理
cart.add_item(id, "pear")                          # 编译期类型安全；缺参/类型不符排队前拒绝
```

完整示例见 [examples/cart.cr](examples/cart.cr)（`crystal run examples/cart.cr`）。

## 本地持久化（M2，开发用）

```crystal
store = Troupe::SQLitePropStore.open("./dev-troupe.db") # WAL 模式
stage = Troupe::Stage.new(store: store, ownership: store.ownership)
```

SQLite Provider 的 CAS 与 fencing 均为单条 SQL 原子语句；进程重启后从文件恢复。
注意：**仅进程/单机持久**（`store.cross_node_safe? == false`），不承诺节点丢失或跨机恢复。

## PostgreSQL Provider（M3，生产）

```crystal
store = Troupe::PostgreSQLPropStore.open("postgres://troupe:troupe@127.0.0.1:5432/troupe",
  owner_instance: "silo-1", lease_ms: 30_000)
stage = Troupe::Stage.new(store: store, ownership: store.ownership)
```

所有权带租期（数据库服务器时钟判定）：跨实例有效租期内 acquire 显式拒绝（可重试），
过期后可取得且 epoch 单调递增；旧 epoch 写一律被 fencing 拒绝。**多节点接管语义**
（`cross_node_safe? == true`）。测试需设置 `TROUPE_PG_URL`（CI 已内置 postgres service）。

## TCP transport（M3，实验）

```crystal
server = Troupe::Transport::TCPServer.new(stage, "127.0.0.1", 0)   # 包既有 Stage
port = server.listen

client = Troupe::Transport::TCPClient.new("127.0.0.1", port)
client.call(id, "increment", args)   # 白名单/背压/超时/取消语义与本地一致
```

帧协议带长度上限与 CRC32 校验（超限读前拒绝）；连接级 in-flight 上限；deadline 超时得
`:executing` 结果未知；断连在途调用得 `UnknownOutcomeError`；cancel 信封传播协作取消。
认证/TLS 另行迭代（PLAN M3）。

## 持久 Reminder（M3）

```crystal
runner = Troupe::ReminderRunner.new(stage, reminder_store, "silo-1", ownership)
runner.schedule(id, "retry-payment", "on_reminder", payload, due_at: 5.minutes.from)
runner.start # 轮询认领 → 作为普通 Turn 交付 → 成功 complete / 失败重投
```

归属过滤（仅认领本节点拥有的 actor）→ 原子 claim（租期）→ 至少一次交付
（失败/宕机到期重投，重复由业务幂等键兜底）。volatile timer 与 durable reminder 保持分离。

## Show realtime（M4）

```crystal
hub = Troupe::ShowHub.new(stage)
hub.show("events").actor_subscribe(id, "on_event")   # Actor Audience：经完整 Turn 交付
hub.show("events").external_subscribe { |payload| ... } # 边界回调（非 Actor 观察者）
report = hub.publish("events", payload)              # 在线尽力：失败放弃不重投
```

两类订阅分离；Actor 交付经同一 Stage 管道（串行/白名单/背压不变）。
跨 Stage Audience：`actor_subscribe(id, turn, other_stage)` 显式绑定 Stage；
订阅生命周期——Stage 停机/排空的交付计入 failed（离线不保证）；
慢订阅者背压隔离（不影响其他订阅者）。
持久化诉求走 Reminder/Outbox——不把 realtime fan-out 称为持久流。

## 调度模式（M4）

```crystal
m.turn "query", OrderActor, :read_only do |actor, ctx, args| ... end  # 并发只读快照（禁写）
m.turn "merge",  OrderActor, :improv     do |actor, ctx, args| ... end  # 并发可写副本+CAS（冲突显式拒绝）
m.turn "apply",  OrderActor              do |actor, ctx, args| ... end  # strict 串行（默认）
```

read_only/improv 不占 strict 串行队列（写不饥饿）；improv 冲突显式拒绝给调用方。
quiesce/drain 等待所有并发在飞。

## 成员视图与路由（M3）

```crystal
roster = Troupe::Roster.new(timeout: 10.seconds)
roster.join("silo-1", "host:1")
router = Troupe::Router.new(Troupe::HashRing.new, roster)
router.route(id)             # canonical identity → 归属节点（死亡节点键漂移到后继）

stage.begin_drain            # 优雅 drain：拒新(:draining, 可漂移转发) → idle? → finish_drain
```

Roster incarnation 单调协商（旧/同 incarnation 重入团拒绝）；HashRing vnodes+CRC32
一致性环（节点增删只移动相邻区间键）。

## 安全与外部副作用（M3）

- Transport token 认证 + 轮换/宽限/撤销（常量时间比较；未认证断连）；
- `ActorBase#emit_event` → Outbox 与 Props 同原子提交 → `OutboxDispatcher` 至少一次派发；
- TLS 为方案指引（[docs/security.md](docs/security.md)），外部副作用指引见
  [docs/outbox.md](docs/outbox.md)。

## 可观测（M2）

```crystal
stage.on_event { |event| ... }                      # 结构化生命周期事件
stage.on_trace { |trace| ... }                      # Turn 边界 TraceEvent（W3C traceparent）
stage.metrics.counter("turns_completed")            # lifecycle/call 计数器

future = agent.call(id, "charge", args, nil, "00-<32hex>-<16hex>-01")   # 传入调用方 W3C context
ctx.traceparent                                     # Turn 内互调时显式作为父传递
```

核心零 OTel 依赖：`on_trace` 即桥接真实 OTel SDK 的钩子（对齐 troupejs onSpan 模式）。

## 基线基准（M2）

```sh
crystal run --release bench/run.cr
```

五场景：激活吞吐 / KB per Actor / 热点 vs 分散调用 / CPU 阻塞调度延迟 / 队列饱和。
口径声明与方法见 [docs/benchmarks.md](docs/benchmarks.md)——本仓自基线，不与其他语言异口径比较。

## 实施阶段

按 [PLAN.md](PLAN.md) 已完成 M1 单机核心与 M2 全部五项（SQLite 本地 Provider、语义硬化、
可观测、类型安全 Agent/宏 manifest、基线基准）。下一阶段 M3：PostgreSQL Provider、
TCP transport、持久 reminder 与生产容错验收。

## 许可

MIT，见 [LICENSE](LICENSE)。
