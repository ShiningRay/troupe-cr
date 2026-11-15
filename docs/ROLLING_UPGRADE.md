# 滚动升级/回滚指引（PLAN M6）

> 基于：schema 逐级迁移（M1）、优雅 drain（M3）、版本兼容矩阵（docs/COMPATIBILITY.md）、
> golden 稳定承诺（ADR 0001）。适用于多 Stage 同进程与多节点（PG Provider）部署。

## 升级流程（滚动）

1. **预检**：核对 docs/COMPATIBILITY.md——新旧版本 Provider/协议兼容性；schemaVersion
   迁移链完整（逐级 v→v+1，禁止跳级）。
2. **逐节点 drain**：`director.drain_stage(name)` → 新 Call 得 `:draining`（retryable，
   调用方漂移转发到其他节点）→ `idle?` 等待在飞/排队清空（quiesce 语义）。
3. **升级节点**：替换二进制/重启；activation 从 Provider（PG/SQLite）最后已提交快照恢复。
4. **回滚窗口**：schema 迁移只前进——回滚 = 旧代码运行于新 schema（逐级迁移保证
   旧代码可读新 schema 的最终字段？**否**——旧代码读 schemaVersion > 自身支持时会
   ActivationError）。因此 schema 迁移必须**向后兼容读**（新增字段带默认值），见下。
5. **全量完成后**：确认各节点 health ok → 移除 drain 状态（自然随重启消失）。

## 回滚

- **二进制回滚**：先 drain 目标节点 → 重启旧版本 → 旧版本对新 schemaVersion 的
  actor 报 ActivationError（schema 只前进）——因此**发布前必须验证迁移链向后兼容读**
  （新增可空/默认字段），否则回滚窗口 = schema 断代。
- **不兼容迁移**：禁止原地回滚——需按 docs/COMPATIBILITY.md 停机迁移流程。

## 检查清单

- [ ] schemaVersion 迁移链注册齐全（v(n-1)→v(n)），旧版本可读新数据（向后兼容读）
- [ ] drain 后 idle? 达成（无排队/在飞/并发只读）
- [ ] Provider 连接配置就绪（PG lease/流游标在重启后恢复）
- [ ] Director health ok=true、metrics 无异常增长（activation_failures/save_failures）
- [ ] 回滚演练已在预发执行（M6 持续验证项）

## 明确不做

- 自动回滚（风险大于收益——schema 只前进语义下自动回滚会放大故障）；
- 跨大版本原地升级（0.x 阶段按停机迁移处理）。
