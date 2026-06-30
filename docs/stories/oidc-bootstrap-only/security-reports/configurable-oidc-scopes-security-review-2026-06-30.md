# Security Review — configurable-oidc-scopes (Epic: oidc-bootstrap-only)

**Reviewer:** Kassandra (Nebu adversarial security reviewer)
**Date:** 2026-06-30
**Diff scope:** staged (`git diff --staged`)
**Framework:** OWASP Top 10, STRIDE, CWE Top 25
**Verdict:** APPROVED — no CRITICAL / no HIGH. 1 MEDIUM, 2 LOW, 1 INFO (all advisory, non-blocking).

---

## Diff scope reviewed

| File | Surface |
|------|---------|
| `server/priv/migrations/000013_config_oidc_scopes_mutable.{up,down}.sql` | RLS UPDATE allowlist for two new scope keys |
| `server/lib/nebu/matrix/sso_login.ex` | `scope_list/0`, `matrix_extra_scopes/0`, `default_matrix_extra_scopes/0` (read path) |
| `server/lib/nebu/admin/auth.ex` | `admin_oidc_scope/0`, `admin_extra_scopes/0`, `default_admin_extra_scopes/0`, bootstrap scope-promotion block |
| `server/lib/nebu/admin/bootstrap_controller.ex` | `save_step3/2`, `validate_scope_string/1`, `save_claim_mapping/1` (write path 1) |
| `server/lib/nebu/admin/config_controller.ex` | `save_scopes/2`, `persist_scopes/1` (write path 2) |
| `server/lib/nebu/admin/{config_html.ex, router.ex}` | output helper + route registration |
| `server/lib/nebu/admin/templates/{bootstrap,config}/index.html.heex` | scope input fields |

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | bootstrap_controller.ex:`validate_scope_string`; auth.ex (promotion); config_controller.ex:`save_scopes` | CWE-20 — regex anchor `$` accepts a trailing newline; `email\n` passes the whitelist | Use `\z` (absolute end) instead of `$`, OR reject control chars / `String.contains?(s, ["\n","\r"])` before the match |
| F-2 | LOW | auth.ex `do_complete_bootstrap` scope-promotion `Logger.warning(... #{inspect(v)})` | CWE-117 (mitigated) — unvalidated operator draft value written to logs | Keep `inspect/1` (already neutralises CRLF); optionally truncate length. No exposure of secrets. |
| F-3 | LOW | migration 000013 up/down | RLS UPDATE policy re-created with `USING` only, no `WITH CHECK` (carried from 000007; 000001 had both) | Add matching `WITH CHECK (key IN (...))` for clarity / defence-in-depth; functionally PG defaults check to USING so key cannot escape allowlist |
| F-4 | INFO | sso_login.ex:474 comment | Comment "a stray server_config value can never inject an arbitrary scope" is now FALSE for the new scope path (scopes ARE read raw from server_config) | Update the comment to scope it to refresh-mode only |

---

## Detail

### F-1 — Trailing-newline bypasses the scope whitelist [MEDIUM] CWE-20

All three write boundaries validate each space-split scope token against
`~r/^[a-zA-Z0-9_:.\-]+$/`. In Elixir/PCRE the `$` anchor matches at the very end
of the string **or immediately before a single trailing `\n`** (PCRE default — `$`
behaves like `\Z`, not `\z`). Verified empirically:

```
String.match?("email\n", ~r/^[a-zA-Z0-9_:.\-]+$/)  => true   # BYPASS
String.match?("email\ninjected", re)               => false  # embedded \n rejected (good)
String.match?("email\r", re)                        => false  # CR rejected (good)
String.match?("email\tfoo", re)                     => false  # tab rejected (good)
```

`String.split(value, " ", trim: true)` splits on space only, NOT on `\n`. So the
stored value `"profile email\n"` splits to `["profile", "email\n"]` — and `email\n`
passes. The trailing newline survives into the read path
(`scope_list/0` / `admin_oidc_scope/0`), which re-joins tokens with a space.

**Why it is NOT HIGH:** the resulting scope string is placed into the IdP
authorization request via `URI.encode_query/1` (sso_login.ex:123, auth.ex:218/341/759),
which percent-encodes `\n` to `%0A`. There is therefore **no CRLF / header-injection,
no request smuggling, and no open-redirect** into the IdP request — the worst real
outcome is a malformed `scope=...%0A` parameter the IdP will ignore or reject. The
injection vectors named in story AC14 (scope injection, SSRF, scope elevation) remain
closed: the IdP only releases scopes its client config permits, scope names are not URLs,
and scopes are read live (no caching).

**Why it still matters:** the regex does not enforce what its author and the AC3
acceptance test believe it enforces. The test suite gives FALSE CONFIDENCE here —
`config_scopes_test.exs:167` and `bootstrap_live_test.exs:290` only exercise an
*embedded* newline (`"profile\nemail"`, which correctly fails); neither covers a
*trailing* newline (`"profile email\n"`, which passes). A future change that routes
the scope string anywhere other than `URI.encode_query` (e.g. a log line built by
string concat, a header, a downstream HTTP call) would inherit a live CRLF-injection
primitive with no validation backstop.

