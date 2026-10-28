---
story_id: admin-config-privileged-forms-sweep
title: "Sweep of the privilege-granting forms under /admin/config: claim mapping and role mapping behind strict fetch metadata + fresh re-authentication + no framing, scopes and refresh mode behind strict fetch metadata, audit row for the SSO scheme list (follow-ups cw, Y-5)"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-14
branch: feature/migrate-to-oauth2
---

# Story: Sweep of the other privileged admin forms (follow-up `cw`)

Source: follow-ups row `cw` (SEC delta gate 2026-10-14, X-1 sibling) and Y-5 (the SSO scheme list writes no audit row).
`docs/stories/oauth-broker/admin-oauth-switch.md` built the mechanism for the OAuth switch (no third mechanism here).

## Story

As an operator I want every form under `/admin/config*` that grants authority or widens trust to be protected like the OAuth client
approval and the SSO trust lists, or to carry a documented reason why it is not, so that a script on the shared Element Web / admin
origin (SO7) that read a CSRF token cannot silently change who is an administrator, how users are identified or which claims are
requested, and so that every such change is audited.

## Decisions (per form)

The mechanism is `Nebu.Admin.OAuthAdminHelpers.gate/3` (strict fetch metadata incl. the Safari click proof `_click_proof`, notice page
instead of a 403; `:marker` additionally a fresh admin re-authentication bound to the page and single use; `:click` without the marker),
the router's unframed rule (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`) and the audit writer.

| Form | Route | Level | Why |
|---|---|---|---|
| SSO redirect origins, SSO redirect schemes | `POST /admin/config/sso-origins`, `/sso-schemes` | `:marker` (unchanged) | redirect sinks for a `loginToken` (story sso-origins-admin-hardening) |
| OAuth switch | `POST /admin/config/oauth-switch` | `:marker` (unchanged) | story admin-oauth-switch |
| **Role mapping** (`admin_group_claim`) | `POST /admin/config/role-mapping` | **`:marker` bound to `/admin/config/role-mapping`**, page unframed | decides WHO IS AN ADMINISTRATOR: a script that points it at a claim the attacker controls (or at one that every user has) takes over the instance |
| **Claim mapping** (`oidc_user_id_claim`, `oidc_displayname_claim`, `oidc_email_claim`) | `POST /admin/config/claim-mapping` | **`:marker` bound to `/admin/config/claim-mapping`**, page unframed | decides which IdP claim identifies a user: pointing the user id claim at an attacker-controlled claim maps logins onto other accounts |
| **OIDC scopes** | `POST /admin/config/scopes` | **`:click`** (strict fetch metadata, no marker) | extra scopes ask the IdP for more claims; alone they grant nothing. NO marker on purpose: the fresh sign-in of the marker uses the admin OIDC client WITH these scopes, so a wrong scope value would lock the admin out of the very sign-in needed to correct it |
| **OIDC refresh mode** | `POST /admin/config/refresh-mode` | **`:click`** | availability / token-lifetime setting; the same lock-out argument for the marker (offline vs online changes what the admin sign-in requests) |

Accepted consequence for the two marker forms: a wrong claim value can lock administrators out of the sign-in; the single-use marker
means the correction needs a working sign-in. The pages say so (a warning next to the form: keep the current session open, test the
sign-in in a second browser before you leave, recovery by SQL in 07-deployment) and the SQL recovery is documented.

- **Other admin forms are out of this sweep** (recorded in follow-ups `de`): logs retention (`/admin/logs/config`), media settings and the
  storage target (`/admin/media/settings*`), the user / room / space actions. They are not under `/admin/config*`; the storage target
  and the media policy deserve the same question (an SSRF / exfiltration target), the user and room actions are the normal admin job.
- **Audit.** New action `sso_redirect_schemes_changed` for the scheme list (Y-5, written like the origins audit: after the save, a
  failing writer never undoes it); `oidc_claim_mapping_changed` and `admin_group_claim_changed` for the two mappings (actor, the new
  values: the three claim names of the claim mapping, the group value of the role mapping). Scopes and refresh mode write `oidc_scopes_changed` / `oidc_refresh_mode_changed` rows after the save (SEC review L-3: they change the claim set and the token lifetime).
- **Bootstrap.** The bootstrap wizard (`/admin/bootstrap*`, before any admin exists) keeps its own controller and is not gated: there is
  no admin session and no IdP login yet.

## Acceptance Criteria

1. `POST /admin/config/role-mapping` and `POST /admin/config/claim-mapping` run `gate(conn, :marker, <their page>)` after `require_admin`
   and the CSRF check and before validation: a missing / wrong fetch metadata header answers the `403` page, a missing / stale / foreign-path
   / foreign-subject marker redirects to `Auth.reauth_start_path(<page>)`, a WebKit request without the click proof gets the notice page;
   the marker is consumed after a SUCCESSFUL write only (a validation error keeps it). `Nebu.Admin.Auth.reauth_return_to/1` accepts the two
   pages, exactly.
2. `POST /admin/config/scopes` and `POST /admin/config/refresh-mode` run `gate(conn, :click, "/admin/config")`: strict fetch metadata,
   no marker; a validation error keeps the 200 re-render. Their forms carry the `_click_proof` field.
3. The GET and POST responses of the two mapping pages carry `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `Cache-Control: no-store`
   (also the `/` and `//` variants, decided on `path_info`); the refusal and notice pages name the mapping page they came from
   (back link, sidebar entry).
4. The forms of the two mapping pages carry the hidden `_click_proof` field and the reauth hint sentence (`aria-describedby` on the button),
   plus the lock-out warning.
5. Audit: the SSO scheme list save writes one `sso_redirect_schemes_changed` row (new `@known_actions` entry, metadata: the new normalized
   list and its size); the two mapping saves write `oidc_claim_mapping_changed` / `admin_group_claim_changed` rows (new values only; a
   failing writer is logged value-free and never undoes the save).
6. The bootstrap wizard and its claim selection are unchanged (tests).
7. Existing tests / e2e flows that save these forms are adapted (fetch metadata headers, a marker through the existing helper; e2e steps use
   the existing Dex re-auth helper; static check only).
8. Documentation: the decision table in ADR-033 (SO10) and `07-deployment.md` (group D / the protection list / the lock-out recovery),
   `follow-ups.md` (`cw` closed, new rows), 11-risks.

- **Migration 000049 (found by the code review, MAJOR-1).** `admin_group_claim` was missing from the `config_update_mutable` RLS allowlist (dropped by 000002), so every save of the Role mapping page raised an RLS error on a bootstrapped instance (a pre-existing gap of the class 000048 fixed). 000049 adds the key (and nothing else); static + DB tests. This widens what the runtime role may update (the form exists to change this value; it now needs a fresh sign-in and is audited): OWNER DECISION recorded in the report.

## Out of scope

The other admin forms (row `de`), the SO7 residual, new UI for the mapping pages beyond the hint.
