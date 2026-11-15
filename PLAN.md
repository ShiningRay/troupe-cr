# Troupe.cr 实施计划

> 本轮只交付方案与脚手架。以下阶段均为后续实施，未标注完成；不设虚构日期。

## M0：设计与验证基线（本轮范围）

- [x] 建立公开仓库、MIT、shard.yml、命名空间/版本与最小 spec。
- [x] 编写目标架构、执行/持久化/集群契约和 Orleans 差距。
- [x] CI 执行 `crystal spec`、格式检查、库源码 `--no-codegen` 编译。
- [x] 明确没有 Actor 运行时，不声称单机或集群可用。

**门禁**：干净 checkout 可执行 spec/format/build；CI 名称不把脚手架测试描述为 Actor 验收。

## M1：语义契约与最小单机核心（已实现，2026-11-14）

- [x] 固定 ActorId、Role manifest、错误类型、Props/PropStore 接口和 JSON 边界试验。
- [x] Memory PropStore：原子 create/write CAS、read 隔离、revision/schemaVersion。
- [x] Stage/Repertoire/Agent：显式注册、RPC 白名单、位置透明本地调用。
- [x] ActorSlot：single-flight、on_stage/off_stage、Intermission、保存失败失效/重激活。
- [x] 单 Fiber FIFO CallBoard：严格串行、排队过期、执行占用、queue depth/bytes、Stage activation 限制。
- [x] Rehearsal 固定 namespace、Memory Provider、可注入时钟和确定性调度。

**验收**：并发首调只激活一次；100 个写 Turn 不交错；排队过期无副作用；执行超时不放行旧 Turn；CAS/保存失败从最后提交快照恢复；任意目录名下 Rehearsal 一致；v1→v3 逐级迁移且失败不写。——全部由 `spec/`（39 例，含反例）覆盖，命令与结果见 [docs/verification.md](docs/verification.md)。

## M2：本地持久化、观测和 API 硬化（已完成，2026-11-14）

- [x] 选择开发用本地 Provider（优先 SQLite），原子 CAS 和重开恢复；说明不能跨节点恢复。（SQLitePropStore/SQLiteOwnershipStore，2026-11-14；CAS/fencing 均为单条 SQL 原子语句，`cross_node_safe? = false` 显式声明能力，Windows/MSYS2 与 CI ubuntu 均验证）
- [x] 完善 UnknownOutcome、幂等请求记录、迁移、取消和 backpressure 语义。（2026-11-14：幂等记录与 Props 单事务原子提交、同键同指纹重放/不同指纹拒绝、失败重放、保留期过期；协作取消 `CallContext#cancel_requested?`/`CallFuture#cancel` 不可强行终止；UnknownOutcome 纤维模式证明（超时后原 Turn 占用通道至 settle、效果提交、无自动重试）；backpressure settle 后预算释放可重试；SQLite 重开迁移成功/失败不写）
- [x] 结构化 lifecycle/call metrics、Trace 事件、W3C context；OTel 适配保持可选。（2026-11-14：StageMetrics 计数器由 emit 单点更新；TraceContext W3C 解析/派生（非法父静默降级、全零拒绝）；TraceEvent 于 Turn 边界产出（completed/failed/expired）经 `Stage#on_trace` 外送；调用链经 `ctx.traceparent` 显式传父；核心零 otel 依赖）
- [x] 类型安全 Agent/宏 manifest、参数校验、公开 API 文档和 minimal Cart 示例。（2026-11-14：`troupe_manifest` 宏生成与手写等价的 Manifest + 嵌套类型安全 `Agent` 代理；`turn_with_schema` 参数 schema 在排队前校验（缺参/类型不符 → InvalidArgumentError，零副作用）；examples/cart.cr 冒烟入 CI；crystal docs 可生成）
- [x] 基准：激活吞吐、KB/Actor、热点/分散调用、CPU 阻塞、队列饱和；不与其他语言异口径比较。（2026-11-14：bench/run.cr 五场景，release 记录见 docs/benchmarks.md——激活 24.3k actors/s、5.3 KB/actor、热点 364k calls/s、CPU 阻塞 victim 延迟≈spin 全长（协作式边界量化）、队列打满显式拒绝 64+9872；CI 仅 --quick 冒烟）

**验收**：重启后恢复、复制边界一致、调用链可见、宏/手写注册行为一致、所有过载路径有界并明确拒绝。

## M3：共享状态与生产容错

