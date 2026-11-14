# Troupe.cr 基线基准（PLAN M2 第五项）

> **口径声明**：以下数字为本仓**自基线**，用于回归观察与边界量化；测试环境、迭代数、调度模式与
> 其他语言实现不同，**不与其他语言做异口径比较**（PLAN.md M2）。复跑命令见文末。

## 方法

- 程序：[bench/run.cr](../bench/run.cr)（`crystal run --release bench/run.cr [-- --quick]`；
  `--quick` 迭代缩至 1/10，仅供 CI 冒烟，数字无意义）
- 运行时：Fiber 调度模式 Stage + Memory PropStore（单线程事件循环、协作式 Fiber）
- 每场景输出：指标、值、单位、口径备注；CPU 阻塞场景对照 idle p95

## 环境（2026-11-14 记录轮）

- 设备 DESKTOP-IBMH65K / Windows 11（win32 10.0.26300 x64）
- Crystal 1.22.1 [23828b0a40]，`--release`，x86_64-w64-windows-gnu（MSYS2 ucrt64）
- 单线程事件循环（未开 preview_mt）

## 结果

| 指标 | 值 | 口径 |
|---|---|---|
| activation_throughput | 24,293 actors/s | 2,000 次冷激活（含 Props create + on_stage），82ms |
| memory_per_actor | 5.3 KB/actor | 3,000 个 Actor 增量，GC.collect 后测；含 slot/激活实例/Props/幂等日志容量，非纯 Props |
| hot_calls_throughput | 364,373 calls/s | 热点：单 Actor 串行 inc+save（Memory CAS）5,000 次 |
| scattered_calls_throughput | 20,297 calls/s | 分散：500 Actor × 10 次（含激活；不含激活的调用吞吐介于两者之间） |
| cpu_block_victim_latency | 120.0 ms(max) | 120ms CPU 密集 Turn（spin 不让出）期间，3 次轻调用延迟 120.0/0.0/0.0ms：**首个 victim 被阻塞整段 spin 时长** |
| idle_call_latency | 0.01 ms(p95) | 无阻塞时轻调用 p95（对照） |
| queue_saturation | 64 accepted / 9,872 rejected | fire-and-forget 5,000 次：入队 181ms（队列打满后显式拒绝），全量落盘 186ms |

## 解读与边界

1. **CPU 阻塞是结构性边界**：spin Turn 占住线程整段时长，同进程其他 Fiber 全部停摆
   （victim 120.0ms ≈ spin 全长）。这与 docs/execution-model.md 的声明一致：Fiber 是协作式
   调度，不是抢占式隔离；CPU 密集/阻塞 C 调用必须外置（独立进程/worker）。
2. **背压有效**：队列深度打满（默认 64）后 fire-and-forget 显式拒绝（CallRejectedError(:backpressure，
   可重试）），内存不随提交速率无界增长；settle 后预算释放（M2 第二项验收）。
3. **热点 vs 分散**：分散场景含激活成本；纯调用吞吐介于热点与分散数字之间。激活路径
   （ownership acquire → read/create → on_stage）占分散场景主要开销。
4. **内存口径**：5.3 KB/actor 为框架常驻（slot + CallBoard + 激活实例 + Props + 幂等日志预留），
   不是纯 Props 负载；大 Props 场景按 payload 线性另计。
5. **不含网络/持久盘**：Memory Provider；SQLite Provider 的持久写放大与 PostgreSQL（M3）
   场景不在本轮口径内。

## 复跑

```sh
crystal run --release bench/run.cr          # 完整口径（约 1-2 分钟）
crystal run --release bench/run.cr -- --quick  # CI 冒烟（数字无意义）
```
