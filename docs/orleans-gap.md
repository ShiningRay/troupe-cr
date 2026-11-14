# Troupe.cr 与 Orleans 10.0 的差距

> 本文描述目标差距，不表示相关能力已实现。

| 能力域 | Orleans 基线 | Crystal 当前状态 | 计划入口 |
|---|---|---|---|
| Identity/lifecycle | 稳定 GrainId、activation incarnation、完整生命周期 | 只有设计 | M1 最小核心 |
| Turn scheduling | turn-based、reentrancy/read-only/call-chain | 只有 strict Fiber/Channel 方案 | M1 strict，M4 交错 |
| Timeout/cancellation | 可配置响应期限、远程取消、失败通知 | 只有语义草案 | M1/M2 |
| Props | IGrainStorage、ETag、显式写与 Provider | 只有 CAS/schemaVersion 方案 | M1 Memory，M2 SQLite，M3 PG |
| Ownership/directory | 目录注册、DHT、视图交接与恢复 | 无实现；先设计 ownership | M3 ownership，M5 directory ADR |
| Placement | compatible silos、resource-aware、rebalancing | 无实现 | M5 |
| Membership | 表维护、健康探测、suspect/dead | 无实现 | M3 基础 Roster |
| Timer/reminders | activation timer 与持久 reminder 分离 | 只有契约 | M3 共享 reminders |
| Streams | 持久队列、sequence token、拉取/订阅/平衡 | 无实现；Show 只规划实时通知 | M4 realtime，M5 persistent ADR |
| Serialization | 代码生成、版本容错 | 只有显式 DTO/manifest 方案 | M1/M2 |
| Transactions/extensions | 分布式参与方、恢复、activation 扩展 | 非近期目标 | M6 独立评估 |
| Observability | metrics、W3C trace、Dashboard | 只有计划 | M2/M4/M6 |
| 测试与发布 | 多层次核心/Provider/分布式测试 | 只有 scaffold CI | 各阶段验收门禁 |

## 不照搬的部分

- 不复制 .NET class、DI 或私有 serializer；Crystal 使用显式 DTO/泛型/宏提供本地体验。
- 不把 Fiber/Channel 等同于 silo 的分布式正确性。
- 不要求每个 Orleans 模块都进入 Crystal 首版。
- 事务和事件溯源必须在共享状态、可靠消息与恢复被验证后单独设计。
