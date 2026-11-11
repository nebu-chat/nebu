---
id: media-download-451-scan-race
epic: bugfix
status: done
security_review: required
ui: false
matrix: true
baseline_commit: 533fbd5439e7663d3be1298a462ce40efdfd3c69
---

# Bug: Media download/thumbnail returns 451 right after upload (race with async ClamAV scan)

## Problem

A client (Element Web) uploads a file and immediately requests
`GET /_matrix/client/v1/media/download/...` and `.../thumbnail/...`. The upload leaves the file
in `:quarantined`, and the async `Nebu.Workers.MediaScanWorker` moves it to `:released` ~100–150 ms
later. The client's requests arrive ~40 ms after the upload, hit the download gate
(`Nebu.Media.download_gate/1`, ADR-026 / story 1c) while the state is still `:quarantined`/`:scanning`,
and get `451 M_NOT_YET_UPLOADED`. Element does not retry, so the image is never displayed even though
the file is `:released` a moment later.

Evidence (UpCloud prod, 2026-10-13, media_id `g09CUGRtFvVEepwDPji6Iw`):

| time         | event                                                   |
|--------------|---------------------------------------------------------|
| 07:24:54.454 | `POST /_matrix/media/v3/upload` → 200                   |
| 07:24:54.464 | `MediaScanWorker ... scan started`                      |
| 07:24:54.492 | `GET .../thumbnail/...` → 451                           |
| 07:24:54.532 | `GET .../download/...` → 451                            |
| 07:24:54.641 | `MediaScanWorker ... scan result: released`             |

## Root cause

Story 2d added a download stall (`Nebu.Media.DownloadStall`): the request is held open via
`Phoenix.PubSub` until the file leaves `:quarantined`/`:scanning` or a timeout elapses. The producer
already exists — `MediaScanWorker.broadcast/2` sends `{:media_state_transition, media_id, new_state}`
on `"media:<media_id>"` for `:released`, `:infected` and `:scan_failed`. But:

1. The stall is **opt-in via `?timeout_ms=N`** (`Nebu.Media.clamped_stall_ms/1`: absent → 0 → no stall).
   Element does not send `timeout_ms`.
2. Only `Nebu.Media.download/4` calls `maybe_await_stall/3`; `Nebu.Media.thumbnail/3` never stalls,
   even when `timeout_ms` is given.

## Story

**As a** Matrix client user,
**I want** media I just uploaded to display immediately,
**so that** the normal upload → display flow works without the client knowing about Nebu's scan pipeline.

## Acceptance Criteria

1. **AC1 — Default stall on download.** `GET .../download/...` for media in `:quarantined` or
   `:scanning` with NO `timeout_ms` query param holds the request open (PubSub-driven, via the existing
   `DownloadStall`, no polling) for the Matrix-spec default of 20_000 ms (CS API v1.18: "the default value is 20000";
   config key `default_stall_ms`, default 20_000, always clamped by `max_stall_ms`), then applies the existing ADR-026 mapping to the re-read state. A scan finishing
   within the window (`:released`) results in `200` with the bytes.
2. **AC2 — Stall on thumbnail.** `GET .../thumbnail/...` behaves exactly like AC1 (default stall, and
   an explicit `timeout_ms` is honoured). Both the `/_matrix/media/v3/*` and the
   `/_matrix/client/v1/media/*` routes go through the same code path.
3. **AC3 — Explicit `timeout_ms` wins.** A valid `?timeout_ms=N` keeps today's semantics
   (clamped to `max_stall_ms`). `timeout_ms=0` ⇒ no stall (client is willing to wait 0 ms).
   Absent param ⇒ default stall (AC1). Malformed/negative value: keep today's behaviour
   (treated as no-stall) — spec defines nothing; document the resolved rule in `clamped_stall_ms/1`
   and test it.
4. **AC4 — Timeout / terminal states unchanged.** If the file is still `:quarantined`/`:scanning`
   after the window, the response is the same 451 `M_NOT_YET_UPLOADED` as today. `:infected`,
   `:admin_blocked`, `:deleted`, `:hard_deleted`, `:scan_failed` keep their existing mapping and stay
   byte-identical to an unknown-media 404 where ADR-026 requires it. Non-stallable states
   (`:released`, deny states, unknown id) must NOT incur any wait or extra DB lookup beyond today's.
5. **AC5 — Concurrency ceiling.** The existing `max_concurrent_stalls` ceiling applies to default
   stalls; when exceeded the request degrades to the immediate 451 (`:no_slot`), never errors.
6. **AC6 — Access control first.** The stall must not become an oracle or bypass: an unauthenticated
   or non-member request is rejected exactly as before and never enters the stall.
7. **AC7 — Regression test.** A failing-first test reproduces the race: media in `:quarantined`,
   request without `timeout_ms`, state flips to `:released` + broadcast mid-wait → `200`.
   Same for thumbnail. Plus a test that a never-released file returns 451 after the window.

## Out of scope

- Changing 451 to `504 M_NOT_YET_UPLOADED` (spec alignment) — needs an ADR-026 decision.
- Changing the scan pipeline or the broadcast contract (producer already correct).

## Dev Notes

- Files: `server/lib/nebu/media.ex` (`download/4`, `thumbnail/3`, `clamped_stall_ms/1`,
  `maybe_await_stall/3`), `server/lib/nebu/media/download_stall.ex`, `server/config/config.exs`
  (`max_stall_ms` block, add `default_stall_ms`), `server/lib/nebu/media/config.ex` (if media
  settings are DB-backed — keep the new key consistent with `max_stall_ms`).
