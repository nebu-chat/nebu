---
story_id: 9a-media-config-table-module
title: "Media Policy Settings: media_config Table + Nebu.Media.Config Module"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Since the epic's Review 3/9, the media-security build-up has quietly hardcoded a
growing list of admin-relevant policy values in `config.exs`/app-env, each with an
explicit "not a dependency of 9a yet, rewire later" note pointing at this exact
story:

- `max_upload_size_bytes` (`Nebu.Media.max_upload_bytes/0`, currently
  `Application.get_env(:nebu_http, :media_max_upload_bytes, 52_428_800)`) — Story
  2b's PUT-upload 413 limit, which explicitly says "a later story rewires
  `max_upload_bytes/0` to call `Nebu.Media.Config.get/0`... this story does not
  depend on 9a."
- `max_file_size_bytes` (ClamAV scan-skip ceiling, default `100 * 1024 * 1024`) —
  Story 3's `Nebu.Media.ClamAV` scan-size guard, cross-referenced by the epic's
  Story 9 policy-settings notes as "admin-configurable ClamAV scan ceiling... the
  admin-configurable override is out of scope here (Story 9)."
- `max_pending_per_user` (default `20`) — Story 2a's `POST /create` 429 rate limit,
  read via `Application.get_env(:nebu_http, :media_max_pending_per_user, 20)`
  with the identical "not a dependency of 2a... a later story (9a...) can point
  this same key at `Nebu.Media.Config.get/0`" note.
- `max_stall_ms` (default `20_000`) — Story 2d's download-stall cap, read via
  `Application.get_env(:nebu, Nebu.Media, [])`, with the same "swapping the
  source to `Nebu.Media.Config.get/0` once Story 9 lands" note. (Story 2d's
  sibling value `max_concurrent_stalls` is deliberately **not** included in this
  table — see Dev Agent Guardrails.)
- `deleted_days`, `infected_days`, `orphaned_hours` — retention windows owned by
  Stories 8a/8b, listed by the epic's Story 9b scope as editable in
  `/admin/media/settings`.
- `webhook_url` — Story 7's admin-notification webhook target. ADR-027 itself
  revises Story 7's first-draft "ops-only, `config.exs`" decision to
  admin-configurable via `media_config`, with the epic's Story 9b scope requiring
  "Save-Time-Validierung wie SCIM-/OIDC-Directory: HTTPS-Pflicht, private/
  link-local IP-Ranges geblockt."
- `released_delete_after_days` (default `nil` = disabled) — Story 8d's
  never-beanstandet-`:released`-file auto-delete, explicitly "Config:
  `released_delete_after_days` (Default `nil` = deaktiviert)," with the epic
  flagging it as "deutlich höheres Blast-Radius als alle anderen Retention-Werte."
- `mime_denylist` (comma-separated MIME-type prefixes, default empty) — Story
  9c's upload-time enforcement, additive to the ClamAV scan, not a replacement.

Story 2e (`Reserved-Upload Cleanup Cron`) explicitly documents the *negative*
space here: the `unused_expires_at` TTL used by its cleanup job is **not** one of
these keys — "that list covers `max_upload_size_bytes`/`max_file_size_bytes`/
`max_pending_per_user`/`max_stall_ms`/`deleted_days`/`infected_days`/
`orphaned_hours`/`webhook_url` only" (as of 2e's writing, before 8d/9c extended
that list). This story is the single place all of the above converge.

Per ADR-027, this story introduces a **dedicated** `media_config` table — not an
extension of `server_config` — following the same key/value shape and RLS
pattern `server_config` already established for OIDC bootstrap config (ADR-022):
`key TEXT PRIMARY KEY, value TEXT NOT NULL, set_at BIGINT NOT NULL`, RLS-gated
`SELECT`/`INSERT`/`UPDATE` policies with an explicit mutable-key allowlist.
`Nebu.Media.Config` is the sole public-API module (ADR-020) that reads or writes
it — `get/0` returns a fully-populated map (DB override per key, falling back to
the existing `config.exs`/app-env default for any key not yet written), and
`upsert/1` is the only write seam, performing per-key validation and writing a
`media_config_updated` audit-log entry.

