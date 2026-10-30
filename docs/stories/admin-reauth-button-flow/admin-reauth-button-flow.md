---
story_id: admin-reauth-button-flow
title: "Admin UI: fresh sign-in state shown on the primary button"
epic: admin-reauth-button-flow
status: ready
security_review: required
matrix: false
ui: true
traceability_id: REQ-2026-001
created: 2026-10-29
---

## Story

**As** an administrator changing a setting that needs a fresh sign-in, **I want** the primary button of the form to show whether I still have to sign in again ("Sign in again to save") or can save now (the normal submit button plus a line saying how long the fresh sign-in is valid), **so that** I sign in BEFORE I enter my change and do not lose my input to a refused POST and a banner I overlook.

### Scope: 9 marker-gated forms on 7 pages

The server decides the state when it renders the page: `Nebu.Admin.Auth.reauth_fresh(conn, <marker path>)` returns `{:ok, _}` = fresh, `:stale` = sign-in needed. The marker path is the path passed to `Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, <path>)` in each controller:

| # | Page / form | Marker path (gate call) | Normal submit text | Stale link text | Existing hooks to keep |
|---|---|---|---|---|---|
| 1 | /admin/config, SSO schemes | `@config_path` = `/admin/config` (`config_controller.ex`) | Save SSO schemes | Sign in again to save | `#sso-schemes-reauth-hint` |
| 2 | /admin/config, SSO origins | `/admin/config` (shared) | Save SSO origins | Sign in again to save | `#sso-origins-reauth-hint` |
| 3 | /admin/config, OAuth 2.0 authorization server switch | `/admin/config` (shared) | Save OAuth settings | Sign in again to save | `#oauth-switch-reauth-hint` |
| 4 | /admin/config/claim-mapping | `/admin/config/claim-mapping` (`claim_mapping_controller.ex` `@page`) | Save | Sign in again to save | `#claim-mapping-reauth-hint`, `#claim-mapping-lockout-hint` |
| 5 | /admin/config/role-mapping | `/admin/config/role-mapping` (`role_mapping_controller.ex` `@page`; marker also carries the role-claim fingerprint, `reauth_role_check/2`, unchanged) | Save | Sign in again to save | `#role-mapping-reauth-hint`, `#role-mapping-lockout-hint`; the existing `reauth_link` assign and `@page_reauth` are unified with the new pattern (`@reauth.href` for the link, boolean assign `:inline_reauth_link` for whether the refusal offers the inline link) |
| 6 | /admin/media/settings, storage policy | `/admin/media/settings` (`media_settings_controller.ex` `@page`) | Save | Sign in again to save | `#media-policy-reauth-hint` |
| 7 | /admin/media/settings, storage target | `/admin/media/settings` (shared) | Save | Sign in again to save | `#media-storage-reauth-hint`; the second submit "test connection" (`formaction=".../storage/test-connection"`, `:click` gate) stays a plain submit in both states |
| 8 | /admin/oauth/registrations/<id>/approve (`approve_confirm.html.heex`) | `/admin/oauth/registrations/<seg(id)>/approve` (already assigned as `@reauth_fresh`) | Approve client | Sign in again to approve | `data-role="approve-confirm"` (on the submit), `data-role="reauth-state"` + `data-reauth="fresh"/"needed"`, the `aria-label` naming the client |
| 9 | /admin/oauth/clients/<id>/revoke (`revoke_confirm.html.heex`) | `revoke_path(client_id)` (already assigned as `@reauth_fresh`) | Revoke client | Sign in again to revoke | `data-role="revoke-confirm"` (on the submit), `data-role="reauth-state"` + `data-reauth`, `#confirm-host-help`, `#revoke-reason-help` |

### Constraints

