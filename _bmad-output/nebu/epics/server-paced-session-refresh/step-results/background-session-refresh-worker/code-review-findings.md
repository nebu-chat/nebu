# Code Review — Cycle 1 — background-session-refresh-worker

Verdict: NOT CLEAN — 1 MAJOR (user decision required), 3 MINOR (fix cycle).

## MAJOR

**M1** — `server/lib/nebu/matrix/session/refresh_worker.ex`, `redeem/1` (~lines 301-315): the worker treats every `revalidate_with_idp/1` error (transient DB hiccup, confirmed `:deactivated`, IdP rejection, missing OIDC RT) identically — log + leave alone. But `revalidate_with_idp/1`'s original caller, `do_refresh_with/2` in `server/lib/nebu/matrix/http_public.ex` (~lines 584-606), treats confirmed rejection/deprovisioning specially: it immediately hard-deletes the session row via `Store.delete_for_user_device/2`. The worker silently drops that stronger guarantee for the identical signal.

**Decision:** Rely on the existing bounded-TTL fail-safe (AC5/AC6) as sufficient, per the story's own explicit Dev Note #6 ("Delete is the fast path, TTL is the fail-safe... Do NOT build retry/guarantee machinery around the delete path"). The story's design intentionally treats fail-closed-via-bounded-expiry as the correct behavior for the background worker, distinct from the interactive `POST /refresh` path where an immediate hard-delete is a nice-to-have UX optimization (faster next-request rejection) but not a security requirement — the ≤60s liveness check (AC7, untouched) already provides fast-path deactivation detection independent of any refresh mechanism. Making the background worker itself opportunistically hard-delete on confirmed rejection is a reasonable, low-risk hardening (tightens the window instead of just relying on TTL) and directly addresses the reviewer's concern about the asymmetry being silent/undocumented rather than a deliberate choice.

**Resolution:** dev-story to add: when `revalidate_with_idp/1` returns a confirmed-rejection signal (the same signal `do_refresh_with/2` treats as delete-worthy — e.g. `:deactivated` or equivalent explicit IdP rejection, NOT a transient/ambiguous error), the worker calls `Store.delete_for_user_device/2` (or equivalent) exactly as `do_refresh_with/2` does, then continues to the next row. Document this explicitly as a deliberate mirroring of the existing client-driven path, not a new invention. Ambiguous/transient errors continue to just log-and-leave-alone (bounded TTL fail-safe covers those).

## MINOR (hand to dev-story same cycle)

- **m1** — no `NEBU_*` env var wiring in `server/config/runtime.exs` for `matrix_refresh_worker_interval_ms` / `matrix_refresh_worker_lookahead_seconds`, unlike precedent `NEBU_MATRIX_SESSION_TTL_SECONDS`. Add for operational configurability consistency.
- **m2** — `refresh_now/1` in `refresh_worker.ex` (~lines 211-222) is unused/untested convenience code. Either add a test for it or remove it if not needed by any caller.
- **m3** — AC4 grace-period-safe selection relies on an unenforced invariant ("only one non-revoked row per device"), guaranteed only by `rotate_tokens/1` convention, not a DB constraint. Add a one-line comment acknowledging this.

## INFO (no action)
- Missing sub-binding gap inherited from `revalidate_with_idp/1` — consistent with existing accepted precedent.
- `defp`→`def` changes minimal, justified, ADR-020 compliant.
- `oidc_plug.ex` confirmed byte-for-byte untouched (AC7 satisfied).
- Cluster-safety reasoning sound (ADR-020).
- Logging hygiene good — no raw/decrypted token material logged.
- TOCTOU placement (AC3) and per-row error isolation (AC2) structurally correct.
- Style/naming mirrors `Sweeper` template well.
