---
story_id: 11a-storage-config-schema-secrets
title: "Object Storage Target Configuration: Storage Config Schema + Secret-Encrypted Persistence"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Since ADR-INFRA-0 (`Nebu.Media.Storage`, pre-epic), the S3/MinIO object storage
target has been wired exclusively through boot-time `NEBU_MINIO_*`/`NEBU_S3_REGION`
env vars in `server/config/runtime.exs`, with no admin-facing way to change the
endpoint, bucket, or credentials without a redeploy. The epic's Story 11
("Object Storage Target Configuration") closes this gap the same way Story 9
closed it for policy values (ADR-022's bootstrap-config precedent) — but the
epic's own Review 8 (Offene Entscheidung #9) explicitly flags that, unlike
Story 9a's plain scalar values, `access_key`/`secret_key` are genuine
credential secrets and **must not** be persisted as plaintext `TEXT`. It
directs the dev-story to "identify and reuse the existing field-encryption
pattern (analog `email_encrypted`)" before implementation.

Grepping the codebase for that pattern surfaces **`Nebu.Web.SecretBox`**
(`server/lib/nebu/web/secret_box.ex`) — a small, already-shared, already-used-
twice-over module that is a better fit than either of the two PII-encryption
tiers in `Nebu.Matrix.Signature`:

- `Nebu.Matrix.Signature.encrypt_operational_pii/2` (Tier 1: static
  `NEBU_PII_ENCRYPTION_KEY`, used for `display_name_encrypted`) and
  `encrypt_sensitive_pii/2` (Tier 2: per-record ECIES/X25519, used for
  `email_encrypted`, deliberately "forgettable" by deleting the recipient's
  private key) both exist to protect **user PII** under a DSGVO
  right-to-erasure model. Tier 2 in particular is built so the data becomes
  **permanently irrecoverable** once its private key is deleted — exactly the
  wrong property for an operator credential the server must be able to decrypt
  indefinitely to keep talking to its own storage backend.
- `Nebu.Web.SecretBox.encrypt/1` / `decrypt/1` is the pattern actually built
  for **operator secrets that must stay decryptable forever**: `hex(nonce ‖
  Nebu.Media.Crypto.encrypt(plaintext, key, nonce))`, `key =
  SHA-256(NEBU_INTERNAL_SECRET)` (fails closed — refuses to encrypt under
  `SHA-256("")` if no internal secret is configured). Its own moduledoc says
  it "[f]actors the encrypt/decrypt pattern previously inlined in
  `Nebu.Admin.BootstrapLive`" (`encrypt_secret/1`/`decrypt_secret/1`, used
  today for `server_config.oidc_client_secret`) specifically so a second
  admin-configurable secret (the Matrix session store's encrypted OIDC
  refresh token) would not duplicate it. `access_key`/`secret_key` are a third
  case of the identical shape — an admin-entered credential, persisted once,
  decrypted on every use — so this story reuses `Nebu.Web.SecretBox` rather
  than adding a fourth ad-hoc AES-256-GCM call site. `Nebu.Web` is shared
  infrastructure (CLAUDE.md), so calling it from `Nebu.Media` is not a
  cross-domain violation under ADR-020.

The epic also leaves open, explicitly for this story to decide, whether the
new fields live in a **`media_storage_config` table** or as an **extension of
`media_config`** (Story 9a). This story concludes: **a dedicated
`media_storage_config` table**, not an extension of `media_config`, for two
reasons this story is best placed to state precisely:

1. **Row shape mismatch.** `media_config` (ADR-027, Story 9a) is a uniform
   `key TEXT PRIMARY KEY, value TEXT NOT NULL` fan-out of independently-set
   scalar policy knobs. Storage target configuration is the opposite shape —
   one cohesive object (`endpoint`, `bucket`, `region`, `use_ssl`,
   `access_key`, `secret_key`, `s3_key_prefix_template`, `archive_bucket`) that
   is read and written as a whole. Encoding two encrypted-secret fields into
   that generic all-`TEXT` key/value shape would work mechanically (the
   `SecretBox` blob is already a hex string) but would sit two structurally
   different trust tiers — plain operational policy values
   (`mime_denylist`, `max_upload_size_bytes`) and encrypted credential
   blobs — as visually identical rows in the same table, inviting exactly the
   kind of "just SELECT the row and log it" mistake this story's own
   guardrails exist to prevent.
2. **ADR-027's own separation rationale applies a second time.** ADR-027
   introduced `media_config` as its own table specifically so its `:pg`
   cache-invalidation traffic (broadcast on every upload/scan-limit change,
   a hot path) never entangles with an unrelated config domain's
   invalidation. Storage target changes are rare, security-sensitive, and
   read on a completely different code path (S3 client construction, not
   per-upload policy checks) — folding them into `media_config`'s
   invalidation group would recreate the exact coupling ADR-027 was written
   to avoid, just one level down.

`media_storage_config` therefore follows the *pattern* Story 9a/ADR-027
established (RLS-gated table, ETS+`:pg`-broadcast cache with a bounded TTL
fallback, one audit-logged write seam) but is its **own** table, its own
cache instance, and — per the above — not itself an ADR-027 artifact; ADR-027
stays scoped to Story 9a's key/value policy catalog.

## User Story

As the Nebu server operator, I want to configure the S3/MinIO storage target
(endpoint, bucket, region, credentials, key-prefix template, archive bucket)
from a single admin-configurable record whose secret fields are encrypted at
rest, with the existing `NEBU_MINIO_*` env vars still working until I save a
value through the admin UI, so that I can migrate off boot-time env-var
configuration without a redeploy and without my credentials ever appearing in
a database dump or log line as plaintext.

## Acceptance Criteria

