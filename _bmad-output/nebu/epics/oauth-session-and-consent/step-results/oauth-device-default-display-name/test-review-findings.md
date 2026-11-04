# Test review (pre-dev): oauth-device-default-display-name (REQ-2026-004)

Reviewer: nebu-test-reviewer (read-only, static; red/green and 47/47 mutants taken from the ATDD report). 0 MAJOR, 6 MINOR, 6 INFO. All 5 scenarios and the rules have non-vacuous tests; the Gherkin is byte-unchanged (only `## Decisions` appended); shared support and existing tests not weakened (only +4 lines in test_helper.exs); no sleeps or hard waits.

## MINOR
1. docs_test.exs:86-95 time bomb: hard-codes `n > 57` although 000058 is reserved for another story; pin the intent differently (this story adds no migration of its own) or drop. erasure_test.exs:45 hard-codes the seven `devices` columns; the `refute` at :46 is near-tautological.
2. docs_test.exs:76-84 matches source text (`UPDATE devices\s+SET display_name`, the literal call string `Nebu.Matrix.DeviceKeyStore.upsert_device(attrs.user_id, attrs.device_id,`, `")\n"` splitting); flow tests already pin never-overwrite behaviourally (:147-229): keep at most the `IS NULL` substring.
3. docs_test.exs:27-58 pins ~25 prose tokens in 08-concepts and CHANGELOG ("last 8", "64", `plain text`, `empty (string|name)`, `no migration`): too coupled to the dev's wording; use a smaller set of anchors.
4. docs_test.exs:64 `refute src =~ ~r/\bLogger\b/` covers @moduledoc too: strip comments/docs first or match `Logger\.(debug|info|warn|error)`.
5. flow_test.exs:188 clears the name with `DeviceKeyStore.rename_device(..., "")`, bypassing the API; use `D.put_name!(first.at, "BLANKDEV01", "")` so the real client path is pinned.
6. `PUT /devices/{id}` without `display_name` sets NULL (rename_device writes `$3` as given); per Decision 5 the next OAuth login re-names that device. Mutant M46 pins it at store level only: add one flow test through the API (or revisit open question 2).

## INFO
7 over-specification vs the Gherkin (exact outputs `<script>alert(1)</script>` => "alert(1)", "<<b>script>x" => "scriptx", constant 64): stated in the Decisions, owner should confirm 64; 8 entity-encoded markup, quotes and emoji deliberately kept (open question 3); 9 the debug request logger writes the GET /devices response body incl. names: not pinned (outside this story); 10 failure modes (UPDATE fails -> issuance rolls back) and revoked/pending/rejected clients are only tested at `for_client/2` level; 11 no weak assertions found (exact equality on names/suffixes, only :164 and erasure `=~ " (ASEDEV01)"` are suffix-specific substrings; `refute name =~ cid/sub/localpart` are guards); 12 isolation fine (flow/erasure async: false, unique subs, Logger level restored).
