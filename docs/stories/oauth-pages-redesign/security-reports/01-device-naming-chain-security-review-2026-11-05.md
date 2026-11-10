## Security Review — 01-device-naming-chain

**Diff scope:** staged server/e2e/docs changes: OAuth Allow page device-name chain (DeviceName.derive/plan/typed, consent POST `device_name`, remembered-Allow gating, FormPost free-text param, oauth_codes.device_display_name migration 000062, token endpoint hand-off).
**Date:** 2026-11-05

### Prescan candidates
The candidates file listed no grep-level candidates (header only). Manual review focused on authorisation, trust boundaries and output encoding.

### Checked and found sound
- **XSS:** the derived/existing name is rendered via `cut_80/1` -> `Plug.HTML.html_escape` (escapes quotes too); the input never echoes the typed value; `name/1` additionally strips Cc/Cf/Zl/Zp before escaping.
- **Forged `device_name`:** `typed_name/4` only uses the typed value when `DeviceName.plan/3` returns `:ask`; it never overrides a derived or an existing device name. `oauth_session_store` writes the default only while `display_name` is NULL.
- **Input handling:** `FormPost` relaxes the control-char check only for the named `device_name` param (valid UTF-8 still required); value is cut to 512 code points before any regex, then sanitised by `clean/1` (tags, control/format/private-use/invisible chars removed, 64 code-point cap); re-sanitised at the token endpoint (`for_client/3` -> `typed/1`). Body bounded by the existing form parser limit.
- **CSRF / origin:** the 422 re-show path runs only after parse, origin (BrowserPost), cookie and CSRF checks; nothing is consumed; consent POST remains rate-limited per IP.
- **Remembered Allow:** `device_named_or_derivable?/2` fails closed (unreadable / non-approved client -> page is shown).
- **Peek-then-consume race:** a client-metadata change between `name_missing?` and `consume` only falls back to the generic "OAuth client (<suffix>)" name — no security impact.
- **Logging:** the typed name is not logged (Logger lines only carry client_id/user_id/device_id).
- **Migration 000062:** nullable TEXT column on oauth_codes, covered by existing grants/row policies; short-lived data.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/priv/migrations/000062_oauth_codes_device_display_name.up.sql:7 | No DB-level length bound on `device_display_name`; the 64-char limit lives only in application code | Optional: `CHECK (char_length(device_display_name) <= 64)` as defense in depth |

### Detail

**Finding #1 — Unbounded column** [LOW]
The application sanitises and caps the typed name before INSERT, and the token endpoint re-sanitises it, so there is no exploit path. A CHECK constraint would keep the invariant if another writer is added later.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 1 — advisory

**Verdict:** APPROVED
