# Code Review — `bugfix-add-sts-iam-endpoints-to-admin-ui` (cycle 0)

**Scope:** 8 staged files, +518/−19. Layers run: Blind Hunter, Edge Case Hunter, Acceptance Auditor.

## Verified clean
SELECT column mapping (name-based via Enum.zip, SAFE), mask_map/1 (iam/sts stay unmasked), DB>env>default per-field precedence, column_for/2 (no other field disturbed), orphan-risk gate (still endpoint/bucket only), validate_storage_params/1 (optional, blank-omit), migration 000037 (nullable, down-migration correct, GRANT already covers new columns, no RLS change needed), release_test.exs bump, test-review MINOR-1 verified fixed, audit allowlist (no change needed), scope (no creep/gap).

## MAJOR (1)

**MAJOR-1 — A persisted iam/sts override can never be cleared from the UI, and the first save on a fresh config silently freezes the env values into the DB.**
- No clear path: blank → omitted (not reset to NULL). Unlike the secret fields there's no "leave blank to keep current value" hint, and the "(optional)" label implies blank=unset, which is false once a DB row exists.
- Silent env→DB promotion on first save: `handle_storage_save/3`'s `:fresh` branch persists the undiffed `changes` map, and the form pre-fills ALL fields (including iam/sts) from the env-resolved value. So saving ANY storage field on a never-configured install copies the env-provided IAM/STS URLs into the DB — after which `NEBU_MINIO_IAM_ENDPOINT` is permanently shadowed, and a later Terraform/cloud-init change to `iam_url` is silently ignored.
- This pattern is consistent with how `region`/`archive_bucket`/etc. already behave (pre-existing, not introduced by this story) — but it directly undercuts the bug-context's scope claim that "Terraform/cloud-init ... unaffected by this change, VM env vars still flow in as before," and for these two specific fields it cuts against the user's original request (show env values for *visibility*, not to silently pin them).
- Product decision, not a mechanical fix.

## MINOR (8)
1. Migration 000037 omits `ADD COLUMN IF NOT EXISTS` / `DROP COLUMN IF EXISTS`, against an explicit repo convention followed by every sibling column-adding migration (000002, 000004, 000012, 000019, 000021).
2. Zero format validation on the new URL fields; help text claims a contract ("full URL") nothing enforces. Route explicitly to Kassandra — ingress widened from infra-provisioned env to admin-UI-writable, unvalidated, DB-persisted field (still zero consumers, so still unexploitable, but a real surface change).
3. "Test Connection" silently ignores iam/sts — `config_overrides/1` never reads these keys, so a successful test-connection tells the admin nothing about whether the IAM/STS URLs are reachable, despite a test name implying otherwise.
4. Widened SELECT fails open if migration 000037 isn't applied/is rolled back — degrades the *entire* storage target to env/compiled defaults with only a log warning (not a crash). Mitigated by migrate-before-start deploy order; not by a rollback window.
5. `docs/architecture/07-deployment.md:909-916` now stale (still says env-only resolution) — flag for the arc42-update step.
6. `blank_to_nil/1` in the controller has no catch-all for non-binary params (pre-existing gap, now reachable via 2 more params; admin-only).
7. `7mf5k.upcloudobjects.com` placeholder in template is UpCloud's own doc example (not leaked data) but is an odd account-hash format for a UI hint; consider a generic placeholder.
8. Hint `<span>` nested inside `<label>` pollutes the accessible name (pre-existing pattern shared with endpoint/access_key/secret_key, not new) — worth a decision on fixing the pattern repo-wide.

