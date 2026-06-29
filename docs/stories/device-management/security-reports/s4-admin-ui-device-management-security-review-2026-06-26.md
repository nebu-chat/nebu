# Security Review — device-management / S4 (Admin UI per-user device management)

**Reviewer:** Kassandra (adversarial security review, SEC Gate 1, story-level)
**Date:** 2026-06-26
**Diff scope:** staged diff — production code only. Files reviewed:
- `server/lib/nebu/admin/users_controller.ex` (new `show/2`, `rename_device/2`, `delete_device/2`, device seams, `actor_id/1`, `enc/1`)
- `server/lib/nebu/admin/templates/users/show.html.heex` (new device list + rename + revoke forms)
- `server/lib/nebu/admin/users_html.ex` (`format_ts/1`, `last_seen_cell/1`, `device_display_name/1`, `device_field/2`)
- `server/lib/nebu/admin/router.ex` (3 new routes)
- `server/lib/nebu/matrix.ex` (`list_user_devices/1`, `rename_user_device/3`, `delete_user_device/2`)
- `server/lib/nebu/matrix/device_key_store.ex` (`created_at` added to two SELECTs + `device_row/1`)
- `server/lib/nebu/compliance/audit_writer.ex` (`device_renamed`/`device_deleted` in `@known_actions`; `do_log` rescue narrowed to `RuntimeError`)

Story `.md` and `_bmad-output` state files excluded from scrutiny per scope. Cross-referenced
against MEMORY.md S4 watch-list and patterns #69/#70/#72.

---

## Verdict

**CLEAN — APPROVED.** No CRITICAL, no HIGH. The story's high-risk surfaces (authz gate, IDOR,
XSS on legacy/backfilled `device_id`/`display_name`, the S3 kill-switch reuse, audit completeness)
are all handled correctly. Three LOW advisories + one INFO. Default blocking severity (CRITICAL)
not reached; commit is not blocked.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `token_denylist.ex:119/134` via `matrix.ex:332` | A `jwt_device_bindings` row with `exp = NULL` yields `revoke_by_hash(hash, nil)` → no-op → that JWT is NOT denylisted on device-delete | Backfill/enforce `exp NOT NULL` on binding writes; or denylist NULL-exp bindings with a bounded fallback exp. Window is narrow (token still bound by its own OIDC `exp`). |
| 2 | LOW | `matrix.ex:316` (`delete_user_device/2`) | No DoS guard against an admin deleting another admin's last/only device → that admin's session is killed (admin self/peer lockout via the kill-switch). Not an auth boundary crossing. | Optional: warn in UI when revoking the last device of an `instance_admin`. Recovery is via re-login (OIDC), so impact is transient. |
| 3 | LOW | `router.ex` / `endpoint.ex:65` | New state-changing POSTs (`rename`, `delete`) have no per-route rate limit and inherit the admin `Plug.Parsers` default body cap (no explicit `length:`). Admin-scoped (post-auth), low risk. | Carry-over of admin-ui-migration F-3; no new exposure. Add a `length:` cap when the admin parser is next touched. |
| 4 | INFO | `users_controller.ex:101` | `:ok = do_delete_device(...)` hard-matches `:ok`. Production facade always returns `:ok`; only the injectable test seam could return otherwise and raise. No production impact. | None required. |

---

## Detail — surfaces verified clean

**AUTH / AUTHZ (no bypass).** `plug Nebu.Admin.Auth, :require_admin` is declared at the controller
level (`users_controller.ex:27`) with **no `only:`/`except:`** — it runs for *every* action in the
module, including the three new ones (`show`, `rename_device`, `delete_device`). `require_admin`
(`auth.ex:84`) matches only `%{"admin" => true}` from the verified session-derived `current_user`
and otherwise `halt()`s with a redirect to `/admin/login`. The `:browser` pipeline does NOT carry
`require_admin` (it is per-controller by design, router moduledoc), so there is no pipeline-vs-plug
gap here — the gate is unconditional for this controller. A non-admin / unauthenticated request
reaches none of the three actions.

