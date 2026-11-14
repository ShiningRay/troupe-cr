# Troupe.cr

面向 Crystal 的 Virtual Actor 框架，语义对标 Orleans，沿用 Troupe 的剧团术语。

> **当前状态：M1 单机最小核心（dev）。** 已实现 ActorId / Role manifest / Memory PropStore（CAS+fencing）/ Stage / Agent / ActorSlot（single-flight）/ 有界 CallBoard / Intermission / Rehearsal。尚未实现 SQLite/PostgreSQL Provider、TCP transport、集群路由、持久 reminder 与 Show；不要据此宣称 production-ready 或跨语言互操作。

## 文档

- [DESIGN.md](DESIGN.md)：目标架构、Crystal 执行模型和核心契约。
- [PLAN.md](PLAN.md)：分阶段方案、验收门禁和非目标。
- [Orleans 差距](docs/orleans-gap.md)
- [执行模型](docs/execution-model.md)
- [持久化与所有权](docs/persistence.md)
- [集群与协议](docs/cluster.md)
- [当前验证](docs/verification.md)
- [多语言统一规划](https://github.com/ShiningRay/troupe-planning)

## 验证

要求 Crystal >= 1.22。

```sh
crystal spec
crystal tool format --check src spec
crystal build src/troupe.cr --no-codegen
```

`--no-codegen` 只验证库源码可编译，不生成可执行程序。各阶段真实命令、环境与结果记录在 [docs/verification.md](docs/verification.md)。

## 最小用法（单机 Stage）

```crystal
require "troupe"

class CartProps
  include JSON::Serializable
  property items : Array(String) = [] of String

  def initialize
  end
end

class CartActor < Troupe::Actor(CartProps)
  def add(item : String) : Int32
    props.items << item
    save
    props.items.size
  end
end

stage = Troupe::Stage.new
stage.register(Troupe::Manifest(CartProps).define("cart", CartActor) do |m|
  m.schema_version 1
  m.initial { CartProps.new }
  m.turn("add", CartActor) do |actor, ctx, args|
    JSON::Any.new(actor.add(args["item"].as_s).to_i64)
  end
end)

id = Troupe::ActorId.new("app", "cart", "cart-1")
result = Troupe::Agent.new(stage).call!(id, "add", JSON.parse(%({"item": "pear"})))
```

Turn 闭包走 JSON 参数/结果边界；`save` 以 revision CAS + epoch fencing 显式提交。测试请使用 `Troupe::Rehearsal`（固定 namespace、Memory Provider、虚拟时钟、pump 确定性调度）。

## 首个实施阶段

按 [PLAN.md](PLAN.md) 已完成**单机最小核心**（M1）。下一阶段（M2）：本地持久化 Provider、观测与 API 硬化。

## 许可

MIT，见 [LICENSE](LICENSE)。
