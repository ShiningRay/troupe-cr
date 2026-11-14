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

### 未验证边界（不宣称）

- PLAN M3 验收中的"至少三个独立 Crystal 进程 + 扩容/kill -9/冻结恢复"完整故障注入矩阵尚未执行（本轮以同进程双实例模拟接管路径，真实多进程/kill -9 用例列入后续 M3 迭代）。
- Reminder（持久 CueStore）不在本迭代（PLAN M3 后续项）。
- PG 用例需要 `TROUPE_PG_URL`；本地未起容器时自动 pending（CI 必跑）。
- acquire 的租期守卫不主动抢占：被拒方需等租期过期后重试（retryable=true），主动探测/续租心跳列入后续调度循环集成。
