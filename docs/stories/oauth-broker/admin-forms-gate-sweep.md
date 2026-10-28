---
story_id: admin-forms-gate-sweep
title: "Sweep of the remaining state-changing admin forms (follow-up de): media policy and storage target behind strict fetch metadata + fresh sign-in, every other admin form post behind strict fetch metadata, test connection never sends stored credentials to a foreign endpoint, audited log retention and room auto-join"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-15
branch: feature/migrate-to-oauth2
---

# Story: the other admin forms (follow-up `de`)

Source: follow-ups row `de` (admin-config-privileged-forms-sweep scope), SEC delta gate admin-switch X2-9 (writers without audit), ADR-033 SO7 / SO9 / SO10.
Mechanism: `Nebu.Admin.OAuthAdminHelpers.gate/3` (strict fetch metadata incl. the Safari click proof `_click_proof`; `:marker` = additionally a fresh admin
sign-in bound to the page). No new mechanism. Classification by Kassandra (design review 2026-10-15, stored with the story).

## Story

As an operator I want every state-changing admin form to be submitted only by a real click of the administrator, and the few forms that can move all media to
another store, destroy user media or hand stored credentials to another host to need a fresh sign-in or a logic fix, so that a script on the shared Element Web /
admin origin (SO7) that read a CSRF token can no longer drive the admin UI by `fetch()`.

## Decision table (ADR-033 SO11)

Levels: **(a)** strict fetch metadata + fresh sign-in marker bound to the page, **(b)** strict fetch metadata only (`:click`), **(c)** unchanged (CSRF + session).

| Item | Route | Level | Risk and reason |
|---|---|---|---|
| M2 storage target save | `POST /admin/media/settings/storage` | **(a)**, page `/admin/media/settings` | exfiltration: every future upload goes to an attacker's store (and that store's content is served back); rare change; break-glass when the IdP is down is SQL on `media_storage_config` (the row wins over the environment) |
| M1 media policy save | `POST /admin/media/settings` | **(a)**, same page | irreversible data destruction (`released_delete_after_days` / `deleted_days` / `infected_days` of 0 delete all released attachments and the infected evidence) and blinding of alerts (`webhook_url`); never needed during an IdP outage |
| M3 test connection | `POST /admin/media/settings/storage/test-connection` | **(b)** + logic fix | persists nothing; the stored credentials sign a request to the SUBMITTED endpoint (access key id and a signature that allows offline guessing). Fix: stored credentials are reused only for the stored endpoint and scheme, else `:secret_required` |
| L1 log levels / retention | `POST /admin/logs/config/retention` | **(b)** + audit | shorter retention deletes INFO / DEBUG rows (covering tracks), DEBUG collects more personal data; NO marker: raising levels is what an operator does while the IdP is broken |
| U2 delete device | `DELETE /admin/users/:uid/devices/:did` | **(b)** | forced logout and key deletion; the incident-response kill switch: must work fast and with the IdP down (a marker would break it); audited |
| R6, S6 force-join member | `POST /admin/rooms/:id/members`, `/admin/spaces/:id/members` | **(b)** | widens access to room content; a marker would need per-room bindings and a sign-in for routine onboarding; audited `member_added`, reversible (R7) |
| R7 force leave | `DELETE /admin/rooms/:id/members/:uid` | **(b)** | incident response; audited |
| R2, S3 auto-join toggles | `POST /admin/rooms/:id/auto-join`, `/admin/spaces/:id/auto-join` | **(b)** + R2 audit | widening for all future users; a flip (the attacker does not choose the value), reversible; R2 wrote NO audit row (raw SQL) |
| R3 room visibility | `POST /admin/rooms/:id/settings` | **(b)** | exposes name and topic in the directory, no change of content access; audited |
| R4, R5 archive / unarchive | `POST /admin/rooms/:id/archive`, `/unarchive` | **(b)** | reversible, incident response; audited |
| R1, S1 create room / space; U1 rename device; S2 space name / topic; S4, S5 add / remove child | `POST /admin/rooms`, `/admin/spaces`, `.../rename`, `/admin/spaces/:id`, `.../children` | **(b)** | low risk, but one rule is testable (every admin form post needs the click) and S2 / S4 / S5 write no audit row: a blind script must not be able to change them ungated AND unaudited |
| Bootstrap wizard B1 - B4 | `/admin/bootstrap/*` | **(c)** | before any admin exists; owner constraint: stays ungated (no IdP sign-in yet). Residual: whoever completes the wizard first configures the IdP; step 2 makes an unguarded server-side GET to the entered issuer (pre-existing) |
| `GET /admin/logout` | | **(c)** | a cross-site logout is a nuisance (`SameSite=Lax`: only a top-level navigation), a same-origin script can log the admin out anyway; a POST is optional and low priority |
| LiveView events (`media_live` block / unblock / delete / rescan / override, War Room start / stop, `start_media_diagnosis`, Trace Map `configure_logging` / capture) | websocket | **(c)** | the websocket carries no fetch metadata. Honest residual: a same-origin script can do over LiveView everything an admin can (block / unblock / soft-delete media with no restore in the UI, start a War Room capture, override infected media only with the `media_admin_override` grant and a reason). Limits: the media audit rows, one active War Room, the `deleted_days` window in which SQL can still restore. Moving the media actions to controller posts is not cheap |