## INFO (11)
AC5 round-trip tested at model+controller layer but not literally POST-then-GET end-to-end (functionally covered); AC6 template deviation (follows `endpoint` pattern not `region`, placed after `bucket` — defensible); GRANT requirement answered via comment not re-issued statement (correct); two over-length lines in build_resolved/2 (cosmetic, no formatter gate); RED-phase test comments now stale (repo-wide convention, not story-specific); candidate_from_params/1 nil vs "" inconsistency (behaviorally inert); loose status-code assertion backed by a stronger assert_received check (sound); no E2E coverage for this page (none exists for the whole page today); hidden DNS-coupling in AC4 tests via MINOR-1's pin (worth knowing, not acting on); `pick/3` treats "" as present (unreachable today); AC2-DB3 mostly duplicates AC1-DB2 (still useful as a future-regression guard).

## Dismissed as false positives
changed_storage_keys/1 "not wired" · missing on_exit cleanup · ensure_started() inconsistency · whitespace not trimmed · missing has_label_or_aria? coverage · audit allowlist needing an update · positional row mapping · missing CHANGELOG entry · "total failure" on rollback framing · test filed in wrong describe · mix format as a CI gate · RED-comment rot as MAJOR.

## Recommendation
Implementation is faithful to the spec; the three highest-risk regression surfaces (row mapping, masking, orphan gate) are provably clean; test-review MINOR-1 genuinely fixed. One MAJOR needs a product decision (clear-path + first-save env pinning). MINOR-1 (migration idempotency) and MINOR-5 (stale doc) are mechanical, worth fixing before commit. MINOR-2 should be handed to Kassandra with the explicit note that the ingress widened.

---

# Cycle 1 re-review

**Cycle-0 MAJOR-1 / MINOR-1: both verified RESOLVED**, traced to real SQL (nil reaches the UPDATE statement, no filtering anywhere in the write path). Zero behavior change for every other field confirmed.

## MAJOR (1, new in cycle 1)

**MAJOR-N1** — Rule 2's "omit if matches" check is baselined on the env-only value (`env_only_iam_sts/0`) instead of the actual resolved/pre-filled value (`StorageConfig.get()`, DB>env>default). Consequence: if a DB override `X` already exists and the admin deliberately edits the field to the env value `Y` (a legitimate change), Rule 2 matches `Y == env` and silently omits the write — the admin's edit is discarded with a false "saved" success message, no error, no log.

Root cause: Rule 2 should ask "did the admin actually change anything from what's currently in effect" (compare against resolved value), not "does this match the env var" (which only coincidentally equals the pre-filled value when no DB override exists yet).

**Recommended fix** (narrow, mechanical, closes 3 findings at once — also fixes MINOR-1 trimming mismatch and MINOR-2 empty-string-never-converges below):
```elixir
defp put_env_backed_field(map, key, raw, resolved_value) do
  submitted = blank_to_nil(raw)
  baseline = blank_to_nil(resolved_value)
  cond do
    submitted == baseline -> map                    # no-op: untouched (whether DB- or env-sourced), or both blank
    submitted == nil -> Map.put(map, key, nil)       # explicit clear: baseline was non-blank, admin blanked it
    true -> Map.put(map, key, submitted)             # genuine new value — persisted even if it equals env
  end
end
```
Pass `StorageConfig.get()`'s (or `get_for_connection()`'s) `iam_endpoint`/`sts_endpoint` as `resolved_value` instead of `env_only_iam_sts/0`.

## MINOR (7 new/escalated)
1. Rule 2 compares trimmed submission against untrimmed env value — whitespace in `NEBU_MINIO_IAM_ENDPOINT` defeats the fix. Fixed by the `blank_to_nil` normalization above.
2. `NEBU_MINIO_IAM_ENDPOINT=""` never converges — every save issues a redundant `SET ... = NULL` + bogus audit entry forever. Fixed by the above (both sides normalize `""` → `nil`, so submitted==baseline==nil → omit).
3. Fresh first save on an install with iam/sts unset writes two spurious NULL columns + names them in the audit trail (contradicts `upsert/2`'s own "changed_fields names only what changed" contract). Same root cause, same fix.
4. No UI signal for "this value is a DB override" vs "this is just the env value" — this is what makes MAJOR-N1 invisible to an admin. Real product gap, bigger than this bugfix's scope — not required to fix now, flagged for a future story.
5. AC3's spec text ("blank→omit") is now superseded by the actual blank→explicit-nil behavior — legitimate supersede (omit can't express "clear"), but nothing in step-results records that this was a deliberate decision. Documented here now.
6. `docs/architecture/07-deployment.md:909-916` still describes env-only resolution — flag again for Step 8 arc42-update, now also needs to explain the 3-way rule.
7. `validate_storage_params/1` now reads real `System.get_env/1` via `env_only_iam_sts/0` on every save when the test seam isn't stubbed — ambient coupling, benign today (19 of the controller test's `post_storage` calls only stub 7 times), will go away once baseline switches to the already-mocked `StorageConfig.get()`.

