# Code Review — Story 11b (Storage UI + Test Connection) — cycle 0

**Verdict:** no MAJOR/CRITICAL findings. 2 MINOR, 3 INFO.

## Focus-area verification (all PASS)
1. AC4 orphan gate — genuine server-side gate, correct fresh/zero-count/non-endpoint-bucket exclusions, submitted values preserved.
2. AC2 secret write-only — masked presence indicators only, no plaintext to template.
3. SSRF/scheme guard — wired on both Save and Test Connection paths, fails closed, re-renders at 200.
4. ADR-018/020 — no Ecto.Changeset, no direct SQL against media_storage_config, save via upsert/2 only, count query correctly inline in Nebu.Admin.DB.
5. Candidate config — config_overrides built from candidate map, not active Storage config.
6. Error leakage — fixed messages only, raw reason server-side logged only.
7. upsert/2 keys — only known fields passed.
8. Non-persistence — test_connection never reaches upsert/2 on any path.

## Findings

**MINOR-1** — `storage_config.ex:790-796`: hand-built `%ExAws.Operation.S3{http_method: :head, ...}`
with a comment/moduledoc claiming `ExAws.S3.head_bucket/1` doesn't exist in pinned ex_aws_s3 2.5.9.
That claim is factually wrong — `head_bucket/1` exists and is public (`request(:head, bucket, "/")`),
and the hand-built struct is functionally equivalent (no behavioral bug), but it deviates from the
story's explicit Technical Requirement and embeds a false justification in code/moduledoc. Fix:
use `ExAws.S3.head_bucket(candidate.bucket) |> ExAws.request(config_overrides(candidate))` and
remove the false comments.

**MINOR-2** — `save_storage/2`/`validate_storage_params/1`: does not diff submitted values against
the persisted config before building `changes` — always includes endpoint/bucket/use_ssl (and
region/s3_key_prefix_template when non-blank) regardless of whether they actually changed. Since
upsert/2 records `changed_fields: Map.keys(fields)`, every save logs a near-full field set as
"changed" even on a no-op/single-field edit — inconsistent with 9b's own `changed_keys/2` diffing
(added in 9b cycle 1 for the same reason) and degrades audit-trail fidelity. Fix: diff submitted
values against `StorageConfig.get/0`/`persisted_target/0` before building `changes`, mirroring 9b's
`changed_keys/2`.

**INFO-1** — persisted_target/0 may over-warn (fail-safe direction) after a partial upsert. No action.
**INFO-2** — count_media_with_storage_key/0 uses query! (raises on transient DB error); matches other Admin.DB helpers. No action.
**INFO-3** — access-key ID (not secret) may reach logs via inspect(reason) in test-connection failure logging; explicitly permitted by story guardrail. Noted only.

**Recommendation:** No user decision required. Hand MINOR-1 and MINOR-2 back to dev agent.
