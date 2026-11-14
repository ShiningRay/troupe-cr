# 集群、路由与协议方案

## 近期：应用内 Stage

Troupe.cr 保持 Troupe 现有应用内 Stage 方向，不先引入 Orbit 式独立 mesh。Stage 内激活 Actor；远程调用经位置透明 Agent 进入同一调度与错误管道。

初期路由可以是 canonical identity → xxh32 HashRing → owner Stage + 漂移转发。哈希只决定候选位置，真正的单激活写保护依赖共享 ownership/fencing。

## 必须分开的组件

- **Roster**：成员视图、join/leave、incarnation、探测、死亡与重新入团。
- **Playbill / Placement**：角色兼容的候选节点与位置策略。
- **Directory（后续 ADR）**：activation 注册/定位、缓存失效、视图交接和恢复。
- **Ownership**：某 Actor 当前写所有权、lease 和 fencing，不等于 Roster 心跳。
- **Transport**：身份校验、帧/连接预算、调用与错误、deadline/cancel/trace。

## 生产边界

- production 入团必须成功，角色/协议不兼容明确拒绝。
- 所有入站 RPC 使用方法白名单与参数 schema，生命周期/内部方法不可调用。
- 限制帧、缓冲、in-flight、Actor queue 和全局 queue bytes。
- 认证、TLS、密钥轮换与最小权限必须进入生产路线；仅 token/受控网络不是终态。
- 业务异常与框架错误分类，stack/secret 不直接上线。

## 跨语言不是默认能力

当前 Troupe 各实现没有共同 wire protocol。Crystal 不单独定义一套并宣称兼容。

统一规划需要 ADR 决定：

1. 只统一语义/contract tests；
2. 公共协议支持跨语言客户端；
3. 完整异构 silo 混群（额外包括 membership、directory、placement 和恢复）。

只有第 1/2 项证据时，不宣称第 3 项。公共协议需 canonical identity/hash、方法/schema ID、语言中立 payload、命名错误、版本协商和 golden fixtures。

## 后续目录与弹性

当 HashRing+ownership 的运维/规模边界被实测证明后，再引入版本化目录：

- register/unregister/cache invalidation；
- membership view、handoff 与 crash recovery；
- capabilities/resource-aware placement；
- activation rebalancing 与回退到简单策略。

StatelessWorker 若未来支持，必须作为显式多实例模型，不能复用单激活保证。
