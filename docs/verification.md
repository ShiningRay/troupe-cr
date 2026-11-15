# 当前验证

## M0 脚手架（2026-11-14）

本仓初始交付为方案与脚手架，Crystal >= 1.22。

```sh
crystal spec
crystal tool format --check src spec
crystal build src/troupe.cr --no-codegen
```

这些命令当时只证明命名空间/版本可加载、spec 可运行、格式和库源码可编译。

## M1 单机最小核心（2026-11-14）

### 环境

- 设备 DESKTOP-IBMH65K / Windows 11（win32 10.0.26300 x64）
- Crystal 1.22.1 [23828b0a40]（2026-10-23），LLVM 23.1.3，默认目标 x86_64-w64-windows-gnu（MSYS2 构建）
- 无外部 shard 依赖（stdlib json + fiber/channel/mutex）

### 命令与结果

```sh
crystal spec
# 39 examples, 0 failures, 0 errors, 0 pending
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

CI（GitHub Actions `Checks`，ubuntu-latest，Crystal 1.22）：run 43598485671 success。
首次 CI 运行在 linux 报 `can't infer block return type`（`Array(MigrationStepBase)` 虚拟类型的
抽象方法 `&.from_version` 推断），已改为显式 `.as(Int32)` 并将 CI Crystal 固定 1.22。

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| ActorId 规范形式 | `%`/`/` 编解码往返；`%2F` 不被二次解码；Unicode 不归一化；空组件/控制字符/畸形 canonical 拒绝 |
| Memory PropStore CAS | 重复 create 报 Conflict(:exists)；revision 不匹配/缺失报 Conflict(:revision) |
| Memory fencing | 旧 epoch write 一律拒绝（fencing 优先于 revision 检查），CallRejected(:ownership) |
| read 隔离 | read 返回序列化快照；解析后修改不影响存储 |
| RPC 白名单 | 生命周期/内部方法（on_stage/off_stage/save/props）与未注册方法被拒；未注册角色报 UnknownRoleError |
| 并发首调只激活一次 | 32 并发首调 + on_stage 内 Fiber.yield 放宽竞争窗口，激活计数 = 1 |
| 100 写 Turn 不交错 | Turn 内含读-写窗口（Fiber.yield），100 并发结果集合恰为 1..100，无丢失更新 |
| 排队过期零副作用 | 过期 Turn 出队即拒（CallTimeout :queued），Props 连创建都未发生 |
| 执行超时不放行旧 Turn | Turn 体内推进虚拟时钟模拟长执行；调用方得 CallTimeout :executing；下一 Turn 严格在其 settle 后执行（事件序验证） |
| CAS 失效恢复 | 外部推进 revision 后 save 报 Conflict(:revision) → 实例失效 → 重激活读外部提交快照 |
| fencing 失效恢复 | 模拟另一 owner 取得 epoch 并提交 → 旧实例 save 被拒(:ownership) → 失效 → 从新快照恢复 |
| v1→v3 逐级迁移 | 存量 v1 → v2 → v3 逐级执行并 fenced CAS 提交；迁移步抛错时零写入（store 保持 v1/revision 1），调用方得 ActivationError |
| 迁移链注册期校验 | 终点 ≠ schema_version、重复起点、缺 schema_version 均在 register 时 fail fast |
| Rehearsal 隔离 | 固定 namespace 参与 identity；不同 namespace 的 Rehearsal 状态互不影响、行为一致 |
| 背压 | 队列深度/字节预算超限显式拒绝（CallRejected :backpressure，retryable）；Stage activation 数上限拒绝 |
| Intermission | 空闲超时 sweep 下线（off_stage 执行、Deactivated 事件）；下次调用重新激活并从已提交快照恢复 |
| 停机 | shutdown 后队列中调用收到 Shutdown 拒绝；新 Call 被拒 |
| on_stage 失败重试 | on_stage 抛错 → ActivationError；后续调用从干净状态重新激活成功 |

### JSON 边界试验结论

- Memory Provider 的 Props 以 JSON 字符串存储：每次激活都经过 `JSON::Serializable` 完整 parse/dump，复制边界由序列化保证，read 不会泄漏可变引用。
- Turn 闭包的参数与返回值走 `JSON::Any`：方法白名单 + JSON 边界在本地调用即生效，M2 宏生成 manifest 与类型安全 Agent 时只需替换样板，不改变该边界。
- 已知成本：每激活一次多一轮 parse/dump；热点 Actor 的性能影响将在 M2 基准中量化。

