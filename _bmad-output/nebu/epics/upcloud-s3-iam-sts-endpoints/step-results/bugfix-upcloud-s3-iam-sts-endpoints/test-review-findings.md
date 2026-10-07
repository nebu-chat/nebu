# Test Review: bugfix-upcloud-s3-iam-sts-endpoints (AC1)

**Scope:** Staged diff to `server/test/nebu/media/storage_config_test.exs` (moduledoc addition, AT1 extension, new `iam-sts-AT1`/`iam-sts-AT2`). Verified against `server/lib/nebu/media/storage_config.ex` (`@defaults`, `build_resolved/2`, `validate_candidate_endpoint/1`) and `bug-context.md`.

## Findings

**MINOR — Independent per-field env resolution not tested.** `iam-sts-AT2` sets both `NEBU_MINIO_IAM_ENDPOINT` and `NEBU_MINIO_STS_ENDPOINT` simultaneously; no test exercises only one being set (the other staying `nil`). Risk is low — `default_env_reader/0` already resolves all 8 existing keys independently via per-key `maybe_put_env/2` calls, and the dev-story step will almost certainly follow that exact pattern — but it's a real gap in the matrix, not just a style nit. Not MAJOR because an incorrect "coupled" implementation is implausible given the established pattern, but worth a one-line addition if cheap.

**NOT A GAP — full-URL-vs-bare-host contract IS asserted, not just documented.** `iam-sts-AT2` uses `"https://7mf5k.upcloudobjects.com:4443/iam"` (scheme + port + path) and asserts byte-exact round-trip through both `get/0` and `get_for_connection/0`. Verified `validate_candidate_endpoint/1` (storage_config.ex:944) *rejects* (not strips) any `http://`/`https://`-prefixed candidate. If a future/incorrect implementation wrongly routed `iam_endpoint`/`sts_endpoint` through that function, the test would fail loudly, not silently pass. Contract distinction is behaviorally enforced, not merely commented.

**NOT A GAP — AT1 extension is safe.** Purely additive (`iam_endpoint: nil, sts_endpoint: nil` appended); all pre-existing key/value pairs from stories 11a/11b/11c are untouched. No intent drift.

**INFO — Default-nil and env-resolution coverage is complete for both read functions.** `iam-sts-AT1` covers `get/0`/`get_for_connection/0` default-nil; `iam-sts-AT2` covers both functions' env resolution and explicitly proves no masking is applied.

**INFO — No hard waits, no non-determinism, no brittle seams.** New tests use the established `Application.put_env(:nebu_http, :media_storage_env_reader, fn -> ... end)` seam identically to existing AT2/AT3/AT8.

**INFO — Naming overlap.** `iam-sts-AT1`/`iam-sts-AT2` names echo the file's pre-existing top-level `AT1`/`AT2`. No functional collision, purely a readability nit.

## Verdict

No MAJOR findings. AC1 coverage is adequate (default-nil + env-resolution, both read functions); the full-URL contract is genuinely asserted. One MINOR (independent-field resolution) worth an optional follow-up, not blocking.
