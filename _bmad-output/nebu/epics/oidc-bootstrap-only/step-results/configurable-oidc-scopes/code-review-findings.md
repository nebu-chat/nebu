# Code Review Findings — configurable-oidc-scopes

**Date:** 2026-06-30 | **Cycle:** 0 | **Agents:** Blind Hunter + Edge Case Hunter + Acceptance Auditor

## Summary

**0 MAJOR · 3 PATCH · 2 DEFER · 3 DISMISS**

Auto-cycle Zyklus 1: Dev agent fixes die 3 PATCH findings.

---

## PATCH Findings (dev agent muss fixen)

### P1 — Regex `*` → `+` in `config_controller.ex:68`

**File:** `server/lib/nebu/admin/config_controller.ex:68`
**Sources:** Blind Hunter (MINOR F2), Edge Case Hunter (MAJOR F1), Acceptance Auditor (MINOR F1)

**Problem:**
```elixir
if String.match?(s, ~r/^[a-zA-Z0-9_:.\-]*$/), do: [], else: [s]
```
Quantifier `*` erlaubt leere Strings als "gültig". `trim: true` beim Split verhindert das in der Praxis, aber semantisch falsch und inkonsistent mit `auth.ex:1403`:
```elixir
String.match?(&1, ~r/^[a-zA-Z0-9_:.\-]+$/)
```

**Fix:** `*` → `+`
```elixir
if String.match?(s, ~r/^[a-zA-Z0-9_:.\-]+$/), do: [], else: [s]
```

---

### P2 — `save_scopes/2` persistiert `""` statt Default

**File:** `server/lib/nebu/admin/config_controller.ex:72-76`
**Source:** Blind Hunter (MAJOR F1, downgraded MINOR)

**Problem:** Wenn Operator leere Strings postet, schreibt `save_scopes/2` `""` in die DB. Flash sagt "Scopes saved". Die Config-Seite zeigt `""`. Effektiv verwendet der Scope-Reader trotzdem den Hardcode-Default — aber der Operator sieht `""` und weiß nicht was tatsächlich verwendet wird.

**Pattern:** `bootstrap_controller.ex:save_claim_mapping/1` nutzt `if(value == "", do: default, else: value)`.

**Fix:** Leeren String vor Persistierung zum Default normalisieren:
```elixir
@scope_defaults %{
  "matrix_oidc_extra_scopes" => "profile email",
  "admin_oidc_extra_scopes" => "profile email groups"
}

changes =
  @scope_keys
  |> Map.new(fn key ->
    raw = String.trim(params[key] || "")
    value = if raw == "", do: @scope_defaults[key], else: raw
    {key, value}
  end)
```

---

### P3 — Kein `Logger.warning` bei ungültigem Scope-Token in `do_complete_bootstrap`

**File:** `server/lib/nebu/admin/auth.ex:1403-1404`
**Source:** Blind Hunter (MINOR F3)

**Problem:** Wenn ein Scope-Token die Whitelist-Prüfung nicht besteht, wird der Key still nicht promoted. Kein Log-Eintrag. Operator weiß nicht warum seine Scope-Konfiguration nicht wirksam ist.

**Current code:**
```elixir
all_valid = Enum.all?(scopes, &String.match?(&1, ~r/^[a-zA-Z0-9_:.\-]+$/))
if all_valid, do: put_config(key, v)
```

**Fix:**
```elixir
all_valid = Enum.all?(scopes, &String.match?(&1, ~r/^[a-zA-Z0-9_:.\-]+$/))
if all_valid do
  put_config(key, v)
else
  Logger.warning("configurable-oidc-scopes: skipping #{key} promotion — invalid scope token in draft value: #{inspect(v)}")
end
```

---

## DEFER Findings

- **D1:** Two DB queries per scope read per login (pre-existing performance pattern; consistent with refresh_mode reader)
- **D2:** Wizard pre-fill `||` doesn't handle `""` from DB — low-impact UX edge (save_claim_mapping writes default when blank, so DB row is never empty in normal flow)

## DISMISS Findings

- **R1:** Empty scope at bootstrap promotion doesn't overwrite stale DB row — false positive; bootstrap runs once per instance, no stale rows on fresh install
- **R2:** `put_flash` on re-render inconsistency with `save_refresh_mode` — functionally better UX than existing pattern; dismiss
- **R3:** Operator can submit "openid" as extra scope — `Enum.uniq/1` deduplicates correctly; dismiss
