# PostgreSQL 多进程故障注入 worker（PLAN M3 验收：三独立进程 + kill -9 + 无未防护双活写）。
# 由 spec/postgresql_multiprocess_spec.cr 编译并作为独立进程spawn。
#
# 用法：pg_worker <url> <instance> <lease_ms> <actor_key> <action> [param]
# action：
#   hold              — acquire + create，之后 renew 循环持锁（等待被 kill -9）
#   probe             — 尝试 acquire 一次，输出 ACQUIRED <epoch> 或 REJECTED 后退出
#   takeover <count>  — 轮询 acquire（最多 15s），成功后写入 {"count": <count>}，输出 WRITTEN <rev>
#   read              — 输出 STATE <data> <rev> 或 STATE nil
require "../../src/troupe"

url = ARGV[0]
instance = ARGV[1]
lease_ms = ARGV[2].to_i64
key = ARGV[3]
action = ARGV[4]

store = Troupe::PostgreSQLPropStore.open(url, instance, lease_ms: lease_ms)
id = Troupe::ActorId.new("mp", "counter", key)

case action
when "hold"
  epoch = store.ownership.acquire(id)
  begin
    store.create(id, 1, %({"count":0}), epoch)
  rescue e : Troupe::ConflictError
    # 已存在（重跑）：确认 revision 后继续持锁
  end
  puts "HOLDING #{epoch}"
  STDOUT.flush
  loop do
    sleep((lease_ms / 3).milliseconds)
    break unless store.ownership.renew(id, epoch)
  end
  puts "LEASE_LOST"
  STDOUT.flush
when "probe"
  begin
    epoch = store.ownership.acquire(id)
    puts "ACQUIRED #{epoch}"
  rescue e : Troupe::CallRejectedError
    puts "REJECTED"
  end
  STDOUT.flush
when "takeover"
  target = ARGV[5].to_i
  deadline = Time.instant + 15.seconds
  got_epoch : UInt64? = nil
  while Time.instant < deadline
    begin
      got_epoch = store.ownership.acquire(id)
      break
    rescue e : Troupe::CallRejectedError
      sleep(150.milliseconds)
    end
  end
  if got_epoch
    record = store.read(id).not_nil!
    store.write(id, record.revision, 1, %({"count":#{target}}), got_epoch)
    puts "WRITTEN #{record.revision + 1}"
  else
    puts "TAKEOVER_TIMEOUT"
  end
  STDOUT.flush
when "read"
  record = store.read(id)
  puts record ? "STATE #{record.data} #{record.revision}" : "STATE nil"
  STDOUT.flush
else
  puts "UNKNOWN_ACTION #{action}"
  STDOUT.flush
end
store.close
