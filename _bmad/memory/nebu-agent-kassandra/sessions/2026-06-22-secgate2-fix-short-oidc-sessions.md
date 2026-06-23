# Session 2026-06-22 — SEC Gate 2: fix-short-oidc-sessions

Epic-end (whole-epic) security review, `git diff HEAD~2..HEAD` (Matrix `cc228680` + Admin `f6a4407d`).

## Verdict
**PASS / CLEAN** — 0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 new LOW + 5 advisories. Epic clear to mark done.
Report: `_bmad-output/implementation-artifacts/epic-fix-short-oidc-sessions-security-review-2026-06-22.md`.

## What I did differently from the per-story reviews
Per-story reviews already ended CLEAN (Matrix HIGH found+fixed cycle-2). At epic scope I focused
ONLY on what a single-diff view misses:
- Shared `SecretBox` used by BOTH stories → checked key reuse / nonce / fail-closed (sound).
- Deactivation completeness across opaque Matrix + admin cookie systems → traced `set_is_active(false)`
  to its single caller; confirmed delete_for_user + the ≤60s provision re-check backstop both fire.
- `invalidate_all_admin_sessions` re-assessed at epic scope (cycle-2 INFO) → LOW, not MEDIUM:
  it's config-rotation re-auth, not the deactivation kill-switch.
- Two unauthenticated refresh endpoints combined → per-IP RL on remote_ip (no XFF trust), no oracle.
- Fail-closed parity across all four token-verify paths via single OidcPlug.verify_token.

## Patterns recorded
- Shared at-rest crypto helper across feature contexts — the key/nonce/fail-closed triad to verify.
- `invalidate_all_*` (config rotation) ≠ deactivation kill-switch — different completeness bars; don't inflate.

## Carried follow-ups (non-blocking)
1. invalidate_all_admin_sessions should also delete opaque matrix_sessions (LOW, follow-up story).
2. Wire cleanup_expired/0 to a supervised sweeper (LOW ops).
3. no-RLS-on-matrix_sessions (advisory, pre-existing table), no global refresh-storm cap (advisory),
   IdP-side-logout lifetime trade-off (documented + accepted).
4. Verify the 2 pending e2e suites are green in CI before tagging.
