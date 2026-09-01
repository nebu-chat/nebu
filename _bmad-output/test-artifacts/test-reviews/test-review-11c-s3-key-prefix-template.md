# Test Quality Review — 11c-s3-key-prefix-template

**Story:** `docs/stories/media-security-admin-control/11c-s3-key-prefix-template.md`
**Epic:** media-security-admin-control
**Review Date:** 2026-07-14
**Reviewer:** TEA (Master Test Architect)
**Scope:** Pre-dev (TDD-gate) review, RED phase — no implementation exists yet

## Test Files Reviewed

| File | Lines | Framework | Status |
|---|---|---|---|
| `server/test/nebu/media/key_prefix_template_test.exs` (new) | 315 | ExUnit, pure-function, `async: true` | RED confirmed (`validate_template/1`/`compute_key/2` absent from `storage_config.ex`) |
| `server/test/nebu/media/storage_config_test.exs` (extended, `11c-AT7`, lines 655–701) | 43K total | ExUnit, `async: false`, injectable seams | RED confirmed (`upsert/1` currently persists invalid templates unchanged — MatchError, not UndefinedFunctionError) |

---

## Quality Score

**Score: 92 / 100 — Grade: A (Excellent)**

| Criterion | Status | Notes |
|---|---|---|
| AC5's 4 rejection categories each independently tested | PASS | AT3 (missing `{media_id}`), AT4 (unrecognized token), AT5 (unbalanced braces), AT6 (path-escaping) — 4 distinct `describe` blocks |
| AT10 proves uniqueness comes from `{media_id}`, not timestamp coarseness | PASS | Frozen `DateTime`, two distinct `media_id`s, explicit expected strings for both |
| AT8/AT9 scope adaptation proves the underlying invariant | PASS | AT8 proves `compute_key/2` interpolates the active template (not a flat fallback); AT9 proves purity/no-hidden-state across an intervening different-template call — the actual property AC4's "zero effect on already-uploaded rows" depends on |
| Adaptation labeling/honesty | PASS | Moduledoc + inline comments explicitly state what AT9 does and does NOT prove (does not simulate the real single-call-site guarantee — correctly deferred to Story 2b) |
| Determinism | PASS | All timestamps frozen/injected; no `DateTime.utc_now()`, no random data |
| Isolation | PASS | `key_prefix_template_test.exs` is pure/`async: true`; `11c-AT7` reuses the file's existing per-test GenServer/ETS reset (`setup` stops any live `StorageConfig` process, fresh `Agent`-backed store/calls per test) |
| Explicit assertions | PASS | No assertions hidden in helpers |
| Config-save-time integration test (`11c-AT7`) | PASS | Checks baseline, error return, underlying store **and** `get/0` — not just cache |
| AT5 discriminating power | WARN | 2 of 3 unbalanced-brace cases would also be rejected by a naive "missing exact `{media_id}` substring" check alone (see MINOR-1) |

---

## Executive Summary

This is a strong RED-phase suite. Every AC5 rejection category gets its own `describe` block with multiple concrete inputs, AT10 is constructed correctly (frozen timestamp, varying only `media_id`, asserting both the inequality and the exact expected strings), and the two scope-adapted tests (AT8/AT9) are not just present but actually exercise the specific properties the real integration tests would need — determinism and template-interpolation-from-active-config — rather than merely re-asserting `compute_key/2` returns *something*. The moduledoc is unusually explicit about what's adapted and why, and about what Story 2b must still add verbatim.

The `11c-AT7` addition to `storage_config_test.exs` is well-integrated: it reuses the file's existing per-test isolation harness, asserts a pre-existing valid baseline survives an invalid `upsert/1` attempt, and checks the underlying fake store (not just the cache) to rule out a false pass where `get/0` looks correct but the write actually went through.

**Key strength:** AT4's bad-template list (`"{room_id}/{media_id}"`, `"{uploader_id}/{media_id}"`, `"{yeat}/{media_id}"`) deliberately keeps `{media_id}` present alongside the bad token — this forces the implementation to have a genuine "reject unrecognized token" rule distinct from the "require `{media_id}`" rule; a validator that only checked the latter would incorrectly accept these.

**One weakness worth knowing about (not blocking):** AT5's three unbalanced-brace cases are not equally discriminating — see MINOR-1.

**Recommendation:** Approve — proceed to dev-story. No MAJOR findings.

---

## Findings

### MINOR-1 — AT5: 2 of 3 unbalanced-brace cases don't independently prove brace-parsing logic exists

**Severity:** MINOR
**Location:** `server/test/nebu/media/key_prefix_template_test.exs` lines 165–172

