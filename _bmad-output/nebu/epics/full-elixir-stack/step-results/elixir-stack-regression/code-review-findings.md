# Code Review — `elixir-stack-regression` (re-review, FIX NOW change)

- **Date:** 2026-06-17
- **Scope:** the regression-gate parity fix only — `router/protected.ex` send handler + its new unit test.
- **Reviewer model:** opus (fresh context)

## VERDICT: CLEAN (0 findings)

### Correctness
The guard `if conn.assigns[:json_parse_error] == true` sits at the top of the send handler, before
`body_params/1` and before any `Core.SendEventRequest`/`call_core`. `JsonBody` (router.ex:20) runs before
`:match`/`:dispatch`, so the flag is reliably assigned by the time the Protected sub-router runs. Malformed
body → `error(conn, 400, "M_BAD_JSON", ...)` → standard Matrix envelope (matrix.ex:94). Happy path untouched
(a valid body never sets the flag; strict `== true` treats the unset `nil` case as the `else` branch). No
happy-path regression.

### Consistency
Mirrors the typing sibling (`protected.ex:260`, `M_BAD_JSON`) and uses the same shared `error/4` helper as
login (which uses `M_NOT_JSON`). The errcode difference is intentional and matches the Go-parity contract.

### Test quality
New test drives the real `NebuHttp.Router.call/2` (full pipeline incl. JsonBody/OidcPlug), uses a real RS256
Bearer (no auth shortcut), needs no DB (guard fires before any room/core lookup), sends a genuine malformed
body, and asserts deterministically on `400` + `M_BAD_JSON`. `try/rescue ParseError → flunk` mirrors the
established login test and makes a 500-class regression explicit. Fails pre-fix, passes post-fix → proves the AC.

No new MAJOR/CRITICAL introduced. ADR-018 respected (no SQL/schema/service-layer changes).
