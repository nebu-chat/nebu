# Code Review Findings — 11a-storage-config-schema-secrets (cycle 0)

Verdict: no MAJOR/CRITICAL findings. Core secrets-handling contract implemented correctly (migration+GRANT, SecretBox-only encryption, masking, audit metadata shape, supervisor mirroring, per-field precedence, partial-update semantics, ADR-020 boundary, guardrails) all verified sound.

## MINOR findings (fix before proceeding)

MINOR-1 — Decrypted plaintext access_key/secret_key are cached in a `:protected` ETS table (server/lib/nebu/media/storage_config.ex, ensure_table/do_refresh), which is VM-globally readable by any process (`:ets.lookup(:nebu_media_storage_config, :catalog)`), bypassing the get/0-masking / get_for_connection/0-is-the-only-sanctioned-path design AC6/AC8 build. get_for_connection/0 is only used for Story 11b's rare "Test Connection" action, not a hot path, so the stated rationale (avoid re-decrypting on every read) is weak. FIX: cache only ciphertext (or non-secret fields + ciphertext) in ETS; decrypt on demand only inside get_for_connection/0, confining plaintext to a short-lived local.

MINOR-2 — decrypt_secret/1 handles decrypt failure inconsistently: a corrupted/wrong-key ciphertext silently falls back to the env-var credential (no log), while a genuinely-unset at-rest secret lets SecretBox.decrypt/1's raise propagate unguarded out of get/0 / the GenServer's :ttl_tick refresh (crash-loop risk, bounded by supervisor's 1000/5s but still incorrect). FIX: log a warning on decrypt failure instead of silently substituting the env-var value; guard the unset-secret raise path so a refresh tick doesn't crash the process (e.g. rescue and log, keep serving stale/masked-nil rather than crash-looping).

## INFO findings (no action required, noted for record)

INFO-3 — upsert/1 uses unconditional GenServer.call(__MODULE__, :refresh) instead of Config's defensive trigger_refresh/0 no-op-if-down guard; per story skeleton literally, low practical risk given unconditional supervision.
INFO-4 — write_audit/2 records Map.keys(fields) (raw input keys) not the columns actually written by build_columns/1; an unknown/no-op key would be audited as "changed" though nothing persisted. Low impact (caller-controlled).
INFO-5 — mask_secret/1 reveals the full plaintext for secrets <=4 chars (cosmetic, matches AC8's example format).
INFO-6 — Story's own AC1 prose (line ~124) says INSERT policy is `WITH CHECK (true)` but the story's own SQL block and the implemented migration correctly use `WITH CHECK (id = 1)` (stricter, correct) — spec-prose inconsistency only, code is right.
INFO-7 — AC1 live-DB verification rests on the dev-story/CI-gate `make redeploy` step (confirmed green, migration applied with no error) rather than a fresh independent DB check in this review pass. Also: resolve_env_secret/3's File.read! on a missing _FILE path would raise out of get/0 at runtime — same class of unguarded-raise concern as MINOR-2, low likelihood.

Recommend MINOR-1 and MINOR-2 be flagged explicitly to the Kassandra security-review pass (this story has security_review: required).

## Cycle 1 re-review (post-fix verification)

Both MINOR-1 and MINOR-2 confirmed RESOLVED (traced full call chains: do_refresh/0 never calls SecretBox.decrypt/1; decryption only happens on-demand inside resolved/0 -> build_resolved/2, fresh on every get/0 and get_for_connection/0 call, never memoized; exception matching for the rescue clause verified correct against SecretBox.at_rest_key/0's actual RuntimeError raise; write-path/upsert/1's fail-closed raise confirmed unchanged/still propagating per AT12). No new issues introduced by the refactor. Test file confirmed unchanged/unweakened. Residual INFO notes only (pre-existing File.read! raise class, out of scope). CLEAN — proceeding to security review.
