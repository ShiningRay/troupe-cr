require "json"
require "./troupe/version"
require "./troupe/errors"
require "./troupe/actor_id"
require "./troupe/clock"
require "./troupe/events"
require "./troupe/metrics"
require "./troupe/trace"
require "./troupe/json_value"
require "./troupe/idempotency"
require "./troupe/props"
require "./troupe/sqlite_prop_store"
require "./troupe/postgresql_prop_store"
require "./troupe/actor"
require "./troupe/manifest"
require "./troupe/call"
require "./troupe/call_board"
require "./troupe/actor_slot"
require "./troupe/stage"
require "./troupe/agent"
require "./troupe/typed_agent"
require "./troupe/transport/framing"
require "./troupe/transport/tcp"
require "./troupe/reminders"
require "./troupe/reminder_runner"
require "./troupe/reminders_pg"
require "./troupe/hash_ring"
require "./troupe/roster"
require "./troupe/outbox"
require "./troupe/show"
require "./troupe/director"
require "./troupe/stream"
require "./troupe/stream_pg"
require "./troupe/directory"
require "./troupe/rehearsal"

# Troupe.cr：Crystal idiomatic virtual actor 框架（对标 Orleans 语义，见 DESIGN.md）。
#
# 当前状态（PLAN M1）：最小单机核心已实现——
# ActorId / Role manifest / 错误分类 / PropStore(CAS+fencing) / Stage / Agent /
# ActorSlot(single-flight) / 有界 CallBoard / Intermission / Rehearsal。
# 尚未实现：SQLite/PostgreSQL Provider、TCP transport、集群路由、持久 reminder、Show。
module Troupe
end
