# Security Review — centralize-scope-resolution (epic oidc-simplification)

**Diff scope:** `git diff --staged` — introduces `Nebu.Web.OidcScopes` as the single source of
OIDC scope resolution + validation; converts `Nebu.Matrix.SsoLogin.scope_list/0` and
`Nebu.Admin.Auth.admin_oidc_scope/0` to thin delegates; removes `union_scopes/2` and the
`Nebu.Matrix.matrix_oidc_extra_scopes/0` Public-API facade; routes `bootstrap_controller.ex` and
`config_controller.ex` through the ONE validator; extends `Nebu.Web.OidcConfig`'s ETS/`:pg` cache
with 4 scope/refresh-mode keys; adds a read-side cache-refresh hook to
`Nebu.Admin.DB.upsert_server_config/1`.
**Date:** 2026-07-01
**Reviewer:** Kassandra (nebu-agent-kassandra), SEC Gate 1 — story-level, security_review: required
**Base files reviewed:** `oidc_scopes.ex` (new), `sso_login.ex`, `admin/auth.ex`, `matrix.ex`,
`admin/db.ex`, `web/oidc_config.ex`, `bootstrap_controller.ex`, `config_controller.ex`,
`oidc_scopes_test.exs` (new), architecture doc `08-concepts.md`.

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No CRITICAL / HIGH / MEDIUM / LOW security findings | — |
| I-1 | INFO | `admin/auth.ex:272` (docstring) | Stale doc comment still asserts `admin_oidc_scope/0` "now folds in the Matrix flow's extra scopes" — the fold code was removed this story (AC3/AC4). Documentation-only inaccuracy; the described behaviour no longer executes. Not a security defect. | Update the `put_current_user/2` docstring to reflect that each client resolves its own scopes independently (no cross-client fold). |

## Detail

### Focus area 1 — `validate_scope_string/1` as the query-string injection boundary — CLEAN

The sole operator-input gate before a scope string reaches `server_config` and is later echoed into
an OAuth authorization-request `scope` parameter. Verified:

- **`\z` (not `$`) is genuinely used everywhere the validator pattern appears in the diff.**
  `oidc_scopes.ex:63` defines `@scope_regex ~r/^[a-zA-Z0-9_:.\-]+\z/`. The two former local regex
  copies in `bootstrap_controller.ex` and `config_controller.ex` are DELETED (not re-anchored copies)
  — both now call `Nebu.Web.OidcScopes.validate_scope_string/1`. `admin/auth.ex`'s bootstrap-promotion
  path (line ~1516) also switched from its inline `~r/^[a-zA-Z0-9_:.\-]+\z/` to the shared validator.
  Zero `$/`-anchored scope validators remain in the diff. This directly closes recurring pattern #76
  (the configurable-oidc-scopes trailing-`\n` bypass): Elixir/PCRE `$` matches immediately before a
  final `\n`, so `"email\n"` passed under `$`; `\z` matches only the absolute end and rejects it.
- **Per-token character allowlist closes the injection alphabet.** After `String.split(_, " ",
  trim: true)`, every token must match `[a-zA-Z0-9_:.\-]+` end-to-end. This rejects `&`, `=`, `%`,
  `#`, `?`, space (already the split delimiter), and all control characters including `\r`, `\n`,
  `\t` — the full CRLF/parameter-smuggling alphabet for the `scope` query param.
- **Defence-in-depth at the sink confirmed.** Even absent the allowlist, the sink is
  `URI.encode_query/1` (`sso_login.ex:124`, `admin/auth.ex:252/392/817`) which percent-encodes,
  so a hypothetical bypass would emit `%0A`/`%26` rather than a raw control/reserved char — no
  CRLF header injection, no open redirect, no parameter smuggling. Two independent controls
  (validate-on-write + encode-on-emit); either alone suffices, both present.
- **Empty string is valid by design** (operator may configure no extra scopes → `"openid"`-only is
  a legitimate outcome). Correct: not a bypass, since an empty token set produces no tokens to inject.

### Focus area 2 — server_config write path / RLS — CLEAN (no new write capability)

`upsert_server_config/1`'s `INSERT ... ON CONFLICT (key) DO UPDATE` SQL is byte-unchanged. The only
addition is a **read-side** side effect AFTER the write commits: when the change touches any of the 4
`@scope_cache_keys`, `refresh_oidc_scope_cache/0` fires `Nebu.Web.OidcConfig.refresh/0` (guarded by
`Process.whereis/1`). No new write path, no new mutable key, no widening of what a caller can persist.
The `config_update_mutable` RLS allowlist (migrations 000007/000013) still gates the identical write
statement it always did — the 4 scope keys were already writable via this same path in
configurable-oidc-scopes. No privilege escalation, no RLS bypass.

### Focus area 3 — AC3 cross-client isolation as a security property — CLEAN (privilege graft eliminated)

The prior finding (bugfix-unify-admin-matrix-oidc-identity introduced
`union_scopes(admin_extra_scopes(), Nebu.Matrix.matrix_oidc_extra_scopes())`) could silently graft
Matrix's `offline_access` (a long-lived refresh capability) onto the higher-trust Admin OIDC client
without explicit operator intent. Verified eliminated with no residual path:

- `union_scopes/2` is DELETED; `resolve_scope/1` reads only `extra_scopes(client)` +
  `refresh_mode(client)` for the ONE client passed in — no fold, no union, no cross-read.