## INFO (10)
Phantom NULL-over-NULL writes when blanking an already-blank field; `^env_value` branch is dead code while `@defaults.iam_endpoint` is nil (latent MAJOR-1 recurrence if that ever changes); `env_only_iam_sts/0` reads live `safe_env()` while pre-fill goes through `get/0`'s snapshot (can disagree in principle, benign today); migration cosmetic two-clause-vs-one-per-ALTER style (valid, not a defect); `IF NOT EXISTS` also masks a wrong-type pre-existing column, not just idempotence; the MAJOR-1 repro test hardcodes the pre-filled value rather than scraping a prior GET (still genuinely exercises the bug); `test_connection/1` moduledoc doesn't mention it now also receives iam/sts; stale RED-phase/convention comments in the test file are actively misleading in one spot (claims blank-omit 40 lines above where blank→nil is implemented); orphan-risk confirm re-render of iam/sts is untested (verified safe by reading the template); down-migration is unconditionally destructive (pre-existing pattern for all storage columns).

## Recommendation
MAJOR-N1 + MINOR-1 + MINOR-2 all stem from the same wrong comparison baseline and are fixed by one narrow edit (swap env-only for resolved-value baseline, normalize both sides). Worth a cycle 2 before commit.

---

# Cycle 2 re-review — VERDICT: CLEAN (0 new MAJOR)

MAJOR-N1 verified genuinely fixed: all 5 cases traced by hand through `column_for/2`/`build_columns/1`/`default_writer/2` to the actual SQL write. `StorageConfig.get()` used as baseline for both pre-fill AND the omit-comparison (same function, same seam) — cycle-1's snapshot-vs-live-env staleness concern is structurally eliminated, not just relocated. `env_only_iam_sts/0` cleanly removed, no dangling references. Zero behavior change confirmed for every other field. Both new tests (MAJOR-N1 regression, empty-env-converges) independently verified to prove what they claim, not shortcuts.

## MINOR (3 new)
1. **N2-MINOR-1 (decision_needed)** — Blanking an *env-sourced* (no DB override) iam/sts field writes a redundant `SET ... = NULL` + false audit `changed_fields` entry, non-convergent (repeats every save). Root cause: Rule 2 can't distinguish "baseline is a DB override" from "baseline is just the env value" — `StorageConfig` has no DB-only accessor for these two columns (`persisted_target/0` only covers endpoint/bucket). Options: accept the audit noise (cosmetic, DB state ends up correct either way), or add a `persisted_overrides/0`-style accessor as a follow-up.
2. **N2-MINOR-2** — A POST that omits `iam_endpoint`/`sts_endpoint` entirely (not blank, literally absent) is treated identically to "blanked" → destructive NULL write if a DB override exists. Only reachable via a scripted/non-browser admin POST (every real HTML submission sends the field, even empty). Admin-authenticated; worst case reverts to env-controlled.
3. **N2-MINOR-3** — `server/config/runtime.exs:135-136`'s `media_iam_endpoint`/`media_sts_endpoint` app-env config is now a second, divergent, never-refreshed source of truth with zero current readers (verified by grep) — now invisible to any future consumer that reads it instead of `StorageConfig.get_for_connection/0`. Nothing to fix in this diff; a one-line warning comment in runtime.exs would prevent the trap for whoever wires a real consumer later.

