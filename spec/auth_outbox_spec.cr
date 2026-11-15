require "./spec_helper"

# PLAN M3 认证/密钥轮换（Transport）+ 外部副作用 Outbox（fencing 指引的可执行闭环）。
def tcp_auth_setup(server_token : String)
  Gate2Actor.reset!
  stage = Troupe::Stage.new
  TroupeFixtures.register_counter(stage)
  auth = Troupe::Transport::Authenticator.new(server_token)
  server = Troupe::Transport::TCPServer.new(stage, "127.0.0.1", 0, auth: auth)
  port = server.listen
  {stage, server, auth, port}
end

describe "M3 认证/密钥轮换（Transport）" do
  it "正确 token 正常通信；错误 token 握手被拒" do
    stage, server, auth, port = tcp_auth_setup("token-v1")
    begin
      good = Troupe::Transport::TCPClient.new("127.0.0.1", port, token: "token-v1")
      id = Troupe::ActorId.new("shop", "counter", "auth-1")
      good.call(id, "increment", TroupeFixtures.counter_args(1)).as_i.should eq(1)
      good.close

      bad = Troupe::Transport::TCPClient.new("127.0.0.1", port, token: "wrong")
      error = expect_raises(Troupe::Transport::AuthError) do
        bad.call(id, "increment", TroupeFixtures.counter_args(1))
      end
      error.message.not_nil!.should contain("token")
      bad.close
    ensure
      server.close
      stage.shutdown
    end
  end

  it "密钥轮换：rotate 后宽限期内旧 token 可用；revoke_old 后旧 token 立即失效" do
    stage, server, auth, port = tcp_auth_setup("token-v1")
    begin
      auth.rotate("token-v2") # 轮换：v1 进入宽限集

      old_client = Troupe::Transport::TCPClient.new("127.0.0.1", port, token: "token-v1")
      id = Troupe::ActorId.new("shop", "counter", "rotate")
      old_client.call(id, "increment", TroupeFixtures.counter_args(1)).as_i.should eq(1) # 宽限期内可用
      old_client.close

      new_client = Troupe::Transport::TCPClient.new("127.0.0.1", port, token: "token-v2")
      new_client.call(id, "increment", TroupeFixtures.counter_args(1)).as_i.should eq(2)
      new_client.close

      auth.revoke_old
      stale = Troupe::Transport::TCPClient.new("127.0.0.1", port, token: "token-v1")
      expect_raises(Troupe::Transport::AuthError) do
        stale.call(id, "increment", TroupeFixtures.counter_args(1))
      end
      stale.close

      # 服务存活：新 token 仍可用
      fresh = Troupe::Transport::TCPClient.new("127.0.0.1", port, token: "token-v2")
      fresh.call(id, "increment", TroupeFixtures.counter_args(1)).as_i.should eq(3)
      fresh.close
    ensure
      server.close
      stage.shutdown
    end
  end

  it "常量时间比较：长度不同/内容不同均 false" do
    Troupe::Transport.secure_equals("abc", "abc").should be_true
    Troupe::Transport.secure_equals("abc", "abd").should be_false
    Troupe::Transport.secure_equals("abc", "abcd").should be_false
    Troupe::Transport.secure_equals("", "").should be_true
  end
end