**Issue:**
AT5 asserts `"{media_id"`, `"media_id}"`, and `"{media_id}/{year"` are all rejected. However, the first two cases lack the literal substring `"{media_id}"` (missing one brace each), so a `validate_template/1` implementation that did nothing more than `String.contains?(template, "{media_id}")` (i.e., no real brace-balance parsing at all) would already reject them — for the *wrong* reason (AC2's mandatory-placeholder rule), not because it detected unbalanced braces. Only the third case, `"{media_id}/{year"`, contains a complete, valid `"{media_id}"` token plus a genuinely dangling `"{year"` — this is the one case that would slip past a naive implementation lacking real brace-parsing, so it's the case actually doing the discriminating work for this AC5 sub-rule.

**Why it matters:**
Not a current gap (the discriminating case is present), but a maintainability trap: if a future refactor treats the three cases as redundant and trims to one of the first two "for brevity," coverage of the real brace-balance rule silently disappears while the test suite still looks like it covers AT5.

**Recommended fix (optional, non-blocking):**
Add a one-line comment above the `for` loop noting that `"{media_id}/{year"` is the load-bearing case for this rule (the other two are also valid inputs but are redundant with AT3's rule), so a future trim doesn't remove it.

---

### INFO-1 — Path-escaping `".."` only tested at template start

**Severity:** INFO
**Location:** `server/test/nebu/media/key_prefix_template_test.exs` lines 178–193 (AT6)

**Note:** AT6 covers leading `"../"`, a literal `"//"` from adjacent placeholders, and a leading `"/"` — all three path-escaping sub-rules from the Technical Requirements are exercised. There's no case for a *mid-template* `".."` segment (e.g. `"{year}/../{media_id}"`). Given the spec describes a simple substring check on the literal skeleton (position-independent), this is very unlikely to be a real gap, just noted for completeness.

---

### INFO-2 — No placeholder case-sensitivity case

**Severity:** INFO
**Location:** `server/test/nebu/media/key_prefix_template_test.exs` lines 148–159 (AT4)

**Note:** AT4's bad-token list doesn't include a case-variant of a real placeholder (e.g. `"{YEAR}"`, `"{Media_Id}"`). AC2 doesn't specify case-insensitivity as a requirement, so this isn't a coverage gap against the ACs as written — just a defensive edge case a reviewer might otherwise wonder about.

---

## AC Coverage Matrix

| AC | Description | Test(s) Present | Coverage | Status |
|---|---|---|---|---|
| AC1 | Config source is `StorageConfig.get/0`, not `Nebu.Media.Config` | Implicit — all tests call `Nebu.Media.StorageConfig` directly | Structural, no dedicated test needed (module choice, not runtime behavior) | PASS |
| AC2 | Exact 5-placeholder set, zero-padded, mandatory `{media_id}` | AT1 (all 5, zero-pad), AT2/AT11 (subset/default) | Direct | PASS |
| AC3 | `compute_key/2` called from exactly one place (Story 2b seam) | AT8 (adapted) proves interpolation-from-active-template; real single-call-site guarantee deferred to Story 2b (not yet landed) | Adapted, correctly scoped and labeled | PASS (as adapted) |
| AC4 | Template change after upload has zero effect on persisted `storage_key` | AT9 (adapted) proves `compute_key/2` purity/determinism — the property the real non-regression test depends on; real end-to-end non-regression deferred to Story 2b's `media_async_upload_test.exs` | Adapted, correctly scoped and labeled | PASS (as adapted) |
| AC5 | Reject: missing `{media_id}`, unrecognized token, unbalanced braces, path-escaping | AT3, AT4, AT5, AT6 — 4 distinct `describe` blocks, each with multiple inputs | Direct, all 4 categories independently exercised | PASS |
| AC5 (config-save wiring) | `upsert/1` calls `validate_template/1`, rejects before persisting | `11c-AT7` in `storage_config_test.exs` | Direct, checks store + `get/0` | PASS |
| AC6 | Collision resistance via mandatory `{media_id}` | AT10 — frozen timestamp, 2 distinct `media_id`s, explicit expected strings | Direct, correctly isolates cause | PASS |

---

## Recommendation

**Approve — proceed to dev-story.**

No MAJOR or blocking MINOR findings. MINOR-1 is an optional comment-only improvement to guard against future test trimming; INFO-1/INFO-2 are optional defensive additions, not gaps against the stated ACs. The AT8/AT9 scope adaptation is handled correctly: it proves the actual invariants (determinism/purity, interpolation-from-active-config) those ATs exist to protect, is explicitly labeled as a stand-in, and defers the real end-to-end pipeline test to Story 2b as instructed.
