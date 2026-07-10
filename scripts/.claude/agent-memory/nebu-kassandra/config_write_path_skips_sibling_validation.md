---
name: config-write-path-skips-sibling-validation
description: New per-entity config write handlers upsert client-controlled keys/values with no validation while a sibling path already enforces bounds/allowlists — latent GDPR/retention landmine, not privesc
metadata:
  type: feedback
---

New config-write UIs in this repo repeatedly persist client-controlled input into dynamic `server_config` keys WITHOUT reusing the validation that a sibling write path already enforces.

**Concrete (trace-map-node-controls, 2026-07-08):** `configure_logging` LiveView handler wrote `log_min_level_<node_key>` / `log_retention_days_<node_key>` straight from phx-change params — no allowlist on `min_level` (module already has `@ui_levels` and a `toggle_level` guard `when level in @ui_levels`), no 1-90 bound on `retention_days` (the global `Nebu.Admin.LogsController.save_retention` path enforces exactly this via `validate_level`/`validate_bound`), no check that `node_key` is an observed endpoint (`cascade_targets/2` satellite branch returns `[node_key]` verbatim).

**Why:** Two effects to always separate. (1) NOT privesc when the key is prefix-constructed (`"log_min_level_" <> x`): `server_config` is exact-match keyed, no path interpretation, and RLS LIKE families use backslash-escaped `_` so they can't over-match or be gamed onto another config surface — don't over-rate it. (2) The real risk is a LATENT one: unvalidated retention/limit values sit harmless while the key is display-only, then silently defeat the control the day a future story wires the dynamic key into a pruner/hot-path. Grade MEDIUM (defense-in-depth + latent compliance), not HIGH.

**How to apply:** On any new config-write handler, (a) grep for a sibling save path for the same value family and check it validates — if so, the new path skipping it is a finding; (b) trace whether the written key is actually CONSUMED anywhere (`grep` the key prefix repo-wide) — display-only-today bounds severity to MEDIUM/latent, hot-path consumption raises it. Related: [[server_config_rls_allowlist]], [[safety_cap_at_consumer_not_api]].