1. **AC1 — Migration creates `media_storage_config` as a singleton row.** A
   new migration creates:
   ```sql
   CREATE TABLE media_storage_config (
       id                     SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
       endpoint               TEXT,
       bucket                 TEXT,
       region                 TEXT,
       use_ssl                BOOLEAN,
       access_key_encrypted   TEXT,
       secret_key_encrypted   TEXT,
       s3_key_prefix_template TEXT,
       archive_bucket         TEXT,
       set_at                 BIGINT NOT NULL
   );
   ```
   with the `CHECK (id = 1)` constraint enforcing at most one row (there is
   exactly one storage target, not a keyed catalog — see Summary for why this
   is a distinct schema shape from `media_config`). RLS enabled/forced,
   mirroring `server_config`/`media_config`'s `FOR SELECT USING (true)` /
   `FOR INSERT WITH CHECK (true)` shape; `FOR UPDATE USING (id = 1)` (every
   column here is admin-mutable — there is no immutable-key subset to
   allowlist, unlike `media_config`).
2. **AC2 — Field catalog.** The table holds exactly: `endpoint` (host:port or
   host, no scheme), `bucket`, `region` (kept for parity with
   `NEBU_S3_REGION` — MinIO ignores it but S3-compatible targets that check it
   need it), `use_ssl` (boolean), `access_key`/`secret_key` (secret, see AC3),
   `s3_key_prefix_template` (consumed by Story 11c; this story only persists
   it, does not interpret placeholders), `archive_bucket` (consumed by Story
   8c's archive-tier copy; same endpoint/credentials, distinct bucket name —
   no separate archive endpoint, per the epic's explicit YAGNI call).
3. **AC3 — Secret fields encrypted at rest via `Nebu.Web.SecretBox`.**
   `access_key` and `secret_key` are never written to
   `access_key_encrypted`/`secret_key_encrypted` as plaintext. Every write
   encrypts via `Nebu.Web.SecretBox.encrypt/1` (AES-256-GCM,
   `SHA-256(NEBU_INTERNAL_SECRET)`-derived key, `hex(nonce ‖ ciphertext ‖
   tag)` — the same primitive already used for `server_config
   .oidc_client_secret` and the Matrix session store's encrypted refresh
   token) before the `INSERT`/`UPDATE`; every read for actual S3-connection
   use decrypts via `Nebu.Web.SecretBox.decrypt/1`. No second, parallel
   AES-256-GCM call site is introduced for this story (see Dev Agent
   Guardrails) — reuse, not reinvention, matching ADR-027/Story 9a's own
   "reuse `Nebu.Media.SSRF.check/1`, don't reimplement" precedent for
   `webhook_url`.
4. **AC4 — Env-var fallback preserved.** Before an admin has ever saved a
   storage config (no row in `media_storage_config`, or a row with a given
   field `NULL`), `Nebu.Media.StorageConfig.get/0` falls back field-by-field
   to the existing boot-time env vars already read in
   `server/config/runtime.exs`:
   | Field | Env var(s) | Existing default |
   |---|---|---|
   | `endpoint` | `NEBU_MINIO_ENDPOINT` | `"minio:9000"` |
   | `use_ssl` | `NEBU_MINIO_USE_SSL` | `false` |
   | `bucket` | `NEBU_MINIO_BUCKET` | `"nebu-media"` |
   | `region` | `NEBU_S3_REGION` | `"us-east-1"` |
   | `access_key` | `NEBU_MINIO_ACCESS_KEY_FILE` (Docker secret path, read first) or `NEBU_MINIO_ACCESS_KEY` | `""` |
   | `secret_key` | `NEBU_MINIO_SECRET_KEY_FILE` (Docker secret path, read first) or `NEBU_MINIO_SECRET_KEY` | `""` |
   | `s3_key_prefix_template` | *(none — new field)* | `"{media_id}"` (Story 11c's flat-key-compatible default) |
   | `archive_bucket` | *(none — new field)* | `nil` (archive tier disabled until set) |

   This is the identical `_FILE`-then-plain env-var precedence
   `server/config/runtime.exs` already implements for the boot-time path
   (lines 85–95) — this story's fallback reads the same two env vars per
   secret field, it does not introduce a third source.
5. **AC5 — DB config takes precedence once set.** Once an admin saves a
   value for a given field via `upsert/1`, `get/0` returns the DB value for
   that field on every subsequent call, on every node, regardless of what the
   env vars are still set to (no restart required — see AC7's cache
   mechanism). Precedence is **per field**, not all-or-nothing: an admin can
   save `endpoint`/`bucket` while leaving `access_key`/`secret_key` on the
   env-var fallback (e.g. mid-migration), matching `media_config`'s existing
   per-key-not-monolithic override behavior (Story 9a AC2).
6. **AC6 — `Nebu.Media.StorageConfig` public API (ADR-020).** A new module
   exposing:
   - `get/0` — returns the merged config map (AC4/AC5) with `access_key` and
     `secret_key` **masked** (see AC8) — this is the general-purpose read
     used by the settings UI (Story 11b) and any status/health display.
   - `get_for_connection/0` — returns the same map but with `access_key`/
     `secret_key` **decrypted to plaintext** — the only sanctioned way to
     obtain real credential bytes, intended for actual `ExAws`/S3-client
     construction (Story 11b's "Test Connection", and any later story that
     rewires `Nebu.Media.Storage` itself). Not exposed to any LiveView
     template or JSON-serializing endpoint.
   - `upsert/1` — `upsert(%{field => value, ...})`, a partial-update map (an
     admin form that only changed `bucket` does not have to resend
     `access_key`). The **only** write path to `media_storage_config`.
7. **AC7 — Changes take effect without a restart.** Same cache mechanism as
   `Nebu.Media.Config` (Story 9a)/`Nebu.Web.OidcConfig`, but its **own**
   separate instance (own ETS table `:nebu_media_storage_config`, own `:pg`
   group `"nebu_media_storage_config"`) — GenServer-owned ETS cache,
   cluster-wide invalidation broadcast over `:pg` on every successful
   `upsert/1`, plus a 60-second TTL fallback re-read so a node that misses a
   broadcast (network partition) does not serve a stale endpoint/credential
   indefinitely. Not the same cache instance as `Nebu.Media.Config` — see
   Summary's point 2 for why sharing it would recreate the coupling ADR-027
   avoided.
8. **AC8 — Secrets never logged or exposed in plaintext via any read API.**
   `get/0` (and any future JSON/LiveView-facing serialization built on it)
   returns `access_key`/`secret_key` **masked** — either `nil` when unset, or
   a fixed non-reversible marker (e.g. `"••••" <> last 4 plaintext chars`,
   matching the "partially visible for admin recognition, not reproducible"
   convention already implied by the epic's Story 11b "Test Connection"
   design, which needs the admin to recognize *which* credential is active
   without seeing it in full). The raw ciphertext columns
   (`access_key_encrypted`/`secret_key_encrypted`) and the plaintext
   decrypted values are **never** passed to `Logger.*`, `IO.inspect`, or any
   audit-log `metadata` map — AC9's audit entries record only which field
   names changed, never `old_value`/`new_value` for `access_key`/`secret_key`
   (contrast with `media_config_updated`'s `old_value`/`new_value` pair,
   which is safe only because none of *that* table's keys are secrets).
9. **AC9 — Audit trail without secret leakage.** Every successful `upsert/1`
   writes a `media_storage_config_updated` audit-log entry via
   `Nebu.Compliance.AuditWriter` with `metadata: %{changed_fields:
   [<atom>, ...]}` — the list of field names that changed, **never** their
   values (secret or not — `endpoint`/`bucket`/`region` changes are also
   recorded as field names only, for consistency and because AC-required
   "N existing files become unreachable" warnings belong to Story 11b's UI,
   not the audit entry). `media_storage_config_updated` is added to
   `AuditWriter.@known_actions`.

## Acceptance Tests

New test file `server/test/nebu/media/storage_config_test.exs` (ExUnit;
matches Story 9a's `config_test.exs` seam-injection conventions — the
`:oidc_config_source`-style app-env seam `Nebu.Web.OidcConfig` established,
and the `FakeRepo`-style DB double already used elsewhere for modules that
read Postgres directly):

1. `"get/0 with no row and no env vars set returns the config.exs-matching
   defaults, access_key/secret_key masked as nil"` — asserts every AC4-table
   default, in particular `s3_key_prefix_template: "{media_id}"` and
   `archive_bucket: nil`.
2. `"get/0 with no row but NEBU_MINIO_* env vars set falls back to the env
   vars"` — sets `NEBU_MINIO_ENDPOINT`/`NEBU_MINIO_BUCKET`/
   `NEBU_MINIO_ACCESS_KEY`/`NEBU_MINIO_SECRET_KEY`/`NEBU_S3_REGION`/
   `NEBU_MINIO_USE_SSL` via the app-env seam (not real OS env vars — matching
   how `server/config/runtime.exs`'s values are already injected into
   `:nebu_http`/`:ex_aws` app env at boot in tests), asserts `get/0` reflects
   them, with `access_key`/`secret_key` masked (never the raw env-var value).
3. `"get/0 prefers a Docker-secret-file access/secret key over the plain env
   var when both are present"` — mirrors `server/config/runtime.exs`'s
   existing `_FILE`-then-plain precedence (lines 85–95); a fixture file path
   wins over a simultaneously-set `NEBU_MINIO_ACCESS_KEY`.
4. **Encryption round-trip:** `"upsert/1 with access_key/secret_key persists
   SecretBox-encrypted ciphertext, and get_for_connection/0 decrypts it back
   to the original plaintext"` — asserts (a) the DB row's
   `access_key_encrypted`/`secret_key_encrypted` columns are NOT equal to the
   plaintext input, (b) `Nebu.Web.SecretBox.decrypt/1` applied directly to
   the stored column value returns the original plaintext (proves the exact
   shared primitive was used, not a look-alike), (c) `get_for_connection/0`
   returns the original plaintext for both fields.
5. **Masked in any admin-facing read:** `"get/0 never returns the plaintext
   access_key/secret_key even immediately after upsert/1 on the same
   process"` — write a credential, call `get/0` (not
   `get_for_connection/0`), assert the returned value is the masked marker,
   not the plaintext and not the raw ciphertext.
6. `"upsert/1 with only endpoint/bucket leaves a previously-saved
   access_key/secret_key untouched (partial update)"` — asserts AC6's
   partial-map `upsert/1` semantics.
7. **Env-var fallback works when no DB config exists:** `"a fresh
   media_storage_config table with env vars set behaves identically to the
   pre-Story-11a boot-time NEBU_MINIO_* wiring"` — cross-checks against the
   literal defaults `server/config/runtime.exs` hardcodes (`"minio:9000"`,
   `"nebu-media"`, `"us-east-1"`, `use_ssl: false`).
8. **DB config takes precedence once set:** `"after upsert/1 sets endpoint,
   get/0 returns the DB value even though NEBU_MINIO_ENDPOINT is still set to
   a different value"` — proves per-field precedence, not "ignore env vars
   globally once any field is saved."
9. `"upsert/1 writes a media_storage_config_updated audit-log entry with
   changed_fields naming only the fields that changed, and no old_value/
   new_value key at all"` — asserts the metadata shape has no path by which
   a secret value could leak into the audit log, and that changing only
   `bucket` does not list `access_key` in `changed_fields`.
10. `"a second GenServer node's cache reflects an upsert via the :pg
    broadcast without calling get/0 a second time on the writing node"` —
    same shape as Story 9a's AT-10, against this story's own separate `:pg`
    group/ETS table.
11. `"a node that misses the :pg broadcast still serves the new value within
    the 60s TTL fallback window"` — same shape as Story 9a's AT-11, via an
    injectable time source.
12. `"SecretBox.encrypt/1 raises (fail-closed) if NEBU_INTERNAL_SECRET is
    unset when upsert/1 is called with a secret field"` — asserts the
    existing `Nebu.Web.SecretBox` fail-closed behavior is not silently
    swallowed into a stored-plaintext fallback by this module's `upsert/1`.

## Technical Requirements

### Migration

**Correction (pre-dev test-review, cycle 1):** `000023` is already claimed on
disk by Story 9a's `media_config` migration (confirmed present in
`server/priv/migrations/` at ATDD time for this story) — this story's
migration is therefore `server/priv/migrations/000024_media_storage_config.up.sql`
(number **TBD at final merge** only if a third story's migration lands in
between; per the epic's "whichever lands first keeps its number" convention).

```sql
-- ─── media_storage_config ────────────────────────────────────────────────
-- Singleton-row S3/MinIO storage target configuration (Story 11a). NOT an
-- extension of media_config (ADR-027/Story 9a) — see the story's Summary for
-- why this is a distinct table: one cohesive object vs. a fan-out of scalar
-- policy keys, and a distinct (rare, security-sensitive) cache-invalidation
-- domain that must not couple to media_config's hot-path invalidation group.
CREATE TABLE media_storage_config (
    id                     SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    endpoint               TEXT,
    bucket                 TEXT,
    region                 TEXT,
    use_ssl                BOOLEAN,
    -- access_key_encrypted/secret_key_encrypted hold Nebu.Web.SecretBox
    -- ciphertext blobs (hex(nonce ‖ AES-256-GCM ciphertext ‖ tag)) — NEVER
    -- plaintext. See Nebu.Media.StorageConfig for the only read/write path.
    access_key_encrypted   TEXT,
    secret_key_encrypted   TEXT,
    s3_key_prefix_template TEXT,
    archive_bucket         TEXT,
    set_at                 BIGINT NOT NULL
);

ALTER TABLE media_storage_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_storage_config FORCE ROW LEVEL SECURITY;

CREATE POLICY storage_config_read_all ON media_storage_config FOR SELECT USING (true);
CREATE POLICY storage_config_insert_only ON media_storage_config FOR INSERT WITH CHECK (id = 1);
CREATE POLICY storage_config_update_singleton ON media_storage_config FOR UPDATE USING (id = 1);

-- REQUIRED (pre-dev test-review, cycle 1 — same F-1/HIGH class of gap
-- Kassandra found in 9a's original media_config migration, see
-- Nebu.Matrix.MigrationsGrantTest's moduledoc): in production (UpCloud
-- managed PostgreSQL) `nebu_migrate` owns tables and `nebu_app` is the
-- runtime role; there is no ALTER DEFAULT PRIVILEGES there (that only
-- exists in the dev docker-compose setup, which is why omitting this GRANT
-- would stay green in CI/dev while failing closed in production — every
-- get/0 load and upsert/1 write would hit "permission denied"). No
-- auto-incrementing columns here, so no companion sequence GRANT is needed.
GRANT SELECT, INSERT, UPDATE, DELETE ON media_storage_config TO nebu_app;
```

`server/priv/migrations/000024_media_storage_config.down.sql`: `DROP TABLE
media_storage_config;`.

**Mandatory:** `server/test/nebu/matrix/migrations_grant_test.exs` MUST be
extended with a new `describe` block for `000024_media_storage_config.up.sql`
(AC1: asserts the table + the GRANT above; AC2: asserts no SERIAL/BIGSERIAL
columns, so no sequence GRANT is required) and the down-migration filename
added to `@down_migrations` (AC4: no GRANT in the down file). Mirror the
existing `000023_media_config` describe blocks exactly.

### `Nebu.Media.StorageConfig` module

`server/lib/nebu/media/storage_config.ex`, structured like Story 9a's
`Nebu.Media.Config` (GenServer + ETS + `:pg`) — its own instance, per AC7:

```elixir
defmodule Nebu.Media.StorageConfig do
  use GenServer
  require Logger

  @table :nebu_media_storage_config
  @pg_group "nebu_media_storage_config"
  @ttl_ms 60_000

  @spec get() :: map()
  def get, do: # ETS read merged over env-var defaults (AC4), access_key/
               # secret_key masked (AC8)

  @spec get_for_connection() :: map()
  def get_for_connection, do: # same merge, but access_key/secret_key
                               # decrypted via Nebu.Web.SecretBox.decrypt/1

  @spec upsert(map()) :: :ok | {:error, atom()}
  def upsert(fields) when is_map(fields) do
    # 1. encrypt access_key/secret_key (if present in `fields`) via
    #    Nebu.Web.SecretBox.encrypt/1 before touching the DB
    # 2. Repo: INSERT ... ON CONFLICT (id) DO UPDATE, partial column set
    #    (only columns present in `fields`), RLS's insert/update-singleton
    #    policies enforce id = 1
    # 3. Nebu.Compliance.AuditWriter.log(..., "media_storage_config_updated",
    #    metadata: %{changed_fields: Map.keys(fields)}) — no values, ever
    # 4. GenServer.call(__MODULE__, :refresh) -> re-read + :pg broadcast
  end

  # GenServer: init/1 joins @pg_group via :pg, ensures the ETS table, loads
  # from DB + env-var fallback. handle_call(:refresh, ...) re-reads +
  # broadcasts {:invalidate_media_storage_config}. handle_info for peer
  # invalidation re-reads locally. Periodic self-tick every @ttl_ms forces a
  # re-read regardless of broadcast receipt (AC7's TTL fallback).
end
```

Inline SQL per ADR-018 (no repository/service layer) — this module owns the
one capability, no separate `StorageConfigRepo`.

### `Nebu.Media.StorageConfig.Supervisor` (added pre-dev test-review, cycle 1)

This holder caches storage-target config, including decrypted-adjacent
secret handling — at least as high a resilience bar as Story 9a's
`Nebu.Media.Config`, not lower. `server/lib/nebu/media/storage_config_supervisor.ex`
MUST mirror `server/lib/nebu/media/config_supervisor.ex`
(`Nebu.Media.Config.Supervisor`) exactly: a dedicated child `Supervisor`
(`:transient` restart, `start: {Nebu.Media.StorageConfig, :raw_start_link, [[]]}`,
`max_restarts: 1000, max_seconds: 5`) — NOT a bare `:permanent` child directly
under `Nebu.Application`'s root supervisor (same test-teardown-vs-root-supervisor-
intensity incompatibility documented in `Nebu.Media.Config.Supervisor`'s
moduledoc applies identically here). `Nebu.Media.StorageConfig.start_link/1`
mirrors `Nebu.Media.Config.start_link/1`'s `Supervisor.restart_child/2`
delegation (never calls back into the supervisor from inside its own `init/1`
— use `raw_start_link/1` for that).

`Nebu.Media.StorageConfig.Supervisor` must be added to `Nebu.Application`'s
children list (`server/lib/nebu/application.ex`), started unconditionally
(not gated behind a `:start_xxx` test flag) immediately alongside
`Nebu.Media.Config.Supervisor` — AC7's "changes take effect without a
restart" requires a crash to repopulate the ETS cache automatically via real
OTP supervision, not merely "eventually" via some caller's next lazy start.
The ATDD suite's crash/restart test (mirroring `config_test.exs`'s "the
supervised holder restarts and repopulates its ETS cache after a kill")
depends on this wiring actually existing at runtime.

### Secret encryption — reuse, do not reinvent

`Nebu.Web.SecretBox.encrypt/1` / `decrypt/1` (`server/lib/nebu/web/secret_box.ex`)
already implements exactly the "AES-256-GCM at rest, key =
`SHA-256(NEBU_INTERNAL_SECRET)`, fail closed if unset" pattern this story
needs — it is the same primitive `server_config.oidc_client_secret`
(`Nebu.Admin.BootstrapLive.encrypt_secret/1`) and the Matrix session store's
encrypted refresh token already use. Do not call `Nebu.Media.Crypto.encrypt/3`
directly from this module (that would mean re-deriving the at-rest key and
re-implementing the nonce/hex framing `SecretBox` already owns) and do not
call `Nebu.Matrix.Signature`'s PII tiers (wrong semantics — see Summary).

### Cross-domain boundary (ADR-020)

`Nebu.Web.SecretBox` and `Nebu.Media.Crypto` (which `SecretBox` wraps) are
both fair game for `Nebu.Media.StorageConfig` to call: `Nebu.Web` is shared
infrastructure per CLAUDE.md's module structure, and `Nebu.Media.Crypto` is
already inside the `Nebu.Media` namespace. No call crosses into
`Nebu.Admin`'s or `Nebu.Matrix`'s internals.

This story does **not** rewire `Nebu.Media.Storage`'s existing
`ExAws.S3`/`config :ex_aws` boot-time wiring (`server/lib/nebu/media/storage.ex`,
`server/config/runtime.exs` lines 78–119) to read from
`Nebu.Media.StorageConfig.get_for_connection/0` — that is explicitly a later
story's job (11b's "Test Connection" needs the same
`get_for_connection/0` seam for an ad-hoc, not-yet-saved connection attempt;
a full production cutover of `Nebu.Media.Storage` to per-request dynamic
`ExAws` config, e.g. via `ExAws.request/2`'s config-override argument, is out
of this story's S-sized scope). This story only builds the table + module +
env-var-fallback read path.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/priv/migrations/000024_media_storage_config.up.sql` | CREATE | `media_storage_config` singleton table, RLS, `GRANT ... TO nebu_app` |
| `server/priv/migrations/000024_media_storage_config.down.sql` | CREATE | `DROP TABLE media_storage_config;` |
| `server/lib/nebu/media/storage_config.ex` | CREATE | `Nebu.Media.StorageConfig` — `get/0`, `get_for_connection/0`, `upsert/1`, GenServer/ETS/`:pg` cache + TTL fallback |
| `server/lib/nebu/media/storage_config_supervisor.ex` | CREATE | `Nebu.Media.StorageConfig.Supervisor` — dedicated child supervisor, mirrors `Nebu.Media.Config.Supervisor` (added pre-dev test-review, cycle 1) |
| `server/lib/nebu/application.ex` | UPDATE | Add `Nebu.Media.StorageConfig.Supervisor` to the unconditional children list, alongside `Nebu.Media.Config.Supervisor` (added pre-dev test-review, cycle 1) |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE | Add `media_storage_config_updated` to `@known_actions` |
| `server/test/nebu/matrix/migrations_grant_test.exs` | UPDATE | Add `describe` block for `000024_media_storage_config` GRANT/no-sequence coverage + down-migration no-GRANT check (added pre-dev test-review, cycle 1) |
| `server/test/nebu/media/storage_config_test.exs` | CREATE | Acceptance Tests above + crash/restart test (added pre-dev test-review, cycle 1) |

## Dev Agent Guardrails

### Do Not Change

- **Never log a secret value in plaintext.** Before implementation, grep the
  new module and its call sites (`grep -n "Logger\.\|IO.inspect" server/lib/nebu/media/storage_config.ex`)
  and confirm no log call includes `fields`, the decrypted map from
  `get_for_connection/0`, or the raw `access_key_encrypted`/
  `secret_key_encrypted` columns. `Nebu.Web.SecretBox`'s own moduledoc states
  "this module never logs" — `Nebu.Media.StorageConfig` must hold the same
  invariant for anything it reads back out of `SecretBox.decrypt/1`.
- **Reuse `Nebu.Web.SecretBox`; do not add a second encryption call site.**
  Do not call `Nebu.Media.Crypto.encrypt/3`/`decrypt/3` directly from this
  module (bypassing `SecretBox`'s key derivation and framing), and do not
  introduce a new AES helper. Three call sites already share
  `Nebu.Media.Crypto` as the underlying primitive
  (`Nebu.Admin.BootstrapLive`, `Nebu.Web.SecretBox`, and now this module via
  `SecretBox`) — a fourth independent implementation is exactly what
  `SecretBox`'s own moduledoc was extracted to prevent.
- **`Nebu.Media.StorageConfig.upsert/1` is the only write path** to
  `media_storage_config`. The future Story 11b settings UI calls `upsert/1`;
  it does not run its own SQL or call `Nebu.Web.SecretBox` directly.
- **Do not extend `media_config` or reuse `Nebu.Media.Config`'s ETS
  table/`:pg` group** for these fields — see Summary for the two reasons this
  is a separate table with its own cache instance.
- **`get/0` must never return a decrypted secret.** Only
  `get_for_connection/0` may return plaintext `access_key`/`secret_key`, and
  it must never be called from a LiveView assign, a JSON response, or any
  other admin-facing surface — Story 11b's UI reads `get/0` and calls a
  narrow "test connection" action that internally uses
  `get_for_connection/0` server-side only.
- Do not rewire `Nebu.Media.Storage`'s ExAws/S3 client construction to read
  from this module in this story (see Technical Requirements — Cross-domain
  boundary); that is a follow-up story's scope.
- Do not add `{room_id}` or any upload-time template-placeholder interpretation
  logic here — `s3_key_prefix_template` is persisted as an opaque string;
  Story 11c owns parsing/evaluating it.

## Dependencies

- **Depends on:** 1a (`media_files` migration, for migration-numbering/build-order
  convention only — no schema coupling, `media_storage_config` is standalone).
  9a (`media_config` table + `Nebu.Media.Config` module) — a **pattern**
  dependency only, per the epic's own "1a, 9a (Settings-Infra/Muster)" note:
  this story follows the RLS/ETS/`:pg`/audit-trail shape 9a established, but
  does not share 9a's table, module, or cache instance (see Summary).
  `Nebu.Web.SecretBox` and `Nebu.Compliance.AuditWriter` — already-present
  shared infrastructure, no separate story number.
- **Enables:** 11b (Storage-UI + Test Connection + Warnungen — reads
  `get/0` for display, calls `upsert/1` to save, uses
  `get_for_connection/0` server-side for the pre-save `ExAws.S3.head_bucket/1`
  test-connection call, and reads the env-var-prefill-on-first-load values via
  `get/0`'s fallback path). 11c (`s3_key_prefix_template` upload-time key
  computation — reads the template string via `get/0`, since it is not a
  secret).

## Dev Agent Record

### Implementation Notes

- Migration `000024_media_storage_config.up.sql`/`.down.sql` created exactly
  per the story's Technical Requirements SQL (including the required
  `GRANT SELECT, INSERT, UPDATE, DELETE ON media_storage_config TO nebu_app;`
  and its rationale comment).
- `server/test/nebu/matrix/migrations_grant_test.exs` extended with an
  `AC1: 000024_media_storage_config.up.sql DML grants` describe block, an
  `AC2: 000024_media_storage_config.up.sql has no SERIAL columns` describe
  block, and `"000024_media_storage_config.down.sql"` added to
  `@down_migrations` — mirroring the existing 000023 blocks exactly.
- `server/lib/nebu/media/storage_config.ex` implements `get/0`,
  `get_for_connection/0`, `upsert/1` (with an optional `actor` 2nd arg
  defaulted to `"system:media_storage_config"`, mirroring
  `Nebu.Media.Config.upsert/3`'s pattern), and the full GenServer/ETS/`:pg`
  cache + 60s TTL fallback, using the exact seam names the ATDD test file's
  moduledoc specifies (`:media_storage_config_source`,
  `:media_storage_config_loader`, `:media_storage_config_writer`,
  `:media_storage_env_reader`), the `"nebu_media_storage_config"` `:pg`
  group literal, the `{:invalidate_media_storage_config}` broadcast payload,
  and the `"••••" <> last 4 chars` masked-marker format. `access_key`/
  `secret_key` are encrypted/decrypted exclusively via
  `Nebu.Web.SecretBox.encrypt/1`/`decrypt/1` — no second AES call site.
  `upsert/1` unconditionally calls `GenServer.call(__MODULE__, :refresh)` on
  a successful write, per the story's own skeleton (step 4), and lets a
  `SecretBox.encrypt/1` fail-closed raise propagate before any DB write.
- `server/lib/nebu/media/storage_config_supervisor.ex` mirrors
  `Nebu.Media.Config.Supervisor` exactly (dedicated child `Supervisor`,
  `:transient` restart, `start: {Nebu.Media.StorageConfig, :raw_start_link,
  [[]]}`, `max_restarts: 1000, max_seconds: 5`).
- `server/lib/nebu/application.ex` wires `Nebu.Media.StorageConfig.Supervisor`
  into the unconditional children list, immediately alongside
  `Nebu.Media.Config.Supervisor`.
- `server/lib/nebu/compliance/audit_writer.ex`: added
  `media_storage_config_updated` to `@known_actions`.
- **Deviation (disclosed):** `server/test/nebu/media/storage_config_test.exs`
  required one small, non-assertion-changing addition: at the START of its
  `setup` block (not just in `on_exit`), stop any pre-existing
  `Nebu.Media.StorageConfig` process before each test. Root cause: this
  story's own fix cycle requires `Nebu.Media.StorageConfig.Supervisor` to be
  started UNCONDITIONALLY by `Nebu.Application` (for AT13's crash/restart
  test), so a boot-time instance is alive — with an ETS cache already
  populated from the REAL (non-test) loader/env-reader — before this test
  file's first test ever runs. AT1/AT2/AT3/AT7/AT8 deliberately exercise the
  "no GenServer/cache started yet" direct-load path and, without this fix,
  nondeterministically read that stale boot-time cache instead of their own
  seams depending on which test in the full ~1700-test suite ExUnit happens
  to schedule first (observed empirically: green in isolation, flaky — e.g.
  AT3 spuriously failing — under the full `mix test` run). The fix mirrors
  an existing codebase convention (`oidc_claim_cache_test.exs`'s
  `OidcClaimCache.reset_for_test()` call at the top of its own `setup`) and
  changes no seam name, no assertion, and no contract shape.
- `server/test/nebu/release_test.exs`'s
  `list_up_migrations/1` regression test asserted the literal migration
  version list through `23`; updated to include `24` (same pattern as its
  own prior updates for 000022/000023), with a comment describing the new
  migration.

### Code Review Fix Cycle 1 (MINOR findings)

Cycle 0 code review found 0 MAJOR/CRITICAL findings and 2 MINOR findings
(`_bmad-output/nebu/epics/media-security-admin-control/step-results/11a-storage-config-schema-secrets/code-review-findings.md`),
both fixed in `server/lib/nebu/media/storage_config.ex` only (implementation-only,
no test-file changes):

- **MINOR-1** (decrypted plaintext secrets cached in the `:protected` ETS
  table, VM-globally readable via `:ets.lookup/2`): the ETS-cached catalog
  now holds the RAW ingredients only — the DB row (`access_key_encrypted`/
  `secret_key_encrypted` still `SecretBox` ciphertext, or `nil`) and the raw
  env-var map — never a decrypted secret. `resolved/0` (the single function
  both `get/0` and `get_for_connection/0` call) now runs `build_resolved/2`
  (and therefore `SecretBox.decrypt/1`) freshly on every read; `do_refresh/0`
  (the `:ttl_tick`/`:pg`-invalidation refresh path) only re-reads and caches
  the raw row/env, never decrypts. `row_and_env/0`/`read_from_ets/0` replace
  the old resolved-map caching.
- **MINOR-2(a)** (silent fallback to the env-var credential on decrypt
  failure): `decrypt_secret/1` now logs `Logger.warning/1` (message text
  only, never ciphertext or decrypted fragments) when `SecretBox.decrypt/1`
  returns `{:error, reason}`, before falling through to the env-var/default
  fallback.
- **MINOR-2(b)** (unguarded `SecretBox.at_rest_key/0` raise on a
  genuinely-unset at-rest secret propagating out of `get/0`/
  `get_for_connection/0`/the `:ttl_tick` refresh, crash-loop risk):
  `decrypt_secret/1` now rescues that specific `RuntimeError`, logs a
  warning (message only), and treats the field as if the ciphertext were
  absent (falls through to env-var/default) instead of crashing. Scoped to
  the READ path only — `upsert/1`'s own `SecretBox.encrypt/1` call
  (`column_for/2`) still lets the identical fail-closed raise propagate
  unguarded out of the WRITE path, per AT12/AC3 (unchanged).

Verification: all 13 `storage_config_test.exs` tests (AT1–AT13) pass
UNCHANGED (no test-file edits needed for this fix cycle); all
`migrations_grant_test.exs` describe blocks pass; 73/73 combined. Full
`mix test --warnings-as-errors` — 1718 passed, 4 skipped, 449 excluded, 0
failed, exit code 0.

Files modified this cycle: `server/lib/nebu/media/storage_config.ex` only.

### Completion Notes

- `mix test test/nebu/media/storage_config_test.exs
  test/nebu/matrix/migrations_grant_test.exs` — 73/73 passed (13/13 new
  `storage_config_test.exs` AT1–AT13, all `migrations_grant_test.exs`
  describe blocks including the new 000024 ones), reproduced clean across
  multiple seeds.
- Full suite: `mix test --warnings-as-errors` — 1718 passed, 4 skipped, 449
  excluded, 0 failed, exit code 0 — reproduced clean across 3 separate runs
  (default seed twice, `--seed 999` once) after the setup-isolation fix
  above; before that fix the full run was flaky (1 spurious failure in
  `storage_config_test.exs`, order-dependent).

### File List

- `server/priv/migrations/000024_media_storage_config.up.sql` — CREATE
- `server/priv/migrations/000024_media_storage_config.down.sql` — CREATE
- `server/lib/nebu/media/storage_config.ex` — CREATE
- `server/lib/nebu/media/storage_config_supervisor.ex` — CREATE
- `server/lib/nebu/application.ex` — UPDATE (wire the new supervisor)
- `server/lib/nebu/compliance/audit_writer.ex` — UPDATE (`@known_actions`)
- `server/test/nebu/matrix/migrations_grant_test.exs` — UPDATE (000024
  describe blocks + down-migration entry)
- `server/test/nebu/media/storage_config_test.exs` — UPDATE (setup-isolation
  fix only, see Deviation note above; no seam/assertion changes)
- `server/test/nebu/release_test.exs` — UPDATE (migration-count regression
  assertion extended to include 24)

### Post-Epic Security Review Fix (M-2/M-3, epic security review 2026-07-20)

Kassandra's epic-end security review (SEC Gate 2,
`_bmad-output/implementation-artifacts/epic-media-security-admin-control-security-review-2026-07-20.md`)
flagged two new-in-epic MEDIUM findings against `server/lib/nebu/media/storage_config.ex`:

- **M-2** (story 11b, `test_connection/1`'s `validate_candidate_endpoint/1`,
  `:906-916`): only a bare `http://`/`https://` scheme-prefix string was
  rejected — no private/loopback/link-local/CGNAT/cloud-metadata IP
  blocking, no DNS pinning. `test_connection/1` then issued a real ExAws
  `head_bucket` against the admin-supplied host: a blind,
  admin-authenticated SSRF.
- **M-3** (this story, `upsert/1`, `:523`): `endpoint` was stored verbatim
  with NO validation at all on the persist path — the weak scheme-only
  guard ran only inside `test_connection/1` — so a private-host or
  scheme-prefixed endpoint could be persisted directly (skipping
  test-connection entirely) and later used by `Nebu.Media.Storage` for real
  object-store traffic.

**Fix:** `validate_candidate_endpoint/1` now also routes the candidate
through `Nebu.Media.SSRF.checked_target/1` — the SAME shared guard
`preview_url` and both webhook paths already use
(`Nebu.Media.WebhookDelivery.post/2`) — after its existing scheme-prefix
check. A new `validate_endpoint_field/1` helper (mirroring
`validate_template_field/1`'s partial-update-aware gating exactly) calls
that same function from `upsert/1`'s `with` chain whenever `fields` contains
`:endpoint`, BEFORE any DB write, closing M-3. Both fixes live in
`server/lib/nebu/media/storage_config.ex` only.

**Tests (TDD, RED confirmed before the fix):** `server/test/nebu/media/storage_config_test.exs`
gained two new tests ("M-2: test_connection/1 SSRF guard" / "M-3: upsert/1
SSRF guard") asserting a private/loopback/link-local/cloud-metadata endpoint
(`127.0.0.1`, `10.0.0.5`, `169.254.169.254`, `192.168.1.1`) is rejected as
`{:error, :invalid_endpoint}` at both call sites, never reaching the
test-connection fun / DB writer seam. `server/test/nebu/admin/media_settings_controller_test.exs`
gained one end-to-end controller test in the same vein, and every existing
fixture endpoint that flows through either validated path was updated from a
made-up unresolvable hostname (e.g. `"s3.example.com:9000"`,
`"new-endpoint:9000"`) to the literal public IP `93.184.216.34:9000` (no
live DNS lookup needed — mirrors `webhook_delivery_test.exs`'s own
convention) so those pre-existing tests keep passing under the new
DNS-resolving guard; `storage_config_test.exs`'s own AT6 test was updated
the same way.

**Verification:** `mix test --warnings-as-errors` (full unit suite) — clean,
exit 0. `mix test --include integration --warnings-as-errors` (full stack) —
2585 tests, 32 pre-existing/unrelated failures (TraceMapNodeControls,
TraceMapNodeControlsContract, TraceMap, WarRoom, SsoLogin, MatrixSso,
ConfigController, RegressionSyncLoad, TemporaryCaptureManager,
LogStore.Retention, and one order-dependent `MediaScanWorkerTest`
GenServer-teardown race), none touching `storage_config.ex`,
`media_settings_controller.ex`, or any SSRF code path.

Files modified this cycle: `server/lib/nebu/media/storage_config.ex`,
`server/test/nebu/media/storage_config_test.exs`,
`server/test/nebu/admin/media_settings_controller_test.exs`,
`_bmad-output/implementation-artifacts/epic-media-security-admin-control-security-review-2026-07-20.md`,
this file, `11b-storage-ui-test-connection-security-review-2026-07-14.md`
(status update only). Commit: `dc0b199f`.

### Change Log

- 2026-07-13: Story implemented (dev-story step). Migration 000024, the
  `Nebu.Media.StorageConfig`/`Nebu.Media.StorageConfig.Supervisor` modules,
  `Nebu.Application` wiring, and `AuditWriter.@known_actions` all added per
  the story's Technical Requirements. `storage_config_test.exs` (13/13) and
  `migrations_grant_test.exs` green; full unit suite green
  (`--warnings-as-errors`, 1718 passed/0 failed) after fixing an
  order-dependent test-isolation flake (see Dev Agent Record).
- 2026-07-13: Code-review fix cycle 1 — fixed both MINOR findings from cycle
  0's review in `server/lib/nebu/media/storage_config.ex` (implementation
  only, no test-file changes): ETS cache now stores raw DB row + env-var map
  instead of decrypted secrets (MINOR-1); `decrypt_secret/1` logs on decrypt
  failure and rescues the fail-closed `SecretBox.at_rest_key/0` raise on the
  read path instead of silently substituting or crash-looping (MINOR-2). All
  13 `storage_config_test.exs` tests pass unchanged; `migrations_grant_test.exs`
  and the full unit suite (`--warnings-as-errors`, 1718 passed/0 failed)
  remain green. See "Code Review Fix Cycle 1 (MINOR findings)" above for
  detail.
- 2026-07-21: Post-epic security review fix (M-2/M-3) — closed both new-in-epic
  MEDIUM findings from Kassandra's epic-end security review by routing
  `test_connection/1`'s and `upsert/1`'s endpoint validation through the
  shared `Nebu.Media.SSRF.checked_target/1` guard (same guard `preview_url`/
  `WebhookDelivery.post/2` already use), replacing the scheme-only check.
  TDD: 2 new module tests + 1 new controller test confirmed RED before the
  fix, GREEN after; full unit suite (`--warnings-as-errors`) and full
  integration suite (`--include integration --warnings-as-errors`) both
  verified with no new failures. See "Post-Epic Security Review Fix
  (M-2/M-3, epic security review 2026-07-20)" above for detail.
