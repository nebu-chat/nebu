# Kassandra SEC Gate 1 — jwt-denylist-persistence

**Date:** 2026-06-23
**Epic:** fix-jwt-denylist-persistence
**Story:** jwt-denylist-persistence
**Reviewer:** Kassandra (nebu-agent-kassandra, headless mode)
**Diff scope:**
- `server/lib/nebu/web/token_denylist.ex` — ETS-as-cache + PostgreSQL persistent denylist
- `server/test/nebu/web/token_denylist_integration_test.exs` — integration + unit regression tests

---

## Findings

| # | Severity | Location | Finding | Status |
|---|----------|----------|---------|--------|
| F-1 | MEDIUM | `token_denylist.ex:122-123` | `rescue ArgumentError -> false` in `revoked?/2` wraps entire body incl. DB fallback — mirrors PATCH-1 pattern missed in `revoke/3` | **FIXED** |

---

## F-1 Detail — ArgumentError scope bypass in `revoked?/2`

**Before fix (problematic):**
```elixir
def revoked?(jti, token) do
  ensure_table()
  if revoked_key?(jti_key(jti)) or revoked_key?(hash_key(token)) do
    true
  else
    db_revoked_any?(jti, token)   # inside rescue scope
  end
rescue
  ArgumentError -> false          # catches ETS AND DB fallback
end
```

**Mechanism:** If `revoked_key?` raises `ArgumentError` (ETS table absent despite `ensure_table()`), the rescue fires immediately and returns `false` without calling `db_revoked_any?`. A token revoked before a restart, persisted in DB but absent from ETS, would pass the check — directly defeating the primary goal of this story.

**After fix (correct):**
```elixir
def revoked?(jti, token) do
  ensure_table()
  ets_result =
    try do
      revoked_key?(jti_key(jti)) or revoked_key?(hash_key(token))
    rescue
      ArgumentError -> false
    end

  if ets_result do
    true
  else
    db_revoked_any?(jti, token)   # always reached on ETS miss or ETS failure
  end
end
```

`db_revoked_any?` is now outside any rescue scope and is always called when `ets_result` is `false`.

---

## All-clean checks

| Check | Result |
|-------|--------|
| SQL injection — all queries parameterized | ✓ |
| Log content — hashes/keys only, no raw tokens | ✓ |
| `exp` source — from verified JWT `claims["exp"]` (is_integer guard) | ✓ |
| Key collision — ETS tuples vs DB strings, disjoint namespaces | ✓ |
| Double-lookup timing oracle — not exploitable for auth bypass | ✓ |
| `invalidated_tokens` no RLS — pre-existing, not introduced here | INFO |
| Integer overflow in `exp` — BIGINT range, normal timestamps safe | ✓ |

---

## Summary

```
CRITICAL: 0
HIGH:     0
MEDIUM:   1 (F-1) — FIXED before commit
LOW:      0

Verdict: APPROVED — F-1 fixed, no blockers, no open findings
```
