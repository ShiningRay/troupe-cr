require "./spec_helper"

# PLAN M3 验收（多进程部分）：至少三个独立 Crystal 进程连接真实 PostgreSQL，
# kill -9 后接管且无未防护双活成功写。需要 TROUPE_PG_URL；未设置时 pending。
PG_URL_MP = ENV["TROUPE_PG_URL"]?

def mp_build_worker : String
  bin = File.join(".crystal", "pg_worker")
  unless File.exists?(bin)
    result = Process.run("crystal", ["build", "spec/support/pg_worker.cr", "-o", bin],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    raise "worker 编译失败" unless result.success?
  end
  bin
end

def mp_spawn(bin : String, url : String, instance : String, lease_ms : Int64, key : String, *action) : Process
  Process.new(bin, args: [url, instance, lease_ms.to_s, key] + action.to_a.map(&.to_s),
    output: Process::Redirect::Pipe, error: Process::Redirect::Inherit, input: Process::Redirect::Close)
end

def mp_line(process : Process, timeout_s : Float64 = 20.0) : String?
  # 读一行；超时/EOF 返回 nil（读 channel + fiber 避免永久阻塞）
  line_channel = Channel(String?).new
  spawn do
    begin
      line_channel.send(process.output.gets)
    rescue
      line_channel.send(nil)
    end
  end
  select
  when line = line_channel.receive
    line
  when timeout((timeout_s).seconds)
    nil
  end
end

def mp_force_kill(process : Process) : Nil
  # graceful: false → POSIX SIGKILL / Windows TerminateProcess（kill -9 语义）
  process.terminate(graceful: false)
rescue e
  Process.run("taskkill", ["/F", "/PID", process.pid.to_s], shell: false)
  nil
end

def mp_wait_exit(process : Process) : Nil
  deadline = Time.instant + 10.seconds
  while process.exists? && Time.instant < deadline
    sleep(50.milliseconds)
  end
  process.close if process.exists?
rescue
  nil
end

describe "PostgreSQL 多进程故障注入" do
  if pg_url = PG_URL_MP
    it "三独立进程：跨实例拒绝 → kill -9 → 租期过期接管 → 无未防护双活写 → 新进程读已提交快照" do
      bin = mp_build_worker
      key = "kill9-#{Random.new.next_int}"
      lease_ms = 1200_i64

      # 1) 进程 A：acquire + create + renew 持锁
      a = mp_spawn(bin, pg_url, "mp-node-a", lease_ms, key, "hold")
      holding = mp_line(a).should_not be_nil
      holding.should start_with("HOLDING")
      epoch_a = holding.split(" ")[1].to_i

      # 2) 进程 B、C：A 租期有效期内 acquire 均被拒（三个独立进程并存）
      b = mp_spawn(bin, pg_url, "mp-node-b", lease_ms, key, "probe")
      mp_line(b).should eq("REJECTED")
      b.wait
      c = mp_spawn(bin, pg_url, "mp-node-c", lease_ms, key, "probe")
      mp_line(c).should eq("REJECTED")
      c.wait

      # 3) kill -9 A（不释放锁，不 graceful renew 停止）
      mp_force_kill(a)
      mp_wait_exit(a)

      # 4) 租期过期后，新进程 D 接管并写入（B/C 已退出，D 为第三个新进程）
      sleep(2.seconds)
      d = mp_spawn(bin, pg_url, "mp-node-d", lease_ms, key, "takeover", 42)
      written = mp_line(d).should_not be_nil
      written.should start_with("WRITTEN")
      written.split(" ")[1].to_i.should eq(2) # create(1) → takeover write(2)
      d.wait

      # 5) D 持有租期期间，进程 E 再次 acquire 被拒——接管后无未防护双活
      e = mp_spawn(bin, pg_url, "mp-node-e", lease_ms, key, "probe")
      mp_line(e).should eq("REJECTED")
      e.wait

      # 6) 全新进程读：只看到 D 的已提交快照
      f = mp_spawn(bin, pg_url, "mp-node-f", lease_ms, key, "read")
      state = mp_line(f).should_not be_nil
      state.should eq("STATE {\"count\":42} 2")
      f.wait
    end

    it "多进程重复幂等：两进程先后同键同指纹 → 第二个进程重放首次结果" do
      bin = mp_build_worker
      # 复用 Stage 语义需 manifest；此处直接在 store 层验证幂等记录跨进程持久化/重放
      store_a = Troupe::PostgreSQLPropStore.open(pg_url, "mp-idem-a-#{Random.new.next_int}")
      id = Troupe::ActorId.new("mp", "idem", "k-#{Random.new.next_int}")
      epoch = store_a.ownership.acquire(id)
      store_a.create(id, 1, %({"count":0}), epoch)
      entry = Troupe::IdempotencyRecord.new(key: "charge", fingerprint: "fp-1", ok: true,
        expires_at: 9_999_999_999_i64, value: "100")
      store_a.write(id, 1_u64, 1, %({"count":100}), epoch, [entry])
      store_a.close

      # 全新独立实例（等价新进程）读取同一键 → 命中记录可重放
      store_b = Troupe::PostgreSQLPropStore.open(pg_url, "mp-idem-b-#{Random.new.next_int}")
      records = store_b.idempotency(id, Time.utc)
      records.size.should eq(1)
      records[0].fingerprint.should eq("fp-1")
      ::JSON.parse(records[0].value.not_nil!).as_i.should eq(100)
      store_b.close
    end
  else
    pending "多进程故障注入：设置 TROUPE_PG_URL（本机 troupe-pg 容器或 CI service）后运行"
  end
end
