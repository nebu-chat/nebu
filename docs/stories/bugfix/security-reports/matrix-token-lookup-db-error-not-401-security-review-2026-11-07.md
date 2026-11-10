## Security Review — matrix-token-lookup-db-error-not-401

**Diff scope:** `server/lib/nebu/matrix/session/matrix_session_store.ex`: `get_by_access_token_hash/1` now tells "no row" (`:error`) apart from "lookup failed" (`{:error, :unavailable}`). It adds `lookup_query/2`, which rescues exceptions and catches exits; `lookup_fault/1`, a test-only fault seam; and `lookup_unavailable/1`, a throttled WARNING that names only the error class. `server/lib/nebu/web/plugs/oidc_plug.ex`: new `{:error, :unavailable}` branch in `call_opaque/2`, which calls `deny_unavailable/1` (503 `M_UNKNOWN`, `Retry-After: 5`). `server/lib/nebu/matrix/session/refresh_worker.ex`: skips the row on `{:error, :unavailable}`. Also reviewed: the unit test `oidc_plug_lookup_failure_test.exs` and the story file.
**Date:** 2026-11-07

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM (pre-existing, not in diff) | `server/lib/nebu/web/plugs/oidc_plug.ex` `call_jwt/2`, `provision/2`; `server/lib/nebu/web/token_denylist.ex:291`; `server/lib/nebu/matrix/session/device_binding.ex:140` | The JWT path fails open on DB errors. A DB error turns three denial checks into "allow": the denylist, the OAuth-device refusal and the deactivation check. | Give each of the three checks an `{:error, :unavailable}` result and answer the same 503 as the opaque path (follow-up story). |
| 2 | LOW | `matrix_session_store.ex` `lookup_unavailable/1` | The warning throttle reuses `RateLimit.take/3`. That function returns `:ok` when the rate limit is disabled, so the throttle turns off with it and every unauthenticated request that fails the lookup writes one WARNING. | Use a throttle that does not depend on the rate-limit disable switch, e.g. a `:persistent_term`/`:atomics` last-logged timestamp. |

### Detail

**Finding #1 — JWT path accepts revoked, refused or deactivated JWTs during a DB outage** [MEDIUM, pre-existing]
This code is not changed by the diff. The owner asked for it to be reported.
- `TokenDenylist.revoked?/2` returns `false` on a DB error ("AC8: any error … returns false"). A JWT that was logged out on a different node, so this node's ETS has no entry, is accepted again.
- `DeviceBinding.lookup/1` maps a DB error to `{:ok, nil, false}`. This skips the T25c refusal ("this device has an OAuth session") and leaves the request with no bound device.
- `provision/2` maps `TokenValidator.validate` `{:error, _}` to `:ok`. A deactivated user is not cached, so the deactivation check runs on every request, and on a DB error that check is skipped.

Each case needs a still-valid JWT signed by the IdP (the signature, `exp`, `iss`, `aud` and alg allowlist checks do not touch the DB) plus a DB outage. The rating is MEDIUM because of those preconditions. It is the same problem this story fixed for the opaque path, but in the other direction (accept instead of reject). The opaque path is not affected: `provision/2` is only a secondary safety net there, because deactivation deletes the `matrix_sessions` rows, and the primary lookup now fails closed.
Remediation: a follow-up story that makes the denylist, binding and validate lookups three-valued and fails closed with the 503 from `deny_unavailable/1`.

**Finding #2 — Log-flood amplification when the rate limit is disabled** [LOW]
`lookup_unavailable/1` throttles with `Nebu.Web.Plugs.RateLimit.take({"session_lookup_unavailable_warning", :node}, 1, 1)`. `take/3` returns `:ok` without checking the bucket when `NEBU_RATE_LIMIT_DISABLED=true` or `:rate_limit_disabled` is set. In that setup, during a DB outage, any unauthenticated client can send a junk Bearer token (no `.`) and cause one WARNING line per request. The per-IP pre-auth limiter is disabled by the same switch. This needs an operator misconfiguration in production (the switch is meant for tests and load runs) plus a DB outage. The log line itself is clean.
Remediation: throttle with a node-local monotonic timestamp (e.g. `:atomics` compare-exchange) that ignores the rate-limit disable switch.

