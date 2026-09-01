# Security Review — 5b-live-updates-nav-badges

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Date:** 2026-07-18 · **Epic:** media-security-admin-control
**Story flag:** `security_review: optional` — run anyway by coordinator decision, consistent with this
epic's practice of running on optional UI stories that touch a genuinely new cross-cutting surface (same
precedent as 5a). This story introduces the first real broadcaster onto a `media:` PubSub topic since
2d/1c's design review assumed none existed.

## Verdict: APPROVED (0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 1 INFO)

## Scope

`server/lib/nebu/media/state_machine.ex` (new `"media:admin"` broadcast in `transition/4`),
`server/lib/nebu/admin/media_attention_badge.ex` (new), `server/lib/nebu/admin/media_live.ex`
(row-patch `handle_info/2`, `visible_media_ids`, `fetch_row_by_id/1`),
`server/lib/nebu/admin/{dashboard_live,audit_log_live,logs_live,logs_live/trace_map,logs_live/war_room}.ex`
(badge wiring), `server/lib/nebu/admin/layouts.ex` (badge render), plus the two new/extended test files.

## Re-verifying 2d's own assumption against this story's actual change

2d's SEC gate (2026-07-14) recorded as a POSITIVE: *"consumer-only neutralizes spoofing — NO lib code
broadcasts on any `media:` topic (only `operational_logs`), and even a FORGED broadcast can't serve wrong
bytes because `with_authorised_media` re-reads authoritative DB state after the wait (broadcast advances
only TIMING, never the decision)."* That premise ("no lib code broadcasts") is now stale — 4b's
`MediaScanWorker` already added a real broadcaster before this story, and this story adds a second, from
`Nebu.Media.StateMachine.transition/4` itself. Re-checked whether the underlying SAFETY property (broadcast
content is never trusted for a security-relevant decision) still holds under the new callers:

