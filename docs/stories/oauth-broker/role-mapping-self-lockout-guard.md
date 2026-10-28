---
story_id: role-mapping-self-lockout-guard
title: "Role mapping self-lock-out guard: the save is refused when the fresh, verified sign-in claims of the saving admin do not satisfy the NEW group value (follow-up dg)"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-15
branch: feature/migrate-to-oauth2
---

# Story: self-lock-out guard for the role mapping (follow-up `dg`)

Source: follow-ups row `dg` (Kassandra L-1 of admin-config-privileged-forms-sweep) and X2-1 of the SEC delta gate admin-switch
(the too-BROAD direction is already refused; this story closes the too-NARROW / typo direction).

## Story

As an instance administrator I want the Role mapping page to refuse a group value that I would not satisfy myself, so that a typo or a
wrong group name cannot lock every administrator out at the next sign-in or session refresh (an open session cannot undo it: the fresh
sign-in the correction needs fails as well; the recovery is `bin/nebu rpc` or SQL).

## Decisions

- **D1 (which claims).** The check uses the verified claims of the FRESH sign-in that the marker of the form already proves (the form is a
  `:marker` form, SO10): `Nebu.Admin.Auth.reauth_complete/3` (the callback of `mode=reauth`) writes, for the return page
  `/admin/config/role-mapping` ONLY, a compact fingerprint of the claim values into the marker. The session holds no claims (only the
  `current_user` summary), and a token exchange at save time would add an IdP round trip and a refresh-token rotation to a form post.
  The fingerprint is bound to the marker like the marker itself: same `sub`, same page, at most 300 s old, consumed with it.
- **D2 (the same predicate as the admin gate).** The set of values is exactly what `Nebu.Admin.Auth.admin_claim?/1` matches against: with
  a configured `admin_group_claim_path` the string values at (and below) that path (a string claim, a list, a nested map / list), without a
  path (instance bootstrapped before `scope-admin-claim-to-path`) every string value of the claims (the any-key scan). Exact, case
  sensitive equality. `Nebu.Web.OidcClaims.string_values_at/2` is the one implementation of "which values count"; `claim_at_path_matches?/3`
  is expressed with it, a test pins the equivalence.
- **D3 (compact and not readable).** The admin session is a SIGNED, not encrypted, cookie of at most 4 KB that already carries the encrypted
  refresh token. The marker therefore holds NO claim value, only `claims_fp`: the concatenation of 6-byte prefixes of
  `SHA-256("nebu-role-fp:" <> value)` of the distinct values, sorted, at most 32 (192 bytes; 64 was tried and measured too close to the limit next to a 2 KB refresh token),
  plus `claims_fp_complete` (false when more values were cut off) and `claims_fp_path` (the path they were taken from; another path is `:unknown`). The guard is accident protection for the saving admin; the marker, the click proof and the fresh sign-in remain the
  protection against an attacker. A truncated hash only makes a false "satisfied" astronomically unlikely for an accidental value.
- **D4 (the check).** After the gate (`:marker`), the X2-1 universal-value refusal and the empty check, the controller asks
  `Auth.reauth_role_check(conn, value)`: `:ok` (the value is among the values of the fresh sign-in), `:not_in_token` (complete fingerprint,
  value absent), `:undecidable` (the fingerprint was cut off at 32 values, value not in the kept part) or `:unknown` (the marker carries no
  fingerprint: it was written by a build without this guard, during a rolling deploy). Everything but `:ok` answers 200, writes nothing,
  audits nothing, keeps the marker and shows a specific message (D5); a validation refusal never consumes the marker.
- **D5 (no override).** There is NO "I lock myself out on purpose" checkbox. Reasons: (a) there is no deadlock: an admin who is about
  to move to a new group joins it at the IdP, signs in again (the page asks for a fresh sign-in anyway, the new token has the group) and saves;
  (b) the intentional hand-over of the admin role to OTHER people is done by the new admins, or by the operator with
  `Nebu.Release.reset_admin_group_claim/1` (`bin/nebu rpc`, audited, deliberately not guarded); (c) an override is one more checkbox that a
  click-through produces the very lock-out the guard is meant to prevent, and its recovery needs the operator anyway. The refusal message names these two ways.
- **D6 (what the guard does not do).** It protects the SAVING admin only; other administrators who lack the new value lose access (that is the
  purpose of the change) and the page says so. It checks the claims of the fresh sign-in, the next refresh uses the claims of the refresh-token
  exchange (same scopes; an IdP that omits the group claim from refresh tokens is a configuration problem the operator sees at the first refresh;
  the rpc recovery exists). The claim path is not editable here, a changed path between marker and save is not detected (the path is bootstrap-only).
  More than 32 distinct values at the claim path make the guard `:undecidable` for a value outside the kept part: the page refuses and names the rpc.
- **D7 (UI).** The page shows the configured claim path read-only ("Looked up in the claim: `groups`", or "every claim of the token (no claim
  path stored by the bootstrap wizard)"), answers the refusal under the field (`role="alert"`, `data-field="admin_group_claim"`) with the
  specific message, and the hint text says that the value must be in the token of the person who saves. No new script, no new mechanism.

## Acceptance Criteria

1. The callback of `mode=reauth` with `return_to` `/admin/config/role-mapping` stores `claims_fp` and `claims_fp_complete` in the marker; for every other
   return page the marker has neither key. The fingerprint contains the hash of every string value at the configured claim path (string, list,
   nested map / list), or of every string value of the claims without a path, and of nothing else (a value under another claim does not count when a
   path is configured).
2. `POST /admin/config/role-mapping` with a value that is in the fingerprint is saved as before (audit row, marker consumed, flash).
3. A value that is NOT in a complete fingerprint answers 200, writes nothing, audits nothing, keeps the marker, and shows the "not in your own
   sign-in" message (`role="alert"`, `data-field="admin_group_claim"`); the submitted value stays in the field.
4. A marker without a fingerprint (`:unknown`) and a truncated fingerprint without the value (`:undecidable`) answer 200 with their own messages, nothing
   written; a truncated fingerprint that contains the value is `:ok`.
5. The X2-1 universal-value refusal and the empty-value refusal run BEFORE the check and keep their messages; the gate (fetch metadata, marker, click
   proof) runs before everything as before.
6. The matching is exact and case sensitive and path scoped: with a path `realm_access.roles` a value that exists only under `name` is refused;
   without a path any string value counts (as the admin gate does); a string claim value, a list member and a nested value all count.
7. The page shows the configured claim path (or the any-claim text) and the hint about the value being in the token of the person who saves; no
   override control exists.
8. Documentation: ADR-033 (SO10 addendum), 07-deployment (role mapping row, recovery, manual verification group D), 11-risks, follow-ups (`dg` closed).
9. The bootstrap wizard and the rpc `reset_admin_group_claim/1` are unchanged.

## Out of scope

The audit atomicity of the mappings (story `admin-config-audit-atomic`, `dh`), other admin forms (`de`), an override checkbox (D5).