### 未验证边界（不宣称）

- 未做真实 Provider（SQLite/PostgreSQL）、跨进程/多节点、TCP transport、故障注入或性能基准。
- Fiber 模式的消费 Fiber 为协作式调度：阻塞 C/CPU 密集 Turn 会延迟同 Stage 其他 Fiber，见 docs/execution-model.md 边界说明。
- Intermission 的 sweep 为宿主显式调用；自动巡回调度列入 M2。
- ownership fencing 的 Memory 实现只模拟单进程语义；跨节点接管需 M3 真实 Provider 证据。

## M2（首项）：SQLite 本地 Provider（2026-11-14）

### 环境

- 同 M1 环境（DESKTOP-IBMH65K / win / Crystal 1.22.1 / MSYS2 ucrt64）
- 依赖：sqlite3 shard 0.24.0（crystal-sqlite3）+ db 0.15.0（crystal-db）
- 本机 MSYS2 包 mingw-w64-ucrt-x86_64-sqlite3 3.53.4（libsqlite3.a/sqlite3.h 于 C:\msys64\ucrt64）

### Windows/MSYS2 可行性验证（探针，已删除）

| 验证点 | 结果 |
|---|---|
| 链接 libsqlite3（MSYS2 ucrt64 工具链） | 通过，运行时无需额外 DLL 配置 |
| 文件库写入/CAS（INSERT OR IGNORE、UPDATE WHERE revision=） | rows_affected 行为符合预期 |
| 重开恢复 | close 后重新 DB.open 读取一致 |
| 三斜杠 URI 绝对路径 `sqlite3:///C:/...` | 可用（`sqlite3://C:/...` 报 URI::Error bad port，不可用） |
| `INSERT ... ON CONFLICT DO UPDATE RETURNING` | 支持（Int64 返回），用于单语句单调 acquire |
| close 后删除文件（Windows 句柄释放） | 立即可删；未 close 的池连接持有句柄会阻止删除 |
| WAL 模式（URI 参数 journal_mode=WAL） | 可用；close 后 sidecar 自动清理 |
| 内存库 URI（`%3Amemory:`） | ConnectionRefused，不使用（Memory Provider 另有实现） |

### 命令与结果

