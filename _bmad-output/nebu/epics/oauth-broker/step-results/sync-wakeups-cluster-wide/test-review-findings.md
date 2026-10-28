# Test review sync-wakeups-cluster-wide (2026-10-26) — summary (reviewer could not run mix: sandbox)
Verdict: 0 MAJOR AC gaps; 2 MAJOR in test_helper.exs (both resolved by decision A below).
- MAJOR-1: fixed public cookie, epmd + dist port on all interfaces, ~/.erlang.cookie side effect.
- MAJOR-2: Node.start after app boot renames node() under Horde/:pg/ETS; peer churn per test; 2 unexplained ModerationFixCycle1UnitTest failures.
- MINOR: Scenario 2 wording (sites 3,5,7,8,9 guard-only; 5 and 8 are actually observable); moduledoc wrong on 5/8; raise-in-CI vs D2; guard holes (import :pg, 3-tuple msgs); on_exit self() bug; strict :pg.start match; late-lookup room cleanup; 401-line file/duplicated fake DB.
Decisions: A revert test_helper (no global distribution); B :peer tests opt-in (:cluster, .oauth-ci/cluster_test.sh, distribution before app boot, random cookie, loopback); C gate = AST guard + dynamic :erlang.trace proof of no get_local_members; D minors fixed; E story amended (D2, Scenario 2, sizing, D4 tokens).