Cache invalidation reuses the already-established `Nebu.Web.OidcConfig` pattern:
an ETS cache owned by a GenServer that joins a `:pg` process group and
broadcasts an invalidation to peer nodes on every `upsert/1`, backed by a low
TTL fallback so a node that misses a broadcast (e.g. during a network
partition) does not serve a stale security-relevant value (MIME denylist,
upload/scan size limits) indefinitely.

## User Story

As the Nebu server operator, I want media policy values (upload/scan size
limits, pending-upload and stall limits, retention windows, webhook URL, MIME
denylist, and the released-file auto-delete window) to live in a single
admin-configurable table with one validated write path, so that a later
settings UI (Story 9b) can edit them safely, changes take effect cluster-wide
without a restart, and every change is auditable.

## Acceptance Criteria

1. **AC1 — Migration creates `media_config`.** A new migration creates:
   ```sql
   CREATE TABLE media_config (
       key    TEXT   PRIMARY KEY,
       value  TEXT   NOT NULL,
       set_at BIGINT NOT NULL
   );
   ```
   with RLS enabled/forced and the same three-policy shape as `server_config`
   (`config_read_all` FOR SELECT, `config_insert_only` FOR INSERT, a
   `config_update_mutable` FOR UPDATE policy naming every key this story knows
   about — see AC2 for the full key catalog). A **dedicated** table, not an
   extension of `server_config` — ADR-027's explicit decision, so that
   `media_config` writes never trigger `server_config`'s (OIDC/SSO/logging)
   cache-invalidation path and vice versa.
