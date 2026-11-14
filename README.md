# Troupe.cr

面向 Crystal 的 Virtual Actor 框架设计与项目脚手架，语义对标 Orleans，沿用 Troupe 的剧团术语。

> **当前状态：仅方案与脚手架。** 已定义 `Troupe` 命名空间和开发版本；尚未实现 Actor、激活、串行调度、持久化、网络或集群。不要把本仓当前测试通过理解为 Actor 运行时可用。

## 文档

- [DESIGN.md](DESIGN.md)：目标架构、Crystal 执行模型和核心契约。
- [PLAN.md](PLAN.md)：分阶段方案、验收门禁和非目标。
- [Orleans 差距](docs/orleans-gap.md)
- [执行模型](docs/execution-model.md)
- [持久化与所有权](docs/persistence.md)
- [集群与协议](docs/cluster.md)
- [当前验证](docs/verification.md)
- [多语言统一规划](https://github.com/ShiningRay/troupe-planning)

## 当前验证

要求 Crystal >= 1.22。

```sh
crystal spec
crystal tool format --check src spec
crystal build src/troupe.cr --no-codegen
```

`--no-codegen` 只验证库源码可编译，不生成可执行程序。本轮没有 Actor 运行时基准或生产验收。

## 首个实施阶段

按 [PLAN.md](PLAN.md) 先实现**单机最小核心**：稳定 Actor identity、类型安全 Props、Memory PropStore、single-flight 激活、严格串行 Turn、超时/背压和 deterministic tests。共享存储、集群、reminders 和流须在前置语义验收后实现。

## 许可

MIT，见 [LICENSE](LICENSE)。
