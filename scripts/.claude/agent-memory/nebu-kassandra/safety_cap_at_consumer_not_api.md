---
name: safety-cap-at-consumer-not-api
description: Resource/collection caps that are the feature's core safety invariant get enforced only in the UI form, not in the public-API module that is the real trust boundary
metadata:
  type: feedback
---

When a feature's whole reason for existing is a bound (max entries, max duration, max
size, rate cap), check WHERE that bound is enforced — it repeatedly lands only in the UI
consumer, not at the public-API / persistence-boundary module.

**Why:** enhanced-logging/war-room-mode (SEC review 2026-07-06). The story exists to stop
`/sync`-scoped elevated logging from flooding the DB (AC7/AC8: "1000s of entries per
second"). The 10..10 000 / 10..3 600 caps on `max_entries`/`max_duration_s` lived ONLY in
`Nebu.Admin.LogsLive.parse_int_bounded/5` (the LiveView form). The explicit public-API
module `Nebu.Admin.WarRoomManager.start_session/1` validated only field *presence*
(`validate_required/1`/`blank?/1`), never numeric range — so any direct caller or a crafted
`phx-submit` could create an unbounded session, defeating the exact safety goal the story
ships. Rated MEDIUM (defense-in-depth; admin-only today, no data leak). Same root as the
Nebu-wide sanctum patterns "validate at the persistence boundary, not only at the consumer"
(Epic 14 lazy-validation) and "DB-module trust-boundary docstring" (Epic 11).

**How to apply:** for any bounded/quota/cap/rate feature, trace the cap from the form down
to the module that writes the row. If the cap is absent at the write boundary, flag it —
the module is the trust boundary, not the form. Zero/negative often fail safe; the
dangerous case is a large *finite* value that still satisfies the DB and defeats the
protection. Companion to [[generic_logger_persistence_sink]] (both are enhanced-logging).

Also confirmed CLEAN on this story and worth remembering as the *correct* shape: a
temporary-elevated-collection feature does NOT become a leak path when the collection
override touches ONLY the persist/retention decision and never re-derives content — the
redaction must sit upstream (inside the `Logger.debug` closure in `RequestLogger`), and the
war-room tagger reads only `route_template` + identifier metadata + writes back an id. Verify
the override cannot reach the message/content field. See [[redaction_wrapper_assumption]].

**Follow-up — the cap is dimensional; fixing the numbers doesn't cover a new collection
field (war-room-dedicated-page, SEC 2026-07-08, F-1 LOW):** the numeric F-1 fix landed
correctly — `WarRoomManager.start_session/1` now enforces `max_entries`/`max_duration_s`
range at the API boundary (`validate_bounds/1`). But the SAME story added a new
admin-supplied collection, `exclusive_scope` (a JSONB list of route strings), and validated
only its *element shape* (`valid_route_shape?/1` = `String.starts_with?("/")`) — NOT list
cardinality or element length. A crafted (non-UI, ~4-checkbox-bypassing) `start_war_room`
frame can store a huge list, then `WarRoom.check/1`'s `route in exclusive_scope` linear-scans
it per log event on the Oracle-gate hot path. So: when a bounded feature grows a NEW
free-shape collection field, re-ask the cap question for THAT field's cardinality + element
size, even if the original numeric caps are already correct at the boundary. Rated LOW here
(admin-only, self-scoped, session-bounded). Companion to [[liveview_unbounded_key_registry]]
(unbounded-collection-from-attacker-input) and [[redaction_wrapper_assumption]].
