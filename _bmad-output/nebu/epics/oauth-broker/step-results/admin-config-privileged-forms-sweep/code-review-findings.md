# code-review cycle 0 admin-config-privileged-forms-sweep (nebu-code-reviewer, 2026-10-14)
1 MAJOR (pre-existing, found here), 7 MINOR, 6 INFO. Bypass inventory: no other writer of the locked keys without the gate (bootstrap only writes the draft / promotes before bootstrap completion;
the gRPC update_server_config path is unreachable dead code).
MAJOR-1: `admin_group_claim` is missing from the `config_update_mutable` RLS allowlist (dropped by migration 000002), so every save of the Role mapping page raised an RLS error on a bootstrapped
instance (reproduced with a probe test against the runtime role). Fixed by migration 000049 (+ static and DB tests); owner decision recorded (widens what nebu_app may update, by design of the page).
MINOR (all applied): recovery SQL role wording (nebu_app / BYPASSRLS), story follow-up ids, weak tests, duplicated allowlist literals (auth.ex attribute, router single list), scopes parameter hardening
(list / map = error) and body_params for schemes / origins, audit wording (group VALUE vs claim names), doc drift (helpers, click proof script, ADR SO4, 07-deployment).
