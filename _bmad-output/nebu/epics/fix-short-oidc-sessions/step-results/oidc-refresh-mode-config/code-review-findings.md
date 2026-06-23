# Code Review — oidc-refresh-mode-config (cycle 0), 2026-06-23
## Verdict: CLEAN (2 MINOR, both fixed in cycle 1)
All AC1-AC7 covered. Correctness verified: Matrix scope offline_access iff offline (default offline);
admin scope offline_access iff offline (default online) with **openid always mandatory** even when
de-forcing offline_access; bootstrap promotes both keys w/ non-empty+enum guard. Enum validation on
EVERY write path + read defaults collapse junk → safe default (no scope injection). ADR-018/020 clean
(Matrix reads server_config via inline SQL; seams under :nebu_http). admin_token_refresh_test.exs:166
flip (assert→refute offline_access) is a legitimate default change (AC3), offline covered by admin_scope_mode_test — not a weakening. let-it-crash: readers default safely on Repo-down/absent key.
## MINOR (fixed cycle 1)
- MINOR-1 ConfigLive <form> missing id → added id="oidc-refresh-mode-form" (also clears form/3 warning in integration test).
- MINOR-2 dead is_map clause in config_value/2 → removed (config/0 always returns a list).
## UX gate: no accessibility blockers (labels + aria-label + native <select> + fieldset/legend). Advisory was the same form id (fixed). Optional: save-confirmation flash (not done — non-blocking).
## Pending: :integration round-trips + @pending e2e run under make test-integration before done.
code-review subagent id: a455bb53bb6f815df · ux subagent id: a96345eb728f75f0b
