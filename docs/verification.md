# 当前验证（2026-11-14）

本仓当前仅为方案与脚手架，Crystal >= 1.22。

```sh
crystal spec
crystal tool format --check src spec
crystal build src/troupe.cr --no-codegen
```

这些命令只证明命名空间/版本可加载、spec 可运行、格式和库源码可编译。没有 Actor、持久化、网络、集群或性能验收。

后续每阶段在本文追加真实命令、环境、结果、跳过项与未验证边界；不把计划文档中的 `[ ]` 改为 `[x]`，直到对应实现和反例测试存在。
