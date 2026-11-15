# ADR 0001：公共跨语言协议（wire protocol）

- 状态：Proposed（troupe.cr 侧已实现锚点：golden fixtures + 契约测试；待 troupe-planning 采纳为全语言标准）
- 日期：2026-11-15
- 关联：troupe-planning docs/target-architecture.md（协议与运维层）、docs/cluster.md（Transport/跨语言不是默认能力）

## 背景

Troupe 各语言实现没有共同 wire protocol（PLAN M5 前提）。跨语言集群需要：canonical
identity/hash、方法/schema ID、payload、错误、deadline/cancel、trace 和版本协商。
本 ADR 记录 troupe.cr 提议的协议 v1 与其锚点实现。

## 决策

### 1. Canonical identity（troupe-identity/1）

`namespace/role/key`，UTF-8；组件非空、不含控制字符（C0/DEL）；`%`→`%25`、`/`→`%2F`
编码后以 `/` 连接；不做 Unicode 归一化。向量见 golden/identity.json。

### 2. 哈希（troupe-hash-crc32/1）

CRC32 IEEE 802.3（poly 0xEDB88320，init/xorout 0xFFFFFFFF）作用于 canonical UTF-8 字节。
仅承诺进程内/同版本环与指纹一致性；**不承诺跨语言哈希环一致性**（各实现可用不同环算法，
只需 golden 向量验证 CRC32 本身）。向量见 golden/hash.json。

### 3. 错误分类码（troupe-errors/1）

跨线错误以稳定码 + 结构化字段表达（非类名）：
`CONFLICT{exists|revision}`、`CALL_TIMEOUT{queued|executing}`、
`CALL_REJECTED{backpressure|whitelist|shutdown|draining|ownership|invalidated} + retryable`、
`UNKNOWN_OUTCOME`、`IDEMPOTENCY_CONFLICT`、`UNKNOWN_ROLE`、`INVALID_ARGUMENT`、
`ACTIVATION`、`INVALID_ACTOR_STATE`、`STALE_INCARNATION`。
业务异常不映射码表——降级为 `message` 透传（接收方按字符串处理）。向量见 golden/errors.json。

### 4. 信封与帧（troupe-envelope/1）

TCP 帧：`magic("TRP1" u32 LE) + length(u32 LE) + crc32(u32 LE) + payload(UTF-8 JSON)`；
首帧必须 auth；长度上限默认 1 MiB（读前拒绝）。信封字段：`t(req|rep|cancel|auth)/id/
actor/m/a/dl(unix ms)/tp(W3C traceparent)/tk/ok/v/ec/em/ek/ert`。向量见 golden/envelope.json。

### 5. deadline/cancel/trace

- deadline 以 Unix 毫秒绝对时刻跨线；到达后调用方得 `CALL_TIMEOUT{executing}`（结果未知）；
- cancel 为协作信号信封，不保证终止；
- traceparent（W3C）随请求传播，Turn 产出子 span。

### 6. 版本协商

auth ack 携带协议版本（v1 起步）；不兼容 → 断连并报告所支持版本
（当前实现：auth ack 未含版本字段——**升级点**，v2 协商落地时补充）。

### 7. golden fixtures 对齐

`golden/*.json` 为本 ADR 的机器可读向量；各语言实现以"读取同一组文件断言行为一致"
为对齐锚点（troupe.cr 见 spec/golden_fixtures_spec.cr）。troupe-planning 采纳后，
向量文件迁入统一仓并按语言发布。

## 后果

- 正面：向量驱动对齐（无隐式假设）；错误码稳定可跨线断言；帧格式与 M3 transport 实现同源。
- 负面：JSON payload 有序列化体积成本；per-call 授权与压缩未包含（后续 ADR）；
  业务异常跨线降级为字符串（不保类型）。

## 备选

- 复用 Orleans_call 协议格式：与 Troupe 术语/错误模型不匹配，弃；
- 仅统一语义不统一 wire：保留为 fallback——若 troupe-planning 否决本 ADR，
  golden 向量仍可作为 identity/hash 基准。