2. **AC2 — Full key catalog with config.exs-matching defaults.** `Nebu.Media.Config.get/0`
   returns a map with exactly these keys, each falling back to the *exact*
   existing app-env default already hardcoded by the citing story when no DB
   row exists:
   | Key | Default | Cites |
   |---|---|---|
   | `max_upload_size_bytes` | `52_428_800` (matches `Nebu.Media`'s `@default_max_upload_bytes`) | Story 2b |
   | `max_file_size_bytes` | `104_857_600` (`100 * 1024 * 1024`) | Story 3 |
   | `max_pending_per_user` | `20` | Story 2a |
   | `max_stall_ms` | `20_000` | Story 2d |
   | `deleted_days` | `30` (existing soft-delete retention default) | Story 8a/8b |
   | `infected_days` | `90` (existing infected-record retention default, kept well clear of `deleted_days` given its compliance-evidence role) | Story 8a/8b |
   | `orphaned_hours` | `24` (existing orphaned quarantined/scanning cleanup window) | Story 8a/8b |
   | `webhook_url` | `nil` (unset — no default notification target) | Story 7 |
   | `released_delete_after_days` | `nil` (disabled — Data-Minimization opt-in, not opt-out) | Story 8d |
   | `mime_denylist` | `""` (empty — no additional denylist beyond the ClamAV scan) | Story 9c |

   These are the only keys this story's migration seeds into the RLS
   allowlist. Story 10c's alert thresholds and Story 10d's fail-open/fail-closed
   mode are explicitly **out of scope** here — see Dev Agent Guardrails — and
   add their own key(s) via their own migration, exactly like `server_config`'s
   incremental key-addition precedent (migrations `000007`/`000013`/`000016`/
   `000018` each extended `config_update_mutable`'s allowlist for a newly
   introduced key).
3. **AC3 — `Nebu.Media.Config` public API (ADR-020).** A new module exposing:
   - `get/0` — returns the full key catalog map (AC2), DB override merged over
     config.exs defaults. No arguments; every known key is always present.
   - `upsert/1` — `upsert(key, value)` (or a single `%{key => value}` map for a
     batched settings-form save). The **only** write path to `media_config`; no
     other module issues `INSERT`/`UPDATE` against this table.
4. **AC4 — Per-key write validation.** `upsert/1` validates before writing and
   returns `{:error, reason}` without touching the DB on failure:
   - Byte/count/duration/day values (`max_upload_size_bytes`,
     `max_file_size_bytes`, `max_pending_per_user`, `max_stall_ms`,
     `deleted_days`, `infected_days`, `orphaned_hours`,
     `released_delete_after_days`) MUST be non-negative integers, OR — for
     `released_delete_after_days` only — `nil` (its explicit "disabled" value;
     `nil` is not accepted for any other key in this list).
   - `webhook_url` MUST be `nil` (disabled) or pass `Nebu.Media.SSRF.check/1`
     **and** have an `https` scheme (reusing the already-existing SSRF/private-IP
     guard module rather than re-implementing address-blocking logic — see
     Technical Requirements).
   - `mime_denylist` MUST be a comma-separated string of syntactically plausible
     MIME-type-prefix tokens (non-empty, no embedded whitespace per token); the
     empty string is valid (denylist disabled).
   - An unknown key is rejected with `{:error, :unknown_config_key}` — the same
     "reject before any DB call" posture `Nebu.Compliance.AuditWriter` already
     uses for unknown audit actions.
5. **AC5 — Changes take effect without a restart.** `get/0` never serves a
   value from a value baked in at boot. The cache invalidation mechanism is
   ETS-backed (GenServer-owned, `:protected`, `read_concurrency: true`) with
   cluster-wide invalidation over Erlang `:pg` (joining a `nebu_media_config`
   `:pg` group and broadcasting on every successful `upsert/1`, mirroring
   `Nebu.Web.OidcConfig`'s exact mechanism — not Phoenix.PubSub). A bounded TTL
   fallback (**60 seconds**, deliberately short given `mime_denylist` and the
   upload/scan size limits are security-relevant) re-reads from the DB even if
   a `:pg` broadcast is missed (e.g. during a network partition), so no node
   can serve a stale security-relevant value indefinitely.
6. **AC6 — Audit trail.** Every successful `upsert/1` call writes a
   `media_config_updated` audit-log entry via `Nebu.Compliance.AuditWriter`
   with `metadata: %{key: key, old_value: old_value, new_value: new_value}`.
   `media_config_updated` is added to `AuditWriter.@known_actions`. A failed
   validation (AC4) writes no audit entry and makes no DB call.

## Acceptance Tests

New test file `server/test/nebu/media/config_test.exs` (ExUnit; matches the
seam-injection conventions of `server/test/nebu/web/oidc_scopes_test.exs` and
`Nebu.Web.OidcConfig`'s `:oidc_config_source` app-env seam pattern, and the
`FakeRepo`-style double already used by `session_expiry_worker_test.exs` for
modules that read Postgres directly):

1. `"get/0 on a fresh media_config table (no rows) returns every catalog key
   with its config.exs default"` — asserts all 10 keys from AC2's table are
   present with the exact documented default values, in particular
   `released_delete_after_days: nil` and `webhook_url: nil`.
2. `"upsert/1 persists a valid value and get/0 reflects it on the next read"` —
   for at least one integer key (e.g. `max_upload_size_bytes`) and the
   `webhook_url` key (a valid `https://` URL to a public host), asserts the row
   exists in `media_config` with the expected `value`/`set_at`, and a
   subsequent `get/0` (after cache invalidation, or via a direct DB-bypassing
   read seam for the test) returns the new value, not the default.
3. `"upsert/1 rejects a negative integer value for every non-negative-integer
   key without writing a row"` — parameterized over
   `max_upload_size_bytes`/`max_file_size_bytes`/`max_pending_per_user`/
   `max_stall_ms`/`deleted_days`/`infected_days`/`orphaned_hours`, asserts
   `{:error, _}` and that no row was written/updated.
4. `"upsert/1 rejects nil for every non-negative-integer key except
   released_delete_after_days"` — asserts `released_delete_after_days: nil`
   succeeds while e.g. `deleted_days: nil` is rejected.
5. `"upsert/1 rejects a non-https webhook_url"` — `http://example.com/hook` is
   rejected.
6. `"upsert/1 rejects a webhook_url pointing at a private/link-local address"`
   — reuses the same blocked-address fixtures as
   `server/test/nebu/media/url_preview_test.exs`'s SSRF coverage (e.g.
   `https://127.0.0.1/hook`, `https://169.254.169.254/hook`), asserts
   `{:error, _}` via the shared `Nebu.Media.SSRF` check.
7. `"upsert/1 rejects an unknown config key"` — `upsert("not_a_real_key",
   "1")` returns `{:error, :unknown_config_key}`, no DB call is made (assert
   via the `FakeRepo`/query-count seam).
8. `"upsert/1 writes a media_config_updated audit-log entry with old_value and
   new_value on success"` — asserts one `Nebu.Compliance.AuditWriter` call (or
   one `audit_log` row, matching however the epic's other Story 9a-adjacent
   audit tests assert) with `metadata: %{key: ..., old_value: ..., new_value:
   ...}`.
9. `"upsert/1 with an invalid value writes no audit-log entry"`.
10. `"a second GenServer node's cache reflects an upsert via the :pg broadcast
    without calling get/0 a second time on the writing node"` — mirrors
    `Nebu.Web.OidcConfig`'s own cluster-invalidation test shape: start two
    named `Nebu.Media.Config` GenServer instances (or the equivalent
    test-double pair used for `OidcConfig`'s own test suite, if found at dev
    time), `upsert/1` on one, assert the other's ETS cache is refreshed after
    the broadcast is delivered (`handle_info` roundtrip), not merely after its
    own TTL elapses.
11. `"a node that misses the :pg broadcast still serves the new value within
    the TTL fallback window"` — simulate a missed `:invalidate_media_config`
    message and assert the stale ETS entry is not served past the documented
    60s TTL (may drive the GenServer's internal clock via an injectable time
    source rather than a real 60s sleep).
12. `"other modules reading via Nebu.Media.Config.get/0 observe a live value
    immediately after upsert on the SAME node"` — a same-process `upsert/1`
    followed immediately by `get/0` (no cross-node broadcast involved) returns
    the new value — the local ETS cache is refreshed synchronously as part of
    the writing GenServer's own `upsert/1` handling, not only via the
    broadcast-to-peers path.

## Technical Requirements

### Migration

`server/priv/migrations/000024_media_config.up.sql` (number **TBD at merge
time** — Story 1a claimed `000022`, Story 4a claims `000023` and Story 4b's
`000023_oban_jobs` notes the same collision risk; whichever of 4a/4b/9a lands
first keeps its number, the others bump, per the existing convention already
used across this epic's migration-numbered stories):

```sql
-- ─── media_config ─────────────────────────────────────────────────────────
-- Key-value store for runtime-configurable media policy values (ADR-027).
-- Dedicated table, NOT an extension of server_config — see ADR-027's
-- rationale: media_config writes must never trigger server_config's
-- (OIDC/SSO/logging) cache-invalidation path, and vice versa.
CREATE TABLE media_config (
    key    TEXT   PRIMARY KEY,
    value  TEXT   NOT NULL,
    set_at BIGINT NOT NULL
);

ALTER TABLE media_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_config FORCE ROW LEVEL SECURITY;

CREATE POLICY media_config_read_all ON media_config FOR SELECT USING (true);
CREATE POLICY media_config_insert_only ON media_config FOR INSERT WITH CHECK (true);

-- Mutable-keys allowlist (Story 9a's initial catalog, see AC2). New keys
-- introduced by later stories (10c thresholds, 10d fail-open/fail-closed
-- mode, etc.) extend this policy via their own migration — same precedent
-- as server_config's 000007/000013/000016/000018.
CREATE POLICY media_config_update_mutable ON media_config
    FOR UPDATE
    USING (key IN (
        'max_upload_size_bytes',
        'max_file_size_bytes',
        'max_pending_per_user',
        'max_stall_ms',
        'deleted_days',
        'infected_days',
        'orphaned_hours',
        'webhook_url',
        'released_delete_after_days',
        'mime_denylist'
    ));
```

`server/priv/migrations/000024_media_config.down.sql`: `DROP TABLE
media_config;` (policies/RLS drop implicitly with the table).

### `Nebu.Media.Config` module

`server/lib/nebu/media/config.ex`, structured like `Nebu.Web.OidcConfig`
(GenServer + ETS + `:pg`), but as `Nebu.Media`'s own instance (ADR-020 — each
namespace's public-API module is self-contained, not shared with
`Nebu.Web.OidcConfig`):

```elixir
defmodule Nebu.Media.Config do
  use GenServer
  require Logger

  @table :nebu_media_config
  @pg_group "nebu_media_config"
  @ttl_ms 60_000

  @defaults %{
    "max_upload_size_bytes" => 52_428_800,
    "max_file_size_bytes" => 104_857_600,
    "max_pending_per_user" => 20,
    "max_stall_ms" => 20_000,
    "deleted_days" => 30,
    "infected_days" => 90,
    "orphaned_hours" => 24,
    "webhook_url" => nil,
    "released_delete_after_days" => nil,
    "mime_denylist" => ""
  }

  @spec get() :: map()
  def get, do: # ETS read (with `:undefined` -> direct DB fallback, matching
                # OidcConfig.get_scopes/0's `:ets.whereis` fallback), merged
                # over @defaults, with per-key type coercion (string -> integer)

  @spec upsert(String.t(), term()) :: :ok | {:error, atom()}
  def upsert(key, value) do
    # 1. key in Map.keys(@defaults)? else {:error, :unknown_config_key}
    # 2. validate(key, value) — see AC4
    # 3. Repo transaction: read old_value, INSERT ... ON CONFLICT (key) DO
    #    UPDATE SET value = $2, set_at = $3 (RLS's insert_only/update_mutable
    #    policies enforce the same insert-then-update-only-if-mutable shape
    #    server_config already relies on)
    # 4. Nebu.Compliance.AuditWriter.log(..., "media_config_updated",
    #    metadata: %{key: key, old_value: old_value, new_value: value})
    # 5. GenServer.call(__MODULE__, :refresh) -> re-read + :pg broadcast
  end

  # GenServer: init/1 joins @pg_group via :pg, ensures the ETS table, loads
  # from DB. handle_call(:refresh, ...) re-reads + broadcasts
  # {:invalidate_media_config} to peer :pg members. handle_info for the peer
  # invalidation re-reads locally. A periodic `Process.send_after/3` self-tick
  # every @ttl_ms forces a re-read regardless of broadcast receipt (AC5's TTL
  # fallback).
end
```

Read/write seams and inline SQL per ADR-018 (no repository/service layer) —
`Nebu.Media.Config` itself is the coherent single module owning this one
capability; it does not delegate to a separate `MediaConfigRepo`.

### `webhook_url` validation — reuse, do not reinvent

`Nebu.Media.SSRF.check/1` (`server/lib/nebu/media/ssrf.ex`) already implements
exactly the "resolve host, reject loopback/private/link-local/CGNAT/metadata
address" guard the epic's Story 9b scope calls for ("Save-Time-Validierung wie
SCIM-/OIDC-Directory"). `upsert/1`'s `webhook_url` validation is: `URI.parse(url).scheme
== "https"` **and** `Nebu.Media.SSRF.check(url) == :ok`. Do not write a second,
parallel private-IP-blocking implementation for this story.

### Cross-domain read boundary (ADR-020)

Every other module in this epic that currently reads one of these 10 values
from `config.exs`/app-env (`Nebu.Media`'s `max_upload_bytes/0`,
`max_pending_per_user`, `Nebu.Media.ClamAV`'s `max_file_size_bytes`,
`Nebu.Media.max_stall_ms/0`, the Story 8a/8b retention workers, Story 7's
webhook sender) keeps reading its existing app-env key for now — rewiring each
call site to `Nebu.Media.Config.get/0` is each of those *other* stories' own
follow-up work (2a/2b/2d/3/7/8a/8b/8d each already say so explicitly), **not**
bundled into this story. This story only builds the table + module; it does
not touch `server/lib/nebu/media.ex`, `server/lib/nebu/media/clamav.ex`, or any
worker.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/priv/migrations/000024_media_config.up.sql` | CREATE | `media_config` table, RLS, mutable-key allowlist (see Technical Requirements — number TBD at merge time) |
| `server/priv/migrations/000024_media_config.down.sql` | CREATE | `DROP TABLE media_config;` |
| `server/lib/nebu/media/config.ex` | CREATE | `Nebu.Media.Config` — `get/0`, `upsert/1`, GenServer/ETS/`:pg` cache + TTL fallback |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE | Add `media_config_updated` to `@known_actions` |
| `server/test/nebu/media/config_test.exs` | CREATE | Acceptance Tests above |

## Dev Agent Guardrails

### Do Not Change

- **All cross-domain reads of media policy values MUST go through
  `Nebu.Media.Config`'s public API (ADR-020) once a consumer is rewired — no
  other module queries the `media_config` table directly.** This story does
  not rewire any existing consumer (see Technical Requirements — Cross-domain
  read boundary); it only guarantees that *when* a consumer is rewired (9b or a
  later per-story follow-up), the read goes through `get/0`, never a raw
  `SELECT ... FROM media_config` elsewhere in the codebase.
- `Nebu.Media.Config.upsert/1` is the **only** write path to `media_config`.
  Do not add a second insert/update call site (e.g. directly from the future
  Story 9b LiveView) — the settings UI calls `upsert/1`, it does not run its
  own SQL.
- Do not extend `server_config` or reuse `Nebu.Web.OidcConfig`'s ETS
  table/`:pg` group for these values — ADR-027's whole point is a dedicated
  table and a dedicated (structurally identical, but separate) cache/broadcast
  instance, so a `media_config` write never invalidates OIDC/SSO/logging
  config and vice versa.
- Do **not** include `max_concurrent_stalls` (Story 2d's stall-concurrency
  ceiling) in this table's key catalog. Story 9b's admin-UI scope enumerates
  `max_stall_ms` only; `max_concurrent_stalls` is an operational safety valve,
  not a policy value the epic's own settings-UI scope names as
  admin-configurable. If a later story wants it exposed, that story adds its
  own migration extending `media_config_update_mutable`, per the same
  incremental precedent this story itself follows for 10c/10d.
- Do **not** add Story 2e's `unused_expires_at` reservation TTL as a key here —
  Story 2e explicitly documents that it is per-row DB state (`media_files`),
  not an admin-tunable policy value, and is deliberately excluded from this
  catalog.
- Do not rewire any of `Nebu.Media`, `Nebu.Media.ClamAV`, or any Story
  8a/8b/8d/7 worker to call `Nebu.Media.Config.get/0` in this story — each of
  those call-site changes belongs to its own citing story (see Technical
  Requirements).

## Dependencies

- **Depends on:** 1a (`media_files` migration lands first purely for migration
  file numbering/build-order convention; no schema coupling — `media_config`
  is a standalone table). Audit-log conventions (`Nebu.Compliance.AuditWriter`,
  registering `media_config_updated`) — no separate story number, already
  present infrastructure.
- **Enables:** 9b (`/admin/media/settings` UI — reads/writes exclusively via
  `Nebu.Media.Config.get/0`/`upsert/1`), 9c (`mime_denylist` enforcement —
  reads the key via `get/0`), 10c (`media_alerts` thresholds — extends this
  table's mutable-key allowlist with its own migration), 10d (fail-open/
  fail-closed kill switch — same), 11a (storage-config schema follows this
  story's established table/module pattern). Referenced by (once each is
  rewired to read from here instead of `config.exs`): 2a, 2b, 2d, 3, 7, 8a, 8b,
  8d.

## Dev Agent Record

### Review Cycle 1 (fix cycle, code-review findings)

- **M1 fixed:** `build_catalog/1` (`server/lib/nebu/media/config.ex`) now
  filters `override` to only the keys known to `@defaults`/`@key_to_atom`
  (`Map.take(override, Map.keys(@defaults))`) BEFORE merging, so any row in
  `media_config` whose key falls outside this story's 10-key catalog (e.g. a
  future Story 10c/10d key written by a newer node in a rolling deploy, or a
  stray/manual row) is silently ignored by `get/0` instead of crashing the
  `Nebu.Media.Config` GenServer with `KeyError` on init/`:refresh`/`:ttl_tick`/
  `:invalidate`. This is the single call site all read paths funnel through
  (`get/0`'s source-seam path, `do_refresh/0`, `read_from_ets/0`'s rescue
  fallback), so one fix covers all of them. Added test `"get/0 ignores an
  unrecognized key returned by the loader instead of crashing"` in
  `config_test.exs`, seeding the fake `store` with an extra
  `{"some_future_10c_key", ...}` row alongside the normal catalog and
  asserting `Config.refresh/0` and the `:pg` `:invalidate_media_config`
  handler both survive it, with `Config.get/0` still returning the correct,
  unaffected 10-key catalog.
