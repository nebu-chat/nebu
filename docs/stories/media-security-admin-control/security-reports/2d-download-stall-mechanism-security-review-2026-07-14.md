# Security Review — `2d-download-stall-mechanism`

- **Epic:** media-security-admin-control
- **Reviewer:** Kassandra (adversarial security review)
- **Date:** 2026-07-14
- **Story security_review flag:** optional (run at coordinator's discretion — new concurrency/timing surface)
- **Scope:** staged diff — `server/lib/nebu/media/download_stall.ex` (NEW), `server/lib/nebu/media.ex`, `server/lib/nebu/application.ex`, `server/config/config.exs`, `server/test/nebu/media/media_download_stall_test.exs` (NEW), `server/test/test_helper.exs`

## VERDICT

**0 CRITICAL — 0 HIGH.** Nothing in this diff blocks the pipeline.

Findings: **1 MEDIUM, 3 LOW, several INFO/positive.** The MEDIUM (no per-IP
rate limit on a now-connection-holding endpoint + single-IP monopolization of
the global stall pool) is the live instance of my own pre-implementation
design-MEDIUM ("stall-mechanism has no concurrency cap on held downloads —
slowloris-shaped"). The concurrency **cap** was added (good — closes the
node/process-exhaustion vector); the **per-IP fairness / rate-limit dimension**
remains open. Because the design degrades gracefully to the pre-2d immediate-451
response when the ceiling is hit, blast radius is bounded and it stays below
HIGH. Recommend fixing M-1 within the epic; L-1 links to the still-open 1c F-1
and should be resolved before Story 6a (admin-block trigger) ships.

---

## What the story does (verified against code, not the summary)

`Nebu.Media.download/4` (media.ex:525) now, before the unchanged 1c
`with_authorised_media` path, calls `maybe_await_stall/3`. On an opt-in
`?timeout_ms=N` (>0, clamped to `max_stall_ms`, default 20 000 ms) against media
currently in `:quarantined`/`:scanning`, it blocks on a `Phoenix.PubSub`-driven
wait (`DownloadStall.await/4`) until a terminal `{:media_state_transition,
media_id, new_state}` broadcast arrives or the clamped window elapses, then falls
through to the **exact same** 1c `with_authorised_media → download_gate →
gate_message` path, which re-reads the row and re-applies the ADR-026 mapping.
The wait is a single `receive/after` inside a `Task`, bounded by a crash-safe
global `:atomics` concurrency ceiling (`max_concurrent_stalls`, default 500) that
degrades to `:no_slot` → immediate 1c response when exceeded.

---

## Findings

### M-1 (MEDIUM) — `download` route has no per-IP rate limit; the stall turns it into a connection-holding endpoint that a single IP can monopolize globally

**Location:** `server/lib/nebu/web/router/media.ex:77-83` (download routes),
`server/lib/nebu/media.ex:534,591-608` (`maybe_await_stall`),
`server/lib/nebu/media/download_stall.ex:78-92` (`await`/`acquire_slot`).

**Mechanism.** The router applies per-IP `Nebu.Web.Plugs.RateLimit` inline to
`upload` (600/min) and `preview_url` (30/min) precisely because they are
"expensive per request" (its own moduledoc, lines 16-32). **`download` has no
rate limit.** Before 2d that was fine — download returned promptly. 2d makes a
download request hold the HTTP connection (plus a request process + a linked
`Task` + a PubSub subscription) open for up to `max_stall_ms` (20 s). The only
governor is the **global** `:atomics` ceiling of 500; there is **no per-user or
per-IP sub-cap**. An authenticated user (the endpoint sits behind `OidcPlug`, so
this is authenticated — not anonymous) can therefore hold and refresh 500
concurrent 20-s stalls from a single IP, monopolizing the entire stall pool.

Two aggravating factors specific to the current codebase state:

- **No producer exists yet (Story 4b not landed).** Nothing broadcasts on any
  `media:` topic today (verified: the only `Phoenix.PubSub.broadcast` calls in
  `lib/` are on `"operational_logs"`). Uploaded media reach `:quarantined` and,
  with no scan worker, **never leave it** — so every stall on a quarantined file
  rides out the **full** clamped window and never self-resolves early. Slot
  monopolization is therefore trivial and durable, not just a brief spike.
- **2× DB-lookup amplification, unthrottled.** Any `?timeout_ms>0` request runs
  an *extra* `current_state/2` lookup (media.ex:594) in addition to
  `with_authorised_media`'s own lookup — even for non-stallable states and even
  when the ceiling is full (the extra lookup happens *before* `acquire_slot`).
  With no rate limit on download, this doubles download-path DB reads on demand.

**Why not HIGH.** The ceiling bounds concurrent held stalls to 500 globally, so
there is **no node/process/connection exhaustion beyond that fixed bound**, and
legitimate users denied a slot get the immediate `451 M_NOT_YET_UPLOADED` — i.e.
exactly the pre-2d behavior (retryable). The attack denies an *optimization* and
consumes a *bounded* resource pool; it does not take the endpoint or node down.
That graceful degradation (AC6) is real and correctly implemented.

**Why still MEDIUM.** It is attacker-triggerable with trivial cost, it
contradicts the router's own established "expensive endpoints get a per-IP
limit" invariant, and (per the two factors above) it is easy and durable to
sustain today. The remediation is cheap and consistent with existing code.

**Remediation.**
1. Add a per-IP `RateLimit` tier to the download route (mirror the
   `upload`/`preview_url` inline pattern; the download tier can be generous —
   its purpose is only to cap the stall-abuse rate, not normal media fetching).
2. And/or add a per-user (or per-IP) sub-ceiling on stall slots so no single
   principal can consume the whole global pool (e.g. a second small `:atomics`
   keyed by a bucket of `current_user`, or reuse the RateLimit bucket to gate
   *entry into the stall branch* specifically).
3. Consider skipping the extra `current_state/2` lookup by having
   `with_authorised_media` surface the state it already reads (removes the 2×
   amplification), though that is a refactor, not required for the fix.

---

### L-1 (LOW) — real-time transition/outcome oracle compounds the still-open 1c F-1 (admin_blocked fingerprint) and 1c F-3 (gate-before-membership)

**Location:** `server/lib/nebu/media.ex:591-608` (stall runs *before*
`with_authorised_media`'s membership check), interacting with `download_gate/1`
(media.ex:725-739).

**Mechanism.** The stall decision (`maybe_await_stall`) runs **before** the
room-membership check — correctly preserving 1c's gate-before-membership
ordering, but that means an authenticated **non-member** can stall on a
`media_id` for a room they are not in. When the scan completes, the request
resolves fast and the resolved **status** distinguishes the outcome:
`:released` → 403 (non-member), `:infected` → 404, `:admin_blocked` → 451
(test AT4 asserts exactly this). So a non-member can observe, event-driven and
in near-real-time, *when* a scan completes and *what* the outcome was — including
the timing of a moderation action that ADR-026's anonymity property intends to
hide.

**Why only LOW / not an independent finding.** This channel is the **status
code**, which a non-member could already obtain by polling the 1c endpoint (the
gate runs before membership — this is the accepted 1c F-3 LOW trade-off), and the
`admin_blocked → (451, M_NOT_FOUND)` unique fingerprint is the **already-recorded
1c F-1 MEDIUM** (pattern: "anonymity by identical BODY but distinguishable STATUS
is not anonymity"). 2d adds **no new information channel** — it converts a
poll-based oracle into an event-driven, lower-noise one. No bytes are served to
the non-member (`:released` still → 403 after the membership check).

**Remediation.** Same as 1c F-1: map `:admin_blocked → 404` (true
indistinguishability + matches ADR-026's prose), or formally accept 451 with
Phil's sign-off and correct the ADR/AC prose. **2d adds urgency: resolve 1c F-1
before Story 6a wires the admin-block trigger**, because 6a + this real-time
oracle together make the moderation-timing leak live and observable.

---

### L-2 (LOW / hardening) — slot accounting via `try/after` in the request process is not robust to asynchronous process termination

**Location:** `server/lib/nebu/media/download_stall.ex:81-92` (`await` — the
`try … after release_slot() end`).

**Mechanism.** The slot is incremented in `acquire_slot/1` and released in an
`after` block, both running in the **request process** (the call chain
`download → maybe_await_stall → DownloadStall.await` is synchronous, not
spawned). `try/after` runs the `after` block on normal return, inline `exit/1`,
raise, and throw — **but not** when the process is terminated by an
**asynchronous** exit signal (`Process.exit(pid, reason)` to a non-trapping
process). Such a path would leak the increment permanently in the global
`:atomics` counter — **unrecoverable without a VM restart**. Enough leaks wedge
the ceiling permanently closed → the stall feature becomes permanently
unavailable (a soft DoS). The counter is `signed`, so it can only drift *up*
(toward wedged-closed), never negative.

**Reachability assessment (independent).** I traced this rather than trusting
the prior code review:
- **Client disconnect:** Bandit/ThousandIsland handle the request synchronously
  in the connection process. While blocked in `Task.await` (i.e. in `receive`),
  the handler is not doing socket I/O and does not observe the disconnect; there
  is no default "max handler runtime" that async-kills a mid-request handler. The
  disconnect surfaces only when the handler finishes and writes the response —
  *after* the stall completed and the slot was already released. So the `after`
  runs. **No leak on client disconnect.**
- **Inner Task crash propagating a link exit:** the linked `Task` body
  (`subscribe` + `recheck_fun` + total `receive`) cannot realistically crash on
  adversarial input — a dead DB makes `DB.lookup` return `{:error,:not_found}` →
  `nil` → not stallable → `:resolved` (no raise). Subscribe only raises if
  `Nebu.PubSub` is down (whole-app failure).

**Conclusion:** no user-reachable async-kill path today (matches the prior
code-review verdict). Recorded as **LOW/hardening**, not a live finding.

**Remediation (optional hardening).** Make accounting robust to the entire
class: have a small supervised counting process (or a `Registry`) **monitor** the
stall task PID and decrement on `:DOWN`, rather than relying on `try/after` in a
process that could in principle be async-killed. This also naturally caps by
liveness rather than by a manual increment/decrement pair.

---

### L-3 (LOW) — `Task.await` +50 ms buffer is measured from Task start, not from the inner deadline → spurious 500 under DB latency

**Location:** `server/lib/nebu/media/download_stall.ex:94-113` (`run_wait` —
`Task.await(task, clamped_timeout_ms + 50)`).

**Mechanism.** The inner task subscribes and does one `recheck_fun` DB lookup
**before** computing `deadline = now + clamped_timeout_ms`. So the task's total
runtime is `ε(subscribe + recheck) + clamped_timeout_ms`, while `Task.await`'s
budget is `clamped_timeout_ms + 50`. If `ε > 50 ms` (slow query / pool
contention under load), `Task.await` fires first and **exits the request process
with `{:timeout, ...}` → a 500 to the client**, instead of the intended graceful
1c fallback. The `after release_slot()` still runs (inline exit), so no slot
leaks — but the request fails. An attacker able to induce DB latency could turn
stall requests into 500s. Availability/robustness only; no data exposure, no auth
bypass.

**Remediation.** Let the inner `receive`'s own `after remaining -> :timeout` be
the sole timeout authority: use `Task.await(task, :infinity)` (the inner block is
already deadline-bounded and always returns), or pass an **absolute** deadline
into the task and give `Task.await` a generous fixed buffer (e.g. +1000 ms)
rather than +50 ms.

---

## INFO / Positives (verified, no action required)

- **Consumer-only design neutralizes broadcast spoofing (concern #4).** No
  user-reachable code path broadcasts on any `media:` topic today (grep-verified:
  only the log store broadcasts, on `"operational_logs"`). More importantly, even
  a *forged* `{:media_state_transition, …}` broadcast **cannot cause wrong/stale
  bytes to be served**: `await/4`'s return is advisory, and
  `with_authorised_media` **re-reads the authoritative DB row and re-applies the
  1c gate** after the wait. A spoofed broadcast can only advance *timing*, never
  the *decision*. This is a strong, correct design property.
- **Auth posture correct.** The download route sits behind `OidcPlug`
  (router/media.ex:51); the stall runs post-auth. Not an anonymous surface.
- **`current_state/2` is total.** `Nebu.Media.DB.lookup/2` returns exactly
  `{:ok, row} | {:error, :not_found}` (db.ex:69-77, catch-all `_`), so the two
  clauses in `current_state/2` are exhaustive — no `CaseClauseError`/500 risk.
- **Boot init closes the double-init race.** `init_counter/0` is eager, nil-
  guarded, invoked once sequentially before the supervisor tree
  (application.ex), mirroring `:nebu_signing_key`. `counter_ref/0` is a pure
  `:persistent_term.get/1`. `test_helper.exs` init is idempotent with it.
- **Input validation total and fail-safe.** `clamped_stall_ms/1` handles
  `nil` / binary / catch-all (list/map shapes from `?timeout_ms[]=`); any
  non-parse, negative, or zero collapses to `0` = no stall; the negative-config
  clamp (`min(n, max(0, max_stall_ms()))`) and the `<= 0` guard in
  `maybe_await_stall/3` cover a misconfigured negative `max_stall_ms`. Tests
  AT6, the negative-cap test, and the list-shape test pin all of these.
- **No atom-exhaustion / topic injection.** `media_id` (URL segment) is used only
  as an opaque PubSub topic string and as a *parameterized* DB argument; state
  atoms come from `parse_state` (`to_existing_atom`, per 1c). A crafted `media_id`
  cannot forge a broadcast or collide meaningfully — subscribing to another
  media's topic only yields the same real-time state signal already covered by
  L-1.
- **Test coverage is strong:** released/infected/admin_blocked mid-wait, timeout
  fallback, clamp, `:reserved` never stalled, ceiling degrade, negative-cap
  no-crash, list-shape no-crash, and full no-param/malformed regression against
  the 1c deny table.

---

## Cross-references (my MEMORY.md)

- Pre-impl design-MEDIUM: *"stall-mechanism has no concurrency cap on held
  downloads — slowloris-shaped"* (media-security-clamav design consultation,
  2026-07-01) → **M-1** is its live instance; cap added, per-IP dimension open.
- 1c F-1 MEDIUM (anonymity-by-body-not-status) + 1c F-3 LOW (gate-before-
  membership state leak), 2026-07-13 → **L-1** compounds both; same fix.
- Default-deny gate (pattern) → verified intact: `download_gate/1` is
  allowlist-of-success (`:released` sole positive), and `@stallable` is likewise
  a closed allowlist (`[:quarantined, :scanning]`).