```sh
shards install
crystal spec
# 43 examples, 0 failures, 0 errors, 0 pending
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

CI（GitHub Actions `Checks`，ubuntu-latest，Crystal 1.22）：新增 `apt-get install libsqlite3-dev` 与 `shards install` 步骤（运行结果见仓库 Actions）。

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| SQLite PropStore 契约 | 与 Memory 契约一致：create 重复 → Conflict(:exists)；expectedRevision 过期 → Conflict(:revision) |
| SQLite fencing 优先 | 旧 epoch 写即使 revision 匹配也拒绝（CallRejected(:ownership)） |
| 重开恢复（Provider 层） | write→close→重新 open：revision/schema_version/data/epoch 与 ownership epoch 均持久 |
| 重启恢复（Stage 端到端） | Stage shutdown → 重开 SQLite store 新建 Stage：increment 从已提交快照继续（5→8） |
| Provider 能力声明 | `cross_node_safe?`：Memory/SQLite 均为 false（不能跨节点恢复） |

### 未验证边界（不宣称）

- SQLite Provider 只承诺进程/单机持久：**不承诺节点丢失或跨机恢复**（persistence.md Provider 层级）；production 接管语义（多节点 fencing/双活防护）待 M3 PostgreSQL 证据，`cross_node_safe? = false` 是显式能力声明。
- 未验证多进程同时写同一 SQLite 文件的锁竞争行为（busy_timeout 5000ms 已设，但未做多进程反例）。
- 未做性能基准（M2 后续项）。

## M2（第二项）：UnknownOutcome / 幂等 / 取消 / 迁移 / backpressure 语义硬化（2026-11-14）

### 命令与结果

```sh
crystal spec
# 57 examples, 0 failures, 0 errors, 0 pending（新增 14 例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| 幂等重放 | 同键同指纹：第二次调用重放首次结果，副作用不重复执行（charged 保持 5） |
| 幂等指纹冲突 | 同键不同指纹 → IdempotencyConflictError，状态不变 |
| 幂等失败记录 | 首次失败（注入异常）→ 记录 ok=false；重放按记录重抛（附原始错误类别）；Props 保持未提交 |
| 幂等保留期 | retention 过期后同键视为新操作（重新执行；激活装载与 Turn 内查找均做时效判定） |
| 幂等原子提交（Memory） | write 失败（revision 冲突）→ 幂等记录不落盘；成功则记录与 Props 同锁生效 |
| 幂等原子提交（SQLite） | 单事务：revision 冲突 → 整体回滚，记录不存在 |
| 幂等持久化 | SQLite 重开后同键同指纹仍重放（troupe_idempotency 表持久） |
| 协作取消 | Turn 轮询 `ctx.cancel_requested?` 提前收束并提交部分状态（steps → 0） |
| 取消不可强杀 | 不观察信号的 Turn 被 cancel 后仍完整执行并提交（full → 7）；cancel 仅置位标志 |
| cancel 幂等 | 已 settle（含 await 已取回复）的 future 上 cancel 返回 false（reply_cache 语义修复） |
| 背压预算释放 | 队列深度达上限拒绝（retryable）→ pump settle → 重试成功（count 3） |
| UnknownOutcome（fiber） | Turn 阻塞超 deadline → 调用方 CallTimeout(:executing)；放行后原 Turn settle、效果提交（结果未知 ≠ 失败）；执行计数 = 1（框架不自动重试）；下一 Turn 严格在其后执行 |
| 迁移 × 重开（SQLite） | 存量 v1 重开激活逐级迁移 v1→v2→v3 并持久化（revision 3）；迁移步抛错 → ActivationError、重开后 store 保持 v1/revision 1（零写入） |

### 未验证边界（不宣称）

- 取消为协作式：不响应信号的 Turn 无法被框架终止（DESIGN 边界，非缺陷）。
- UnknownOutcomeError 本身留待 M3 transport（断连/对端停机）产生；本地未知结果由 CallTimeout(:executing) 表达。
- 幂等重放错误重建为 `::Exception`（保留原类别名与消息，不重建原类型）——与 troupejs 行为一致。
- 未验证多线程运行时（preview_mt）下 CancelSignal 布尔标志的可见性；当前单线程事件循环内无竞争。

## M2（第三项）：metrics / Trace 事件 / W3C trace context（2026-11-14）

### 命令与结果

```sh
crystal spec
# 65 examples, 0 failures, 0 errors, 0 pending（新增 8 例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| W3C tracecontext 派生 | new_span 合法；child 继承 trace-id、换 span-id |
| 非法父降级 | 空/乱串/长度错/非 hex/全零 trace-id/全零 span-id/版本 ff 均拒绝，child_span 静默降级为新根 span（W3C 容错） |
| 根 span 独立 | 无父的两次调用各自新 trace-id；TraceEvent.parent_traceparent 为 nil |
| 调用链传播 | Actor 互调显式传 `ctx.traceparent`：leaf 的 parent = root 的 traceparent、同 trace、不同 span（M2 无隐式传播，宏层 M4 再自动化） |
| metrics 一致性 | activations/turns_started/turns_completed 与真实激活/执行次数一致 |
| metrics 反例 | 激活失败→activation_failures；业务失败→turns_failed；排队过期→turns_expired；白名单拒绝→rejections（按角色）；fencing 保存失败→save_failures |
| trace 过期事件 | 过期 Turn 产出 outcome=expired、ok=false、duration=0 |
| OTel 可选 | 核心零 otel 依赖；`Stage#on_trace` 为桥接钩子（对齐 troupejs onSpan 模式） |

### 未验证边界（不宣称）

- Trace 总线无环形缓冲/采样/过滤（troupejs 有，M2 Crystal 仅回调钩子；量级需求出现后再加）。
- 调用链为显式传父：宏生成的类型安全 Agent（M2 第四项）与跨 Stage transport（M3）承担自动化传播。
- 未对真实 OTel SDK 导出做集成验证（适配器保持可选，核心契约即钩子）。