- **m3 fixed:** `do_upsert/3` now inspects `AuditWriter.log/6`'s return value.
  The config write itself is NOT rolled back on an audit failure (consistent
  with the accepted m2 note below — the two writes are sequential, not
  atomic). `AuditWriter.log/6` never raises and already `Logger.error/2`s
  internally on its own failure; `do_upsert/3` additionally logs via
  `Logger.error/1` with the `key`/`actor` context AuditWriter's generic
  message lacks. `upsert/2`'s return value stays `:ok` in both cases — the
  config value was written successfully, which is the contract callers rely
  on — matching every other audit-bridge call site already in this codebase
  (`session_expiry_worker.ex`, `user_deletion.ex`,
  `temporary_capture_manager.ex`, `users_controller.ex`), none of which
  propagate `{:error, :audit_write_failed}` to their own caller either. Added
  test `"upsert/1 logs the audit-write failure but still returns :ok and the
  config value is still written"`, using `ExUnit.CaptureLog` and a
  `FakeAuditRepo.insert/2` that returns `{:error, :simulated}` for this test
  only.
- **m4 fixed:** `upsert/2` is now `upsert(key, value, actor \\ @audit_actor)`
  — arity-3 with a default, so every existing arity-2 call site (including
  every existing test) keeps compiling and behaving identically. `actor` is
  threaded through to `AuditWriter.log/6`'s `actor_user_id` (first positional
  arg), which was previously hardcoded to `@audit_actor` there too. Story 9b's
  `/admin/media/settings` UI can now pass the real admin's identity. Added
  test `"upsert/3 with a custom actor attributes the audit row to that
  actor"`, asserting `row.actor_user_id` on the captured audit row.