## Carried MINORs (re-verified still open, unchanged from cycle 0/1)
No URL format validation (route to Kassandra) · Test Connection ignores iam/sts · widened SELECT fails open · no DB-override-vs-env UI signal · stale deployment doc · blank_to_nil/1 no non-binary catch-all (contract widened, still unreachable) · ambient System.get_env coupling only partially resolved (moved into get/0's safe_env fallback, 3 new tests don't stub the env-reader seam, latent flake if vars are exported locally) · nested hint span a11y pattern · UpCloud placeholder hash format.

## INFO
StorageConfig.get() now called twice per save (negligible, ETS-cached); @defaults being nil means Rule 2's non-convergence can't manifest via compiled defaults today; 3 stale test comments (one actively wrong: claims iam/sts follow blank-omit convention 40 lines after blank→nil is implemented); 2 over-length lines (cosmetic, no formatter gate); StorageConfig's own private blank_to_nil/1 doesn't trim (unrelated helper, same name); AC3 spec text still not updated in bug-context.md itself; migration quality reconfirmed solid.

## Bottom line
"The fix is correct, minimal, and well-tested... Nothing blocks the commit." Pausing for user decision on whether to spend a 3rd fix cycle on the 3 new MINORs (N2-MINOR-1 explicitly decision_needed) or accept them as documented/known and proceed to security-review.

---

# Cycle 3 re-review — VERDICT: CLEAN (0 new MAJOR), ship-able

All 3 cycle-2 MINORs (N2-MINOR-1/2/3) genuinely fixed, verified via full 2-axis decision-matrix hand-trace. Nothing from cycles 0-2 regressed (MAJOR-1 clear path, MAJOR-1 no-promotion, MAJOR-N1 override-to-env-value, empty-env-converges all re-traced and intact). `persisted_iam_sts/0` confirmed to read the raw DB row via the same seam as `persisted_target/0`, not the resolved value — the fix is substantive. Per-field independence confirmed. Both new tests are genuine regression guards (verified by mentally deleting each guard and confirming RED).

## MINOR (7 new, all narrow/edge-case)
1. **N3-M1** — `has_db_override?` isn't normalized through `blank_to_nil/1` like everything else; a DB column holding `""`/whitespace would be unclearable forever. Unreachable today (nothing writes `""`), one-word fix (`not is_nil(blank_to_nil(persisted_iam_sts.iam_endpoint))`).
2. **N3-M2** — the absent-param no-op doesn't survive a re-render round trip (`storage_config_from_params/1` turns absent into `""`, so a second POST after a bounced orphan-gate/invalid-input re-render can still clear). Narrower than N2-MINOR-2, bounds its completeness.
3. **N3-M3** — `persisted_iam_sts/0` conflates "no override" with "DB read failed" (same fail-open convention as `persisted_target/0` since story 11b) — now gates a write decision, not just a gate decision. Pre-existing conflation, new consequence.
4. **N3-M4** — the exact branch this whole fix hinges on ("row exists, column NULL") has zero test coverage — most actionable item if more work happens.
5. **N3-M5** — the AC4 `changed_storage_keys/1` test for iam/sts is only vacuously covered (rule 1 already omits before that function runs; proven it can never be reached for these two fields). Pre-dates cycle 3.
6. **N3-M6** — comment preamble now internally contradictory (says `/4` not `/5`, says "3-way" for a 5-branch cond, wrong doc-reference, cycle-2-vs-cycle-3 attribution mismatch, one stale test comment still claims blank-omit convention).
7. **N3-M7** — `docs/architecture/05-building-blocks.md:957-958`'s field catalog missing the two new columns (new finding, bundle with the other deferred doc items for Step 8).