## M2（第四项）：类型安全 Agent / 宏 manifest / 参数校验 / Cart 示例（2026-11-14）

### 命令与结果

```sh
crystal spec
# 70 examples, 0 failures, 0 errors, 0 pending（新增 5 例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
crystal run examples/cart.cr
# 示例冒烟通过（typed 调用、trace、参数校验拒绝、白名单拒绝、metrics）
crystal docs -o .crystal/api-docs
# API 文档可生成（公开 API 均有 docstring）
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| 宏 manifest 等价性 | `troupe_manifest` 生成的 Manifest 与手写 define/turn 行为一致（typed 与 raw JSON 双路径同结果）；重复注册 RoleConflictError |
| 类型安全代理 | 编译期校验参数/返回类型；可选参数缺省（qty 缺省→1）；返回值按声明类型解包 |
| 参数校验（排队前） | 缺参 → InvalidArgumentError；类型不符 → InvalidArgumentError；非对象参数 → InvalidArgumentError；拒绝后 store 无记录（零副作用、不占用队列） |
| 可选参数 | 缺省通过；出现但类型不符拒绝 |
| 校验顺序 | 白名单先于参数校验（生命周期方法 → CallRejectedError(:whitelist)） |
| 指标 | 拒绝计入 rejections（按角色） |
| trace 透传 | typed agent 传 traceparent → TraceEvent.parent_traceparent = 传入值、trace-id 继承 |
| 宏拒绝编译期 | 不支持的参数/返回类型、缺 returns、非 turn 声明均在宏展开时报错（编译期反例，非运行时） |

### 未验证边界（不宣称）

- 宏支持的参数/返回类型限于 Int32/Int64/String/Bool/Float64/JSON::Any 及 `T?` 可选形（数组/嵌套结构走 JSON::Any）；Schema 演进随公共协议 ADR。
- 宏生成的 manifest 不覆盖迁移声明（迁移仍走手写 `m.migrate`，与 schemaVersion 逐级迁移语义一致）。
- 参数校验为 presence/type 级；深度 schema 校验（范围、自定义谓词）留待需要时。
- `crystal docs` 未入 CI 门禁（本机验证可生成；CI 仅示例冒烟）。

## M2（第五项）：基线基准（2026-11-14）

程序：`bench/run.cr`（五场景，`--quick` 供 CI 冒烟）。完整方法、结果表与解读见
[docs/benchmarks.md](benchmarks.md)。本机 release 记录（2026-11-14，Crystal 1.22.1 --release）：
激活 24,293 actors/s（2,000 冷激活/82ms）、5.3 KB/actor（3,000 个，GC 后增量）、
热点 364,373 calls/s（单 Actor inc+save 5,000 次）、分散 20,297 calls/s（500 Actor × 10，含激活）、
CPU 阻塞 victim 120.0ms ≈ spin 全长（协作式调度停顿量化，对照 idle p95 0.01ms）、
队列饱和 64 accepted / 9,872 rejected（打满显式拒绝）+ 186ms 全量落盘。
口径声明：本仓自基线，用于回归观察，不与其他语言实现异口径比较。

### 未验证边界（不宣称）

- 基准不含网络/持久盘（Memory Provider）；SQLite 持久写放大与 PostgreSQL（M3）场景不在本轮口径。
- CPU 阻塞场景量化了协作式调度停顿（结构性边界，非缺陷）；外置 CPU worker 方案待后续评估。
- 基准数字随环境波动，仅同一环境内的趋势对比有意义；CI 只跑 `--quick` 冒烟（不校验数字）。

## M4（第三项）：Show 跨 Stage / 订阅生命周期 / 背压（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="..." crystal spec
# 127 examples, 0 failures, 0 errors, 0 pending（新增 5 例跨 Stage 用例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| 跨 Stage Audience | 同一 topic 订阅者来自两个 Stage：publish 各自交付（两 Stage props 均更新） |
| 订阅生命周期（停机） | Stage 停机后其订阅交付失败（:shutdown → 离线不保证）；其他 Stage 照常 |
| 订阅生命周期（排空） | draining Stage 的订阅交付失败（:draining 可漂移转发给调用方） |
| 背压隔离 | 慢订阅者（Manual+队列深度 1 确定性满队）failed；快订阅者同 publish 照常收到 |
| 退订幂等 | 重复退订/未知 actor 退订返回 false |

### 未验证边界（不宣称）

- publish 仍为同步顺序 fan-out；并发交付与 per-subscriber 并发预算属后续 Show 背压深化。
- 慢订阅者背压反例使用 Manual Stage（确定性满队）；Fiber Stage 的队列时序由背压语义自然覆盖。
## M4（第二项）：Show realtime（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="..." crystal spec
# 122 examples, 0 failures, 0 errors, 0 pending（新增 8 例 Show 用例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| Actor Audience 经完整 Turn | publish 交付为普通 Turn：props 经 save 持久化、白名单/串行语义不变 |
| 分离性 | 边界回调与 Actor 订阅独立退订互不影响；并存时两条路径各自收到 |
| 在线尽力（Turn 抛错） | 交付失败计入 actors_failed；无累积/补投；零持久化副作用（激活 record 保持初始值） |
| 离线不保证（背压） | 队列满 → 交付入队触发背压 → actors_failed=1（在线尽力放弃） |
| 边界回调隔离 | 坏回调抛错 → external_failed=1，后续订阅者仍收到 |
| 未订阅 | publish 全零报告 |
| 多 topic | 同一 Actor 订阅两个 topic 独立交付，last_topic 保持最后交付（完整 Turn 串行） |
| 退订 | actor/external 退订后 publish 不投 |

### 未验证边界（不宣称）

- 在线尽力放弃 = **不重投**（实时语义）；持久化诉求走 Reminder（M3）/Outbox（M3 指引）/持久流（M5 待做）。
- publish 为同步 fan-out（单 fiber 顺序交付）；并发交付与跨 Stage Show 属下一项（Show 跨 Stage、订阅生命周期和背压）。
- 不把 fan-out 称为持久流：无事件日志/游标/ack/replay（M5 待做）。
## M4（首项）：ReadOnly 快照并发 + 显式 Improv 规则（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="..." crystal spec
# 114 examples, 0 failures, 0 errors, 0 pending（新增 7 例 M4 用例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| read_only 并发通道 | 长只读阻塞期间，后续只读与 strict 写经并发通道立即完成（写饥饿反证：2s deadline 内完成） |
| 只读快照 | read_only 看到已提交状态；save 显式拒绝（InvalidActorStateError），零写入 |
| improv 显式冲突 | 阻塞窗口期间 strict 推进 revision → save CAS 失败 → ConflictError 给 improv 调用方；最终状态 = strict 的值（无隐式覆盖） |
| improv 无冲突 | gate 放行后 CAS 成功提交（count 5） |
| quiesce | Manual：并发在飞（gate 阻塞）时 idle?=false → 放行 → idle?=true → finish_drain；漏计并发在飞即挂 |
| turn mode 协商 | turn_mode(method) 驱动分流；strict 默认不变（既有 99 例回归全绿） |
| 宏支持 | troupe_manifest turn 声明 `mode: :read_only/:improv` 透传 |

### 未验证边界（不宣称）

- read_only 快照读取为 store 单条读（不含未提交 strict 状态）；多快照间的顺序无保证。
- improv 冲突策略为"显式拒绝"（DESIGN 禁止隐式覆盖）；合并/多写冲突解决留待 ADR。
- 并发 read_only 的数量上限暂复用 max_activations 语义（slot 级 in-flight 计数）；独立预算列入 M4 后续。
- Fiber 模式并发重叠的 peak 计数反例因 Windows fiber 调度时序不稳定，以"阻塞期间后续完成"的时序断言替代（等价并发性证明）。
## M3（认证/轮换/Outbox）：安全与外部副作用（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="postgres://troupe:troupe@127.0.0.1:55444/troupe" crystal spec
# 107 examples, 0 failures, 0 errors, 0 pending（新增 8 例：auth 3 + outbox 5）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| token 认证 | 正确 token 正常通信；错误 token 握手拒绝（AuthError，不回显提交内容） |
| 密钥轮换宽限 | rotate 后旧 token 可用（滚动窗口）；新 token 同时可用 |
| 撤销 | revoke_old 后旧 token 立即拒绝，新 token 不受影响，服务存活 |
| 常量时间比较 | 长度/内容不等均 false |
| Outbox 同原子提交 | emit 后 save 落盘；save 失败（fencing/CAS）→ outbox 不落盘（Memory 同锁/SQLite+PG 单事务回滚） |
| 至少一次派发 | 交付回调失败 → 不标记 → 下轮重投；成功 → mark_sent 后不再投 |
| Actor 集成 | emit_event → save → 重开/派发器读出（跨"进程"持久） |

### 未验证边界（不宣称）

- TLS 未实现（docs/security.md 为方案指引：OpenSSL 包装集成点，构建验证留待独立迭代）；
- 认证仅保护连接建立，无 per-call 授权；帧协议不防重放（依赖 TLS/幂等键）；
- Outbox 至少一次必然可能重复——接收方幂等（event_id）是使用前提；
- 派发器无归属过滤（与 owner 解耦），多节点并发派发由轮询去重（mark_sent 原子性）兜底。
## M3（持久 CueStore/Reminder）：归属过滤 + 至少一次重投（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="postgres://troupe:troupe@127.0.0.1:55444/troupe" crystal spec
# 93 examples, 0 failures, 0 errors, 0 pending（新增 9 例：Memory 6 + PG 3）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 实现要点

- `ReminderStore` 契约 + Memory/PostgreSQL 双实现：稳定键 (actor_id, name)、turn、payload、
  nextDue、claim lease、statusVersion（docs/persistence.md Reminders 规格）。
- claim_due 单语句**先按归属过滤（troupe_ownership 持有者）再原子认领**（PG UPDATE+元组 IN 子查询，
  租期/到期判定全用 DB 时钟 now()）；无所有权记录的 reminder 任何节点可认领（调度先于激活）。
- complete/release 均 fencing：status_version + claim_holder + 租期有效同时匹配；
  失配返回 false → 提醒留给当前 owner 重投（不丢失）。
- `ReminderRunner`：claim → 作为普通 Actor Turn 交付（经同一 Stage 管道，白名单/背压/超时不变）
  → 成功 complete / 失败 release 立即重投。poll_once 供测试/宿主确定性驱动（manual_pump 支持
  Rehearsal）；start/stop 为生产轮询循环。

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| 到期才认领 | due_at 未到 → claim_due 为空 |
| 归属过滤 | node-b 认领不到 node-a 持有 actor 的 reminder；所有权转移 + 租期过期后 node-b 可认领 |
| 至少一次（交付失败） | Turn 抛错 → release → 立即重投（status_version 递增） |
| 至少一次（认领者宕机） | claim 后不 complete → 租期过期 → 其他 owner 重投 |
| fencing 反例 | 旧 status_version 的 complete 被拒，reminder 不丢；正确版本删除成功 |
| cancel | 已取消不再投递；重复 cancel 返回 false |
| Runner 确定性 | 前两次注入失败 + 第三次成功 → 最终恰投递一次（效果 count=1，无重复） |
| PG 契约 | 上述语义在真实 PostgreSQL 上同样成立（CI service 必跑） |

### 未验证边界（不宣称）

- 多节点 ReminderRunner 并发轮询的争用行为仅由 PG 原子 claim SQL 保证，未做长时并发压测。
- Runner 轮询间隔/批量为固定配置；动态调节与 metric 暴露列入 M4 运维项。
- 重复投递的兜底是业务幂等键（`ActorBase#idempotent`），框架不承诺 exactly-once（DESIGN 明确禁止）。
## M3（Roster/HashRing/漂移转发/drain）：成员视图与路由实验（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="..." crystal spec
# 99 examples, 0 failures, 0 errors, 0 pending（新增 6 例 roster/routing/drain）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 实现要点

