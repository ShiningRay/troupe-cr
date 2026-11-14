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
