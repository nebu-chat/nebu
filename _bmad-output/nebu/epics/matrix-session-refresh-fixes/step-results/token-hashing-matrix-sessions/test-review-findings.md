# Test review — token-hashing-matrix-sessions (pre-dev)
Verdict: 0 MAJOR, 9 MINOR, 9 INFO. AC1–AC6 covered, AC7 (docs) untested by design. No assertion weakened while porting (oracle test now `flunk` = stricter). No crash/restart test needed.

## MINOR — to be handled by the dev agent (tests unless noted)
- M-1 (most important, AC5): `config/test.exs` sets `config :logger, level: :warning`, so `capture_log([level: :debug], ...)` captures no debug/info lines. RequestLogger logs at debug/info and is the likeliest leak source. Fix: in setup `Logger.configure(level: :debug)` and restore in `on_exit` (see http_foundation_test.exs / cors_plug_test.exs); add a positive control (`assert log =~ "<known debug line>"`) proving capturing works, THEN refute token/hash in log.
- M-2: release_test.exs does not detect duplicate/gapped migration numbers: add `assert versions == Enum.uniq(versions)` and `assert versions == Enum.to_list(1..length(versions))` (still not hardcoded; tolerant of another pipeline adding 000035 as long as numbering is contiguous and unique).
- M-3: migration test temp DB name `nebu_hashmig_<System.unique_integer>` collides across parallel mix runs; add a random suffix (e.g. `:crypto.strong_rand_bytes(4) |> Base.encode16`). Optional: `setup_all` drops stale `nebu_hashmig_%` databases.
- M-4: remove the "`hash_token(` appears >= 8x in the store" count guard (keep `def hash_token(`); behaviour tests already prove every op hashes.
- M-5: relax the `ORDER BY access_token_hash` >= 2x counter and the literal `refresh_token_hash = $1 ... FOR UPDATE` guard in the NEW guard tests (a shared SQL fragment/CTE would be legitimate). The pre-existing ported lock tests that match `pg_stat_activity` text stay as they were (inherited coupling), but make the matching tolerant (`refresh_token_hash` + `FOR UPDATE`, not the exact `= $1`).
- M-6: migration static-check regexes pin the backfill formula text exactly (`encode(sha256(convert_to(access_token,'UTF8')),'hex')`); the behavioral tests already check the backfilled value == sha256_hex == Store.hash_token. Loosen or drop the textual regexes; loosen the down-migration header check (not just contiguous `--` head).
- M-7: `hash_token/1` for non-binary input: assert that SOME exception is raised (FunctionClauseError OR ArgumentError) rather than exactly FunctionClauseError.
- M-8: exact map key names `:access_token_hash`/`:refresh_token_hash` are an implementation detail but are the agreed contract (used by hash-addressed worker/http_public handling); keep, no change required.
- M-9: migration test environment: skip (not raise) with a clear message when `NEBU_DB_URL_MIGRATE` is absent/lacks CREATEDB; decode URL userinfo; do not hard-code `ssl: false` if the repo has an env for it (postgres-ssl-env-var story).

## Design note for dev (from ATDD)
- RefreshWorker and HttpPublic.do_refresh_with take `sess.access_token` from session maps; with hash-only maps they need hash-addressed store variants (e.g. `*_by_hash`).
- INFO I-4 (optional extra tests): backfill edge cases (NULL oidc_refresh_token/auth_time, created_at preserved, legacy rows with a future grace_until count as consumed), down migration restores `idx_matrix_sessions_refresh_token`.
- INFO I-5: grep guards strip @doc/@moduledoc heredocs and `#` lines; inline comments after code are not stripped.
