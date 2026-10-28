---
story_id: admin-config-audit-atomic
title: "Atomic audit for the privileged server_config saves: SSO origin and scheme lists, claim and role mapping, OIDC scopes and refresh mode write the upsert and the audit row in ONE transaction (follow-up dh, SEC delta gate X2-4); SsoStore.peek_confirm reads the ETS table directly (follow-up di, X2-5)"
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

# Story: atomic audit for the config saves (follow-up `dh`)

Source: follow-ups row `dh` (Kassandra L-2 of admin-config-privileged-forms-sweep), X2-4 and X2-5 of the SEC delta gate admin-switch (rows `dh` / `di`),
the `dd` seams. The pattern is `Nebu.OAuth.SwitchStore` (story admin-oauth-switch, ADR-033 AS7): upsert and audit row in one transaction.

## Story

As a compliance officer I want every change of a privileged `server_config` setting (who is an administrator, how users are identified, which
redirect targets are trusted, which claims and scopes are requested) to be audited atomically, so that an audit writer that fails can never
leave an authority change without its row (and an audit row never describes a change that did not happen), without ever making a roll-back or an
emergency reset depend on a working audit table.

## Decisions

- **D1 (one transaction).** `Nebu.Admin.DB.save_config_audited(changes, opts)` runs the upserts of `changes` and the audit function in ONE
  `Repo.transaction/1` (the audit writer's own `Repo.transaction/1` nests: the carve-out pattern of the OAuth switch and the client decisions). Options:
  `:audit` (0-arity, `:ok | {:error, reason}`, a raise counts as failed; required), `:unaudited_ok` (default false). Results:
  `{:ok, %{audited: true}}`, `{:ok, %{audited: false}}` (only with `unaudited_ok: true`: the transaction is retried ONCE without the audit function after a
  failed audit, one value-free ERROR), `{:error, {:audit, reason}}` (nothing persisted), `{:error, reason}`. The cache invalidations and refreshes that
  `upsert_server_config/1` does after the writes (claim cache, OIDC scope cache, log policy cache) run AFTER the commit, once, for the changed keys
  (one shared function, `upsert_server_config/1` keeps its behaviour). Test seam (test builds only, compile-guarded): `:nebu_http, :admin_config_tx`, a
  2-arity `fn changes, audit -> :ok | {:error, term}` that replaces the transaction.
- **D2 (the audit is mandatory unless the change is a way back).** Per form (the Kill-Switch principle of AS7: a roll-back or reset must never hang on a
  broken audit table; an authority change must never be unaudited):

  | Form | audit failure | Why |
  |---|---|---|
  | role mapping, claim mapping | the save is REFUSED (nothing written) | authority / identity changes; the operator's way back without the UI exists (`reset_admin_group_claim/1`) or is SQL (claim mapping) |
  | SSO origin list, SSO scheme list | refused when the new list is NOT a subset of the stored list (a widening: a new redirect sink for a `loginToken`); applied unaudited when it is a subset (narrowing, clearing = the roll-back) | widening trust needs its row, narrowing is the way back |
  | OIDC scopes | refused unless every changed key's new scope set is a subset of the stored one (clearing included: the way out of a scope that breaks the IdP sign-in) | extra scopes widen the claim set (X2-2) |
  | OIDC refresh mode | applied unaudited only when every changed key goes to `online` or stays as stored; `offline` is refused | `offline` adds `offline_access` (a refresh token that outlives the IdP session, SEC review L-2); `online` is the way out of a sign-in lock-out |

  Subset = every token of the new value (comma separated for origins and schemes, case-insensitive for schemes; space separated for scopes) is a token of the
  stored value; an unreadable stored value counts as the empty set (so nothing is a subset of it except the empty value).
- **D3 (what the admin sees).** Refused: nothing is written, the marker (marker forms) is kept, the flash (role `alert`) says "<form> not saved: the audit entry
  could not be written, so nothing was changed. Try again; if it persists, ask the operator to check the database and the server log." Saved without its row (the
  roll-back paths): the marker is consumed (the write happened), the flash says "... saved, but the audit entry could not be written. Check the database and the
  server log." and one value-free ERROR is logged naming the form and the changed keys, never a value or the actor. A missing actor counts as a failed audit.