- **m1 (supervisor convention) — accepted, not fixed** (coordinator decision):
  documented in place via a one-line note added to
  `server/lib/nebu/media/config_supervisor.ex`'s moduledoc, acknowledging the
  bespoke-`Supervisor` + `:transient` deviation from the codebase's usual
  bare-`:permanent`-child convention. Verified correct by code review; not
  worth further churn for this story.
- **m2 (no DB transaction around read-old-value → write → audit) — accepted,
  not fixed, known limitation for future work:** `do_upsert/3` still performs
  a plain loader-read, then a writer-call, then an `AuditWriter.log/6` call,
  with no surrounding `Repo.transaction/1`. Under concurrent same-key
  `upsert/2` calls, the `old_value` recorded in the audit entry can be stale
  (TOCTOU) — the interleaving writer would win the actual row, but a
  differently-interleaved reader could record the wrong prior value in its
  own audit metadata. This is accepted for this story's single-admin-typically
  scope (Story 9b's settings UI has no concurrent-editor story yet), but is a
  real gap versus the story's own skeleton (which specified a `Repo`
  transaction) and should be revisited if Story 9b or a later hardening pass
  needs multi-admin-concurrent-edit correctness for `media_config`.

### Review Cycle 2 (Kassandra security-review findings)

- **F-1 fixed — HIGH — missing `GRANT` on `media_config` (production
  fail-open).** `000023_media_config.up.sql` created the table, RLS, and all
  3 policies but never granted `nebu_app` (the runtime role) any DML
  privilege. In dev/CI, docker-compose's `ALTER DEFAULT PRIVILEGES` masks
  this entirely; in production (UpCloud managed PostgreSQL, `nebu_migrate`
  owns tables, no default-privileges compensation) `nebu_app` would have had
  **zero** privilege on `media_config`: `get/0`'s loader would hit
  `permission denied`, silently fall back to `%{}` (compile-time defaults —
  fail-open on a security-relevant cache: `mime_denylist`, upload/scan size
  limits), and every `upsert/3` call would error. Fixed by adding
  `GRANT SELECT, INSERT, UPDATE, DELETE ON media_config TO nebu_app;` to the
  end of `000023_media_config.up.sql`, and extending
  `Nebu.Matrix.MigrationsGrantTest` with a `000023` describe block (DML grant
  assertion + a no-SERIAL-columns guard, matching the existing 000006/
  000008/000009/000010/000011/000012/000022 precedent) so this exact class of
  omission cannot ship green again for this table.
  **⚠ Process flag for every subsequent story in this epic that adds a new
  table (10c, 10d, 11a, etc.): a missing `GRANT ... TO nebu_app` on a new
  migration silently passes CI/dev (docker-compose's default privileges mask
  it) and only fails in production. Double-check every new
  `CREATE TABLE` migration has both (a) an explicit `GRANT` to `nebu_app` and
  (b) a corresponding `Nebu.Matrix.MigrationsGrantTest` describe block, the
  same way `000023` now does.**
- **F-2 (webhook_url SSRF store-time-only check) — hand-off to Story 7, not
  fixed here.** `upsert/3`'s validation calls `Nebu.Media.SSRF.check/1` at
  write-time only; Story 7's webhook sender (not yet landed) re-resolves the
  host at send-time, so a DNS-rebinding or redirect-based SSRF against
  `127.0.0.1`/`169.254.169.254`/etc. is possible at the actual sink even
  though this story's store-time check is correct and genuinely invoked on
  every non-nil write. Story 7 must add its own send-time re-check
  (IP-pinning / no unvalidated redirects) rather than trusting the stored
  value as pre-vetted.
- **F-3 (missing explicit `WITH CHECK` on `media_config_update_mutable`) —
  accepted, not fixed.** The UPDATE policy only specifies `USING (key IN
  (...))`, relying on PostgreSQL's implicit `WITH CHECK = USING` fallback
  (which does correctly block a `key`-rename escape today). `server_config`'s
  precedent spells out both clauses explicitly. Low-severity inconsistency —
  fix opportunistically if this migration (or its `server_config` analogue)
  is touched again for another reason, not worth a dedicated migration now.
