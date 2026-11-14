# Troupe.cr 设计

> 状态：方案与脚手架，尚未实现 Actor 运行时。以 Orleans 10.0 为主要语义参照；跨语言共同决策由 [troupe-planning](https://github.com/ShiningRay/troupe-planning) 协调。

## 1. 目标

- 提供 Crystal  idiomatic、类型安全的 virtual actor 开发体验。
- 从可验证的单机核心开始，逐步达到共享状态、跨进程故障接管和小型生产集群。
- 与其他 Troupe 实现共享核心语义、Provider 合同和测试向量，而非强求同一语法。
- 保留 Crystal 的静态类型、Fiber、Channel、宏与低常驻成本优势。

## 2. 非目标

- 不在首版复制 Orleans 全部模块、.NET DI/serializer 或分布式事务。
- 不通过 Ruby C API 嵌入 Ruby 实现，不包装 trouperb 冒充 Crystal 运行时。
- 不把 Fiber 轻量等同于 Actor 单激活或分布式容错。
- 不在没有共享存储/fencing 证据时宣称 production-ready。
- 不在公共协议 ADR 前宣称与其他 Troupe 语言互操作。

## 3. 概念映射

| Troupe | 含义 | Crystal 设计方向 |
|---|---|---|
| Troupe / Stage | 集群 / 节点运行时 | 显式 `Troupe::Runtime` 与 `Stage`，避免 Ruby 的同名模块/类遮蔽 |
| Actor / Role | 虚拟 Actor / 角色类型 | 模块/泛型接口 + 显式注册表，编译期 manifest 可选 |
| Agent | 位置透明代理 | 类型安全异步调用，稳定方法 ID 与返回错误 |
| Props | 可恢复状态 | schemaVersion、revision CAS、显式序列化/复制边界 |
| CallBoard / Turn | Actor 邮箱 / 串行执行 | 每 activation 有界 Channel + 单消费者 Fiber |
| Casting | 激活与 single-flight | Stage 内按 ActorId 单飞，失败取消并允许后续重试 |
| Intermission | 空闲钝化 | 可注入时钟；等待 quiesce 后下场 |
| Improv / ReadOnly | 显式交错 | 后置实验，先定义状态一致性，不默认并行修改 Props |
| Cue / Reminder | 内存 timer / 持久提醒 | 分开 API；共享 reminder 需要持久 claim 与至少一次语义 |
| Show | 实时通知 / 后续持久流 | 不把 Channel fan-out 称为持久流 |
| Roster / Playbill | 成员 / 放置与路由 | 先 HashRing + ownership；目录/资源放置后续 ADR |
| Rehearsal | 测试运行时 | 固定 namespace、内存 Provider、虚拟时钟和调度控制 |

## 4. 最小单机核心

首实现只包含：

1. `ActorId(namespace, role, key)` canonical identity。
2. 显式 `Role` 注册和方法白名单，拒绝生命周期/内部方法 RPC。
3. `PropStore` 接口与 Memory 实现，create/write 原子 CAS，read 返回独立快照。
4. `ActorSlot` 生命周期与 single-flight，InMemory Props 初始状态。
5. 每 Actor 单 Fiber 严格串行消费有界 CallBoard，FIFO、deadline、queue limit。
6. `on_stage/off_stage`、Intermission、保存失败失效与重激活。
7. 可注入时钟、无网络的 Rehearsal、异常/结果未知类型。

此阶段不支持 TCP、分布式所有权、交错、Show、持久 reminders 或热替换。

## 5. Crystal 执行模型

- **一个 activation 一个调度 Fiber**，顺序处理调用；等待用户异步 I/O 时是否允许下一 Turn 由 strict/annotated 契约决定，初始 strict 不允许。
- Fiber 是协作式调度，阻塞 C 调用/CPU 密集代码仍可能妨碍调度；不能将 Fiber 当抢占式隔离。
- 每 Actor 有界 Channel、Stage 总队列字节/调用预算、连接 in-flight 限制；过载明确拒绝。
- 响应 deadline 与执行占用分离：超时释放调用方等待，不自动放行后续 strict Turn。
- 协作取消通过显式 context 传播；不能强行 kill 单个 Fiber 来伪装资源已安全释放。
- Props 初始实现使用不可变快照或受控复制，禁止调用方与 Actor 意外共享可变结构。
- 后续 `ReadOnly` 可基于快照并发；`Improv` 必须定义提交/冲突规则，不能采用隐含 last-write-wins。

详见 [execution-model.md](docs/execution-model.md)。

## 6. 类型、序列化和版本

- Actor Props 通过显式 serializable DTO/schema 定义，禁止任意对象图、Fiber、Channel、Proc 进入 Props。
- 方法注册产生稳定 role/method ID、参数 schema、版本和错误映射；宏只减少样板，不改变语义。
- 内部 Memory Props 可以采用受控 clone，但 Rehearsal/远程必须验证同一序列化边界。
- schemaVersion 迁移逐级 v→v+1，失败即激活失败；所有权取得前不得创建/迁移共享 Props。
- 公共跨语言协议未冻结；首版不将 Crystal `JSON::Serializable` 的字段名默认直接当永久协议。

## 7. 持久化与所有权

先 Memory，再本地开发 Provider，再 PostgreSQL：

- `revision` 控制状态 CAS，`schemaVersion` 控制迁移，`epoch/fencingToken` 控制所有权，三者独立。
- 激活顺序：acquire → read → migrate/validate → fenced write → on_stage。
- 旧 epoch 的 create/write/migrate/reminder-complete 必须失败；失败实例不继续基于未提交状态服务。
- File/SQLite 只用于进程级持久，production 拒绝用于跨节点恢复。
- 外部 HTTP/消息副作用需要接收方 epoch 或持久 Outbox。

详见 [persistence.md](docs/persistence.md)。

## 8. 集群与后续演进

- 初始路由可复用统一 xxh32 HashRing 契约，但公共哈希必须通过跨语言 golden vectors 验证。
- 节点成员视图与 ownership 分离；分区期间依赖存储租约/fencing，不自欺为已解决脑裂。
- 版本化目录、能力/资源放置、activation rebalancing 在共享容错后通过统一 ADR 决定。
- 公共协议需要独立身份/schema/envelope/错误/版本/追踪规范，不能使用 Crystal 私有 Marshal 或默认 JSON 代表跨语言。

详见 [cluster.md](docs/cluster.md)。

## 9. 可靠性与运维

- 默认 RPC 不自动重试非幂等副作用；超时/断连是 UnknownOutcome。
- Cue 内存 timer 与持久 reminder 分离；后者共享 claim、lease、至少一次、业务幂等。
- Show 初始只规划实时通知；持久流需要日志、游标、ack/replay、保留与慢消费者策略。
- 从 M0 纳入结构化错误、metrics、W3C trace context 和生命周期事件；OTel 适配不绑死核心。
- 测试分层：单元、契约、真实 Provider、多进程、故障注入、版本兼容和发布安装。

## 10. 完成定义

“实现某功能”必须同时具备：

1. 代码与公开语义文档；
2. 正常路径与至少一个关键反例；
3. 资源上限、错误分类和失败恢复；
4. 对应 CI 可执行验证；
5. 对分布式能力，真实拓扑/Provider 证据。

仅有类、接口、README 或单次 happy-path 调用不算完成。
