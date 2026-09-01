## Oracle Gate — Story 2d (download-stall-mechanism)

**Endpoints (spec, v1.18):**
- `GET /_matrix/client/v1/media/download/{serverName}/{mediaId}` (+ `/{fileName}`) — auth required, added v1.11
- Deprecated: `GET /_matrix/media/v3/download/{serverName}/{mediaId}` (+ `/{fileName}`) — unauth, frozen post-v1.12
- All four variants carry the same wait-param semantics below

**⚠️ CRITICAL — param name mismatch:**
- Spec param is **`timeout_ms`** (integer, ms) — **not** `?timeout=N` as drafted in AC1/AC7
- Story 1c's own `oracle-context.md` (line 8) already recorded `timeout_ms` correctly; 2d regressed the name
- Impact: real clients (Element et al.) send `timeout_ms`; if the handler only recognizes `timeout`, AC1's "absent" fallback fires for **every real request** — the stall feature is silently dead on arrival
- **Action:** rename to `timeout_ms` before dev-story, or explicitly document `?timeout=` as an internal-only alias with `timeout_ms` as the real wire param

**MUST requirements (spec text, `#get_matrixclientv1mediadownloadservernamemediaid`):**
- `timeout_ms`: "maximum ms client is willing to wait ... in case content not yet uploaded"; **spec default = 20000ms when absent** (waits by default)
- Content repository SHOULD impose a maximum for this param — matches AC2's cap
- Content repository MAY respond before the timeout elapses — matches AC4's early-return-on-terminal-state
- 200 response: `Content-Disposition` (Required, inline/attachment) + `Content-Type` (Required, exact-or-reasonably-close) — unaffected by stall, must still hold
- 504 response: standard error body, `errcode: M_NOT_YET_UPLOADED` — spec's mandated pairing for "timeout elapsed, content still unavailable"

**Deviation to reconcile (accepted-deviation pattern, not a new bug):**
- AC1 defines "absent timeout_ms" as immediate no-wait (1c behavior) — this **inverts the spec default** (spec: absent → wait up to 20s). Deliberate Nebu choice; record as accepted deviation like the 451-vs-504 one below, so it isn't "fixed" back later
- AC4's timeout-elapsed fallback must emit **451** (ADR-026, accepted deviation from spec's 504+M_NOT_YET_UPLOADED, recorded 2026-07-13) — not spec's literal 504

**Error codes / status codes / edge cases to test-cover:**
- 200 + required `Content-Disposition`/`Content-Type` headers (success-after-wait path, identical to 1c's immediate-success shape)
- 451 `M_NOT_YET_UPLOADED` (Nebu overlay) — both immediate (1c, AC1/AC7) and post-wait-timeout (AC4 fallback) cases
- 451 `M_NOT_FOUND`-shaped body for `:admin_blocked`/deleted terminal states reached via broadcast (AC4 second bullet) — body must be byte-identical to genuine 404 per existing 1c contract
- `:reserved` state + `?timeout_ms` present → still immediate 1c deny (AC3) — no PubSub subscribe, verify no wait occurs
- Malformed `timeout_ms` (non-integer/negative/zero) → treated as absent, no 400 (AC7) — spec doesn't enumerate this case, so no MUST is violated; defensible
- Cap clamping: `N > max_stall_ms` silently clamped, not an error (AC2) — matches "content repo SHOULD impose a maximum," no client-visible error required
- 429 `M_LIMIT_EXCEEDED` + `retry_after_ms` — generic rate limiting, **orthogonal** to AC6's concurrency-guard; AC6's "degrade to no-stall, no error" is spec-safe since spec defines no behavior for stall-slot exhaustion specifically
- 502 `M_TOO_LARGE` — unrelated to timeout param, must not regress
- Lost-wakeup race: subscribe-before-recheck ordering (AC4) is not spec-observable directly but is required for correctness of the MUST-adjacent "MAY respond before timeout" guarantee — test via a broadcast-arrives-during-recheck-window scenario

**Non-spec-observable (implementation-only, flag for test-design not to force spec citations):**
- AC5 (no busy-polling / single receive-after) — pure implementation detail
- AC6 (concurrency ceiling mechanism) — Nebu-owned capacity policy, no spec correlate
- `media_files.state` transitions (`:quarantined`/`:scanning`/`:released`) — no spec correlate, same as 1c's finding