- `HashRing`：vnodes+CRC32（纯 Crystal）一致性环；节点增删只移动相邻区间键（一致性性质反例：
  3000 键移除 1/3 节点，非死亡节点键迁移数=0）。
- `Roster`：join（新成员 incarnation=1；死亡重入团从已移除成员的最后 incarnation 单调 +1——
  用独立 @last_incarnation 表，判死移除后仍可递增）；heartbeat incarnation 不匹配拒绝；
  sweep 超时判死；同/低 incarnation 重加入 → StaleIncarnationError（生产协议协商边界）。
- `Router`：成员视图同步到环（sync! 返回 added/removed 漂移名单）；死亡节点键漂移到环上后继，
  其他节点键不变。
- `Stage` 优雅 drain 三段式：begin_drain（新 Call → CallRejectedError(:draining, retryable=true，
  可漂移转发)）→ idle?（全部 slot 无排队无在途）→ finish_drain（→ :shutdown）。
  排队/在途 Turn 照常完成（执行占用语义不变）；Manual/Fiber 双模式验证。

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| 环负载均衡 | 3 节点 3000 键：各节点份额 10%~60%（无独大） |
| 环一致性 | 移除 1/3 节点：其他节点键迁移数=0，死亡节点键全部漂移 |
| incarnation 协商 | 现存=1 时以 1 重加入被拒；死亡重入团 =2；同 incarnation 心跳拒绝 |
| 判死与重入团 | 超时 sweep 移除（持续心跳者存活）；重入团 incarnation 单调 +1 |
| 漂移转发 | Router.sync! 死亡节点移除 → 仅其键漂移到后继 |
| drain 拒新 | begin_drain 后新 Call → :draining retryable=true |
| drain 完成判定 | idle?=false（有排队/在途）→ 排空后 true |
| finish 边界 | finish_drain 未排空时显式拒绝（InvalidActorStateError）；排空后 → :shutdown |

