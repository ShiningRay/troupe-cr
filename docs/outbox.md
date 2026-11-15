# 外部副作用指引：fencing 与持久 Outbox（PLAN M3 指引）

> 状态：Outbox 可执行闭环已实现（三 Provider 同事务提交 + 派发器至少一次）；本文是
> 使用指引与边界说明。来源：docs/persistence.md——外部 HTTP/消息副作用不受 Props
> fencing 自动保护，需接收方 epoch 校验或持久 Outbox。

## 问题

Actor Turn 内直接调用外部系统（HTTP/消息队列/邮件）存在两难：
- **先副作用后 save**：save 失败/实例失效 → 外部效果已发生但状态回滚 → 重试时重复副作用；
- **先 save 后副作用**：save 成功后崩溃 → 外部效果丢失。

## 方案：持久 Outbox（本仓实现）

```crystal
# Turn 内：事件与状态同原子提交
m.turn "pay", OrderActor do |actor, ctx, args|
  actor.props.paid = true
  actor.emit_event("payment", JSON.parse(%({"order": "o-1"})))
  actor.save   # Props CAS + 幂等记录 + Outbox 事件单事务/同锁提交
  ...
end

# 进程内派发器：轮询 → 交付回调（外部副作用在此发生）→ 标记已投递
dispatcher = Troupe::OutboxDispatcher.new(store, ->(record) { http_post(record.topic, record.payload) })
dispatcher.poll_once(id)
```

- **同原子提交**：Memory 同锁、SQLite/PostgreSQL 与 Props 同事务——CAS/租期/fencing
  失败时事件整体不落盘（反例覆盖）；
- **至少一次**：交付回调抛错不标记 → 下轮重投；派发器宕机 → 未标记记录再次 poll；
  标记（`mark_sent`）后才算交付完成；
- **重复投递**：至少一次必然可能重复——外部接收方必须幂等（幂等键=event_id）或
  接收方实现自己的 epoch 校验（拒绝已过任期的请求）。

## 方案 B：接收方 epoch 校验（替代/叠加）

外部系统可校验"请求是否来自当前所有者"：Actor 在调用外部系统时附带
`(actor_id, epoch)`，接收方通过查询 troupe_ownership（或缓存）确认 epoch 仍是当前
所有者才执行。适用于接收方可查询框架状态的内网系统；跨组织场景用 Outbox。

## 实现映射

| 组件 | 位置 |
|---|---|
| 事件记录 | `ActorBase#emit_event(topic, payload, event_id?)` → ActivationContext journal |
| 原子提交 | `PropStore#write(..., outbox: [...])`（Memory 同锁；SQLite/PG 单事务） |
| 未投递读取 | `PropStore#poll_outbox(actor_id, limit)`（激活时装载回 journal） |
| 投递标记 | `PropStore#mark_sent(actor_id, event_id)` |
| 派发 | `Troupe::OutboxDispatcher`（poll → 交付回调 → mark_sent） |

## 边界（不宣称）

- Outbox 保证 at-least-once + 事件与状态原子可见；**不保证 exactly-once**（DESIGN 禁止）；
- 派发器为进程内组件：节点宕机后其未标记记录由任意节点重新派发（无归属过滤——
  Outbox 与具体 owner 解耦，避免依赖 lease 心跳；如需归属过滤可叠加 ownership 查询）；
- SQLite Provider 的 sent_at 为秒级精度（strftime）；PG 为 TIMESTAMPTZ。
- 事件顺序：单 Actor 内按 created_at/插入序交付；跨 Actor 无顺序承诺。
