# Troupe.cr 基准（PLAN M2 第五项）。
#
# 场景：激活吞吐 / KB per Actor / 热点 vs 分散调用 / CPU 阻塞调度延迟 / 队列饱和。
# 口径声明：数字仅为本仓自基线（Windows/MSYS2 单线程事件循环），用于回归观察；
# 不与其他语言实现做异口径比较（PLAN.md M2）。
#
# 运行：crystal run --release bench/run.cr [-- --quick]
# --quick：迭代数缩至 1/10，供 CI 冒烟（只验证可运行，数字无意义）。
require "../src/troupe"

QUICK = ARGV.includes?("--quick")
SCALE = QUICK ? 0.1_f64 : 1.0

def scaled(n : Int32) : Int32
  [(n.to_f * SCALE).round.to_i, 1].max
end

class BenchProps
  include JSON::Serializable
  property n : Int32 = 0
  property payload : Array(String) = [] of String

  def initialize
  end
end

class BenchActor < Troupe::Actor(BenchProps)
  troupe_manifest "bench", schema_version: 1 do
    turn touch, {} of String => String, returns: Int32
    turn inc, {} of String => String, returns: Int32
    turn spin, {ms: Int32}, returns: Int32
  end

  def touch : Int32
    1 # 纯激活路径：不写 Props
  end

  def inc : Int32
    props.n += 1
    save
    props.n
  end

  def spin(ms : Int32) : Int32
    # CPU 密集且不让出调度：演示 Fiber 协作式调度的边界（DESIGN §5）
    deadline = Time.instant + ms.milliseconds
    x = 0
    while Time.instant < deadline
      x = (x + 1) % 1_000_003
    end
    x
  end
end

def percentile_f(values : Array(Float64), p : Float64) : Float64
  return 0.0 if values.empty?
  sorted = values.sort
  idx = [(p * (sorted.size - 1)).round.to_i, sorted.size - 1].min
  sorted[idx]
end

stage = Troupe::Stage.new(config: Troupe::StageConfig.new(max_activations: 10_000)) # Fiber 调度模式（真实并发路径）
stage.register(BenchActor.troupe_manifest)
bench_agent = BenchActor::Agent.new(stage)

def bench_id(prefix : String, i : Int32) : Troupe::ActorId
  Troupe::ActorId.new("bench", "bench", "#{prefix}-#{i}")
end

results = [] of Tuple(String, String, String, String)

report = ->(name : String, value : String, unit : String, note : String) do
  results <<({name, value, unit, note})
  puts "#{name.ljust(28)} #{value.rjust(12)} #{unit.ljust(8)} #{note}"
end

puts "Troupe.cr 基准（#{QUICK ? "quick 模式：数字仅供 CI 冒烟" : "release 模式"}）"
puts "环境：Crystal #{Crystal::VERSION} / #{`uname -s`.strip} / 单线程事件循环（协作式 Fiber）"
puts "-" * 86

# ---- 1. 激活吞吐：冷激活新 Actor（含 on_stage + Props 创建） ----
n_activate = scaled(2000)
t0 = Time.instant
n_activate.times do |i|
  bench_agent.touch(bench_id("act", i))
end
elapsed = Time.instant - t0
report.call("activation_throughput", "#{(n_activate / elapsed.total_seconds).round(0)}", "actors/s",
  "#{n_activate} 次冷激活，#{elapsed.total_milliseconds.round(0)}ms")

# ---- 2. KB per Actor：激活后常驻内存增量（slot + 激活实例 + Props + 幂等日志等） ----
n_mem = scaled(3000)
gc_before = GC.stats.total_bytes
n_mem.times do |i|
  bench_agent.touch(bench_id("mem", i))
end
GC.collect
bytes_per_actor = (GC.stats.total_bytes - gc_before) / n_mem
report.call("memory_per_actor", "#{(bytes_per_actor / 1024.0).round(1)}", "KB/actor",
  "#{n_mem} 个 Actor 的增量（含 slot/实例/Props，非纯 Props）")

