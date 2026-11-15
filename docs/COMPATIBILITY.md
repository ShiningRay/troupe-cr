# 版本兼容矩阵（M6 发布包）

> 状态：0.x 开发期——任何版本可能包含破坏性变更；本矩阵记录已验证组合与承诺边界。

## Crystal 版本

| troupe.cr | Crystal | 状态 |
|---|---|---|
| 0.17–0.19 | 1.22.x | ✅ 本仓 CI 持续验证（ubuntu + 本地 Windows/MSYS2） |
| < 1.22 | — | ❌ 未验证（shard.yml 声明 `>= 1.22`） |

## Provider 支持矩阵

| 能力 | Memory | SQLite | PostgreSQL |
|---|---|---|---|
| Props CAS + fencing | ✅ | ✅（单机持久） | ✅（跨节点 lease/fencing） |
| 幂等记录同事务提交 | ✅（同锁） | ✅（单事务） | ✅（单事务） |
| Outbox 同事务提交 | ✅（同锁） | ✅（单事务） | ✅（单事务） |
| 跨节点接管 | ❌ `cross_node_safe?=false` | ❌ `false` | ✅ `true` |
| 持久流（M5） | ✅ MemoryStreamStore | ❌ | ✅ PostgreSQLStreamStore |
| 持久 Reminder（M3） | ❌（Memory 版语义同构） | ❌ | ✅ PostgreSQLReminderStore |

## 特性阶段矩阵

| 特性 | 阶段 | 迭代 |
|---|---|---|
| ActorId/manifest/Stage 串行核心 | M1 ✅ | M1 |
| SQLite/PG Provider | M2/M3 ✅ | M2-1, M3-1 |
| 幂等/取消/UnknownOutcome/背压 | M2 ✅ | M2-2 |
| metrics/W3C trace | M2 ✅ | M2-3 |
| typed Agent 宏 | M2 ✅ | M2-4 |
| 基线基准 | M2 ✅ | M2-5 |
| 多进程 kill -9 故障注入 | M3 ✅ | M3 验收 |
| TCP transport | M3 ✅ | M3-3 |
| 持久 Reminder | M3 ✅ | M3-4 |
| Roster/HashRing/drain | M3 ✅ | M3-5 |
| 认证/Outbox | M3 ✅ | M3-6 |
| ReadOnly/improv | M4 ✅ | M4-1 |
| Show realtime/跨 Stage | M4 ✅ | M4-2, M4-3 |
| Director/健康端点 | M4 ✅ | M4-4 |
| 持久流 | M5 ✅ | M5-1 |
| 版本化目录/rebalancing | M5 ✅ | M5-2 |
| 公共协议 ADR + golden fixtures | M5 ✅（Proposed） | M5-3 |
| 跨进程 directory 持久化 | 待做 | — |
| Show 并发交付 | 待做 | — |
| TLS | 方案（docs/security.md） | — |
| 持久流消息队列 Provider/消费组 | 待做（M5） | — |
| 版本化 directory/公共协议 v2 协商 | 待做（M5） | — |
| Booth/OTel 完善、事件溯源 | 待做（M6） | — |

## 承诺边界

- 0.x 阶段：**仅同版本二进制/同 shard 版本互操作有保障**；跨版本兼容矩阵在 1.0 前
  不做承诺（DESIGN：不宣称未验证能力）。
- 公共协议向量（golden/*.json）从 0.19 起视为稳定输入（变更需更新 ADR 0001 并同步
  向量文件）。
