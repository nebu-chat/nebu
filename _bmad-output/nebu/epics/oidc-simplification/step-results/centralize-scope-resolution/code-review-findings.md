# Code Review Report — `centralize-scope-resolution` (epic `oidc-simplification`)

**Cycle:** 0 | **Diff:** staged changes, 14 files (+1460 / -394) | **Verdict: CLEAN — 0 MAJOR/CRITICAL, 3 INFO only.**

## Acceptance Criteria verification

| AC | Status |
|----|--------|
| AC1 (module + API shape) | PASS |
| AC2 (extends OidcConfig ETS/:pg cache) | PASS |
| AC3 (no cross-client offline_access leak) | PASS |
| AC4 (thin delegates, facade removed, no other caller) | PASS |
| AC5 (both controllers use the ONE validator) | PASS |
| AC6 (OIDC Scopes Law — full-diff grep swept, zero hardcoded literals) | PASS |
| AC7 (6 named suites green, seam names unchanged, new \z test) | PASS |

Both pre-dev test-review MAJORs confirmed resolved in the implementation (non-scope Nebu.Matrix
calls preserved in auth.ex; real ETS/:pg integration test genuinely exercises the extended cache).

## Findings (all INFO, non-blocking)

- **INFO-1**: `resolve_scope/1` splits extra-scopes on `" "` only (not `\s+`) — defense-in-depth
  gap only, both write paths already gate on `validate_scope_string/1`.
- **INFO-2**: `stringify_keys(changes)` computed twice in `db.ex` upsert_server_config/1 — pure
  micro-polish.
- **INFO-3**: RED-phase test narration comments in oidc_scopes_test.exs ship in present tense
  alongside the now-working GREEN implementation — documentation-only, no assertion affected.

## Pipeline recommendation

No MAJOR/CRITICAL → no user decision required. Approved. Proceeding to security-review.
