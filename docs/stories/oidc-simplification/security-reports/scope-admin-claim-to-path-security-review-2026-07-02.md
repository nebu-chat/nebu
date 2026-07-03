## Security Review — scope-admin-claim-to-path (epic oidc-simplification)

**Diff scope:** staged diff (`git diff --staged`) — path-scoped admin-group-claim gate.
Key files: `server/lib/nebu/web/oidc_claims.ex` (new `claim_at_path_matches?/3`),
`server/lib/nebu/admin/auth.ex` (`admin_claim?/1` path-scoped + fallback; `bootstrap_confirm_claim/2`
mandatory-path enforcement; `resolve_selection/1`; `select_claim_html/1`),
`server/priv/migrations/000016_config_admin_group_claim_path.{up,down}.sql`, and the accompanying
unit / AC4-AC5 regression / migration-content tests.
**Reviewer:** Kassandra (SEC Gate 1)
**Date:** 2026-07-02

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| A1 | LOW (advisory, pre-existing, out of diff scope) | `server/lib/nebu/admin/role_mapping_controller.ex:46` | Post-bootstrap Role-Mapping editor writes `admin_group_claim` (value) alone, never `admin_group_claim_path`. An admin changing the marker value leaves the stale path pointing where the old value lived → value/path decoupling. | Fails CLOSED (path resolves, new value absent → no admin); cannot grant admin to a non-admin. Recommend: have the editor either co-edit the path or refuse a value not present at the configured path. Track as follow-up. |

No CRITICAL, HIGH, or MEDIUM findings.

### Detail — Special-focus verification (a)–(d)

**(a) AC4 provably closes the risk — CONFIRMED.**
The regression tests genuinely exercise the vulnerable scenario: marker value `"instance_admin"`
present under a DIFFERENT key (`name`) than the configured path (`groups`), with `groups: ["user"]`.
`admin_oidc_login_test.exs` (AC4) asserts `refute Auth.admin_claim?(claims)`; the unit test
`oidc_claims_test.exs` ("does NOT match when the target appears elsewhere in the tree but not at the
configured path") asserts `refute OidcClaims.claim_at_path_matches?(%{"groups"=>["user"],
"name"=>"instance_admin"}, "groups", "instance_admin")`. The pre-story "accepted risk" test was
correctly re-labelled to pin the FALLBACK branch (no path configured), not "the" behavior. AC5
proves a real admin (`groups: ["instance_admin"]`) stays admin on BOTH the path-scoped and the
fallback branch. The fix mechanism is sound: `claim_at_path_matches?/3` resolves ONLY the operator-
selected dot-path, then matches the marker against just that subtree; a hit elsewhere in the tree
does not count. Recursing arbitrarily deep *below* the selected path is safe — the subtree under an
operator-chosen path is IdP-managed (same accepted-risk class as prior claim-scanner traversal
widening; the path is the allowlist).

**(b) Fallback introduces no privesc + M1 fix is real, sound, unbypassable — CONFIRMED.**
The fallback branch (AC3.2) is byte-for-byte the pre-story `claim_value_matches?/2` any-key scan —
unchanged behavior, reachable only for deployments bootstrapped before this story (no
`admin_group_claim_path` row). It logs at INFO (no PII) per AC3.3. The M1 fix is real:
`resolve_selection/1` returns `{nil, nil}` (never a value paired with a nil path) for any
legacy/malformed/undecodable submission; `is_nil(selected_path)` is checked in the `cond` at
auth.ex:822 BEFORE any completion. It cannot be bypassed:
- Bootstrap completes exactly once — guarded by `bootstrap_completed?/0` (cond line 789).
- The endpoint (`POST /admin/bootstrap/select-claim`) is CSRF-protected and is DELIBERATELY excluded
  from the test-only CSRF bypass (`@csrf_bypass_excluded_paths`, router.ex:110) — so `protect_from_forgery`
  always runs, even in tests. Forged/replayed cross-site POST is blocked.
- Requires a valid `bootstrap_sub` in the server-side draft (set by the OIDC callback) — cond line 796.
- `not MapSet.member?(discovered_claim_pairs(draft), {selected_path, selected})` (line 848) enforces
  the submitted {path, value} pair is one actually discovered in the verified token — an attacker
  cannot pair an unrelated valid path with an unrelated valid value.
- No race: completion is a single guarded `Nebu.Repo.transaction`, idempotent ON CONFLICT upsert.
- Belt-and-suspenders: `do_complete_bootstrap/3` (line 1790) itself refuses to persist an empty-string
  path, protecting any future/test-only caller that bypasses the confirm gate.

**(c) No new hardcoded denylist — CONFIRMED.**
Allowlist-of-selected-path throughout. The gate scopes to the ONE operator-selected path; the
discovered-pair membership check is an allowlist of `{path, value}` pairs from the verified token.
No claim-key denylist was introduced (the SEC NOTE explicitly cites the prior rejection of a denylist
as unsafe). A legitimately-configured admin_group_claim cannot be silently broken by a denylist
because none exists.

**(d) Standard checks — CONFIRMED clean.**
- XSS in the picker: `select_claim_html/1` interpolates the JSON-encoded choice via
  `esc/1` (`Phoenix.HTML.html_escape |> safe_to_string`) into the radio `value` attribute; `key` and
  `value` in the label are likewise escaped. IdP-influenceable claim content cannot inject markup.
- `admin_group_claim_choice` JSON decode: `Jason.decode` with default STRING keys (matched as
  `%{"value" => ..., "path" => ...}`) — no atom injection, no atom-table exhaustion.
- Discovered-pair membership check (auth.ex:848) prevents pairing an unrelated valid path with an
  unrelated valid value — present, unchanged, sound.
- Migration 000016: pure RLS `config_update_mutable` policy widening (adds `admin_group_claim_path`
  to the `USING (key IN (...))` allowlist), no schema change, no injection vector; `.down.sql`
  correctly omits the key; migration-content test asserts both directions; `release_test.exs`
  version count bumped to include 16.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 1 (A1 — pre-existing value/path decoupling in Role-Mapping editor; fails closed, out of diff scope, follow-up)

**Verdict:** APPROVED — CLEAN.

### Memory update

Verdict is CLEAN, so per the story's Definition-of-Done ("Kassandra aktualisiert ihr Gedächtnis
selbst.") the previously-accepted "admin_claim?/1 any-key claim-value scan" MEDIUM risk (from
bugfix-unify-admin-matrix-oidc-identity and bugfix-nested-oidc-claim-support, both 2026-07-01) is
marked RESOLVED by this story in the Kassandra sanctum (`_bmad/memory/nebu-agent-kassandra/`).
The cross-cutting agent-memory dir was also updated with the resolution and the LOW A1 follow-up.