**IDOR / cross-user — clean.** Every operation is scoped to the **route** `user_id`, never to a
value derived from the device:
- `rename_device/2` / `delete_device/2` decode and pass the **route** `user_id` into the facade
  (`users_controller.ex:67-74`, `93-101`). The `device_id` is only the second scoping key.
- Facade → store SQL is uniformly `WHERE user_id = $1 AND device_id = $2`, fully parameterized, in
  every path: `DeviceKeyStore.rename_device` (`UPDATE … WHERE user_id=$1 AND device_id=$2`),
  `DeviceKeyStore.delete_device` (per-table `DELETE … WHERE user_id=$1 AND device_id=$2`),
  `DeviceBinding.list_for_user_device` / `delete_for_user_device`, and
  `MatrixSessionStore.delete_for_user_device`. A crafted `device_id` cannot reach another user's
  row because the composite predicate always pins `user_id` to the route value. `rename_device`
  returns `:error` (→ flash, never another user's device) when `num_rows != 1`.

**XSS — clean.** All dynamic values render through HEEx `{...}` (auto HTML-escaped) — there is no
`raw/1`, no `{:safe, …}`, no `Phoenix.HTML.raw`, no `html_escape` anywhere in the template or
`users_html.ex` (grep confirmed zero hits). Specifically:
- `device_id` and `display_name` (legacy/backfilled, may contain markup) render escaped in the table
  cells, the rename `value=`, the `<label>`, the `id=`/`for=`, the `data-device-id`/`data-confirm`/
  `aria-label` attributes, and the form `action=` URLs. HEEx escapes attribute values, so even
  markup-bearing legacy values cannot break out.
- Action URLs additionally percent-encode the segment via `URI.encode(…, &URI.char_unreserved?/1)`,
  matching the controller's `enc/1` so the PRG redirect target round-trips.
- `users_html.ex` helpers build only plain strings (em-dash, ISO-8601 timestamp, `"#{ts} · #{ip}"`)
  — no markup is assembled as a string that would bypass escaping. `format_ts` emits
  `DateTime.to_iso8601/1` (digits/`-`/`:`/`T`/`Z` only) or `"—"`. `last_seen_ip` is rendered as
  text only (and per S2 review originates from `remote_ip`, not raw XFF).

**INLINE JS INJECTION — clean.** The revoke form's `onsubmit="return confirm('Revoke this device?
…')"` is a **fixed string literal** — no `device_id`/`display_name` interpolation into the JS string
or the attribute. No breakout vector. (The `data-confirm` attribute *does* interpolate `device_id`,
but it is a dead `data-*` attribute on a non-LiveView page — never evaluated as JS — and is
HTML-escaped regardless.)

**CSRF — clean.** The `:browser` pipeline runs `protect_from_forgery`; both forms include a hidden
`_csrf_token` = `Plug.CSRFProtection.get_csrf_token()`. The `_method=DELETE` override is wired via
`Plug.MethodOverride` in `endpoint.ex:70`, which runs in the endpoint *before* the router pipeline,
so CSRF still applies to the effective POST. The compile-time `:admin_csrf_bypass` env is test-only
(never set in prod) and explicitly excludes the bootstrap path; the new routes get full CSRF
enforcement in production. No method-override abuse: the override only maps POST→DELETE for routing;
it does not relax CSRF.

**SQL injection — clean.** Every device query is parameterized (`$1`/`$2`/`$3`/`$4`). The new
`created_at` column was added to two SELECT *column lists* (static SQL, no interpolation). The only
string interpolation into SQL is `DeleteDevice`'s `#{table}` loop over a **hardcoded literal list**
(`device_one_time_keys`, `device_fallback_keys`, `device_keys`, `devices`) — no user input.

**PATH / PARAM handling — clean.** `URI.decode/1` on `user_id`/`device_id` produces strings fed only
to parameterized SQL and the kill-switch — no filesystem path, no shell, no traversal sink. Over-long
or control-char `device_id` is a pre-existing input-validation gap flagged at S1/S2 (mirrored from
000009; S2's combined review F-2, MEDIUM) — **not introduced by S4** and not exploitable here because
the value is parameterized and HTML-escaped on render. The Admin UI now renders it as escaped text,
so even a markup-bearing legacy id is inert.

**AUDIT INTEGRITY — clean.** Both `device_renamed` and `device_deleted` are registered in
`@known_actions` at the same commit (merge-gotcha closed). `rename_device` writes an audit row on
**both** success (`outcome="success"`) and failure (`outcome="failure"`, `"rename_failed"`).
`delete_device` writes a success row after the (idempotent, always-`:ok`) kill-switch. There is no
state-changing path that completes without an audit emit. The narrowed
`rescue e in [RuntimeError]` in `AuditWriter.do_log` is a sound improvement: it degrades only the
documented down-Repo case (`Ecto.Repo.Registry.lookup` raising on a missing/unstarted Repo) to
`{:error, :audit_write_failed}` while letting genuine logic bugs (FunctionClause/ArgumentError)
surface. Because the controller does not pattern-match the audit return, an audit-write failure does
not crash the admin action — acceptable best-effort behavior consistent with the project-wide audit
indirection; the failure is still `Logger.error`-logged. No attacker-controllable way to suppress an
audit row was found.

**KILL-SWITCH (S3 reuse) — clean; pattern #70 satisfied.** `delete_user_device/2` (`matrix.ex:316`)
tears down **both** token forms, in the correct order:
1. Enumerates `DeviceBinding.list_for_user_device(user_id, device_id)` → `{token_hash, exp}` pairs
   and `TokenDenylist.revoke_by_hash(token_hash, exp)` each (raw-JWT path denylisted until its own
   `exp`; the S3 `exp` column from migration 000012 supplies it).
2. `DeviceBinding.delete_for_user_device/2` drops the binding rows.
3. `MatrixSessionStore.delete_for_user_device/2` deletes the opaque session row (opaque path).
4. `DeviceKeyStore.delete_device/2` removes the device identity + all key material.

This is **not** a weaker reimplementation of S3 — it reuses the same revocation primitives and
covers opaque + JWT. The denylist is ETS + DB-backed (`db_revoke`), so revocation is cluster-correct
(consulted via `db_revoked_any?` on other nodes). Ordering is safe: tokens are revoked **before**
keys/rows are deleted, so there is no window where keys are gone but the token still authenticates as
a *live* session — and even the reverse (revoke succeeds, delete lags) only denies access earlier.
The one residual is Finding #1: a binding row with `exp = NULL` would no-op the denylist for that
JWT (still bounded by the token's own OIDC exp) — LOW.

**Open-redirect / PRG — clean.** The post-action redirect builds `"/admin/users/#{enc(user_id)}"`
from the route `user_id` only (server-controlled path prefix + percent-encoded segment). No
user-controlled host/scheme; not an open redirect.

**Timing / secrets — n/a.** No secret comparison, no crypto primitive, no token/secret logged in the
new code. `actor_id/1` reads the verified `current_user` for the audit actor.

---

## Summary

- CRITICAL: 0 — *(none)*
- HIGH: 0 — *(none)*
- MEDIUM: 0
- LOW: 3 — advisory (NULL-exp binding no-op on revoke; admin last-device self/peer lockout; no
  per-route rate limit / explicit body cap)
- INFO: 1 — `:ok =` hard-match on the always-`:ok` facade (test-seam only)

**Verdict: APPROVED / CLEAN.** Commit not blocked.

S4 watch-list items (MEMORY.md, recorded 2026-06-26) all confirmed in code:
- Device-delete reuses S3's path and revokes opaque + denylists JWT (does not reimplement a weaker
  revoke). ✓
- New audit actions registered in `@known_actions` at the same commit; every rename/delete emits an
  audit row. ✓
- Admin authz gate on view AND act (`:require_admin`, no `only:`/`except:` gap). ✓
- `last_seen_ip` rendered as escaped text only. ✓