## Carried MINORs (re-verified, all still open, mostly unchanged)
No validation on the two URL fields (**routed to Kassandra — with a correction: there is NO live request path, "dials on demand" claim was a layer false-positive, don't let it overstate the risk**) · Test Connection ignores iam/sts (contract now also documented-vs-actual mismatch) · widened SELECT fails open (impact now fully characterized: reverts entire config incl. credentials, bypasses orphan gate, overwrites with undiffed form data — same triage as cycle 0) · blank_to_nil/1 no non-binary catch-all (pre-existing parity, surface grew a 3rd time) · String.trim/1 doesn't strip zero-width chars (newly identified, pre-existing class) · no DB-override-vs-env UI signal (accepted cost of the cycle-1 decision, not a defect) · stale deployment doc (3rd cycle, deferred to Step 8) · AC3 spec text still says blank-omit (bug-context.md is the only spec of record since no story file exists) · ambient env-reader coupling narrowed from 3 tests to 2.

## Dismissed as false positives (do not re-raise, do not forward to Kassandra)
mix format non-compliance (no .formatter.exs/gate exists anywhere) · persisted_iam_sts/0 vs build_resolved/2 using different row-read helpers (row_get/2 is a bare Map.get passthrough, definitionally identical) · "Test Connection dials the new URLs on demand" (config_overrides/1 never reads iam/sts, zero live request path — only the absence-of-validation is real) · various speculative test-fixture concerns (all verified correct as written).

## Recommendation
"Nothing blocks the commit." MINOR count is narrowing each cycle (8→7→3→7, but each new round needs out-of-band SQL/transient DB failure/hybrid non-browser client to trigger) — diminishing returns, not instability. Reviewer explicitly recommends NOT running a full cycle 4; instead apply 3 cheap mechanical fixes as cleanup (not a dev↔review cycle): N3-M1 (blank_to_nil wrap), N3-M4 (one test), N3-M6 (comment tidy). Route the SSRF/validation item to Kassandra with the no-live-request-path correction; route the 3 doc items (07-deployment.md, 05-building-blocks.md, bug-context.md AC3) to Step 8 arc42-update.

---

# Post-security-review fix cycles (cycle 4, cycle 5) + final verification

**Cycle 4** implemented Kassandra's F-1 remediation: two-layer guard (controller `validate_changes_iam_sts/1` + model `validate_iam_sts_fields/1` in `upsert/1`) requiring `https://` scheme + `Nebu.Media.SSRF.checked_target/1` on any non-nil iam_endpoint/sts_endpoint value. 6 test fixture URLs switched to a literal public IP (93.184.216.34) since existing `.example.com`/`upcloudobjects.com` fixtures don't resolve under live DNS.

A focused review of cycle 4 found the model-layer guard correctly scoped (validates only the decided partial-update value) and the security objective genuinely closed, but the CONTROLLER-layer guard had a MAJOR regression (**R-1**): it validated the raw submitted param unconditionally, before the clear/no-op/override decision — so an untouched, env-sourced value that failed the new check would block ALL storage saves forever, not just writes to that field (strictly worse than `endpoint`'s own two-layer shape, which only SSRF-validates at the model layer where partial-update scoping already applies).

**Cycle 5** fixed R-1: moved the controller-layer check from "raw param, unconditional" to "the decided value in `changes`, post-`put_env_backed_field/5`" via new `validate_changes_iam_sts/1`/`validate_change_iam_sts_field/2`. Absent key or `nil` → `:ok` (nothing to validate); non-nil decided value → validated. 3 new regression tests (untouched invalid env value doesn't block unrelated saves; genuine new invalid override still blocked; blanking an existing bad DB value still clears).

**Final verification** (narrow-scope review): R-1 genuinely fixed (traced to the exact `Map.fetch`/rule-1/rule-3 branches), F-1's security property still holds (genuine override attempts still rejected, traced to SQL), explicit-clear-over-bad-value correctly never re-validates the value being discarded, no new bypass, model-layer defense-in-depth confirmed untouched and intact, all 3 new tests proven non-vacuous. 0 MAJOR. 2 trivial stale-comment MINORs (one dead-code cross-reference, one over-claiming test comment) — both fixed directly (not worth another cycle).

**Verdict: ready to commit.**
