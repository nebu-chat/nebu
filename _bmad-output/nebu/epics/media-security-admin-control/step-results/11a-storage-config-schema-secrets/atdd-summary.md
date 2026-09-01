# ATDD Summary — 11a-storage-config-schema-secrets

12 failing tests written to server/test/nebu/media/storage_config_test.exs (AT1-AT12), all fail with UndefinedFunctionError (Nebu.Media.StorageConfig does not exist yet). No lib/ or migration files touched.

## Judgment calls flagged for dev-story:
1. Env-var fallback seam: Application.get_env(:nebu_http, :media_storage_env_reader) — 0-arity fun returning string-keyed map, per story's explicit "app-env seam, not real OS env vars" directive for AT2.
2. get/0 / get_for_connection/0 assumed to work WITHOUT the GenServer running (mirrors Nebu.Media.Config's :ets.whereis-guarded direct-loader fallback).
3. upsert/1 assumed to unconditionally call GenServer.call(__MODULE__, :refresh) (per skeleton's literal text) — tests call ensure_started() first.
4. Masked-marker format pinned as "••••" <> last 4 plaintext chars (AC8 gave this only as an example).
5. Invented :media_storage_config_writer seam: fn columns, set_at -> :ok | {:error, term()} end, partial string-keyed column map (already-encrypted secrets).
6. Migration number confirmed as 000024 (000023 already taken by media_config/9a) — GRANT ... TO nebu_app REQUIRED per migrations_grant_test.exs precedent (F-1 HIGH finding from 9a's own Kassandra review — do not repeat).
7. No pg_group/0 helper assumed — tests use literal "nebu_media_storage_config" string directly.