Not decided by the story (owner / compliance, recorded as follow-ups, NOT closed): audit rows for S2 / S4 / S5 (check whether the state event sender is the admin), `configure_logging`
(audit it or remove the dormant keys), War Room start / stop and `start_media_diagnosis` (a partial record exists: the session row with `started_by` and `reason`), bootstrap
completion (the actor before any admin exists), logout, the media policy audit that is written AFTER the write (atomic audit at least for `released_delete_after_days`, `deleted_days`,
`infected_days` is a Media-domain change), the discarded pinned SSRF target of the storage test and save path (DNS-rebinding window, pre-existing), the same stored-secret rule on the storage SAVE path,
`ab` (account page audit rows) stays open. The `de` row named user role / deactivation actions: no such admin routes exist (the only user actions are U1 / U2).

## Decisions

- **D1 (one rule).** Every non-bootstrap admin form post and DELETE (the table above) runs `gate/3` after `require_admin` and the CSRF check, before anything is read or
  changed: a controller plug `Nebu.Admin.OAuthAdminHelpers.click_gate/2` (level `:click`), the two marker forms call `gate(conn, :marker, "/admin/media/settings")` in the action. Missing or wrong fetch
  metadata answers the 403 page, a WebKit request without the click proof the notice page (nothing changed). The pages of the forms carry the hidden field
  `<input type="hidden" name="_click_proof" value="" data-click-proof />` (19 forms in 8 templates); the global script fills it.
- **D2 (one marker per page).** The media settings page holds ONE object (the instance configuration), so M1 and M2 share the marker bound to `/admin/media/settings` (as the SSO trust lists share `/admin/config`).
  It is consumed after each successful M1 / M2 save; M3 never consumes it (it persists nothing). `reauth_return_to/1` accepts the literal `/admin/media/settings` (and no room / space pattern);
  the callback notice for that page says to enter the change again including the access and secret key (the form comes back empty). The page is unframed (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`).
- **D3 (refusal pages).** The refusal and notice pages name the page the admin came from (back link and sidebar entry for rooms, a room, spaces, a space, a user, log retention, media settings).
- **D4 (M3).** `StorageConfig.test_connection/1` attaches the stored access / secret key to the candidate only when the candidate endpoint (trimmed, case-insensitive) and `use_ssl` equal the stored ones;
  otherwise `{:error, :secret_required}` and the controller says to enter the access key and secret key to test a different endpoint. The IAM / STS endpoints are not compared (the test never contacts them).
- **D5 (L1).** The log retention save writes value and audit row in one transaction (`save_config_audited/3`, story admin-config-audit-atomic), action `log_settings_changed` (new `@known_actions` entry),
  `unaudited_ok` only when every changed key is a `log_collect_*` key set to `false` (less collection); everything else is refused when the row cannot be written.
- **D6 (R2).** The room auto-join toggle calls the audited `Nebu.Matrix.set_room_auto_join/3` (row `room_auto_join_changed`, as the space toggle) instead of raw SQL; the test seam stays.

## Acceptance Criteria

1. Every route of the table (U1, U2, R1 - R7, S1 - S6, L1, M1 - M3) answers without the strict fetch metadata with the 403 page and changes nothing (a test enumerates `Nebu.Admin.Router` and fails for a
   new post / delete route that is neither gated nor on the explicit allow list: the bootstrap routes); each answers a WebKit request without the click proof with the notice page; the existing flows with the headers work.
2. M1 and M2 need a fresh marker bound to `/admin/media/settings` (a missing, stale, foreign-page or foreign-subject marker redirects to the sign-in of that page), consume it after a successful save only, keep it after a validation error;
   M3 needs none and never touches it. The page is unframed; the notice text mentions the secret.
3. The templates: every form of the eight templates is followed by a `_click_proof` field (static test); the refusal pages name their source page (back link, sidebar entry).
4. M3: stored credentials only for the stored endpoint and scheme (unit tests with the test-connection seam: same target uses the stored secret, another endpoint or scheme without typed keys is refused and the function is never called,
   typed keys work for another endpoint, one blank key counts as blank).
5. L1: one transaction with a `log_settings_changed` row, refused when the row cannot be written except for a pure "collection off" change; the action is in `@known_actions` and the real writer writes it (integration).
6. R2: the default path calls `Nebu.Matrix.set_room_auto_join/3` and writes one `room_auto_join_changed` row (integration); no raw `UPDATE rooms SET is_auto_join` remains in the controller.
7. The unit tests that post to these routes carry the strict headers (`device_management_test`, `logs_controller_test`, `media_settings_controller_test`, ...); the bootstrap wizard is unchanged (tests); e2e flows of the touched forms are real clicks.
8. Documentation: ADR-033 SO11 (the table), `07-deployment.md` (protection table, break-glass SQL for the storage target, manual verification group D incl. media settings in Safari / Firefox / Chrome: there is no e2e for the media forms), 11-risks, follow-ups (`de` closed / re-cut, new rows), `AuditWriter` `@known_actions`.

## Out of scope

The owner / compliance decisions listed above, LiveView events, the bootstrap wizard.
