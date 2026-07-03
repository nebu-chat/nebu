# Code Review Report — fix-bootstrap-admin-session-identity (epic oidc-simplification)

Diff source: staged changes (5 files, +658/-25). Review cycle: 0.
Verdict: Story goal correctly achieved for the primary path (AC1/AC2/AC3/AC4 all satisfied and
genuinely tested). The controllers' defense-in-depth fallback introduces one MAJOR (correctness
divergence, entangled with an ADR-020 concern and possible scope creep) requiring a user decision.
Remainder are MINOR/INFO.

## Acceptance-criteria verification (independent)

- AC1 — same session builder. MET. `bootstrap_confirm_claim/2` now calls `put_current_user(claims)`
  (auth.ex:766), the exact builder `normal_callback/2` uses (auth.ex:541). Old hand-rolled map
  fully deleted. Session carries `matrix_user_id`.
- AC2 — full claims stashed & identical derivation. MET on the primary path. `bootstrap_callback/2`
  stashes `Jason.encode!(claims)` under `bootstrap_full_claims` (auth.ex:592); `bootstrap_claims/1`
  decodes it and feeds `put_current_user/2`. Test pins byte-for-byte equality with a subsequent
  normal re-login. The claim-cache-timing test's previously-flagged tautological-seam MAJOR is
  fixed and verified present.
- AC3 — regression through real pipeline. MET. Drives Endpoint → Router → `RoomsController.create/2`
  → `actor_id/1` via the `admin_room_creator` seam with a session fixture shaped exactly as the
  pre-fix bug produced it.
- AC4 — existing suites stay green. MET. Deliberate `session_exp`-floors-by-`exp` change is pinned
  by a dedicated test.

## MAJOR

**MAJOR-1 — `actor_id/1` fallback silently mis-attributes writes when `oidc_user_id_claim` ≠
sub/email; also two new ADR-020 submodule reach-throughs; also likely scope creep. Requires user
decision.**

Files: `server/lib/nebu/admin/rooms_controller.ex:511-519`, `server/lib/nebu/admin/users_controller.ex:213-221`.

The new fallback derives `matrix_user_id` from ONLY the stale session's `sub`/`email`:
`Nebu.Matrix.UserId.from_claims(%{"sub" => sub, "email" => user["email"]}, server_name())`.
If the instance's configured `oidc_user_id_claim` is `preferred_username` (or `name`, or any
non-sub/email claim), that claim is absent from the stale session, so `from_claims/2` resolves to
a different, plausible-but-wrong localpart than the operator's real Matrix identity. It trades the
old failure mode (raw opaque sub, obviously wrong) for a subtler one (a valid-looking
`@sub-derived:server` that is silently the wrong user).

Three entangled concerns:
- Correctness: the divergence above.
- ADR-020: both call sites are NEW live cross-domain reach-throughs into `Nebu.Matrix.UserId` (a
  submodule), which `matrix-conventions.md` forbids ("nicht `Nebu.Matrix.*`-Submodule direkt").
  No `from_claims` delegate exists on the `Nebu.Matrix` facade.
- Scope: the dev's own report concedes this "was NOT explicitly requested by the story's
  Implementation Map." AC3 targets the freshly-bootstrapped path, which the primary fix already
  covers; stale-cookie handling is added scope.

If dropped (return `nil`, let the session expire so the operator re-logs in), MAJOR-1 evaporates
entirely. If kept, the ADR-020 part is a one-line `Nebu.Matrix.user_id_from_claims/2` defdelegate
and the divergence should be documented as an accepted trade-off.

## MINOR (auto-cycle to dev)

- MINOR-1: Stale RED-phase moduledoc in `bootstrap_admin_session_identity_test.exs:3` — reads
  "RED-phase ATDD tests" while this changeset ships the GREEN fix. Doc-only, reword.
- MINOR-2: `server_name/0` and the entire `actor_id/1` fallback duplicated verbatim across both
  controllers. If MAJOR-1's fallback is kept, extract to a shared location (e.g. `Nebu.Admin.Auth`).
  Collapses on its own if MAJOR-1 is resolved by dropping the fallback.

## INFO (no action required)

- INFO-1: Path-dependent `session_exp` flooring — the flattened-claims fallback path can't carry
  `exp` (binary-only flatten guard drops integers), so legacy in-flight bootstraps don't get the
  exp-floor. Benign, narrow window.
- INFO-2: Pre-existing ADR-020 debt already exists elsewhere (`rooms_controller.ex:227`, `auth.ex:294`)
  — not introduced by this diff, not required to fix here.
- INFO-3: Comment density is high relative to logic volume — accurate, not flagged as a problem.

## Orchestrator's independent cross-check (matches reviewer's findings)

I independently identified the same MAJOR-1 divergence risk during my own investigation (before
the reviewer's report arrived): confirmed via `Nebu.Matrix.UserId.localpart/1`
(server/lib/nebu/matrix/user_id.ex:41-54) that `configured_claim()` is checked FIRST, before
`preferred_username`/`name`/`sub` — a synthetic claims map with only `sub`/`email` cannot honor a
non-default configured claim. I also independently confirmed the ADR-020 precedent question:
`auth.ex:294` already calls `Nebu.Matrix.UserId.from_claims/2` directly (pre-existing, not
introduced by this story) — so the NEW calls in the two controllers extend an existing pattern
rather than inventing a new violation from scratch, which is useful context for the user's
decision but doesn't change the substance of the finding.