### Review notes (owner focus)

1. **Fail closed.** `call_opaque/2` authenticates only in the `{:ok, sess}` branch (not revoked, not expired, not deactivated). `{:error, :unavailable}` calls `deny_unavailable/1`, which sends the response and halts without assigning anything, so no handler runs. `get_by_access_token_hash/1` matches exactly two success shapes: `{:ok, %{rows: [row]}}` authenticates and `{:ok, %{rows: []}}` gives 401. Every other result, including several rows or an unexpected shape, falls through to `lookup_unavailable/1`, which is fail closed. `lookup_query/2` rescues exceptions and catches `:exit`, so a pool checkout timeout can no longer crash the request or turn into a 401. `lookup_unavailable/1` has its own `rescue`, so a missing RateLimit table still returns `{:error, :unavailable}`. `has_open_grace_window?/1` and `mark_access_token_used/1` run only after a successful lookup. If either fails, the request has already been correctly authenticated. The only effect is that the pending old refresh token keeps its grace window until the next request (pre-existing best-effort design, no bypass). `provision/2` on the opaque path is covered under Finding #1. The refresh worker skips the row on `:unavailable`: it never deletes, extends or resurrects a session.
2. **Availability and oracle.** Every token without a `.` (valid, unknown, malformed) runs the same `hash_token` lookup and gets the same constant 503 body when the DB fails. The answer depends on the DB state, not on the token, so the response is no oracle. No `soft_logout` and no `retry_after_ms`. `Retry-After: 5` is a constant. Timing during an outage is dominated by the pool/DB failure path and is the same for every token. A DB outage cannot authenticate anything on the opaque path. The 503 does not cause new DB load: the lookup happened before this change too. JWTs do not take this path; see Finding #1.
3. **No Sensitive Data in Logs law.** The log line is `"matrix auth: access token lookup unavailable class=#{class}"`. The class is an exception module name (`inspect(module)`, e.g. `DBConnection.ConnectionError`, `Postgrex.Error`), `exit_<atom>`, an atom error tag, or `unknown`. It contains no message, no SQL, no params, no token, no hash, no user and no device. The 503 body is fixed text. `Nebu.Repo.QueryTelemetry` logs only at debug level and only the source and the ok/error class, never `:query` or `:params`. The Repo is configured with `log: false` in runtime.exs. Driver-level connection errors (Postgrex/DBConnection) do not contain the query params. Compliant.
4. **Log flood / DoS.** With the rate limit enabled: at most 1 WARNING per minute per node, keyed by an internal tuple that a client cannot derive or exhaust per user. With it disabled, see Finding #2. Each failing request still costs one DB/pool attempt, as before (no new amplification).
5. **Test seam.** `if Mix.env() == :test do … else defp lookup_fault(fun), do: fun.() end` is evaluated at module compile time. The release is built with `RUN MIX_ENV=prod mix release` (Dockerfile:30), so only the pass-through clause is compiled in. No `Application.get_env(:nebu_http, :matrix_session_lookup_fault)` read exists at runtime, and `Mix` is not called at runtime. Compliant.
6. **Other entry points.** `Router.Protected`, `Router.Media` and `Router.ClientV1Media` (`authenticate/2` calls `OidcPlug.call/2`) all go through `OidcPlug.call/2`, so all get the 503 behaviour. `get_by_access_token/1` has no other caller. `get_auth_context/1` (used by UIA `caller_auth_time/1`) still returns `:error` on a DB failure. That becomes `nil`, `Uia.fresh?(nil)` returns `false`, and the client gets a UIA challenge, which is fail closed. It is not a security issue: at worst there is one extra re-auth prompt during an outage. The JWT path is in Finding #1.

**Prescan:** 0 grep candidates (path trigger only: `matrix_session_store.ex`).

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 — advisory (pre-existing, outside the diff; follow-up story recommended)
LOW: 1 — advisory

**Verdict:** APPROVED
