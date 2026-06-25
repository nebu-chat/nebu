# Code Review — admin-http-refactor (cycle 1)

## All cycle-0 MAJORs: FIXED ✓

## Remaining MINOR findings (cycle 1):

**MINOR-1 — ConfigController.save_refresh_mode: `:ok =` hard match (config_controller.ex:37)**
Same pattern as MAJOR-3 was about. `upsert_server_config` uses bang internally so it's redundant rather than a new crash vector, but inconsistent with defensive patterns elsewhere. Use `case _/` for parity.

**MINOR-2 — RoleMapping POST validation has no test**
Cycle-0 fix added empty-value validation to RoleMappingController, but no POST test was added. ClaimMapping has the symmetric POST empty-field test (:301-318); RoleMapping does not. Add a test: `POST /admin/config/role-mapping` with empty `admin_group_claim` → 200 + role="alert".

## INFO (3) — all non-blocking:
- INFO-1: AC19 CSP tightening deferred (3 LiveViews remain) — AC as worded is met
- INFO-2: RouteKindShim technical debt — accepted
- INFO-3: Spaces has no remove_member — matches old SpacesLive scope

## ADR compliance: PASS
## All 19 ACs met. 851/854 (3 pre-existing DeployConfigTest unrelated).
