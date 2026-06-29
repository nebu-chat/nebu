# Pre-Dev Test Review — S3 (device_endpoints_test.exs)

Verdict (post-fix): PASS. Coverage matrix complete — every AC + G1/G2/G3 + F-1 + F-2 has >=1 test.
No hard waits/sleeps; real SSO flows only; staleness driven by app-env injection.

## Findings and resolution (fixed in-suite before dev starts)

- **MAJOR-1 (RESOLVED) — UIA m.login.sso re-submit baked a non-spec `auth.token` shape.**
  Oracle (definitive follow-up) confirmed: m.login.sso has NO inline credential; completion is
  out-of-band via the auth FALLBACK endpoint, and the re-submit `auth` dict is `{"session": id}` ONLY.
  FIX: `uia_sso_auth/2` replaced by `complete_uia_sso!/2`, which drives the REAL fallback flow
  (`GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id>` -> SSO redirect -> callback)
  then returns the spec-shaped `%{"session" => id}`. The stale-path and replay tests updated to use it.
  This makes the executable contract spec-correct — dev builds a fallback endpoint, not an inline-token sink.

- **MINOR-2 (FIXED) — G2 only covered cross-user replay.** Added a same-user single-use test:
  a satisfied UIA session re-used for a SECOND op must re-challenge (401), second device survives.

- **MINOR-3 (FIXED) — F-2 errcode loosely coupled.** Pinned all four F-2 assertions to
  `errcode == "M_INVALID_PARAM"` (dropped the `M_BAD_JSON` alternative — the JSON is valid; the
  device_id value is semantically rejected).

- **MINOR-4 (FIXED) — AC4 bulk-delete IDOR untested.** Added a test: A mixes B's device_id into the
  `devices` array -> A's own device deleted, B's device UNTOUCHED (scoped to caller).

- **MINOR-1 (NOTED, no test added) — AC6 E2EE invariant.** None of S3's endpoints touch
  `m.room.encryption`; AC6 is covered by the existing E2EE-rejection suite (createRoom / state-PUT
  403 M_FORBIDDEN). Dev must NOT add any encryption-enabling path. No new test needed.

- **INFO-1 — `if Process.whereis(Nebu.Repo) ... else assert true` soft-skip** is the established
  project convention for `:integration` tests; bodies execute under the live stack. Accepted.

## Key contract handed to dev (must implement to make tests green)
1. Routes: `PUT /client/v3/devices/:device_id`, `DELETE /client/v3/devices/:device_id`,
   `POST /client/v3/delete_devices`, and a new auth-fallback `GET /client/v3/auth/m.login.sso/fallback/web`.
2. UIA freshness env key: `Application.get_env(:nebu_http, :uia_fresh_auth_seconds)` (from
   `NEBU_UIA_FRESH_AUTH_SECONDS`, default 900). 0 => always challenge; large => always fresh.
3. Re-submit `auth` dict accepted = `{"session": id}` (session only). UIA session is server-issued,
   single-use, bound to (user, pending op).
4. Delete = full teardown: remove devices + device_keys/OTK/fallback, revoke matrix_sessions token,
   AND denylist the bound JWT (F-1 kill-switch) so a later request with that token -> 401 M_UNKNOWN_TOKEN.
5. device_id ingress validation (F-2): byte_size <= 255 and no control chars (\x00-\x1f,\x7f) at login
   and /keys/upload -> 400 M_INVALID_PARAM.
6. New forward migration 000012 (auth_time on matrix_sessions + jwt_device_bindings.exp + index, UIA
   session store if DB-backed). release_test expects 12 migrations.