- Presentation only, plus the controllers assigning the freshness flag (and, if needed, a read-only accessor in `Nebu.Admin.Auth` for the remaining validity). The server-side gates (`OAuthAdminHelpers.gate/3`, `click_gate`, `reauth_fresh/2`, `consume_reauth/1`, `reauth_role_check/2`), the freshness rules (5 minutes, bound to one page path, consumed by one successful write) and the IdP flow stay UNCHANGED.
- Stale state: the primary control is an `<a href>` styled as a button (not a `<button type="submit">`), href = `Nebu.Admin.Auth.reauth_start_path(<marker path>)`, built from the server-side page path, never from request parameters or user input. Its text names the action ("Sign in again to save" / "... to approve" / "... to revoke"), it is keyboard reachable, and it keeps `aria-describedby` to the reauth hint of its form (and to the lockout hint where the submit has one today).
- Fresh state: the normal submit button with its normal text, plus a short visible text line (inside the existing hint or `reauth-state` element, referenced by `aria-describedby`) saying the fresh sign-in is valid, for how many minutes (server-rendered) and for one save. Not colour only.
- The hint paragraphs "Saving this setting needs a fresh sign-in. If you are asked to sign in again, ..." are reworded to the new flow (sign in first, then enter the change and save; for the storage target: the access key and secret key are never pre-filled). The post-return flash from `reauth_notice/2` may stay or be shortened, but must no longer tell the admin that a change was refused when no POST happened.
- No JavaScript, no countdown, no replay of a refused POST, no pre-filling after return.
- The strict fetch-metadata / Safari click proof on the submit forms is unchanged; existing element ids and `data-role` / `data-reauth` attributes stay.
- No secret, form value or marker content in any URL (the link carries only `mode=reauth` and `return_to=<page path>`) or log line.
- Out of scope: the "OIDC scopes" and "refresh mode" forms on /admin/config (`:click` gate, no fresh sign-in): they stay plain submits in both states.

## Acceptance Criteria