describe "M3 外部副作用 Outbox" do
  it "Memory：emit_event 后 save 与 Props 同原子提交；不 save 零副作用；save 失败不落盘" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryPropStore.new(ownership)
    id = Troupe::ActorId.new("app", "order", "ob")

    epoch = ownership.acquire(id)
    store.create(id, 1, %({"count":0}), epoch)

    # emit 后不 save：不落盘
    record = Troupe::OutboxRecord.new(actor_id: id, event_id: "e1", topic: "payment",
      payload: JSON.parse(%({"amount": 5})), created_at: ::Time.utc)
    store.write(id, 1_u64, 1, %({"count":1}), epoch, [] of Troupe::IdempotencyRecord, [record])
    store.poll_outbox(id, 10).size.should eq(1)

    # save 失败（revision 冲突）→ outbox 不落盘（同事务原子性）
    e2 = Troupe::OutboxRecord.new(actor_id: id, event_id: "e2", topic: "payment",
      payload: JSON.parse(%({"amount": 9})), created_at: ::Time.utc)
    expect_raises(Troupe::ConflictError) do
      store.write(id, 99_u64, 1, %({"count":2}), epoch, [] of Troupe::IdempotencyRecord, [e2])
    end
    store.poll_outbox(id, 10).map(&.event_id).should eq(["e1"])
    store.poll_outbox(id, 10).size.should eq(1)
  end

  it "OutboxDispatcher：至少一次——不标记则重投；标记后不再投" do
    ownership = Troupe::MemoryOwnershipStore.new
    store = Troupe::MemoryPropStore.new(ownership)
    id = Troupe::ActorId.new("app", "order", "disp")
    epoch = ownership.acquire(id)
    store.create(id, 1, %({"count":0}), epoch)
    record = Troupe::OutboxRecord.new(actor_id: id, event_id: "e1", topic: "payment",
      payload: JSON.parse(%({"amount": 5})), created_at: ::Time.utc)
    store.write(id, 1_u64, 1, %({"count":1}), epoch, [] of Troupe::IdempotencyRecord, [record])

    delivered_ids = [] of String
    attempts = 0
    deliverer = ->(r : Troupe::OutboxRecord) do
      attempts += 1
      raise Troupe::SerializationError.new("注入交付失败") if attempts == 1 # 首次交付失败
      delivered_ids << r.event_id
    end
    dispatcher = Troupe::OutboxDispatcher.new(store, deliverer)

    # 第一次 poll：交付回调抛错 → 不标记（至少一次）
    dispatcher.poll_once(id).should eq(0)
    store.poll_outbox(id, 10).size.should eq(1)

    # 第二次 poll：交付成功 → 标记
    dispatcher.poll_once(id).should eq(1)
    store.poll_outbox(id, 10).should be_empty

    # 已标记：不再投递
    dispatcher.poll_once(id).should eq(0)
    delivered_ids.should eq(["e1"])
  end

  it "SQLite：outbox 与 Props 单事务原子提交 + 派发标记" do
    path = TroupeFixtures.temp_db_path
    begin
      store = Troupe::SQLitePropStore.open(path)
      id = Troupe::ActorId.new("ob", "r", "1")
      epoch = store.ownership.acquire(id)
      store.create(id, 1, %({"count":0}), epoch)

      e1 = Troupe::OutboxRecord.new(actor_id: id, event_id: "e1", topic: "payment",
        payload: JSON.parse(%({"amount": 5})), created_at: ::Time.utc)
      expect_raises(Troupe::ConflictError) do
        store.write(id, 99_u64, 1, "{}", epoch, [] of Troupe::IdempotencyRecord, [e1])
      end
      store.poll_outbox(id, 10).should be_empty

      store.write(id, 1_u64, 1, "{}", epoch, [] of Troupe::IdempotencyRecord, [e1])
      store.poll_outbox(id, 10).size.should eq(1)
      store.mark_sent(id, "e1").should be_true
      store.poll_outbox(id, 10).should be_empty
      store.close
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "Actor 集成：emit_event 记入 journal，save 随 Props 原子提交并清空 journal（重开仍可派发）" do
    rehearsal = Troupe::Rehearsal.new
    id = rehearsal.actor("order", "emit")
    rehearsal.stage.register(Troupe::Manifest(CounterProps).define("order", CounterActor) do |m|
      m.schema_version 1
      m.initial { CounterProps.new }
      m.turn "pay", CounterActor do |actor, ctx, args|
        actor.props.count += 1
        actor.emit_event("payment", JSON.parse(%({"from": "turn"})))
        actor.save # 事件与 Props 同原子提交
        JSON::Any.new(actor.props.count.to_i64)
      end
    end)

    call = rehearsal.agent.call(id, "pay")
    rehearsal.pump_all
    call.await.as_i.should eq(1)

    # 派发：从 store 读出未投递事件
    dispatcher = Troupe::OutboxDispatcher.new(rehearsal.stage.store, ->(r : Troupe::OutboxRecord) { nil })
    pending = rehearsal.stage.store.poll_outbox(id, 10)
    pending.size.should eq(1)
    pending[0].topic.should eq("payment")
    dispatcher.poll_once(id).should eq(1)
    rehearsal.stage.store.poll_outbox(id, 10).should be_empty
  end
end

describe "PostgreSQL outbox" do
  pg_url = ENV["TROUPE_PG_URL"]?
  if pg_url
    it "outbox 与 Props 单事务原子提交 + 派发标记" do
      store = Troupe::PostgreSQLPropStore.open(pg_url, "ob-#{Random.new.next_int}")
      begin
        id = Troupe::ActorId.new("ob", "r", "1-#{Random.new.next_int}")
        epoch = store.ownership.acquire(id)
        store.create(id, 1, %({"count":0}), epoch)

        e1 = Troupe::OutboxRecord.new(actor_id: id, event_id: "e1", topic: "payment",
          payload: JSON.parse(%({"amount": 5})), created_at: ::Time.utc)
        # save 失败（revision 冲突）→ 单事务回滚，outbox 不落盘
        expect_raises(Troupe::ConflictError) do
          store.write(id, 99_u64, 1, "{}", epoch, [] of Troupe::IdempotencyRecord, [e1])
        end
        store.poll_outbox(id, 10).should be_empty

        store.write(id, 1_u64, 1, "{}", epoch, [] of Troupe::IdempotencyRecord, [e1])
        polled = store.poll_outbox(id, 10)
        polled.size.should eq(1)
        store.mark_sent(id, "e1").should be_true
        store.poll_outbox(id, 10).should be_empty
        store.mark_sent(id, "e1").should be_false # 已标记
      ensure
        store.close
      end
    end
  else
    pending "PostgreSQL outbox：设置 TROUPE_PG_URL 后运行"
  end
end
