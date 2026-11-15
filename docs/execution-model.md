# Crystal 执行模型方案

## 默认：严格串行 Turn

每个 activation 有一个邮箱和一个调度 Fiber。CallBoard 只由该 Fiber 消费，因此同一 Actor 的 strict Turn 不并发修改 Props。

```text
Agent call
  → role/method/argument validation
  → ActorId lookup + activation single-flight
  → bounded CallBoard + deadline
  → strict Turn → optional fenced Props commit → reply
  → Intermission/quiesce → off_stage → deactivate
```

Fiber 只提供轻量调度，不提供强制隔离。阻塞 C 扩展、CPU 密集代码和永不返回的用户代码需要显式约束；超时不等于终止。

## 背压与资源上限

- Actor queue depth 和估算字节限制。
- Stage activation 数、全局 queue bytes、网络 in-flight 限制。
- 超过限制返回可重试/不可重试明确的背压错误，不无限创建 Fiber/Channel。
- Cue  tick、Show 投递、Director 调用也进入同一预算，不绕开业务背压。

## 时间与取消

- 排队过期：不执行、零副作用。
- 执行中超时：调用方停止等待，结果未知；旧 strict Turn 仍占串行通道直到 settle。
- 协作取消经 CallContext 传递；Actor 内 I/O 与互调需响应，框架不能声称强制停止外部 C 调用。
  实现（M2）：`CallFuture#cancel` 置位 `CallContext#cancel_requested?`，Turn 自行决定何时收束；
  不响应信号的 Turn 完整执行，取消不改变副作用语义。
- 时钟可注入，Rehearsal 使用虚拟时间/确定性调度，避免依赖 sleep 的脆弱测试。

## Props 一致性

- strict 是默认且唯一允许直接提交状态变更的模式。
- ReadOnly：并发执行只读快照，不写 Props。实现状态（M4）：`turn(name, T, :read_only)`
  在**已提交快照**的影子 actor 上并发执行（不占 strict 串行队列——写不饥饿），
  save 显式拒绝（InvalidActorStateError）；quiesce/drain 计入并发在飞。
- Improv：并发可写副本 + 激活时 revision CAS。实现状态（M4）：`turn(name, T, :improv)`
  以快照 revision 走既有 save CAS——期间 strict 推进则 ConflictError 显式拒绝给调用方
  （禁止隐式覆盖）；无冲突则正常提交。确定性反例（gate 窗口）覆盖冲突与成功两路径。
- 内存 Props 与调用参数需要不可变快照或受控复制，避免 Fiber 间共享可变引用。

## 调度验证

- 并发首次调用只创建一个 activation。
- A 超时后 B 不与 A 交错。
- A→B→A 的死锁/重入行为有明确配置和错误，不偷偷放开 strict。
- read/annotated 与 strict 的矩阵、写饥饿、quiesce 等待所有在飞。
- 长任务期间邮箱/内存有界；慢存储、用户异常、off_stage 异常均有可观测事件。