```gherkin
Feature: Fresh sign-in state shown on the primary button of marker-gated admin forms

  Scenario: Without a fresh sign-in the primary control is a "Sign in again" link
    Given I am a signed-in administrator without a fresh sign-in marker for the page of one of the 9 marker-gated forms
    When I open that page
    Then the form shows instead of its submit button a keyboard-reachable link styled as a button with the text "Sign in again to save" ("Sign in again to approve" on the approve confirm page, "Sign in again to revoke" on the revoke confirm page) whose href is reauth_start_path of that page path, and which keeps aria-describedby to the reworded reauth hint

  Scenario: With a fresh sign-in the normal submit button and the validity line are shown
    Given I signed in again via that link less than 5 minutes ago and the marker is bound to this page path
    When the page is rendered
    Then the form shows its normal submit button with its normal text ("Save SSO schemes", "Save", "Approve client", "Revoke client", ...) and a text line, referenced by aria-describedby, saying that the fresh sign-in is valid for the server-rendered remaining minutes and for one save

  Scenario: After a successful save the link comes back
    Given the page shows the fresh state and I submit a valid change
    When the change is saved and the marker is consumed
    Then the page rendered next shows the "Sign in again to ..." link again for every form bound to that marker path (on /admin/config all three gated forms, on /admin/media/settings both gated forms)

  Scenario: Marker expires while the page is open
    Given the page was rendered in the fresh state and the marker has expired (older than 5 minutes) before I press the submit button
    When I submit the form
    Then the server refuses the POST and redirects to the fresh sign-in exactly as today, nothing is saved, the refused POST is not replayed, and no form value or secret appears in the redirect URL or in any log line

  Scenario: A fresh sign-in for another page does not unlock this page
    Given I hold a valid fresh sign-in marker bound to a different page path (for example /admin/config/claim-mapping)
    When I open /admin/config, /admin/media/settings or an approve or revoke confirm page
    Then that page shows the "Sign in again to ..." link, not the submit button, while the OIDC scopes, refresh mode and test connection submits stay plain submit buttons in every state
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions (owner delegated, 2026-10-29: the defaults below were accepted by the orchestrator)

- Validity line: the REMAINING whole minutes (read-only accessor for the marker timestamp in `Nebu.Admin.Auth`, no new state), rounded down; "less than a minute" below 60 s.
- Stale state: the form inputs stay editable; the reworded hint tells the admin to sign in first (anything typed before the sign-in round trip is lost, the refused POST is never replayed).
- Role mapping: the existing inline "Sign in again, then enter the value once more" link stays next to the refusal error in addition to the primary-control link; both use `@reauth.href` (the `:reauth` assign of `OAuthAdminHelpers.assign_reauth/2`; the boolean assign `:inline_reauth_link` says whether the refusal shows the inline link).
- Read-only accessor contract: `Nebu.Admin.Auth.reauth_remaining_minutes(conn, path) :: {:ok, 0..5} | :stale` (floor of the remaining whole minutes of the 300 s window, 0 = less than a minute; `{:ok, _}` exactly when `reauth_fresh/2` is `{:ok, _}`; never writes the session).
- Scope extension (found by the test review, security): Phoenix prints request parameters at `:debug` even when a gate halts the request, and `config :phoenix, filter_parameters` (`server/config/config.exs`) lists only `password`, `reason`, `confirm_host` and the CSRF tokens. The form values of the gated forms (SSO lists, issuer URL, claim and role values, webhook URL, storage `access_key` / `secret_key`) would be logged in clear. This story therefore ALSO extends `filter_parameters` (existing keys stay). A direct test pins every field name of the 9 forms.
- Enter key in the stale state (accepted trade-off, UX note, no test): single-input forms still submit on Enter and are refused by the server as today; on the storage form the first submit is "Test Connection". Nothing is saved, nothing is replayed.
- Confirm pages (approve / revoke): the stale hint no longer says "type ... again" (nothing was typed before the sign-in); it tells the admin to sign in first.
- Fix cycle 1 (Kassandra #1, MEDIUM): `Nebu.Web.Plugs.RequestLogger` (mounted in `Nebu.Web.Router`, which serves `/admin/*`) captured `conn.body_params` of admin POSTs at `:debug`, filtered only by the exact-key `PayloadRedactor`. It no longer captures request bodies of `/admin/*` at all (covers future forms). A full-path log test (`admin_reauth_button_flow_request_logging_test.exs`) pins this for the storage target and the claim mapping form on both logging paths.
- Fix cycle 1 (user info): the plain storage `endpoint` rejects `@`; `iam_endpoint` / `sts_endpoint` (full `https://` URLs) do NOT reject user info. The rejected-URL warnings logged the whole URL: they now log the host only, and `filter_parameters` also masks `endpoint` (substring match, covers `iam_endpoint` / `sts_endpoint`; only the media form has such a parameter). Done in fix cycle 2: see below (the validation now rejects user info).
- Fix cycle 1: the post-return notice reads "Signed in again. Nothing is changed yet: enter your change and press Save. ..." so it is true after a link sign-in and after a refused POST; the storage hint says in both states that the keys are never filled in and that Test Connection needs no sign-in; the stale hint says that input typed before the sign-in is lost; the stale "Sign in again to revoke" link has its own class (the fresh submit keeps `btn-error`).
- Fix cycle 2 (UX gate): the stale revoke link is a plain `btn` (`btn-neutral` failed the contrast / focus-ring check; `btn-secondary` is not used); the notice names no minutes (a flash outlives the page; the validity line of the form carries them); the validity line reads "When this page was opened, your fresh sign-in was valid for N minutes and for one save on this page" (no countdown, `one approval` / `one revocation` on the confirm pages); the stale storage hint says "Sign in first, then enter the connection details: Test Connection does not use up the sign-in, so you can test and then save"; the revoke page gives the host field no autofocus in the stale state and its stale hint says typed input is lost; on the role mapping the inline link keeps its text and gets an explanation in front of it.
- Fix cycle 2 (Kassandra delta): the RequestLogger decides "admin" on the percent-DECODED first `path_info` segment in `call/2` (`/%61dmin/...` was a bypass of the raw-path check). `iam_endpoint` / `sts_endpoint` URLs with user info (any `@`, so also a password with `/ ? #`) are rejected in the form check and in `StorageConfig.upsert/1` before the SSRF check and before any log line (value-free message, log and re-render; the former follow-up is done). A rejected plain `endpoint` with an `@` is not echoed back into the form either.