# ---- 3. 热点 vs 分散调用：同一 Actor 高频 vs 分散到多 Actor ----
hot_id = bench_id("hot", 0)
bench_agent.touch(hot_id) # 预激活
n_calls = scaled(5000)
t0 = Time.instant
n_calls.times { bench_agent.inc(hot_id) }
hot_elapsed = Time.instant - t0
report.call("hot_calls_throughput", "#{(n_calls / hot_elapsed.total_seconds).round(0)}", "calls/s",
  "热点：单 Actor 串行 inc+save，#{n_calls} 次")

scatter_actors = scaled(500)
per_actor = [(n_calls / scatter_actors).round.to_i, 1].max
t0 = Time.instant
scatter_actors.times do |i|
  sid = bench_id("scat", i)
  bench_agent.touch(sid) # 激活
  per_actor.times { bench_agent.inc(sid) }
end
scatter_elapsed = Time.instant - t0
total_scatter = scatter_actors * per_actor
report.call("scattered_calls_throughput", "#{(total_scatter / scatter_elapsed.total_seconds).round(0)}", "calls/s",
  "分散：#{scatter_actors} Actor × #{per_actor} 次（含激活）")

# ---- 4. CPU 阻塞：CPU 密集 Turn 期间的调度停顿（协作式 Fiber 边界） ----
hog_id = bench_id("hog", 0)
bench_agent.touch(hog_id)
hog_ms = QUICK ? 20 : 120
victim_id = bench_id("victim", 0)
bench_agent.touch(victim_id)
# 立即连发：hog 占住线程后 victim 才排队，await 延迟 ≈ hog 剩余时间（不 sleep，避免 hog 先完成）
hog = stage.call(hog_id, "spin", Troupe::Json.any({ms: hog_ms}))
victim_latencies = [] of Float64
3.times do
  t0 = Time.instant
  stage.call(victim_id, "touch", JSON.parse(%({}))).await
  victim_latencies << (Time.instant - t0).total_milliseconds
end
hog.await
report.call("cpu_block_victim_latency", "#{percentile_f(victim_latencies, 1.0).round(1)}", "ms(max)",
  "spin #{hog_ms}ms 期间 3 次轻调用延迟：#{victim_latencies.map { |v| v.round(1) }.join("/")}ms")
baseline_latencies = [] of Float64
20.times do
  t0 = Time.instant
  stage.call(victim_id, "touch", JSON.parse(%({}))).await
  baseline_latencies << (Time.instant - t0).total_milliseconds
end
report.call("idle_call_latency", "#{percentile_f(baseline_latencies, 0.95).round(2)}", "ms(p95)",
  "无阻塞时轻调用 p95（对照）")

# ---- 5. 队列饱和：fire-and-forget 打满有界队列，显式拒绝可重试 ----
sat_id = bench_id("sat", 0)
bench_agent.touch(sat_id)
n_fire = scaled(5000)
accepted = 0
rejected = 0
t0 = Time.instant
n_fire.times do
  begin
    stage.call(sat_id, "inc", JSON.parse(%({}))) # 不等待：队列有界，超限即拒绝
    accepted += 1
  rescue e : Troupe::CallRejectedError
    rejected += 1 if e.reason.backpressure?
    rejected += 1
  end
end
fire_elapsed = Time.instant - t0
# 等待全部 settle：轮询 store 计数
deadline_wait = Time.instant + 30.seconds
while Time.instant < deadline_wait
  record = stage.store.read(sat_id)
  break if record && record.revision >= accepted.to_u64 + 1 # 激活 create 占 revision 1
  sleep(5.milliseconds)
end
drain_elapsed = Time.instant - t0
report.call("queue_saturation", "#{accepted}+#{rejected}", "acc/rej",
  "fire #{n_fire}：入队 #{fire_elapsed.total_milliseconds.round(0)}ms，全量落盘 #{drain_elapsed.total_milliseconds.round(0)}ms")

puts "-" * 86
puts "口径声明：以上为本仓自基线（回归观察用）；Fiber 为协作式调度，CPU 阻塞 Turn 会拖延同进程调度（见 docs/execution-model.md）。"
puts "不与其他语言实现做异口径比较（PLAN.md M2）。"
puts "QUICK=#{QUICK}"
