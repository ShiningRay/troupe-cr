# Props、持久化与所有权方案

## 三个独立版本维度

| 字段 | 用途 | 不能替代 |
|---|---|---|
| `revision` | Props 乐观并发 CAS | ownership epoch、schemaVersion |
| `schemaVersion` | 状态结构升级与逐级迁移 | 代码版本或 wire protocol version |
| `epoch / fencingToken` | 当前激活所有权与旧写拒绝 | Props revision、Stage 健康证明 |

## 激活顺序（不可颠倒）

1. 通过共享 OwnershipStore acquire/renew，获得 epoch。
2. 读取 Props；没有记录则创建，仍需 fencing。
3. 校验并逐级执行 `migrateProps`。
4. 以 expectedRevision + fencingToken 原子提交迁移。
5. `on_stage` 成功后才进入 running。
6. 失败释放所有权，不在未提交/半迁移状态上服务。

## Provider 层级

- **Memory**：Rehearsal，固定 namespace，模拟 CAS/fencing 和复制边界。
- **SQLite/File（开发）**：进程/单机持久，不能承诺节点丢失或跨机恢复。
- **PostgreSQL（生产首选）**：共享 Props、ownership、reminders；原子 SQL/事务实现，不做应用层“先读后写”伪 CAS。

production 必须拒绝不满足共享/fencing 合同的 Provider，而不是只打印 warning。

实现状态（M2）：`PropStore#cross_node_safe?` 显式声明 Provider 能力——Memory/SQLite 均为 false
（仅进程/单机持久，不能跨节点恢复）；SQLite Provider 的 CAS 与 fencing 均在单条 SQL 语句内原子完成，
`write` 的 expectedRevision 与 epoch 都在 UPDATE 的 WHERE 中，无应用层先读后写。
幂等请求记录已实现：`ActorBase#idempotent(key, fingerprint)` 同键同指纹重放首次结果/重抛首次错误、
不同指纹 `IdempotencyConflictError`、保留期过期视为新操作；记录与 Props 在同一原子提交内落盘
（Memory 同锁、SQLite 单事务回滚验证），激活时装载未过期记录，重开（SQLite）后重放仍有效。

## 失败语义

- CAS/fencing/保存失败使实例失效，后续调用从最后已提交快照恢复。
- 数据写结果未知时读取确认，不盲目覆盖；调用方收到 UnknownOutcome。
- 幂等记录与 Props 原子提交，同 requestId 同指纹重放，不同指纹拒绝。
- 外部 HTTP/消息副作用不受 Props fencing 自动保护，需接收方 epoch 或持久 Outbox。

## Reminders

- volatile timer 与 durable reminder 分开。
- 持久 reminder 具备稳定名称、payload、nextDue、claim lease、statusVersion。
- 认领后作为普通 Actor Turn 执行，至少一次；失败/宕机到期重投，业务幂等。
- 多节点调度先按当前归属过滤，再原子 claim，减少所有节点抢同一批记录。
