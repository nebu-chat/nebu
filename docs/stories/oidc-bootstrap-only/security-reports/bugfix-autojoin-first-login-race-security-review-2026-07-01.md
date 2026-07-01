## Security Review — bugfix-autojoin-first-login-race

**Diff scope:** Staged diff (`git diff --staged`). Wires the previously-dead post-login
auto-join provisioning into the real, publicly-reachable `POST /_matrix/client/v3/login`
path. Files: `server/lib/nebu/matrix/event_dispatcher/server.ex` (new public
`run_post_login_provisioning/2` extracted from the `Task.start` block that was inlined only
in the no-production-caller `validate_token/2`; now called from 3 sites — `validate_token/2`,
`bulk_import_users/2`, and the new HTTP `/login` site — join-failure logs raised
`warning`→`error`), `server/lib/nebu/matrix/http_public.ex` (`provision_and_respond/6` now
calls `run_post_login_provisioning/2`), and a new regression test.
**Date:** 2026-07-01
**Reviewer:** Kassandra (adversarial security review)
**Base:** working tree, branch `bugfix/remove-default-scopes` (bug pipeline run, no story file)

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No CRITICAL/HIGH/MEDIUM/LOW findings introduced by this diff | — |
| C-1 | INFO (carry-over) | `server.ex` `ensure_auto_join_memberships/1` → `Room.Server.join/2` | Pre-existing F-4 (epic room-naming-and-default-rooms, 2026-05-28): auto-join `join/2` performs NO `m.room.join_rules`/ban check. Not a regression — MVP has no ban/join_rule subsystem; explicit in-code TODO comment present. | When ban/join_rule support lands, switch this call site to an `:auto_join` variant that respects those checks so a previously-banned user is not re-added at first login. Already tracked in sanctum. |

### Detail

**Focus #1 — Auto-join as a privilege-escalation vector.** NOT INTRODUCED. Room selection is
purely server-side DB state: `list_auto_join_rooms/0` and `list_auto_join_spaces/0`
(`room/db.ex:1049,1078`) are zero-parameter SQL queries gated on `is_auto_join = true AND
status = 'active'`. No client-supplied `room_id`, claim, header, or body field selects which
rooms are joined. The `is_auto_join` flag is settable only via the admin-authorized
`update_room_settings`/`set_room_auto_join` path (F-1 trusted-identity gate, unchanged by this
diff). The `user_id` and `is_new` passed to `run_post_login_provisioning/2` on the HTTP path
are both server-derived: `user_id = UserId.from_claims(verified_claims)` (after
`OidcPlug.verify_token` succeeds), and `is_new` originates solely from
`TokenValidator.Postgres.validate/4` — it is `true` only when the DB `users` lookup returns no
row (brand-new user), and is NEVER read from the request body. A client cannot force
`is_new: true`. Wiring the existing behavior to the real login path therefore lets a new user
auto-join exactly the rooms an admin designated for auto-join — the intended behavior, no new
escalation.

**Focus #2 — Room/space join_rule bypass.** NO NEW BYPASS. `Room.Server.join/2`
(`room/server.ex:64`) unconditionally joins without evaluating join_rules/ban — but this is
pre-existing behavior (finding F-4, sanctum row 168) and the ban/join_rule subsystem does not
exist in MVP. This diff does not modify `join/2` and does not change what "auto-join" does; it
only changes WHEN it is triggered (real login instead of dead code). The concern that an
`is_auto_join=true` room with a restrictive `join_rule` would be incorrectly overridden is not
newly created here — there are no join_rules to override yet. The code carries an explicit
comment binding the future fix to this call site. Recorded as INFO carry-over C-1, not a new
finding.

**Focus #3 — Information disclosure via `Logger.error`.** CLEAN. The four log lines raised
from `warning` to `error` (`ensure_auto_join_memberships/1` join-fail + `:exit`;
`ensure_auto_join_space_memberships/1` join-fail + `:exit`) and the new spawn-failure
`Logger.warning` in `run_post_login_provisioning/2` interpolate only `#{room_id}`/`#{space_id}`,
`#{user_id}`, and `inspect(reason)`. No email, display name, token, or other users' membership
details are logged. `user_id` (a Matrix MXID) and `room_id` were already present in the prior
`warning`-level lines — the severity change surfaces the same content at a higher level, adding
no new PII. `reason` is an internal GenServer/DB error term, not user-supplied data. The login
handler continues to obey the SEC directive to never log the token (`http_public.ex:287`).

**Focus #4 — DoS / resource exhaustion.** LOW residual, NOT a finding. Auto-join now genuinely
runs on every first-time real login (previously dead). Mitigations in place: (a) the `/login`
route applies `@login_rate_limit` (30/min, burst 10, per-IP tier "login", keyed on `remote_ip`
NOT trusted XFF) via `RateLimit.call/2` at `http_public.ex:113` BEFORE token verification and
provisioning; (b) auto-join fires only after successful `OidcPlug.verify_token` AND only when
`is_new` (first-ever login of a genuinely new DB user); (c) the work is a fire-and-forget
`Task.start`, so the login response is never delayed and a spawn failure is logged, not fatal.
Amplification requires an attacker able to mint many DISTINCT valid OIDC identities — Nebu does
not self-register users; identities are issued by the external IdP, so this is bounded by the
IdP's registration policy plus the per-IP login rate limit. `bulk_import_users/2` is
admin-only. No unbounded concurrent-task fan-out reachable by an unauthenticated attacker. The
number of auto-join rooms is operator-controlled (admin flags them), not attacker-controlled.
Consistent with the family-wide "no global storm cap" advisory already carried (sanctum
fix-short-oidc-sessions LOW) — not newly created by this diff.

**Focus #5 — `update_room_settings` authorization regression.** NO REGRESSION. This diff does
not touch `update_room_settings/2`, `set_room_auto_join/3`, the F-1 trusted-identity extraction
(`server.ex:862`), or the F-2 audit emit (`server.ex:897`). The gate on who may toggle
`is_auto_join` is unchanged; existing tests continue to cover it.

### Additional sweep (beyond focus items)

- **SQL injection:** both auto-join queries are static, zero-parameter SQL via
  `Ecto.Adapters.SQL.query/3` — no interpolation. `reject_opted_out` and the lookup use
  parameterized `$1`. CLEAN.
- **Auth bypass on the new call site:** `run_post_login_provisioning/2` runs only AFTER
  `OidcPlug.verify_token` succeeds in `do_login`; it is not a route and adds no new
  unauthenticated surface.
- **Idempotency / opt-out preserved:** `reject_opted_out` still filters left auto-join rooms;
  `{:error, :already_member}` remains a silent `:ok`. No behavior change to opt-out.
- **`is_new` default is fail-safe:** `Map.get(user, :is_new, false)` at both call sites —
  a validator that omits the key defaults to NO auto-join (existing-user re-logins never
  auto-join), the safe default.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO (carry-over, not introduced by this diff): 1 (C-1 — pre-existing F-4 join_rule/ban gap)

**Verdict:** APPROVED — CLEAN

This diff moves an already-audited, admin-controlled, server-side-only provisioning behavior
from dead code onto the real login path, guarded by an existing per-IP rate limit and gated on
a server-derived `is_new` flag. It introduces no new attacker-controllable input to room
selection, no new PII in logs, no new unauthenticated surface, and no regression to the
`is_auto_join` authorization gate. The only latent concern (auto-join not honoring join_rules/
ban) is a pre-existing MVP gap already tracked in the sanctum with an in-code fix pointer at the
exact call site.