- Cluster-safety: PubSub is cluster-wide; the scan worker may run on another node than the request.
  No node-local state beyond the existing `:atomics` counter.
- SQL stays inline (ADR-018); no new layers.
- Beware of Cowboy/Bandit request timeouts and the LB/nginx `proxy_read_timeout` (90 s) — default
  (20 s) stays well below them.
- Oracle (spec v1.18): `timeout_ms` default 20000 on all six media endpoints; server SHOULD cap it and
  MAY answer early; after the wait the spec code is `504 M_NOT_YET_UPLOADED` — Nebu's 451 is a known
  deviation (out of scope, ADR-026). Assert `errcode == M_NOT_YET_UPLOADED` rather than the status in
  new timeout tests where possible, so a later 504 switch is a one-line change. Add a pending/tagged
  test or comment that tracks the 451-vs-504 follow-up.
- Required test cases (Oracle): absent param released mid-window → 200 (download+thumbnail, v1+v3
  routes); never released → error after window; `timeout_ms=0` immediate; `timeout_ms` > max clamped
  (response no later than max); malformed value; already released → no added wait; unknown id → 404
  no wait; unauthenticated v1 → 401 before any stall.

## Dev Agent Record

### Implementation Plan
- `Nebu.Media.default_stall_ms/0` + `config :nebu, Nebu.Media, default_stall_ms: 20_000` (app-env only, like `max_stall_ms`; always clamped, <= 0 = kill switch for the absent case).
- `clamped_stall_ms/1`: absent -> default; `N>0` -> clamped; `0`/malformed/negative/array -> 0 (no stall).
- `with_authorised_media/5` takes the stall window; `download/4` and `thumbnail/3` both pass it. The single initial row read (`lookup_maybe_stalled/4`) decides: only `:quarantined`/`:scanning` AND room member enter `DownloadStall.await/4` (subscribe-then-recheck), then one re-read feeds the unchanged 1c gate + membership + fetch path. Non-stallable states/unknown ids: exactly one lookup, no wait.
- AC6: membership is checked before stalling; a non-member gets the same immediate 1c answer as `timeout_ms=0`.

### Completion Notes
- Full `mix test --warnings-as-errors`: 2411 passed, 3 skipped. Stall test file: 60 passed, 1 skipped (451-vs-504 tracker).
- Test-review findings 1-8 applied in `media_download_stall_test.exs`.

### Review Cycle 2 (Kassandra security review: CLEAN, F-1 + F-4 guard fixed)
- **F-1 (MEDIUM, fixed):** stall slot leaked on HTTP/2 client disconnect (Bandit kills the request process with an exit signal; `try/after` never runs). `Nebu.Media.DownloadStall` now ties each slot to the requester's lifetime: a per-slot unlinked keeper process monitors the requester and performs the ceiling-checked increment itself (no gap between slot and monitor). Release is exactly-once via a per-slot `:atomics` compare-exchange (1 -> 0): the requester releases synchronously in `after` (normal/timeout/raise), the keeper releases on `:DOWN`; the loser is a no-op, so the counter is never decremented twice or negative. Public API (`await/4`, `init_counter/0`) unchanged; no supervisor change needed. Added `active_stalls/0` (`@doc false`, diagnostics/tests).
- **F-4 (in scope, fixed):** `clamp_stall_ms/1` requires an integer `max_stall_ms` (non-integer cap => 0 = no stall).
- **Tests:** `server/test/nebu/media/download_stall_slots_test.exs` (kill mid-stall frees slot with ceiling 1, `{:shutdown, :peer_closed}`, exactly-once on normal/timeout/raise/no_slot paths, counter never negative); in `media_download_stall_test.exs`: HTTP-level request process killed mid-stall frees the slot and a follow-up request stalls again; string `max_stall_ms` => no stall/no crash.
- **Follow-ups (not in this bugfix, also in `docs/architecture/10-quality.md` M-1):** F-2 per-user/per-IP stall sub-cap and per-IP `RateLimit` on download/thumbnail (not ~1 line with this design; left open); F-3 thundering herd on release (jitter / single-flight per media id); F-4 remainder: `default_stall_ms`/`max_stall_ms` are compile-time config only and the admin-UI `max_stall_ms` (1 ms-1 h) is not read by the handler.

- Cycle 2 verification: `test/nebu/media/` 551 passed, 1 skipped; full `mix test --warnings-as-errors` 2423/2424 passed, 3 skipped - the single failure differs per run and is in `Nebu.Workers.*` tests (MediaScanWorker/MediaOrphanDetection/MediaReleasedAutoDelete), flaky also when `test/nebu/workers` runs alone (pre-existing, unrelated to DownloadStall).

- Cycle 3 (MINOR hardening): M-1 `acquire_slot/1` `:DOWN` branch now calls idempotent `release_claim/2` (a keeper killed after `claim=1` / between `add_get` and `sub` no longer leaks the counter; comment corrected; not deterministically testable without a prod test seam - documented in the slots test). M-2 non-integer/non-positive `max_concurrent_stalls` fails closed (`:no_slot`); tests for "500"/nil/0/negative/float assert no stall and no counter leak.

### File List
- server/test/nebu/media/download_stall_slots_test.exs
- server/lib/nebu/media.ex
- server/lib/nebu/media/download_stall.ex
- server/config/config.exs
- server/test/nebu/media/media_download_stall_test.exs
- server/test/nebu/media/media_download_gate_test.exs
- server/test/nebu/media/media_response_content_type_test.exs

### Change Log
- 2026-10-13: default stall on download + thumbnail, access-control-first stall entry.
