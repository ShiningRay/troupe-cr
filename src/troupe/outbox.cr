module Troupe
  # 外部副作用 Outbox（PLAN M3 指引，docs/outbox.md）：
  # - Actor 内 `emit_event(topic, payload)` 把事件记入 journal，`save` 时与 Props
  #   **同一原子提交**落盘（任一失败整体不生效）——杜绝"先副作用后崩溃"；
  # - `OutboxDispatcher` 轮询未投递记录 → 交付回调（外部副作用在此发生）→ 标记已投递；
  #   不标记则重复 poll → **至少一次**，外部接收方必须幂等（或带 epoch 校验）。
  # Outbox 的存取并入 `PropStore` 契约（write 参数 + poll_outbox/mark_sent），
  # 保证与 Props CAS 同事务/同锁提交——这是"同原子提交"的结构性保障。
  record OutboxRecord,
    actor_id : ::Troupe::ActorId,
    event_id : String,
    topic : String,
    payload : ::JSON::Any,
    created_at : ::Time

  # 交付调度器：poll → 交付回调 → 标记已投递。
  # 交付回调抛错不标记 → 下轮重投（至少一次）。
  class OutboxDispatcher
    @store : ::Troupe::PropStore
    @deliver : Proc(::Troupe::OutboxRecord, Nil)
    @batch : Int32

    def initialize(@store, @deliver : Proc(::Troupe::OutboxRecord, Nil), @batch : Int32 = 64)
    end

    # 单次轮询；返回本轮成功标记的条数。交付回调抛错时该条跳过（下轮重投）。
    def poll_once(actor_id : ::Troupe::ActorId) : Int32
      marked = 0
      @store.poll_outbox(actor_id, @batch).each do |record|
        begin
          @deliver.call(record)
        rescue
          next # 交付失败：不标记，下轮重投（至少一次）
        end
        marked += 1 if @store.mark_sent(actor_id, record.event_id)
      end
      marked
    end
  end
end