- [x] PostgreSQL Props/Ownership：事务、CAS、lease、单调 epoch 与 fencing。（2026-11-14：PostgreSQLPropStore/PostgreSQLOwnershipStore——acquire 单语句 RETURNING 带租期守卫、跨实例租期内拒绝可重试、同实例/过期重取 epoch 单调、renew 同 epoch 续租、fencing（epoch+租期有效期）在单条 UPDATE 的 WHERE 内原子校验、幂等记录单事务提交；`cross_node_safe? = true`；CI 以 postgres service 必跑真实 PG 用例；reminder 部分属后续项）
- [x] 激活先 acquire 再读/迁移/写；所有旧 epoch 写拒绝。（M1 激活顺序已有反例；本轮以真实 PG 补端到端接管反例——另一节点取得所有权提交后，旧实例 save 被 fencing 拒绝并失效，重新激活从 PG 已提交快照继续）
- [x] TCP transport 实验：长度上限、帧校验、in-flight、方法白名单、错误分类、超时/取消。（2026-11-15：`Troupe::Transport` 帧协议 magic+length+CRC32（纯 Crystal，超限读前拒绝不分配内存）、TCPServer 复用 Stage 管道（白名单/背压/超时/取消不新增语义）+ 连接级 in-flight 上限 + cancel 信封协作取消传播、TCPClient call_id 多路复用 + deadline :executing + 断连 UnknownOutcome；7 例反例；认证/TLS 另行迭代）
- [x] Roster/HashRing/漂移转发、生产角色与协议协商、优雅 drain。（2026-11-15：`Roster` 成员视图（join/heartbeat/sweep 判死，incarnation 协商——旧/同 incarnation 重入团 StaleIncarnationError 拒绝、死亡重入团单调 +1）；`HashRing` vnodes+CRC32 一致性环（增删只移动相邻区间）；`Router` 同步成员视图到环——死亡节点键漂移到后继、其他节点键不变；`Stage` 优雅 drain 三段式 begin(:draining retryable 拒新)→idle?(队列+在途清空)→finish(:shutdown)，执行占用语义不变；6 例反例。跨节点探测协议与远程 handoff 留待 M4/M5 实验）
- [x] 持久 CueStore、归属过滤、至少一次重投与幂等。（2026-11-15：`ReminderStore` 契约 + Memory/PostgreSQL 双实现 + `ReminderRunner` 交付调度——稳定键 (actor_id, name)、payload、nextDue、claim lease、statusVersion；claim 单语句先按归属过滤（troupe_ownership 持有者，无记录任何节点可认领）再原子认领；complete/release 均 fencing（status_version+claim_holder+租期，DB 时钟判定）；交付失败 release 立即重投、认领者宕机租期过期他人重投——至少一次，重复由业务幂等兜底；9 例反例含真实 PG；volatile timer 与 durable reminder 保持分离）
- [x] 认证/TLS/密钥轮换方案；外部副作用 fencing/Outbox 指引。（2026-11-15：`Transport::Authenticator` token 认证+轮换/宽限/撤销（常量时间比较）+ TCP 握手集成（未认证断连，3s ack 超时防 Windows 关闭时序死锁）；外部副作用 Outbox 三 Provider 同事务/同锁提交（`ActorBase#emit_event`+`OutboxDispatcher` 至少一次派发）；TLS 为 docs/security.md 方案指引（OpenSSL 包装集成点），Outbox 指引 docs/outbox.md；11 例反例）

**验收**：至少三个独立 Crystal 进程连接真实 PostgreSQL，扩容、kill -9、冻结恢复后无未防护双活成功写；旧 epoch 写拒绝；Cue 跨进程恢复与重复幂等；POSIX CI 必跑故障用例。

## M4：调度扩展与实时 Show

- [x] 在 strict 核心稳定后引入 ReadOnly 快照并发和显式 Improv 规则；写饥饿/quiesce 反例。（2026-11-15：`Manifest#turn(mode:)` 三类调度——strict 串行独占（默认）/ read_only 并发已提交快照（禁写，save 显式拒绝 InvalidActorStateError）/ improv 并发可写副本（save 以激活时 revision CAS，冲突显式 ConflictError 拒绝，禁止隐式覆盖）；写饥饿反例（长只读阻塞期间 strict 立即完成）与 quiesce 反例（drain/idle 等待并发在飞，漏计即挂）；7 例反例，Manual/Fiber 双模式）
- [ ] Show realtime：Actor Audience 经完整 Turn，边界回调与 Actor 订阅分离。
- [ ] Show 跨 Stage、订阅生命周期和背压；明确在线尽力通知，离线不保证。
- [ ] Director/CLI/基础健康与指标端点，故障与未知结果可见。

**验收**：交错组合矩阵、无写饥饿、慢订阅者不耗尽全局内存；不将 Show 称为持久流。

## M5：可靠消息、目录与互操作（统一 ADR 后）

- [ ] 持久流：事件日志、游标、ack/replay、保留、慢消费者和 Provider；优先复用成熟消息系统。
- [ ] 版本化 directory、capabilities/resource placement、handoff/recovery 与 activation rebalancing。
- [ ] 公共协议：canonical identity/hash、方法/schema ID、payload、错误、deadline/cancel、trace 和版本协商。
- [ ] 与 troupe-planning golden fixtures/contract tests 对齐，再决定跨语言客户端或异构 silo。

**验收**：按 ADR 限定范围验证，不以共享 JSON 或 Fiber/Channel 名称宣称多语言集群。

## M6：高级模块与生态

- [ ] Booth/OTel 完善、发布包与版本兼容矩阵、滚动升级/回滚。
- [ ] 持久 Outbox、事件溯源与扩展点；有独立需求后再评估分布式事务。
- [ ] Provider/故障/性能持续验证，公开不支持项与容量边界。

## 风险与对应

| 风险 | 对策 |
|---|---|
| Fiber 遇阻塞 C/CPU 任务无法及时调度 | 文档边界、独立 worker/进程评估、心跳/调度延迟基准 |
| 静态类型与公共协议耦合过紧 | 显式版本化 DTO/manifest，协议独立 IDL/golden vectors |
| Channel 队列只限 Actor 未限全局 | Actor depth + Stage bytes/activation/inflight 多层预算 |
| 跨 await 交错破坏 Props 一致性 | strict 默认；快照/冲突协议先行；禁隐式覆盖 |
| 先写后 acquire 破坏 fencing | 激活顺序测试和旧 epoch 反例作为 Provider 合同 |
| 测试像 Ruby namespace 一样假阳性 | 固定 Rehearsal namespace，断言真实旧快照与接管 epoch |
| 把脚手架当框架 | README/CI/版本均标 dev，功能只在可执行反例后声明 |