- **`Nebu.Media.DownloadStall` (2d's own consumer):** unaffected — this story does not touch the existing
  3-tuple broadcast on `"media:#{media_id}"` at all (confirmed: `media_scan_worker.ex`'s `broadcast/2`
  private function is unchanged; `state_machine.ex`'s new broadcast targets `"media:admin"` only, a
  distinct topic string). `download_stall.ex`'s `with_authorised_media`-style re-read-after-wait
  property (the actual thing 2d's positive rests on) is untouched by this diff.
- **`Nebu.Admin.MediaLive`'s new row-patch (`handle_info/2`):** does NOT trust the broadcast's own
  `new_state` value for what gets rendered — `fetch_row_by_id/1` re-reads the row fresh from
  `media_files` by `media_id` (a parameterized query) before patching the stream. Same "broadcast
  advances only WHEN a re-render happens, never WHAT gets shown" property 2d established. A broadcast for
  a `media_id` that isn't on the admin's current page/filter (i.e. not in `visible_media_ids`) is a
  pure no-op — no query, no leak.
- **`Nebu.Admin.MediaAttentionBadge.apply_transition/3` (the one place this story DOES trust the
  broadcast payload directly):** the 3-state attention count is adjusted by `classify(new) -
  classify(old)` computed straight from the broadcast tuple, with no DB re-read per event (by design —
  see the story's own Technical Requirements: one `COUNT` per mount, zero per broadcast). This is a
  genuinely new trust extension relative to 2d's pattern. Assessed reachability: the ONLY producer of a
  `"media:admin"` message is `Nebu.Media.StateMachine.transition/4`'s own guarded, DB-backed transaction
  (`allowed?/2` guard table + `SELECT ... FOR UPDATE` lock) — there is no HTTP-reachable path to inject an
  arbitrary tuple onto this topic; doing so would require code execution on the BEAM node itself, a
  materially different (and already fully compromising) threat model, out of scope for a diff-level
  review of admin-UI code. **Blast radius if it ever did happen: a transient badge miscount only** — no
  authz decision, no byte-serving decision, and no other row's data is affected. AC4's own design already
  treats this as an accepted, self-healing property: "a fresh page load/reconnect always re-derives the
  count from the DB... drift... is bounded to the remaining lifetime of that one LiveView process."
  Verdict: the extended trust is correctly scoped to a non-security-relevant value (a UI counter), not a
  new vulnerability.

## Information disclosure

- **Broadcast payload:** `{:media_state_transition, media_id, from_state, to_state}` carries only the
  opaque `media_id` (already known to/derivable by anyone with table access) and `media_state` ENUM atoms
  (already the exact value rendered in the table's own state-badge column). No `filename`,
  `uploader_user_id`, `scan_metadata`, or any other PII/content field is added to any broadcast payload in
  this diff. Confirmed by reading every `Phoenix.PubSub.broadcast/3` call site touched or added
  (`state_machine.ex`, unchanged `media_scan_worker.ex`).
- **Subscriber audience:** grepped every new `MediaAttentionBadge.subscribe()` call site — all 6 land
  inside the existing `live_session :admin` block (`on_mount: {Nebu.Admin.Auth, :require_admin}`), the
  same gate 5a's own review already verified. No non-admin process subscribes to `"media:admin"`; the
  data this topic carries reaches only sessions that already pass the admin-auth gate and already have
  unrestricted read access to `media_files` via the table itself. No new confidentiality boundary crossed.
- **Nav badge markup (`layouts.ex`):** the count is a plain integer interpolated via HEEx `{...}` (auto-
  escaped, though an integer has no escapable content anyway) — no `raw(`/`Phoenix.HTML.raw`/`{:safe,
  ...}` introduced. Grepped the diff for all three; zero matches.

## DB read-amplification / DoS check

- `fetch_row_by_id/1` (the only new per-broadcast DB read) fires ONLY when the broadcast's `media_id` is a
  member of `visible_media_ids` — bounded by (rows currently on THIS admin's page/filter, ≤ `@page_size`
  + however many "Weitere laden" clicks accumulated) per connected `MediaLive` session, not by system-wide
  event volume. An attacker cannot target this amplification without already controlling which specific
  `media_id`s are on a given admin's currently-open page — not an externally reachable lever.
  `MediaAttentionBadge.apply_transition/3` is pure in-process arithmetic (no I/O at all) for every other
  broadcast, so badge-side cost does not scale with connected-session count in any DB-relevant way.
- The broadcast itself piggybacks on `Nebu.Media.StateMachine.transition/4`, which ALREADY performs a
  `SELECT ... FOR UPDATE` + two `INSERT`/`UPDATE`s inside a transaction per call — the pre-existing write
  path already dominates the cost of triggering a transition; this story's one additional
  `Phoenix.PubSub.broadcast/3` (an in-memory, non-blocking operation, per Phoenix.PubSub's own design) is
  a negligible marginal addition, not a new amplification vector. Any upload/scan-rate throttling this
  system already has (out of scope here) bounds the achievable transition rate identically to before this
  story.

## INFO (non-blocking)

- **INFO-1:** This is the first story since 2d/1c's pre-implementation design review where a `media:`
  topic has a real, non-consumer-only broadcaster with a NEW trust extension (the badge's own delta
  arithmetic, see above). Recording this here — and in MEMORY.md — as the pattern-tracking baseline for
  whichever future story (6a/8a/13x) becomes the next caller of `transition/4`: any NEW caller
  automatically gets the "media:admin" broadcast for free (by design), so it inherits this same
  reasoning without needing its own broadcast-safety re-derivation — but if a FUTURE change ever makes the
  badge (or any other "media:admin" consumer) use the broadcast payload to make an authorization or
  content-serving decision instead of a UI-counter decision, that would cross into 2d's original "don't
  trust the broadcast for the decision" territory and should be re-reviewed at that time.

## Summary for pipeline log

APPROVED, 0 CRITICAL/HIGH/MEDIUM/LOW, 1 INFO (accepted, non-blocking, pattern recorded for future
`transition/4` callers). Confirms 2d's "broadcast is timing-only, never the decision" property still
holds for the row-patch and for `DownloadStall`'s untouched consumer; the one new trust extension (badge
count arithmetic trusting the broadcast payload directly) is scoped to a non-security-relevant UI counter
with an explicitly designed, self-healing bounded-drift property (AC4), not a vulnerability.
