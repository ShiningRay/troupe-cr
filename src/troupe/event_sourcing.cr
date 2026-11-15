module Troupe
  # 事件溯源扩展点（PLAN M6"持久 Outbox、事件溯源与扩展点"）。
  #
  # 模式：Actor 状态的真相源是**事件流**（StreamStore 追加写）而非整份 Props——
  # Turn 产生事件（append）→ 状态由事件重放重建（rebuild）。与 M2 Outbox 组合：
  # Outbox 负责"事件→外部副作用"，事件溯源负责"事件→状态"，两者互不替代。
  #
  # 这是**扩展点**（示例模式与最小 helper），不是框架强制的存储路径：
  # - `rebuild(initial, events, &apply)`：顺序折叠事件重建状态；
  # - `rebuild_from_snapshot(snapshot, events, &apply)`：快照加速——快照之后的
  #   增量事件重放，结果必须与全量重放一致（一致性反例覆盖）。
  #
  # 并发边界：事件溯源 actor 的 Turn 仍走 strict 串行——事件 append 顺序即
  # Turn 顺序（并发 read_only 不产生事件，improv 不适用此模式）。
  module EventSourcing
    # 全量重放：初始状态 + 顺序应用全部事件。
    def self.rebuild(initial : P, events : Array(::Troupe::StreamEvent),
                     &apply : P, ::Troupe::StreamEvent -> P) : P forall P
      events.reduce(initial) { |state, event| apply.call(state, event) }
    end

    # 快照加速：从 snapshot_state（对应 snapshot_seq 之后的事件）继续重放。
    # 语义契约：rebuild_from_snapshot(snapshot, snapshot_seq 之后的事件) ==
    # rebuild(initial, 全部事件)——不一致即快照/增量错位（调用方 bug，测试反例覆盖）。
    def self.rebuild_from_snapshot(snapshot_state : P, events : Array(::Troupe::StreamEvent),
                                   &apply : P, ::Troupe::StreamEvent -> P) : P forall P
      events.reduce(snapshot_state) { |state, event| apply.call(state, event) }
    end

    # 事件追加便捷：把领域事件编码进持久流（payload = {type, data}）。
    def self.append_event(store : ::Troupe::StreamStore, topic : String,
                          type : String, data : ::JSON::Any) : ::UInt64
      store.append(topic, ::JSON::Any.new({
        "type" => ::JSON::Any.new(type),
        "data" => data,
      } of ::String => ::JSON::Any))
    end
  end
end