- **D4 (no second mechanism).** The controllers call `Nebu.Admin.OAuthAdminHelpers.save_config_audited/3` (actor, audit closure, flash mapping inputs);
  the gate, the marker and the page rules are unchanged. `audit_config_change/5` (after-the-save audit) and the origins' private writer are removed.
- **D5 (seams, follow-up `dd`).** The per-form writer seams (`:admin_config_*_writer`) and `:admin_server_config_reader` are read only inside
  `if Mix.env() == :test` blocks (a stray `Application.put_env` in a release can never replace the write or the reader).
- **D6 (X2-5 / `di`, small and safe).** `Nebu.Matrix.SsoStore.peek_confirm/1` reads the (now named, `:protected`, `read_concurrency`) ETS table directly
  instead of asking the node-local GenServer: the confirmation page's per-request lookup is no longer queued behind `put_state`, the loginToken mint and the
  `/login` redemption of every legacy SSO user, so a flood of well-formed random cookies cannot delay them through this call. Writes, `pop_confirm` and the
  cluster replication stay in the process. A missing table (store not started) answers `:error`. The stateless MAC cookie variant of `di` stays a follow-up.
- **D7 (SIEM).** A filter on `sso_redirect_origins_changed` must also watch `oauth_switch_changed` (the issuer origin is a legacy-SSO trust source, X2-4);
  documented in 07-deployment.

## Acceptance Criteria

1. `Nebu.Admin.DB.save_config_audited/2`: all upserts and the audit function in one transaction (the audit runs on the transaction's connection); a failing
   upsert or audit rolls back everything (real database); the result shapes of D1; the retry only with `unaudited_ok`; no audit function is `{:error, :audit_required}`;
   empty / non-string changes are `{:error, :invalid_changes}`; the cache invalidations run after the commit and only on success.
2. The six forms use it (action, target and metadata as before): role mapping, claim mapping, SSO origins, SSO schemes, OIDC scopes, OIDC refresh mode.
3. Audit failure per D2: role / claim mapping refused; origins and schemes refused for a widening and applied unaudited for a subset (incl. clearing); scopes
   refused unless narrowing; refresh mode to online applied unaudited, to offline refused; flashes and marker behaviour per D3; a missing actor is a failed audit.
4. Success path unchanged for the admin: same flashes, redirects, marker consumption, audit rows (one per save, same metadata).
5. The seams of D5 are compile-guarded (static test).
6. `SsoStore.peek_confirm/1` answers from the ETS table without a GenServer call (works while the store process is suspended / busy); an expired or unknown key
   and a missing table are `:error`; `put_confirm` / `pop_confirm` semantics unchanged.
7. Documentation: ADR-033 (SO10 / AS7 addendum with the table of D2), 07-deployment (policy, SIEM note), 11-risks, follow-ups (`dh`, `di`, `dd` partly), the
   `AuditWriter` moduledoc carve-out.
8. Real database test: the atomicity of each form's save (an audit that fails leaves the old value; a successful save leaves value and row).

## UI / e2e note (test-review MAJOR-2, waiver)

`ui: true` only because two flash texts are new ("<form> not saved: the audit entry could not be written ..." and "... saved, but the audit entry could not be written ...");
both need an unwritable audit table, which no e2e flow can produce without breaking the stack. The happy path of every form is unchanged and covered by
the existing features (`role-mapping.feature`, `claim-mapping.feature`, the SSO origin / scheme and refresh mode features). No new e2e scenario; the flashes are
unit-tested (role `alert`, the typed value kept) and reviewed by the UX gate. ADR-033 gets the heading `SO10 addendum: atomic audit of the config saves`.

## Out of scope

Other admin forms (`de`), a stateless MAC binding cookie for the SSO confirmation (rest of `di`), compile-guarding seams outside the six forms.