### 未验证边界（不宣称）

- Roster 探测为心跳超时模型，未实现 gossip/全互联探测协议与消息边界（跨进程实验留待 M4）。
- Router 仅给出归属决策，远程 handoff（连接迁移、在途转移）未实现；漂移转发的"转发"由调用方
  按新归属重试（:draining retryable=true 语义支撑）。
- HashRing 用 CRC32，进程内一致；跨语言 canonical hash 待 M5 公共协议 ADR。
## M3（TCP transport 实验）：帧协议与服务端/客户端（2026-11-15）

### 命令与结果

```sh
TROUPE_PG_URL="postgres://troupe:troupe@127.0.0.1:55444/troupe" crystal spec
# 84 examples, 0 failures, 0 errors, 0 pending（新增 7 例 TCP 用例）
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 实现要点

- 帧协议：`magic("TRP1") + length(u32 LE) + crc32(u32 LE) + payload`；CRC32 纯 Crystal 实现
  （Windows 构建无 zlib）；长度上限在读 payload **之前**校验，超限不分配内存；
  魔数/超限/CRC 不符 = 协议违规，立即断连。
- TCPServer：包既有 Stage——白名单/参数校验/背压/超时/取消语义全部复用，不新增调用语义；
  连接级 in-flight 上限（超限回 CallRejectedError(:backpressure, retryable)，不断连）；
  cancel 信封 → 既有 CallFuture#cancel；断连时协作取消在途 Turn。
- TCPClient：单连接 call_id 多路分发；deadline 用 Unix 毫秒跨线（RFC3339 截断毫秒的坑）；
  调用方 deadline 先到 → CallTimeoutError(:executing)；断连 → 在途调用 UnknownOutcomeError；
  新连接自动重建，既有 pending 不受影响。
- 错误分类跨线：Troupe 错误带结构化字段（kind/phase/reason/retryable）原样重建；
  业务异常与未知类别保留类别名+消息降级为普通 Exception（与 troupejs 行为一致）。

### 已验证语义（含反例）

| 语义 | 反例/验收 |
|---|---|
| 端到端 | 类型安全结果跨线；白名单(:whitelist)/未知角色/业务异常跨线保真 |
| 长度上限 | 4096B 帧 vs 512B 上限：服务端读前拒绝并断连；服务存活、新客户端正常 |
| 帧校验 | 错误 CRC → 协议违规断连；新连接不受影响 |
| in-flight | 上限 2：第 3 个调用显式拒绝(:backpressure, retryable)；放行后前两个完成 |
| 超时 | 调用方 deadline 300ms 先到 → :executing（结果未知）；Turn settle 后效果照常提交 |
| 取消 | cancel 管线跨线（未匹配 id 无副作用）；后续调用完好 |
| 断连恢复 | 服务端整个关闭 → 在途调用 UnknownOutcomeError；同 Stage 新 server 实例恢复服务，快照延续 |

### 未验证边界（不宣称）

- 认证/TLS/密钥轮换不在本实验（PLAN M3 认证项另行迭代）。
- cancel 为协作式：服务端 Turn 不响应信号时不可强杀（DESIGN 边界）。
- 客户端 deadline 到期后不撤回服务端在途 Turn（结果未知语义的一部分；服务端 Turn 自行 settle）。
- 未做网络分区/半开连接/粘包压力等网络层故障注入；帧协议为实验性质，公共跨语言协议仍待 ADR（PLAN M5）。

## M3（首项+次项）：PostgreSQL Props/Ownership Provider（2026-11-14）

### 环境

- 本机：Docker `troupe-pg`（postgres:15，端口 55444，用户/库同名 troupe）
- 依赖：pg shard 0.31.0（will/crystal-pg）+ db 0.15.0
- CI：ubuntu-latest postgres:15 service container（`TROUPE_PG_URL` 注入，postgres 用例必跑）

### 命令与结果

```sh
TROUPE_PG_URL="postgres://troupe:troupe@127.0.0.1:55444/troupe" crystal spec
# 75 examples, 0 failures, 0 errors, 0 pending（新增 5 例真实 PG 用例）
# 未设置 TROUPE_PG_URL 时 PG 用例自动 pending，不伪造绿灯
crystal tool format --check src spec
# 通过
crystal build src/troupe.cr --no-codegen
# 通过
```

### 已验证语义（含反例，全部连真实 PG）

| 语义 | 反例/验收 |
|---|---|
| 契约一致性 | create 重复 → Conflict(:exists)；expectedRevision 过期 → Conflict(:revision)；`cross_node_safe? = true` |
| fencing 优先 | 同实例重入 epoch 单调 +1；旧 epoch 写即使 revision 匹配也拒绝（CallRejected(:ownership)） |
| lease 跨实例 | 其他实例有效租期内 acquire 显式拒绝（retryable）；同 epoch renew 续租成功；旧 epoch renew 失败 |
| lease 过期接管 | 租期过期（数据库时钟判定）后另一节点可取得所有权，epoch 单调递增 |
| 幂等原子提交 | revision 冲突 → 单事务回滚，记录不落盘；成功则同事务生效 |
| Stage 端到端接管 | A 节点激活写入 → 租期过期后 B 节点 acquire 并提交 count=50 → A 的旧实例 save 被 fencing 拒绝失效 → 重新激活从 PG 已提交快照继续（51） |

### 多进程故障注入（M3 验收核心，2026-11-14 补）

程序：spec/support/pg_worker.cr（独立进程 worker）+ spec/postgresql_multiprocess_spec.cr；
worker 由 spec 编译为 `.crystal/pg_worker` 后作为真实子进程 spawn（6 个进程参与全流程）。
全套 77 examples（含 PG 用例与多进程用例），0 failures。

| 步骤 | 结果 |
|---|---|
| 三独立进程并存 | A（hold+renew 循环持锁）；B、C 同时 acquire 显式拒绝 |
| kill -9 | A 被 TerminateProcess（graceful: false，POSIX 为 SIGKILL）强杀，无 graceful 释放 |
| 接管 | 租期过期（DB 时钟判定）后新进程 D 轮询 acquire 成功（epoch 单调），写入 count=42 revision=2 |
| 无双活 | D 持租期间进程 E acquire 被拒——同一时刻仅一个 owner 可写 |
| 已提交快照 | 全新进程 F 读到 D 的提交（count=42，rev 2） |
| 跨进程幂等 | 进程实例 A 写入幂等记录 → 全新独立实例 B 读同键命中可重放（记录与 Props 同事务持久） |

### 未验证边界（不宣称）

- "扩容"（容量均衡放置）与"冻结恢复"（suspend/整节点暂停）用例未单独构造；kill -9 + lease 过期已覆盖最硬的接管路径，扩容/冻结随 Roster/drain 项一起验收。
- Reminder（持久 CueStore）不在本迭代（PLAN M3 后续项）。
- PG 用例需要 `TROUPE_PG_URL`；本地未起容器时自动 pending（CI 必跑）。
- acquire 的租期守卫不主动抢占：被拒方需等租期过期后重试（retryable=true），主动探测/续租心跳列入后续调度循环集成。
