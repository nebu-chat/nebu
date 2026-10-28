# Security Review: admin-forms-gate-sweep (SEC Gate 1), 2026-10-15

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator (condensed from the agent's hand-back). A design review (levels per form, the M3 logic fix, the audit split) preceded the implementation: `_bmad-output/nebu/epics/oauth-broker/step-results/admin-forms-gate-sweep/kassandra-design-review.md`.
Scope: `git diff --staged` (40 files): `click_gate/2` plug on the users / rooms / spaces / logs / media controllers, the `:marker` gate of the media policy and the storage target, `StorageConfig.resolve_candidate_secrets/1`, L1 / R2 audit, `back_path/1`, templates, docs.

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW, 4 INFO). Approved.**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| L-1 | LOW | The R2 audit (`Nebu.Matrix.set_room_auto_join/3`) runs after the write and its result is ignored; the docs said the toggle "writes its audit row". | FIXED in the docs ("best effort, after the write", follow-up `dn` extended to `room_auto_join_changed`); better than before (no row at all). |
| L-2 | LOW | Break-glass while the IdP is down was documented for `media_storage_config` only; the media policy is behind the marker now too. | FIXED: SQL for `media_config` (for example extend `deleted_days` to keep evidence) and a concrete SQL for the storage target in 07-deployment. |
| I-1 | INFO | `back_path` let `%2e%2e` through (same origin, inside `/admin`: not exploitable). | FIXED (`%2e` rejected). |
| I-2 | INFO | After an unused fresh sign-in the marker stays valid for 300 s for either media form. | accepted (SO7, the same pattern as `/admin/config`). |
| I-3 | INFO | WebKit: a same-origin script can set `_click_proof=1` and `form.submit()` on `:click` forms (the known SO7 / SO9 residual; `:marker` forms still need the fresh sign-in). | accepted. |
| I-4 | INFO | Same host spelled differently (trailing dot, explicit default port) answers `:secret_required`: fails closed. | accepted. |

Checked and fine: every non-bootstrap post / DELETE behind the gate (the enumeration test drives the real endpoint; no PUT / PATCH routes; `Plug.MethodOverride` only turns a POST; the proof is read from `body_params`); plug order (CSRF, `require_admin`, gate before any DB read); marker binding, single use, consumed only after success, kept by validation errors, the orphan-risk re-render and failed writes; no deadlock when the IdP is down (U2, R7, L1 need no marker); D4: case normalised, trailing dot / added port / IPv6 spelling / scheme flip / one blank key all `:secret_required`, IAM / STS correctly not compared (the test never contacts them), the message is static; L1 cannot shorten retention unaudited (retention keys are only sent for enabled levels, the way-back predicate is re-checked under `FOR UPDATE`), `log_settings_changed` is allow-listed; back links start with `/admin/`, HEEx-escaped, ids are plain segments; follow-ups `dj` - `do` state the residuals honestly, row `ab` untouched.