**Remediation:** replace `$` with `\z` in all three regexes:
`~r/^[a-zA-Z0-9_:.\-]+\z/` and add a regression test with a trailing-newline payload.

### F-2 — Unvalidated draft scope value logged at WARN [LOW] CWE-117 (mitigated)

`auth.ex` `do_complete_bootstrap` logs the rejected draft on the invalid branch:
`Logger.warning("...invalid scope token in draft value: #{inspect(v)}")`. The value is
operator-controlled and, at this point, unvalidated. `inspect/1` escapes `\n`/`\r` to
literal `\n`/`\r` in the output, so **log injection is neutralised** and scope names
are operator-config, not secrets (no OIDC-metadata leak of the kind AC14 warns about).
Advisory only: consider truncating very long values. No change required to ship.

### F-3 — RLS UPDATE policy has no WITH CHECK [LOW]

Migration 000013 re-creates `config_update_mutable` with `USING (key IN (...))` and no
`WITH CHECK`. The original 000001 policy had BOTH clauses; the immediate predecessor
000007 already dropped `WITH CHECK`, so 000013 is **consistent with its predecessor —
not a regression introduced by this story**. Functionally, when `WITH CHECK` is absent
PostgreSQL applies the `USING` expression as the check, so the `key` column still cannot
be mutated outside the allowlist — there is no row-escape and no key-immutability break
(contrast MEMORY pattern #24 / migration 000045). Adding an explicit matching
`WITH CHECK (key IN (...))` is a clarity / defence-in-depth improvement, not a fix.
The two new keys (`matrix_oidc_extra_scopes`, `admin_oidc_extra_scopes`) are correctly
scoped by key — no scope-elevation via server_config tampering (STRIDE: EoP) is opened.

### F-4 — Stale invariant comment [INFO]

sso_login.ex:474 still reads "so a stray server_config value can never inject an
arbitrary scope" — written for the refresh-mode resolver (which collapses any non-"online"
value to "offline"). That guarantee no longer holds for the new scope path, where the
stored value is returned RAW (`default_matrix_extra_scopes/0` returns the DB value with no
validation at read time). The actual control is now the write-boundary whitelist (F-1).
Scope the comment to refresh-mode to avoid misleading a future auditor.

---

## Checks performed — CLEAN

- **Whitelist consistency (AC14):** identical regex `^[a-zA-Z0-9_:.\-]+$` at all 3 write
  sites (bootstrap_controller, auth.ex promotion, config_controller). Per-token validation
  after space-split. CLEAN except the shared trailing-`\n` anchor gap (F-1).
- **Default-scope silent-drop (AC14 focus):** matrix default `"profile email"`, admin
  default `"profile email groups"` byte-identical across all 4 sites. Empty submitted value
  re-defaults on WRITE (config_controller `if raw == "", do: @scope_defaults[key]`); empty
  stored value re-defaults on READ. `groups` is removed ONLY by explicit operator action,
  which the story documents. No silent drop.
- **XSS (CWE-79):** both HEEx templates interpolate stored values via `value={...}`
  attribute syntax — HEEx auto-escapes `" < > &` in attribute context. No breakout. CSP is
  `script-src 'self'` (no unsafe-inline) — XSS lever closed (MEMORY #56/#72).
- **CSRF:** config form injects `_csrf_token`; `/admin/config/scopes` is under
  `pipe_through :browser` → `protect_from_forgery`. Bootstrap step-3 is intentionally
  pre-auth (first-time setup) but still CSRF-protected in production.
- **AuthZ:** `ConfigController` has module-level `plug Nebu.Admin.Auth, :require_admin`
  → `save_scopes` is admin-gated. Bootstrap step-3 is locked by `:bootstrap_gate` once
  bootstrap completes.
- **SQL injection:** all queries parameterised / static (`SELECT value FROM server_config
  WHERE key = '...'` are constant string keys; writes via `upsert_server_config`). CLEAN.
- **SSRF / scope-elevation / replay (AC14 1–4):** scope names are not URLs; scopes read
  LIVE per login (no cache → no replay); IdP enforces its own per-client scope grants.
- **Output encoding to IdP:** `URI.encode_query/1` on both Matrix and admin authorize URLs
  — neutralises F-1 into a percent-encoded no-op.
- **Migration:** forward-only, idempotent (`DROP POLICY IF EXISTS`), inline SQL (ADR-018),
  down-migration cleanly reverts to the predecessor allowlist (existing rows unaffected;
  only future UPDATEs of the two keys are blocked post-rollback).

---

## Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 1 (F-1 — advisory; URI-encoding neutralises practical injection; fix `$`→`\z` + test)
LOW: 2 (F-2 log value, F-3 missing WITH CHECK)
INFO: 1 (F-4 stale comment)

**Verdict: APPROVED.** No blocking findings. Recommend a single hardening follow-up to
change `$`→`\z` in the three scope-validation regexes and add a trailing-newline regression
test (closes F-1 and corrects the false-confidence test gap).
