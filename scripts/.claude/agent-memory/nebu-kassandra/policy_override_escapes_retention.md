---
name: policy-override-escapes-retention
description: A "persist regardless of the collection policy" override (war-room) produces rows the retention pruner never reaches, because the pruner keys on level while the safety-net TTL covers only warn/error — a cross-story gap invisible to any single per-story review
metadata:
  type: feedback
---

When one story adds a code path that PERSISTS records "regardless of the ambient
collection/retention policy" (an override for a legitimate reason), verify the RETENTION/
pruning side was extended to cover those override-created rows — it usually was not, because
the pruner and the override were written by different stories.

**Why:** enhanced-logging epic SEC GATE 2 (2026-07-06), Finding X1 (MEDIUM). war-room-mode's
`Handler.log/2` persists any war-room-tagged entry via
`should_persist?(level) or not is_nil(entry[:war_room_id])` — bypassing the collection
toggle (correct, AC4). But `Retention.prune_operational_logs/0` prunes ONLY by `level`:
per-level TTL/max-count for info/debug (which default to `nil` = no-op when collection is off,
the exact state a war room runs in) plus a hardcoded 90-day safety-net TTL that covers ONLY
`warning`/`error`. So war-room-tagged INFO/DEBUG rows (carrying user_id/device_id + redacted
payload) are persisted while collection is off and then pruned by NOTHING — indefinite
retention, GDPR storage-limitation gap, outside crypto-shred erasure scope. Volume is bounded
per session (max_entries/max_duration at the WarRoomManager boundary) so it is NOT a DoS — it
is a compliance/retention gap. No per-story review caught it: the retention safety-net
(admin-logs-retention-settings) predated the persist-override (war-room-mode), and war-room's
own review verified the write-boundary cap + redaction but not the retention reachability of
its new rows. Fix: add a level-INDEPENDENT war-room safety-net prune
(`DELETE ... WHERE war_room_id IS NOT NULL AND inserted_at < now() - '90 days'`), reusing the
same constant + the existing `operational_logs_war_room_id_idx`.

**How to apply:** (a) For any "persist/collect regardless of policy X" override, immediately
find the pruner/GC/TTL for that store and confirm it reaches the override-created rows — check
what dimension the pruner keys on (level? owner? type?) vs. what dimension distinguishes the
override rows (war_room_id). A safety-net TTL scoped to only SOME values of the pruner's key
(warn/error only) leaves the override rows in the uncovered values (info/debug). (b) The
dangerous default is `nil`/"no limit" on the very dimension the override lives in — a level
whose TTL is unset because collection was deliberately off. (c) This is the retention twin of
[[safety_cap_at_consumer_not_api]]: there the cap was missing at the write boundary; here the
bound is missing at the retention boundary for a policy-bypassing write. Both are
"the invariant was enforced in one place but the second story opened a path around it."
Related: [[generic_logger_persistence_sink]] (the always-collected-no-retention tier this
safety-net was built to close — the override reopened it for a different level).