- `offline_access` is appended EXCLUSIVELY when that client's OWN `*_refresh_mode == "offline"`
  (`oidc_scopes.ex:80`). Matrix defaults to `"offline"`, Admin to `"online"` — parity with prior
  per-domain behaviour; the enum-collapse (`case reader.() do "online"->... ; _->"offline"` for
  matrix, mirror for admin) means a stray/junk server_config value cannot inject an arbitrary scope,
  only collapse to the client's historical default.
- **No shared-key collision:** the 4 cache keys are distinct (`matrix_oidc_*` vs `admin_oidc_*`) in
  the same ETS map; `get_scopes/0` returns all four under separate map keys and each
  `extra_scopes/refresh_mode` clause reads only its own. No `Application.env` seam-name collision:
  the 4 seams (`:matrix_oidc_extra_scopes_reader`, `:matrix_oidc_refresh_mode_reader`,
  `:admin_oidc_extra_scopes_reader`, `:admin_oidc_refresh_mode_reader`) are per-client-distinct.
- Test suite pins both directions: Matrix-configured `offline_access` does NOT appear in the admin
  scope while admin stays online (test ~line 203); admin-configured `offline_access` does NOT leak
  into Matrix (~line 225); admin gets `offline_access` ONLY via its own offline mode (~line 235); a
  regression test asserts the `union_scopes/2` fold is gone (~line 524). This is a genuine backstop,
  not cosmetic.

### Focus area 4 — ADR-020 Public-API boundary — CLEAN

The `Nebu.Matrix.matrix_oidc_extra_scopes/0` facade (`matrix.ex`) is fully removed. A repo-wide grep
of `server/lib/` for `matrix_oidc_extra_scopes` (function), `union_scopes`, and `matrix_extra_scopes`
finds ZERO remaining function callers — all surviving hits are `server_config` KEY STRINGS (data),
docstrings, test-seam names, and HEEx template field names. Admin no longer reaches into the Matrix
domain for scopes directly or indirectly. Both `:matrix` and `:admin` now read via
`Nebu.Web.OidcConfig.get_scopes/0`, which lives in the shared `Nebu.Web` infrastructure namespace
(not the Matrix domain) — a legitimate shared-infra dependency, not a cross-domain reach. No new
coupling replaces the removed facade.

### Focus area 5 — AC6 OIDC Scopes Law as a security control — CLEAN (PII-claim leak backstop intact)

No hardcoded `"profile"`/`"email"`/`"groups"` scope literal exists in any added line
(full-diff grep of added lines returned empty). `resolve_scope/1` base is `["openid"]`; extras come
only from `server_config`. In `oidc_config.ex`, extra-scope values default to `""` (never
nil-to-hardcoded), refresh-mode values pass through raw so `OidcScopes` applies the per-client enum
default. `@empty_config` (used on ETS-miss / DB-error / cache-not-started) carries `nil` for all
scope keys → resolves to `"openid"` alone. This mechanically prevents an operator-uncontrolled
default that would leak PII claims into ID tokens without explicit operator consent.

### Focus area 6 — Standard sweep — CLEAN

- **AC2 cache / cluster-safety (ADR-020):** the 4 keys live in the SAME ETS table and SAME
  `do_refresh -> load_from_db -> :pg broadcast` path as issuer/audience/jwks_uri. No second
  node-local-only cache, no ad-hoc SQL in `OidcScopes` (it reads only via `OidcConfig.get_scopes/0`).
  The write-triggered `refresh/0` broadcasts cluster-wide, so an Admin-Config edit is visible on the
  next read on every node — the stale-multi-node failure mode AC2 targets is closed.
- **SQL injection:** the extended `load_from_db` `WHERE key IN (...)` uses a static literal key list
  (no interpolation); `upsert_server_config` remains fully parameterized (`$1/$2/$3`).
- **Audit immutability / compliance RSP:** no audit-log code path touched; scope resolution is a
  read/config-plumbing change, no `audit_log` writes added or removed.
- **Crypto:** N/A — no key material, hashing, or token signing touched.
- **Secret logging:** the one log line (`admin/auth.ex` bootstrap-promotion skip) logs `inspect(v)`
  of a REJECTED scope draft value on the invalid branch only — scope tokens are not secrets, and
  `inspect` neutralizes CRLF; unchanged from configurable-oidc-scopes (prior F-2 LOW, already
  assessed). No token/secret/PII newly logged.
- **XSS/CSRF:** unchanged — controllers reuse existing `require_admin` + `protect_from_forgery`;
  scope values echoed only into HEEx (auto-escaped) and into `URI.encode_query`.

## Summary

CRITICAL: 0 — no block
HIGH: 0 — no block
MEDIUM: 0
LOW: 0
INFO: 1 (I-1 stale docstring at `admin/auth.ex:272` — non-security, advisory)

**Verdict:** APPROVED / CLEAN

This story is a net security IMPROVEMENT: it consolidates four scattered scope validators into one
`\z`-anchored validator (closing recurring pattern #76 at the source), eliminates the cross-client
`offline_access` privilege-graft (a prior LOW finding), removes an ADR-020-adjacent facade, and adds
cluster-safe cache invalidation. The regression test suite specifically pins the `$`-vs-`\z`
distinction and both cross-client leak directions. No follow-up story required; I-1 is a
documentation cleanup that may ride any future touch of `auth.ex`.
