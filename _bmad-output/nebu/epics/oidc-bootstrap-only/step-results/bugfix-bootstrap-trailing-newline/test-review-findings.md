# Test Review — bugfix-bootstrap-trailing-newline

## Verdict: CLEAN (0 MAJOR, 0 MINOR)

## Existing Failing Test (bootstrap_live_test.exs:329)

```
test "scope with trailing newline is rejected (\\z anchor regression)"
```

- AC covered: \\z anchor correctly rejects trailing newlines
- Test posts "profile email\n" as matrix_oidc_extra_scopes
- Expects 200 (rejection) — correctly documents bug
- Failure message: "Trailing newline must be rejected (\\z required, not $); got 302"
- Test is well-structured, no changes needed

## Root Cause (confirmed)

`bootstrap_controller.ex:165` — `String.trim(params["matrix_oidc_extra_scopes"] || "")` removes `\n` before
`validate_scope_string/1` is called. The regex never sees the trailing newline.

`config_controller.ex` already implements the correct pattern: validates raw params first, trims only on save.

## Fix Scope

Single-file fix in `server/lib/nebu/admin/bootstrap_controller.ex`:
- Remove `String.trim` from lines 165–166 (the local variables used only for validation)
- `save_claim_mapping/1` already calls `String.trim(params[key] || "")` independently (line 225), so storage behavior is unchanged
