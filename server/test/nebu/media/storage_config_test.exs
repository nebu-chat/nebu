defmodule Nebu.Media.StorageConfigTest do
  @moduledoc """
  RED-phase ATDD tests for story `11a-storage-config-schema-secrets` (epic
  `media-security-admin-control`).

  ## What is under test

  A brand-new module `Nebu.Media.StorageConfig` (does not exist yet — every
  test in this file fails with `UndefinedFunctionError` until the dev agent
  implements `server/lib/nebu/media/storage_config.ex`) is the SOLE public-API
  module (ADR-020) for the singleton `media_storage_config` table this story
  also creates. It structurally mirrors Story 9a's `Nebu.Media.Config`
  (GenServer + ETS + `:pg`) but is its OWN cache instance (own ETS table, own
  `:pg` group — never shared with `Nebu.Media.Config`, per the story's Summary)
  and its two secret fields (`access_key`/`secret_key`) are encrypted at rest
  via `Nebu.Web.SecretBox`, unlike any of `media_config`'s plain-scalar keys.

    * AC1 — migration creates `media_storage_config` as a singleton row (RLS +
      3 policies). Verified against the dev DB as part of the eventual
      dev-story step, NOT re-asserted here as an ExUnit test (same split
      `config_test.exs` already uses for AC1) — this file covers AC2-AC9.
    * AC2 — field catalog (endpoint/bucket/region/use_ssl/access_key/
      secret_key/s3_key_prefix_template/archive_bucket).
    * AC3 — secret fields encrypted at rest via `Nebu.Web.SecretBox`.
    * AC4 — env-var fallback (`NEBU_MINIO_*`/`NEBU_S3_REGION`), `_FILE`-then-
      plain precedence for the two secret fields.
    * AC5 — DB config takes precedence over env vars, per field.
    * AC6 — `get/0` / `get_for_connection/0` / `upsert/1` public API shape,
      including partial-update semantics.
    * AC7 — ETS/`:pg`-backed cache invalidation + 60s TTL fallback, this
      module's OWN instance.
    * AC8 — secrets masked in `get/0`, never plaintext/raw-ciphertext.
    * AC9 — `media_storage_config_updated` audit trail, field NAMES only.

  ## Migration number (context for the dev-story step; not exercised here)

  `priv/migrations/` currently ends at `000023_media_config.up.sql`/`.down.sql`
  (Story 9a, already landed — confirmed by listing the directory at the time
  this file was written). The story's own text anticipated 9a would claim
  `000024` and reserved `000025` for this story, but 9a actually claimed
  `000023`, so **`000024` is the correct next number** for
  `media_storage_config`
  (`priv/migrations/000024_media_storage_config.up.sql`/`.down.sql`) — the
  dev-story step should use `000024`, not the story text's `000025`, per the
  epic's own "whichever lands first keeps its number, the other renumbers"
  convention. This file does not create or touch any migration file (ATDD
  scope is test-file-only). The dev-story step's migration MUST also include
  `GRANT SELECT, INSERT, UPDATE, DELETE ON media_storage_config TO nebu_app;`
  — this is the same convention `server/test/nebu/matrix/migrations_grant_test.exs`
  enforces for every other application table; it is not re-asserted in THIS
  file (out of scope for a Media-domain module test) but is called out here so
  the dev-story step does not miss it.

  ## Why this suite avoids a live Postgres/`Nebu.Repo` entirely

  Exactly like `config_test.exs`: `mix test` never starts `Nebu.Repo` under
  plain `mix test` (no `NEBU_DB_URL`, `:integration`-tagged tests excluded).
  Every test below drives `Nebu.Media.StorageConfig` entirely through
  injectable seams — no live DB, no real `System.get_env` env-var reads.

  ## Seam contract this file imposes on the dev-story implementation

  Mirrors `Nebu.Media.Config`'s seam conventions (see its moduledoc), adapted
  for this module's own table/cache instance and its two secret fields:

    * `Application.get_env(:nebu_http, :media_storage_config_source)` —
      0-arity fun. When set, `get/0` calls it directly (bypassing ETS/
      GenServer/DB/env-fallback entirely) and merges the returned map over the
      config.exs defaults — mirrors `:media_config_source`'s test-only fast
      path. **Documented here for seam-contract completeness (mirrors the
      sibling exactly) but deliberately NOT exercised by any test below** —
      using it for the AC4/AC5 fallback-behavior tests (AT1/2/3/7/8) would
      bypass the very env-var/DB-precedence logic those tests exist to prove.
      This is a judgment call — see the report accompanying this file.
    * `Application.get_env(:nebu_http, :media_storage_config_loader)` —
      0-arity fun returning the CURRENT persisted `media_storage_config` row
      as a STRING-keyed map (column names: `"endpoint"`, `"bucket"`,
      `"region"`, `"use_ssl"`, `"access_key_encrypted"`,
      `"secret_key_encrypted"`, `"s3_key_prefix_template"`,
      `"archive_bucket"`, `"set_at"`) — or `nil` when no row has ever been
      written (the singleton-row-does-not-exist-yet case). Consulted by the
      GenServer's DB-refresh step AND directly by `get/0`/`get_for_connection/0`
      whenever the ETS table is not yet populated (mirrors
      `Nebu.Media.Config.get/0`'s `:ets.whereis/1`-guarded direct-loader
      fallback — **this file assumes `Nebu.Media.StorageConfig.get/0` and
      `get_for_connection/0` work correctly even before the GenServer/cache
      process has ever started**, exactly like the sibling; this is a second
      judgment call, flagged in the report). Defaults to a real
      `SELECT ... FROM media_storage_config` when unset.
    * `Application.get_env(:nebu_http, :media_storage_config_writer)` — a fun
      of arity 2, `fn columns, set_at -> :ok | {:error, term()} end`, where
      `columns` is a STRING-keyed map containing ONLY the columns that
      changed for this `upsert/1` call (already `SecretBox`-encrypted for
      `access_key_encrypted`/`secret_key_encrypted` when those fields were
      present in the input) — the real implementation's
      `INSERT ... ON CONFLICT (id) DO UPDATE` with a partial `SET` clause.
      Defaults to real SQL when unset. This seam is INVENTED for this test
      file (the story's skeleton fixes `upsert/1`'s public contract but not
      its internal DB-write seam) — mirrors `:media_config_writer`'s shape as
      closely as this table's different row-shape (singleton, partial
      column set vs. key/value upsert) allows.
    * `Application.get_env(:nebu_http, :media_storage_env_reader)` — 0-arity
      fun returning a STRING-keyed map standing in for the `NEBU_MINIO_*`/
      `NEBU_S3_REGION` env vars `server/config/runtime.exs` already reads at
      boot (keys: `"NEBU_MINIO_ENDPOINT"`, `"NEBU_MINIO_USE_SSL"`,
      `"NEBU_MINIO_BUCKET"`, `"NEBU_S3_REGION"`, `"NEBU_MINIO_ACCESS_KEY_FILE"`,
      `"NEBU_MINIO_ACCESS_KEY"`, `"NEBU_MINIO_SECRET_KEY_FILE"`,
      `"NEBU_MINIO_SECRET_KEY"` — any absent/nil key means "not set", exactly
      like `System.get_env/1`'s own `nil`-when-unset contract). **This is the
      THIRD, most consequential judgment call in this file**: the story's own
      Acceptance Test #2 text says env vars must be injected "via the app-env
      seam (not real OS env vars)" — this codebase has ALSO used real
      `System.put_env/2` + `on_exit`-restore for `NEBU_*` vars elsewhere
      (`release_ssl_test.exs`, `release_test.exs`, `jwks_cache_test.exs`,
      `matrix_router_test.exs`, `url_preview_test.exs`), but the story's own
      acceptance-test prose is the more specific, more authoritative
      instruction for THIS module, so this file follows it literally: a new
      `:media_storage_env_reader` seam takes the place of `System.get_env/1`
      itself. The `_FILE`-then-plain precedence logic (AC4, AT3) is left as
      REAL behavior inside `Nebu.Media.StorageConfig` (mirroring
      `runtime.exs` lines 85-95 exactly: if the map's `"..._FILE"` key is
      present/non-nil, `File.read!/1` it and trim; else use the plain key) —
      this file writes a REAL temporary file for AT3 so that precedence logic
      is genuinely exercised end-to-end, not faked away.
    * The `:pg` group is the literal `"nebu_media_storage_config"` string the
      story's own module skeleton hardcodes as `@pg_group` — this file uses
      that literal directly rather than requiring a `pg_group/0` public
      function (AC6 does not list one; `Nebu.Media.Config.pg_group/0` exists
      only as a test/diagnostics convenience the story's skeleton for THIS
      module does not mention, so this file does not assume it exists).
    * The `:pg` cluster-invalidation broadcast payload is the 1-tuple
      `{:invalidate_media_storage_config}` (mirrors
      `{:invalidate_media_config}`).
    * The periodic TTL fallback (AC7, 60s) is driven by an internal
      `Process.send_after(self(), :ttl_tick, 60_000)` self-message loop, per
      the story's own skeleton. Tests drive it deterministically by sending
      `:ttl_tick` directly to the registered `Nebu.Media.StorageConfig` pid,
      exactly like `config_test.exs`/`session_expiry_worker_test.exs`.
    * `upsert/1` is assumed to unconditionally call
      `GenServer.call(__MODULE__, :refresh)` as its last step on success, per
      the story's own skeleton text (step 4) — unlike `Nebu.Media.Config`'s
      defensive `trigger_refresh/0` (which no-ops if the cache holder is not
      running), this file takes the skeleton literally and therefore starts
      the cache holder (`ensure_started/0`, mirroring `config_test.exs`'s own
      helper) before every test that calls `upsert/1` and expects it to
      succeed. AC2/AC4/AC5/AC8 pure-`get/0`-only tests (AT1/2/3/7/8) do NOT
      call `upsert/1` and therefore do NOT start the cache holder, exercising
      the "no GenServer running yet" direct-loader/env-reader fallback path
      instead (see the `:media_storage_config_loader` seam note above).

  ## Masked-marker format for `access_key`/`secret_key` in `get/0` (AC8)

  The story's AC8 gives this only as an example ("e.g. `\"••••\" <> last 4
  plaintext chars`"), not a pinned format — a FOURTH judgment call. This file
  pins the format exactly as that example: `"••••" <> String.slice(plaintext,
  -4..-1)` (4 U+2022 BULLET characters, then the last 4 plaintext bytes/chars),
  and `nil` (not the masked-marker string) when the field is genuinely unset.
  See `masked/1` below. The dev-story implementation must produce EXACTLY this
  format for these tests to pass in the green phase — if the dev-story agent
  prefers a different marker, it should update this file's `masked/1` helper
  to match and note the deviation, not silently diverge.

  ## AT10/AT11 cluster-invalidation test design note

  Same technique as `config_test.exs`'s own AT10/AT11: the TEST PROCESS joins
  `Nebu.Media.StorageConfig`'s `:pg` group as a stand-in peer node and asserts
  it receives the broadcast / the TTL tick is driven directly on the
  registered pid — no second real BEAM node is spun up.

  ## AT13 (added pre-dev test-review, cycle 1 — MAJOR fix)

  A prior test-review flagged that this file, unlike `config_test.exs`, had no
  crash/restart test for the supervised GenServer holder — this module caches
  storage-target config, including secret-adjacent decrypted reads via
  `get_for_connection/0`, so its resilience bar must be at least as high as
  the sibling's, not lower. AT13 mirrors `config_test.exs`'s "the supervised
  holder restarts and repopulates its ETS cache after a kill" test exactly.
  This REQUIRES the dev-story step to add `Nebu.Media.StorageConfig.Supervisor`
  (mirroring `Nebu.Media.Config.Supervisor` — `:transient` restart child,
  `raw_start_link/1` MFA) and wire it into `Nebu.Application`'s unconditional
  children list, alongside `Nebu.Media.Config.Supervisor` — see the story's
  Technical Requirements (updated in this same fix cycle) for the exact shape.

  ## bugfix-upcloud-s3-iam-sts-endpoints (AC1) — `iam_endpoint`/`sts_endpoint`

  A real UpCloud Managed Object Storage bucket exposes three distinct
  endpoint URLs (public S3, IAM, STS) — only the public S3 one has ever been
  wired through (`endpoint`, above). This bugfix adds two new resolved-config
  keys, `iam_endpoint` and `sts_endpoint`, each resolved from new env vars
  `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` via the SAME
  `:media_storage_env_reader` seam `endpoint` already uses — see the seam
  contract note above (the real env-var names are added to
  `server/config/runtime.exs`'s S3 block and to the env-reader map
  `default_env_reader/0` builds, both out of this file's scope to assert
  directly).

  Unlike `endpoint` (a bare `host[:port]`, never a full URL, and validated via
  `validate_candidate_endpoint/1`'s scheme-rejection on the write path),
  `iam_endpoint`/`sts_endpoint` ARE expected to be full URLs (matching
  UpCloud's own `iam_url`/`sts_url` shape, e.g.
  `"https://7mf5k.upcloudobjects.com:4443/iam"`) — they must round-trip
  through `get/0`/`get_for_connection/0` completely verbatim, with no
  scheme-stripping and no `validate_candidate_endpoint/1` scheme-rejection
  applied to them.

  Both fields are infra-provisioned-only: there is no `media_storage_config`
  DB column for either one (Terraform writes them straight into the VM's env,
  not into the admin DB), so they are resolved from the env reader with a
  compiled default of `nil` only — no DB-row precedence to test, unlike every
  other field `build_resolved/2` already handles. They are not secrets, so
  `mask_map/1` must never touch them: `get/0` and `get_for_connection/0` are
  expected to return the identical value for both fields, unlike
  `access_key`/`secret_key`, which `get/0` masks and `get_for_connection/0`
  does not.

  `AT1` below is updated (not just extended) to include
  `iam_endpoint: nil, sts_endpoint: nil` in its exact-equality default-shape
  assertion, so it stays the single source of truth for the resolved map's
  full key set and fails loudly if a future change silently drops either new
  key from `@defaults`.

  ## bugfix-add-sts-iam-endpoints-to-admin-ui (AC1/AC2) — DB-override columns

  Follow-on to the bugfix above: `media_storage_config` gains two nullable
  columns, `iam_endpoint TEXT`/`sts_endpoint TEXT`
  (`priv/migrations/000037_media_storage_config_iam_sts.up/down.sql`), so
  these two fields now get the SAME DB > env > default per-field precedence
  as every other plain field (`region`, `archive_bucket`, ...), instead of
  always resolving from the env reader only. See the new
  "bugfix-add-sts-iam-endpoints: DB-override columns" describe
  block below for the net-new DB-row-fixture tests this adds; the three
  `iam-sts-AT1/AT2/AT3` tests directly above are untouched (env-only
  regression guard — they run with no DB row seeded, so they continue to
  exercise the "no row has ever been written" default/env-fallback path
  exactly as before).
  """

  use ExUnit.Case, async: false

  alias Nebu.Media.StorageConfig
  alias Nebu.Web.SecretBox

  @pg_group "nebu_media_storage_config"

  # ─── FakeAuditRepo ────────────────────────────────────────────────────────
  #
  # Reused shape from config_test.exs / audit_writer_test.exs — replaces
  # Nebu.Repo for Nebu.Compliance.AuditWriter.log/6 via the SAME `:compliance,
  # :repo` seam those suites already use, so AC9's audit trail can be
  # asserted without touching PostgreSQL.

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter. Test-private."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      bucket = Application.get_env(:compliance, :__test_media_storage_config_audit_bucket__)
      if bucket, do: Agent.update(bucket, fn rows -> [struct | rows] end)
      {:ok, struct}
    end

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  # ─── Setup / Teardown ─────────────────────────────────────────────────────

  setup do
    # Defensive isolation fix (dev-story step, not part of the pre-dev fix
    # cycle's own text): Nebu.Media.StorageConfig.Supervisor is started
    # UNCONDITIONALLY by Nebu.Application (AT13's own requirement), so a
    # boot-time instance is already alive, with an already-populated ETS
    # cache built from the REAL (non-test) loader/env-reader, before this
    # file's very first test runs. AT1/AT2/AT3/AT7/AT8 deliberately exercise
    # the "no GenServer/cache started yet" direct-load path (see moduledoc)
    # and would otherwise nondeterministically read that stale boot-time
    # cache instead of this test's own seams, depending on which test in this
    # module ExUnit happens to schedule first relative to the rest of the
    # (1700+ test) full suite. Stopping any pre-existing instance at the
    # START of setup (not just in on_exit, which only cleans up AFTER a test
    # this file itself started) mirrors the same "reset shared boot-started
    # state before every test" convention already used by
    # oidc_claim_cache_test.exs's `OidcClaimCache.reset_for_test()` call at
    # the top of its own `setup`.
    if pid = Process.whereis(Nebu.Media.StorageConfig) do
      if Process.alive?(pid), do: (try do GenServer.stop(pid) catch :exit, _ -> :ok end)
    end

    {:ok, audit_bucket} = Agent.start_link(fn -> [] end)
    Application.put_env(:compliance, :__test_media_storage_config_audit_bucket__, audit_bucket)
    Application.put_env(:compliance, :repo, FakeAuditRepo)

    # `store` stands in for the media_storage_config singleton row: either
    # `nil` (no row yet) or a STRING-keyed map of column values (secret
    # columns already SecretBox-encrypted, mirroring the real DB contents).
    {:ok, store} = Agent.start_link(fn -> nil end)
    {:ok, calls} = Agent.start_link(fn -> %{loader: 0, writer: 0, last_write_columns: nil} end)

    loader = fn ->
      Agent.update(calls, &Map.update!(&1, :loader, fn n -> n + 1 end))
      Agent.get(store, & &1)
    end

    writer = fn columns, set_at ->
      Agent.update(calls, fn c ->
        c
        |> Map.update!(:writer, fn n -> n + 1 end)
        |> Map.put(:last_write_columns, Map.keys(columns))
      end)

      Agent.update(store, fn
        nil -> Map.put(columns, "set_at", set_at)
        row -> row |> Map.merge(columns) |> Map.put("set_at", set_at)
      end)

      :ok
    end

    Application.put_env(:nebu_http, :media_storage_config_loader, loader)
    Application.put_env(:nebu_http, :media_storage_config_writer, writer)
    Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

    on_exit(fn ->
      Application.delete_env(:compliance, :__test_media_storage_config_audit_bucket__)
      Application.delete_env(:compliance, :repo)
      Application.delete_env(:nebu_http, :media_storage_config_source)
      Application.delete_env(:nebu_http, :media_storage_config_loader)
      Application.delete_env(:nebu_http, :media_storage_config_writer)
      Application.delete_env(:nebu_http, :media_storage_env_reader)

      if pid = Process.whereis(Nebu.Media.StorageConfig) do
        if Process.alive?(pid), do: (try do GenServer.stop(pid) catch :exit, _ -> :ok end)
      end
    end)

    {:ok, audit_bucket: audit_bucket, store: store, calls: calls}
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT1 — AC2/AC4: full default catalog, no row, no env vars
  # ════════════════════════════════════════════════════════════════════════

  test "AT1: get/0 with no row and no env vars set returns the config.exs-matching defaults, access_key/secret_key masked as nil" do
    # `store` is nil (no row) and the env-reader seam returns %{} (no env vars
    # set) — both wired by `setup`. No GenServer/DB involved.
    #
    # bugfix-upcloud-s3-iam-sts-endpoints (AC1): iam_endpoint/sts_endpoint
    # are added to this exact-equality default-shape assertion so this test
    # remains the single source of truth for the FULL resolved-map key set —
    # see the moduledoc's "bugfix-upcloud-s3-iam-sts-endpoints (AC1)" note.
    # This assertion now passes (GREEN): @defaults has both keys.
    assert StorageConfig.get() == %{
             endpoint: "minio:9000",
             bucket: "nebu-media",
             region: "us-east-1",
             use_ssl: false,
             access_key: nil,
             secret_key: nil,
             s3_key_prefix_template: "{media_id}",
             archive_bucket: nil,
             iam_endpoint: nil,
             sts_endpoint: nil
           }
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT2 — AC4: env-var fallback when no row exists, secrets masked
  # ════════════════════════════════════════════════════════════════════════

  test "AT2: get/0 with no row but NEBU_MINIO_*/NEBU_S3_REGION env vars set falls back to them, masked" do
    Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
      %{
        "NEBU_MINIO_ENDPOINT" => "s3.example.internal:9000",
        "NEBU_MINIO_BUCKET" => "custom-bucket",
        "NEBU_S3_REGION" => "eu-central-1",
        "NEBU_MINIO_USE_SSL" => "true",
        "NEBU_MINIO_ACCESS_KEY" => "env-access-key-1234",
        "NEBU_MINIO_SECRET_KEY" => "env-secret-key-5678"
      }
    end)

    result = StorageConfig.get()

    assert result.endpoint == "s3.example.internal:9000"
    assert result.bucket == "custom-bucket"
    assert result.region == "eu-central-1"
    assert result.use_ssl == true
    assert result.s3_key_prefix_template == "{media_id}"
    assert result.archive_bucket == nil

    assert result.access_key == masked("env-access-key-1234")
    assert result.secret_key == masked("env-secret-key-5678")
    refute result.access_key == "env-access-key-1234"
    refute result.secret_key == "env-secret-key-5678"
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT3 — AC4: Docker-secret-file precedence over the plain env var
  # ════════════════════════════════════════════════════════════════════════

  test "AT3: get/0 prefers a Docker-secret-file access/secret key over the plain env var when both are present" do
    access_key_path = write_secret_file!("file-based-access-key-9999\n")
    secret_key_path = write_secret_file!("file-based-secret-key-8888\n")

    Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
      %{
        "NEBU_MINIO_ACCESS_KEY_FILE" => access_key_path,
        "NEBU_MINIO_ACCESS_KEY" => "plain-value-should-lose-0000",
        "NEBU_MINIO_SECRET_KEY_FILE" => secret_key_path,
        "NEBU_MINIO_SECRET_KEY" => "plain-value-should-lose-1111"
      }
    end)

    result = StorageConfig.get()

    # File content is trimmed of its trailing newline (mirrors runtime.exs's
    # `File.read!() |> String.trim()`), so the last 4 chars are "9999"/"8888".
    assert result.access_key == masked("file-based-access-key-9999")
    assert result.secret_key == masked("file-based-secret-key-8888")
    refute result.access_key == masked("plain-value-should-lose-0000")
    refute result.secret_key == masked("plain-value-should-lose-1111")
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT4 — AC3: encryption round-trip via the REAL Nebu.Web.SecretBox
  # ════════════════════════════════════════════════════════════════════════

  test "AT4: upsert/1 with access_key/secret_key persists SecretBox-encrypted ciphertext, and get_for_connection/0 decrypts it back",
       %{store: store} do
    with_admin_secret_at_rest("storage-config-test-at-rest-key", fn ->
      ensure_started()

      plaintext_access = "AKIAABCDEFGH1234"
      plaintext_secret = "supersecretsecretkeyvalue5678"

      assert :ok =
               StorageConfig.upsert(%{access_key: plaintext_access, secret_key: plaintext_secret})

      stored = Agent.get(store, & &1)

      refute stored["access_key_encrypted"] == plaintext_access
      refute stored["secret_key_encrypted"] == plaintext_secret

      assert {:ok, plaintext_access} == SecretBox.decrypt(stored["access_key_encrypted"])
      assert {:ok, plaintext_secret} == SecretBox.decrypt(stored["secret_key_encrypted"])

      conn = StorageConfig.get_for_connection()
      assert conn.access_key == plaintext_access
      assert conn.secret_key == plaintext_secret
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT5 — AC8: get/0 never returns plaintext, even immediately after upsert
  # ════════════════════════════════════════════════════════════════════════

  test "AT5: get/0 never returns the plaintext access_key/secret_key even immediately after upsert/1 on the same process",
       %{store: store} do
    with_admin_secret_at_rest("storage-config-test-at-rest-key-2", fn ->
      ensure_started()

      plaintext_access = "AKIAZZZZZZZZ7777"
      plaintext_secret = "another-super-secret-value-9999"

      assert :ok =
               StorageConfig.upsert(%{access_key: plaintext_access, secret_key: plaintext_secret})

      result = StorageConfig.get()

      assert result.access_key == masked(plaintext_access)
      assert result.secret_key == masked(plaintext_secret)

      refute result.access_key == plaintext_access
      refute result.secret_key == plaintext_secret

      stored = Agent.get(store, & &1)
      refute result.access_key == stored["access_key_encrypted"]
      refute result.secret_key == stored["secret_key_encrypted"]
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT6 — AC6: partial update leaves untouched fields (incl. secrets) alone
  # ════════════════════════════════════════════════════════════════════════

  test "AT6: upsert/1 with only endpoint/bucket leaves a previously-saved access_key/secret_key untouched",
       %{calls: calls} do
    with_admin_secret_at_rest("storage-config-test-at-rest-key-3", fn ->
      ensure_started()

      original_access = "AKIA-ORIGINAL-0001"
      original_secret = "ORIGINAL-SECRET-VALUE-0002"

      # M-3 fix (epic security review, 2026-07-20): endpoint is now validated
      # via the shared Nebu.Media.SSRF.checked_target/1 guard on the persist
      # path, same as test_connection/1 — literal public IPs (no live DNS
      # lookup needed, mirroring webhook_delivery_test.exs's own convention)
      # instead of the bare made-up hostnames this test used before the fix.
      assert :ok =
               StorageConfig.upsert(%{
                 access_key: original_access,
                 secret_key: original_secret,
                 endpoint: "93.184.216.34:9000"
               })

      # (media-storage-uses-admin-config, fix B: a CHANGED endpoint now needs both keys in the same save, so the second
      # save keeps the endpoint and changes the bucket: the stored keys stay untouched.)
      assert :ok = StorageConfig.upsert(%{endpoint: "93.184.216.34:9000", bucket: "new-bucket"})

      # The partial-column-set write for the SECOND upsert must not even
      # mention the secret-ciphertext columns — proving this is a genuine
      # partial UPDATE, not a read-modify-write-the-whole-row that happens to
      # preserve values by re-writing them.
      last_columns = Agent.get(calls, & &1.last_write_columns)
      refute "access_key_encrypted" in last_columns
      refute "secret_key_encrypted" in last_columns

      conn = StorageConfig.get_for_connection()
      assert conn.access_key == original_access
      assert conn.secret_key == original_secret

      result = StorageConfig.get()
      assert result.endpoint == "93.184.216.34:9000"
      assert result.bucket == "new-bucket"
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT7 — AC4: env-var fallback matches runtime.exs's literal hardcoded
  # defaults exactly (regression-proofs against the two default sets drifting
  # apart independently)
  # ════════════════════════════════════════════════════════════════════════

  test "AT7: a fresh media_storage_config table with no env vars set behaves identically to the pre-Story-11a boot-time NEBU_MINIO_* wiring" do
    # No row, no env vars — identical premise to AT1, but asserted against
    # LITERAL inline strings matching server/config/runtime.exs lines 78-119
    # verbatim, rather than reusing AT1's expectation, so a future edit to
    # either this test file or runtime.exs that silently drifts the two
    # default sets apart is caught here specifically.
    result = StorageConfig.get()

    assert result.endpoint == "minio:9000"
    assert result.bucket == "nebu-media"
    assert result.region == "us-east-1"
    assert result.use_ssl == false
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT8 — AC5: DB config takes precedence per field, not all-or-nothing
  # ════════════════════════════════════════════════════════════════════════

  test "AT8: after a DB row sets endpoint, get/0 returns the DB value even though NEBU_MINIO_ENDPOINT is still set to a different value",
       %{store: store} do
    # Seed the store directly (simulating a prior upsert/1 that only ever
    # touched `endpoint`) WITHOUT calling upsert/1 itself — mirrors
    # config_test.exs's own "ignores an unrecognized key" test seeding the
    # store Agent directly before any GenServer/cache involvement.
    Agent.update(store, fn _ ->
      %{"endpoint" => "db-endpoint:9000", "set_at" => System.system_time(:millisecond)}
    end)

    Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
      %{
        "NEBU_MINIO_ENDPOINT" => "env-endpoint-should-lose:1111",
        "NEBU_MINIO_BUCKET" => "env-bucket-should-win-since-db-unset"
      }
    end)

    result = StorageConfig.get()

    # DB wins for the field the DB row actually set.
    assert result.endpoint == "db-endpoint:9000"
    # Env var still wins for a field the DB row left NULL — precedence is
    # per-field, not "DB has ANY value written, so ignore env vars globally".
    assert result.bucket == "env-bucket-should-win-since-db-unset"
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT9 — AC9: audit trail with field names only, no old_value/new_value
  # ════════════════════════════════════════════════════════════════════════

  test "AT9: upsert/1 writes a media_storage_config_updated audit entry with changed_fields naming only the fields that changed, no old_value/new_value",
       %{audit_bucket: audit_bucket} do
    with_admin_secret_at_rest("storage-config-test-at-rest-key-4", fn ->
      ensure_started()

      assert :ok =
               StorageConfig.upsert(%{
                 access_key: "AKIA-BASELINE-0001",
                 secret_key: "BASELINE-SECRET-0002"
               })

      assert :ok = StorageConfig.upsert(%{bucket: "only-bucket-change"})

      rows = Agent.get(audit_bucket, & &1)
      assert length(rows) == 2, "expected exactly two audit rows, got #{length(rows)}"

      [second_row, first_row] = rows

      assert first_row.action == "media_storage_config_updated"
      assert second_row.action == "media_storage_config_updated"

      assert Enum.sort(first_row.metadata.changed_fields) ==
               Enum.sort([:access_key, :secret_key])

      refute Map.has_key?(first_row.metadata, :old_value)
      refute Map.has_key?(first_row.metadata, :new_value)

      assert second_row.metadata.changed_fields == [:bucket]
      refute :access_key in second_row.metadata.changed_fields
      refute Map.has_key?(second_row.metadata, :old_value)
      refute Map.has_key?(second_row.metadata, :new_value)
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT10 — AC7: cross-node :pg broadcast invalidation
  # ════════════════════════════════════════════════════════════════════════

  test "AT10: a second node's cache reflects an upsert via the :pg broadcast without calling get/0 a second time on the writing node" do
    with_admin_secret_at_rest("storage-config-test-at-rest-key-5", fn ->
      ensure_started()
      ensure_pg()
      :pg.join(@pg_group, self())
      on_exit(fn -> :pg.leave(@pg_group, self()) end)

      assert :ok = StorageConfig.upsert(%{bucket: "pg-broadcast-bucket"})

      assert_receive {:invalidate_media_storage_config}, 500
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT11 — AC7: 60s TTL fallback for a node that missed the broadcast
  # ════════════════════════════════════════════════════════════════════════

  test "AT11: a node that misses the :pg broadcast still serves the new value within the 60s TTL fallback window",
       %{store: store} do
    ensure_started()

    assert StorageConfig.get().bucket == "nebu-media"

    # Simulate a DB change this node's cache did NOT learn about via
    # broadcast, by mutating the underlying store directly (bypassing
    # upsert/1 entirely, exactly like config_test.exs's own AT11).
    Agent.update(store, fn _ ->
      %{"bucket" => "ttl-fallback-bucket", "set_at" => System.system_time(:millisecond)}
    end)

    # Still stale — no refresh has happened yet.
    assert StorageConfig.get().bucket == "nebu-media"

    pid = Process.whereis(Nebu.Media.StorageConfig)
    send(pid, :ttl_tick)
    :sys.get_state(pid)

    assert StorageConfig.get().bucket == "ttl-fallback-bucket",
           "expected the TTL fallback tick to re-read the DB and pick up the missed change"
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT12 — AC3: SecretBox.encrypt/1 fails closed; upsert/1 must not swallow it
  # ════════════════════════════════════════════════════════════════════════

  test "AT12: SecretBox.encrypt/1 raises (fail-closed) if the at-rest secret is unset when upsert/1 is called with a secret field",
       %{calls: calls} do
    with_no_at_rest_secret(fn ->
      assert_raise RuntimeError, ~r/SecretBox key unavailable/, fn ->
        # (both keys: a lone key is `{:error, :key_pair_required}` before it is ever encrypted)
        StorageConfig.upsert(%{access_key: "AKIA-SHOULD-NEVER-BE-STORED-0000", secret_key: "secret-should-never-be-stored-0000"})
      end

      # The raise must propagate BEFORE any DB write — upsert/1 must not
      # swallow it into a stored-plaintext or empty-ciphertext fallback.
      assert Agent.get(calls, & &1.writer) == 0,
             "no DB write may happen when SecretBox.encrypt/1 fails closed"
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT13 (pre-dev test-review, cycle 1 — MAJOR fix) — AC7: the supervised
  # holder restarts and repopulates its ETS cache after a crash.
  #
  # This module caches storage-target config (including secret-adjacent
  # decrypted reads via get_for_connection/0), so its resilience bar must be
  # at least as high as the sibling Nebu.Media.Config's — which itself only
  # gained this exact test after a prior test-review flagged the same gap
  # (see config_test.exs's "F2 (pre-dev test-review gap)" comment). Mirrors
  # that test and oidc_claim_cache_test.exs's own "AC6: the supervised
  # holder restarts and repopulates after a kill": monitor the current pid,
  # kill it, poll for a NEW pid under the same registered name (proving the
  # surrounding OTP supervisor — Nebu.Media.StorageConfig.Supervisor, added
  # to Nebu.Application by this same fix cycle — restarted it, not merely
  # that some other code kept it alive), then assert a subsequent read
  # repopulates correctly. A bare, unsupervised start_link/1 (like
  # ensure_started/0's own fallback path) would never come back on its own
  # after :kill — only real supervision makes this pass.
  # ════════════════════════════════════════════════════════════════════════

  test "AT13: the supervised holder restarts and repopulates its ETS cache after a kill" do
    ensure_started()

    # init/1's own do_refresh (see AT1-AT9) already populates the cache from
    # this test's loader/env-reader seams — no separate public refresh/0 is
    # assumed here, since AC6 does not list one for this module.
    assert StorageConfig.get().bucket == "nebu-media"

    pid = Process.whereis(Nebu.Media.StorageConfig)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    new_pid = wait_for_restart(pid)
    assert is_pid(new_pid) and new_pid != pid

    # No manual admin action should be required to recover the correct
    # config after a crash — a subsequent get/0 repopulates transparently.
    assert StorageConfig.get().bucket == "nebu-media"
  end

  # ════════════════════════════════════════════════════════════════════════
  # 11c-AT7 — story `11c-s3-key-prefix-template` AC5: upsert/1 rejects an
  # invalid s3_key_prefix_template and does not persist the row
  # ════════════════════════════════════════════════════════════════════════
  #
  # RED-phase note (distinct failure mode from key_prefix_template_test.exs):
  # `upsert/1`'s CURRENT implementation (story 11a, this same file's subject
  # module) has no validation of `s3_key_prefix_template` at all —
  # `column_for/2` (server/lib/nebu/media/storage_config.ex, ~line 373) passes
  # any string straight through to the write path unchanged. Story 11c's
  # Technical Requirements call for `upsert/1` to call a new
  # `validate_template/1` function whenever `fields` contains
  # `:s3_key_prefix_template` — but that function does not exist yet either
  # (see key_prefix_template_test.exs). Unlike THAT file's tests (which fail
  # with UndefinedFunctionError because they call a wholly new function
  # directly), THIS test calls `upsert/1`, which already exists and compiles
  # today — so it currently fails at the
  # `assert {:error, _reason} = StorageConfig.upsert(...)` assertion with a
  # MatchError (`upsert/1` returns `:ok` and silently persists the invalid
  # template), not an UndefinedFunctionError. This is the correct and
  # expected RED for this specific test: the missing behavior is "upsert/1
  # never calls validate_template/1", which manifests as a wrong return
  # value/wrong persisted state, not a missing symbol — because the
  # currently-missing piece (the validation CALL) lives inside an
  # already-existing function body, not as an as-yet-undefined public
  # function this test invokes directly.

  test "11c-AT7: upsert/1 with an invalid s3_key_prefix_template returns an error and does not persist the row",
       %{store: store} do
    ensure_started()

    # Baseline: a previously-saved (valid) template is in place before the
    # rejected attempt, so this test can assert it survives the rejected
    # upsert/1 call untouched.
    assert :ok = StorageConfig.upsert(%{s3_key_prefix_template: "{media_id}"})
    assert StorageConfig.get().s3_key_prefix_template == "{media_id}"

    assert {:error, _reason} =
             StorageConfig.upsert(%{s3_key_prefix_template: "{room_id}/{media_id}"})

    # The rejected value must never have reached the write path.
    stored = Agent.get(store, & &1)
    refute stored["s3_key_prefix_template"] == "{room_id}/{media_id}"

    # get/0 still reflects the prior (valid) template, not the rejected one.
    assert StorageConfig.get().s3_key_prefix_template == "{media_id}"
  end

  # ════════════════════════════════════════════════════════════════════════
  # M-2/M-3 (epic security review, 2026-07-20) — SSRF guard reuse on the
  # storage-config endpoint, both at test-connection time and at persist time
  # ════════════════════════════════════════════════════════════════════════
  #
  # Kassandra's epic-end security review (SEC Gate 2,
  # `_bmad-output/implementation-artifacts/epic-media-security-admin-control-security-review-2026-07-20.md`)
  # flagged two MEDIUM findings against this module's admin-supplied
  # `endpoint` field:
  #
  #   * M-2 — `test_connection/1`'s `validate_candidate_endpoint/1` rejected
  #     only a bare `http://`/`https://` scheme-prefix string — no private/
  #     loopback/link-local/CGNAT/cloud-metadata IP blocking, no DNS pinning.
  #     `test_connection/1` then issued a real ExAws `head_bucket` against the
  #     admin-supplied host: a blind, admin-authenticated SSRF.
  #   * M-3 — `upsert/1` stored `endpoint` verbatim with NO validation
  #     whatsoever on the persist path (the weak scheme-only guard ran only on
  #     the test-connection path), so a private-host/scheme-prefixed endpoint
  #     could be persisted directly (skipping test-connection) and later used
  #     by `Nebu.Media.Storage` for real traffic.
  #
  # The fix routes BOTH call sites through the SAME shared
  # `Nebu.Media.SSRF.checked_target/1` guard `preview_url` and both webhook
  # paths already use (`Nebu.Media.WebhookDelivery.post/2`) — mirroring
  # `webhook_delivery_test.exs`'s own convention exactly: literal IP
  # addresses need no live DNS lookup, since `SSRF.checked_target/1` parses a
  # literal IP via `:inet.parse_address/1` before ever touching the network,
  # so these tests are fully deterministic with no live-network dependency.
  #
  # RED-phase note: BEFORE the fix, `validate_candidate_endpoint/1` only
  # rejects an `http://`/`https://` prefix — none of the bare
  # `host[:port]`-shaped private/loopback/metadata addresses below carry that
  # prefix, so every one of them currently passes straight through to the
  # test-connection fun / the DB writer. These tests are therefore expected
  # to be genuinely RED (the blocked addresses reach the mocked seam / the
  # writer instead of being rejected) until the fix lands.

  describe "M-2: test_connection/1 SSRF guard" do
    test "rejects a private/loopback/link-local/metadata endpoint before any real request" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
        send(test_pid, {:test_connection_called, candidate})
        :ok
      end)

      for blocked_endpoint <- [
            "127.0.0.1:9000",
            "10.0.0.5:9000",
            "169.254.169.254:80",
            "192.168.1.1:9000"
          ] do
        assert {:error, :invalid_endpoint} =
                 StorageConfig.test_connection(%{
                   endpoint: blocked_endpoint,
                   bucket: "some-bucket",
                   region: "us-east-1",
                   use_ssl: false,
                   access_key: "AKIA1234",
                   secret_key: "secret1234"
                 }),
               "expected #{blocked_endpoint} to be rejected as :invalid_endpoint (M-2 fix)"

        refute_received {:test_connection_called, _candidate},
                        "expected #{blocked_endpoint} to be rejected BEFORE reaching the " <>
                          "test-connection fun / any real ExAws request"
      end
    end
  end

  describe "M-3: upsert/1 SSRF guard" do
    test "rejects a private/loopback/link-local/metadata endpoint and never persists it",
         %{calls: calls} do
      for blocked_endpoint <- [
            "127.0.0.1:9000",
            "10.0.0.5:9000",
            "169.254.169.254:80",
            "192.168.1.1:9000"
          ] do
        assert {:error, :invalid_endpoint} = StorageConfig.upsert(%{endpoint: blocked_endpoint}),
               "expected #{blocked_endpoint} to be rejected as :invalid_endpoint (M-3 fix)"
      end

      assert Agent.get(calls, & &1.writer) == 0,
             "no DB write may happen for any endpoint that resolves to a blocked address"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # bugfix-upcloud-s3-iam-sts-endpoints — AC1: iam_endpoint/sts_endpoint
  # resolved config keys. See the moduledoc's "bugfix-upcloud-s3-iam-sts-
  # endpoints (AC1)" note for the full rationale. The three tests below
  # (`iam-sts-AT1`, `iam-sts-AT2`, `iam-sts-AT3`) now pass (GREEN):
  # `Nebu.Media.StorageConfig.get/0` and `get_for_connection/0` return a map
  # with both fields added to `@defaults`, resolved from
  # `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` inside
  # `build_resolved/2`.
  # ════════════════════════════════════════════════════════════════════════

  describe "bugfix-upcloud-s3-iam-sts-endpoints: AC1 iam/sts endpoint keys" do
    test "iam-sts-AT1: get/0 and get_for_connection/0 default iam_endpoint/sts_endpoint to nil with no env vars" do
      # `setup` already wires the env-reader seam to `fn -> %{} end` (no env
      # vars set) and `store` to `nil` (no row) — identical premise to AT1,
      # asserted via dot-access on both read functions instead of AT1's full
      # map equality, so a failure here points directly at the missing keys
      # rather than at the whole-map diff.
      assert StorageConfig.get().iam_endpoint == nil
      assert StorageConfig.get().sts_endpoint == nil
      assert StorageConfig.get_for_connection().iam_endpoint == nil
      assert StorageConfig.get_for_connection().sts_endpoint == nil
    end

    test "iam-sts-AT2: get/0 and get_for_connection/0 resolve iam_endpoint/sts_endpoint from env vars verbatim, unmasked" do
      # Real UpCloud-shaped full URLs (scheme + port + path) — unlike
      # `endpoint`'s bare `host[:port]` contract, these must round-trip with
      # NO scheme-stripping and no `validate_candidate_endpoint/1`-style
      # rejection applied.
      iam_url = "https://7mf5k.upcloudobjects.com:4443/iam"
      sts_url = "https://7mf5k.upcloudobjects.com:4443/sts"

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_IAM_ENDPOINT" => iam_url,
          "NEBU_MINIO_STS_ENDPOINT" => sts_url
        }
      end)

      get_result = StorageConfig.get()
      conn_result = StorageConfig.get_for_connection()

      assert get_result.iam_endpoint == iam_url
      assert get_result.sts_endpoint == sts_url

      # Not secrets — get/0 must never mask these (contrast with
      # access_key/secret_key, AT2 above, where get/0's masked value differs
      # from get_for_connection/0's plaintext). Asserting BOTH functions
      # return the exact same verbatim string proves no masking was applied.
      assert conn_result.iam_endpoint == iam_url
      assert conn_result.sts_endpoint == sts_url
    end

    test "iam-sts-AT3: iam_endpoint and sts_endpoint resolve independently — each stays nil when only the other is set" do
      # Pre-dev test-review MINOR finding: iam-sts-AT2 sets both env vars
      # together, which can't distinguish a correct per-key maybe_put_env/2
      # implementation from an (incorrect) coupled one where setting either
      # var accidentally resolves both. Mirrors default_env_reader/0's own
      # per-key pattern (one maybe_put_env/2 call per var) by asserting each
      # var independently.
      iam_url = "https://7mf5k.upcloudobjects.com:4443/iam"
      sts_url = "https://7mf5k.upcloudobjects.com:4443/sts"

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_IAM_ENDPOINT" => iam_url}
      end)

      assert StorageConfig.get().iam_endpoint == iam_url
      assert StorageConfig.get().sts_endpoint == nil
      assert StorageConfig.get_for_connection().iam_endpoint == iam_url
      assert StorageConfig.get_for_connection().sts_endpoint == nil

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_STS_ENDPOINT" => sts_url}
      end)

      assert StorageConfig.get().iam_endpoint == nil
      assert StorageConfig.get().sts_endpoint == sts_url
      assert StorageConfig.get_for_connection().iam_endpoint == nil
      assert StorageConfig.get_for_connection().sts_endpoint == sts_url
    end

  end

  # ════════════════════════════════════════════════════════════════════════
  # bugfix-add-sts-iam-endpoints-to-admin-ui — AC1/AC2: DB-override columns
  # for iam_endpoint/sts_endpoint, added on top of the env-only resolution
  # the prior bugfix-upcloud-s3-iam-sts-endpoints story wired (the describe
  # block directly above, untouched). This adds the SAME DB > env > default
  # per-field precedence every other plain field in build_resolved/2 already
  # has (region, archive_bucket, ...), plus the companion masking regression
  # guard (AC2: these fields are not secrets, so mask_map/1 must never touch
  # them, DB-sourced or not).
  #
  # RED-phase note: today build_resolved/2 passes a literal `nil` (never
  # `row_get(row, "iam_endpoint"/"sts_endpoint")`) as the DB-value argument to
  # `pick/3` for both fields (see storage_config.ex ~line 730-731), and
  # column_for/2 has no clause for either atom key (falls through to the
  # `column_for(_unknown_key, _value), do: nil` catch-all, so upsert/1 builds
  # an EMPTY columns map for these keys — AT12's own `:ok` return value is
  # unaffected, since upsert/1 does not know build_columns/1 silently dropped
  # them). Every test below therefore fails on a plain, clean assertion
  # mismatch (the resolved value differs from what was just written/seeded),
  # never a crash — expected and correct for this RED phase.
  # ════════════════════════════════════════════════════════════════════════

  describe "bugfix-add-sts-iam-endpoints: DB-override columns" do
    test "AC1-RT: upsert/1 persists iam/sts to their own DB columns; get/0 reflects them (round trip)",
         %{calls: calls} do
      ensure_started()

      # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): upsert/1
      # now validates iam_endpoint/sts_endpoint via validate_iam_sts_fields/1
      # (https:// + Nebu.Media.SSRF.checked_target/1), so a literal public IP
      # is used here (no live DNS lookup needed — mirrors the M-2/M-3 tests'
      # own convention and AT6's own "93.184.216.34" endpoint fixture above)
      # instead of a hostname like "7mf5k.upcloudobjects.com" that does not
      # actually resolve.
      iam_url = "https://93.184.216.34:4443/iam"
      sts_url = "https://93.184.216.34:4443/sts"

      assert :ok = StorageConfig.upsert(%{iam_endpoint: iam_url, sts_endpoint: sts_url})

      last_columns = Agent.get(calls, & &1.last_write_columns)

      assert "iam_endpoint" in last_columns,
             "expected column_for/2 to map :iam_endpoint to its own \"iam_endpoint\" DB column, " <>
               "got written columns: #{inspect(last_columns)}"

      assert "sts_endpoint" in last_columns,
             "expected column_for/2 to map :sts_endpoint to its own \"sts_endpoint\" DB column, " <>
               "got written columns: #{inspect(last_columns)}"

      get_result = StorageConfig.get()
      conn_result = StorageConfig.get_for_connection()

      assert get_result.iam_endpoint == iam_url
      assert get_result.sts_endpoint == sts_url
      assert conn_result.iam_endpoint == iam_url
      assert conn_result.sts_endpoint == sts_url
    end

    test "AC1-DB2: get/0 prefers a DB-row iam/sts value over the env var, per field (mirrors AT8)",
         %{store: store} do
      # Seed the store directly (simulating a prior upsert/1 that only ever
      # touched iam_endpoint), exactly like AT8 does for `endpoint` — DB sets
      # iam_endpoint but leaves sts_endpoint NULL, so the per-field (not
      # all-or-nothing) precedence can be proven in one test.
      Agent.update(store, fn _ ->
        %{
          "iam_endpoint" => "https://db-iam.example.com:4443/iam",
          "set_at" => System.system_time(:millisecond)
        }
      end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_IAM_ENDPOINT" => "https://env-iam-should-lose.example.com/iam",
          "NEBU_MINIO_STS_ENDPOINT" => "https://env-sts-should-win.example.com/sts"
        }
      end)

      result = StorageConfig.get()
      conn_result = StorageConfig.get_for_connection()

      # DB wins for the field the DB row actually set.
      assert result.iam_endpoint == "https://db-iam.example.com:4443/iam"
      assert conn_result.iam_endpoint == "https://db-iam.example.com:4443/iam"

      # Env var still wins for the field the DB row left NULL.
      assert result.sts_endpoint == "https://env-sts-should-win.example.com/sts"
      assert conn_result.sts_endpoint == "https://env-sts-should-win.example.com/sts"
    end

    test "AC2-DB3: get/0 does not mask a DB-sourced iam/sts value (not secrets)",
         %{store: store} do
      iam_url = "https://db-iam.example.com:4443/iam"
      sts_url = "https://db-sts.example.com:4443/sts"

      Agent.update(store, fn _ ->
        %{
          "iam_endpoint" => iam_url,
          "sts_endpoint" => sts_url,
          "set_at" => System.system_time(:millisecond)
        }
      end)

      result = StorageConfig.get()

      assert result.iam_endpoint == iam_url,
             "a DB-sourced iam_endpoint must round-trip through get/0 completely unmasked, " <>
               "got: #{inspect(result.iam_endpoint)}"

      assert result.sts_endpoint == sts_url,
             "a DB-sourced sts_endpoint must round-trip through get/0 completely unmasked, " <>
               "got: #{inspect(result.sts_endpoint)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08) —
  # upsert/1's validate_iam_sts_fields/1 guard
  # ════════════════════════════════════════════════════════════════════════
  #
  # The two new DB-override columns above (iam_endpoint/sts_endpoint) were
  # admin-UI-writable and DB-persisted with NO scheme assertion and NO SSRF
  # guard — the only admin-writable, DB-persisted, URL-shaped fields on this
  # table without one, unlike `endpoint` (validate_endpoint_field/1,
  # M-3 fix above) and `webhook_url`. This guards the persist path
  # regardless of caller — these tests call upsert/1 directly, never through
  # Nebu.Admin.MediaSettingsController, proving the model-layer guard holds
  # even for a caller that skips the controller's own mirror of this check.

  describe "F-1: upsert/1 iam_endpoint/sts_endpoint scheme + SSRF guard" do
    test "rejects a non-https iam_endpoint/sts_endpoint and never persists it", %{calls: calls} do
      for field <- [:iam_endpoint, :sts_endpoint],
          bad_value <- ["93.184.216.34:4443/iam", "http://93.184.216.34:4443/iam"] do
        assert {:error, :invalid_iam_sts_endpoint} = StorageConfig.upsert(%{field => bad_value}),
               "expected #{field}=#{inspect(bad_value)} to be rejected as :invalid_iam_sts_endpoint"
      end

      assert Agent.get(calls, & &1.writer) == 0,
             "no DB write may happen for a non-https iam_endpoint/sts_endpoint"
    end

    # story admin-reauth-button-flow (Kassandra delta #2/#3): an https URL with user info (`https://user:password@host`) is never accepted and never logged,
    # also when the password holds `/`, `?` or `#` (URI.parse then reads the user name as the host and the rest as the path).
    test "rejects an iam_endpoint/sts_endpoint with user info (also with / ? # in the password), never persists or logs it", %{calls: calls} do
      urls = [
        "https://canary-user:canary-pass@93.184.216.34/iam",
        "https://canary-user:se/cret-canary@93.184.216.34/iam",
        "https://canary-user:se?cret-canary@93.184.216.34/iam",
        "https://canary-user:se#cret-canary@93.184.216.34/iam",
        "https://canary-user@93.184.216.34/iam"
      ]

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          for field <- [:iam_endpoint, :sts_endpoint], url <- urls do
            assert {:error, :invalid_iam_sts_endpoint} = StorageConfig.upsert(%{field => url}), "expected #{field}=#{inspect(url)} to be rejected"
          end
        end)

      assert Agent.get(calls, & &1.writer) == 0, "no DB write for a URL with user info"
      assert log =~ "IAM/STS endpoint", "the rejection is logged (value free)"
      refute log =~ "canary", "nothing of the URL (user name, password, host) is logged: #{log}"
    end

    test "rejects a private/loopback/link-local/metadata iam_endpoint/sts_endpoint and never persists it",
         %{calls: calls} do
      # Literal IPs — no live DNS lookup needed (mirrors the M-2/M-3 SSRF
      # tests above and webhook_delivery_test.exs's own convention).
      for field <- [:iam_endpoint, :sts_endpoint],
          blocked_url <- [
            "https://127.0.0.1:4443/iam",
            "https://10.0.0.5:4443/iam",
            "https://169.254.169.254/iam",
            "https://192.168.1.1:4443/iam"
          ] do
        assert {:error, :invalid_iam_sts_endpoint} = StorageConfig.upsert(%{field => blocked_url}),
               "expected #{field}=#{blocked_url} to be rejected as :invalid_iam_sts_endpoint"
      end

      assert Agent.get(calls, & &1.writer) == 0,
             "no DB write may happen for a blocked-address iam_endpoint/sts_endpoint"
    end

    test "accepts nil for both iam_endpoint and sts_endpoint (the explicit clear-override value)" do
      ensure_started()

      assert :ok = StorageConfig.upsert(%{iam_endpoint: nil, sts_endpoint: nil}),
             "nil must always be accepted unvalidated — it is the explicit " <>
               "clear-this-override value, not a candidate endpoint"
    end

    test "accepts a valid https, non-private iam_endpoint/sts_endpoint and persists it", %{
      calls: calls
    } do
      ensure_started()

      iam_url = "https://93.184.216.34:4443/iam"
      sts_url = "https://93.184.216.34:4443/sts"

      assert :ok = StorageConfig.upsert(%{iam_endpoint: iam_url, sts_endpoint: sts_url})

      last_columns = Agent.get(calls, & &1.last_write_columns)

      assert "iam_endpoint" in last_columns
      assert "sts_endpoint" in last_columns
    end
  end

  describe "NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS opt-in (UpCloud *-private endpoints, CGNAT)" do
    setup do
      previous = Application.get_env(:nebu_http, :media_storage_allow_private_endpoints)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:nebu_http, :media_storage_allow_private_endpoints)
          value -> Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, value)
        end
      end)

      :ok
    end

    test "default: a CGNAT iam_endpoint/endpoint is rejected" do
      Application.delete_env(:nebu_http, :media_storage_allow_private_endpoints)

      assert {:error, :invalid_iam_sts_endpoint} =
               StorageConfig.upsert(%{iam_endpoint: "https://100.126.127.4:4443/iam"})

      assert {:error, :invalid_endpoint} = StorageConfig.upsert(%{endpoint: "100.126.127.4:443"})
    end

    test "opt-in: CGNAT/RFC1918 iam_endpoint and endpoint are persisted", %{calls: calls} do
      ensure_started()
      Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, true)

      # a changed endpoint needs both keys in the same save (media-storage-uses-admin-config, fix B), encrypted for the write
      with_admin_secret_at_rest("storage-config-test-at-rest-key-cgnat", fn ->
        assert :ok =
                 StorageConfig.upsert(%{
                   endpoint: "100.126.127.4:443",
                   access_key: "AKIA-CGNAT-0001",
                   secret_key: "CGNAT-SECRET-0002",
                   iam_endpoint: "https://100.126.127.4:4443/iam",
                   sts_endpoint: "https://10.0.0.5:4443/sts"
                 })
      end)

      assert Agent.get(calls, & &1.writer) == 1
    end

    test "opt-in: loopback/link-local/metadata stay rejected", %{calls: calls} do
      Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, true)

      for endpoint <- ["127.0.0.1:9000", "169.254.169.254:80"] do
        assert {:error, :invalid_endpoint} = StorageConfig.upsert(%{endpoint: endpoint})
      end

      assert {:error, :invalid_iam_sts_endpoint} =
               StorageConfig.upsert(%{iam_endpoint: "https://169.254.169.254/iam"})

      assert Agent.get(calls, & &1.writer) == 0
    end

    test "describe_invalid_endpoint/1 names the real reason" do
      Application.delete_env(:nebu_http, :media_storage_allow_private_endpoints)

      assert StorageConfig.describe_invalid_endpoint("https://host:443") =~ "no http:// or https://"

      msg = StorageConfig.describe_invalid_endpoint("100.126.127.4:443")
      assert msg =~ "private"
      assert msg =~ "NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS"
      refute msg =~ "bare host"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Pins the AC8 masked-marker format this file assumes (see moduledoc):
  # 4 bullet characters followed by the last 4 chars of the plaintext. `nil`
  # (not this function) represents "genuinely unset".
  defp masked(plaintext) when is_binary(plaintext) do
    "••••" <> String.slice(plaintext, -4..-1)
  end

  defp ensure_started do
    case StorageConfig.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ensure_pg do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # Adapted from config_test.exs's own wait_for_restart/2 (itself adapted
  # from oidc_claim_cache_test.exs) — polls for a NEW pid under the same
  # registered name after AT13's kill, proving the surrounding OTP
  # supervisor (Nebu.Media.StorageConfig.Supervisor) actually restarted it.
  defp wait_for_restart(old_pid, attempts \\ 50)

  defp wait_for_restart(_old_pid, 0),
    do: flunk("Nebu.Media.StorageConfig did not restart after being killed")

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(Nebu.Media.StorageConfig) do
      nil ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)

      ^old_pid ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)

      pid ->
        pid
    end
  end

  # Real temp file for the Docker-secret-file precedence test (AT3) — the
  # `_FILE`-then-plain resolution is real behavior inside StorageConfig
  # (mirrors runtime.exs's File.read!/1), so a real file must exist on disk.
  defp write_secret_file!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "nebu_storage_config_test_#{System.unique_integer([:positive])}.secret"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Sets the :nebu_http, :admin_secret_at_rest app-env seam SecretBox itself
  # reads (server/lib/nebu/web/secret_box.ex), restoring whatever value (or
  # absence) was there before — mirrors the convention already established by
  # test/nebu/admin/*bootstrap*_test.exs and test/nebu/web/oidc_bootstrap_only_test.exs.
  # Runs `fun` with the seam set, then restores in an `on_exit` regardless of
  # test outcome (other test files in this suite may rely on it being unset).
  defp with_admin_secret_at_rest(secret, fun) do
    previous = Application.get_env(:nebu_http, :admin_secret_at_rest)
    Application.put_env(:nebu_http, :admin_secret_at_rest, secret)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:nebu_http, :admin_secret_at_rest)
        val -> Application.put_env(:nebu_http, :admin_secret_at_rest, val)
      end
    end)

    fun.()
  end

  # Forces SecretBox.at_rest_key/0's fail-closed path (AT12): clears the
  # :admin_secret_at_rest app-env seam AND the two real OS env vars it falls
  # back to, so the test is deterministic regardless of the ambient shell/CI
  # environment. Real OS env var mutation here mirrors the accepted
  # release_ssl_test.exs/release_test.exs convention for NEBU_* vars (save +
  # on_exit restore) — distinct from the app-env-fun seams used elsewhere in
  # this file, and acceptable here because SecretBox.at_rest_key/0 itself (not
  # this module) is what defines NEBU_INTERNAL_SECRET/_FILE as its real
  # fallback source; there is no app-env seam for THAT in the existing code.
  defp with_no_at_rest_secret(fun) do
    previous_app_env = Application.get_env(:nebu_http, :admin_secret_at_rest)
    previous_secret = System.get_env("NEBU_INTERNAL_SECRET")
    previous_secret_file = System.get_env("NEBU_INTERNAL_SECRET_FILE")

    Application.delete_env(:nebu_http, :admin_secret_at_rest)
    System.delete_env("NEBU_INTERNAL_SECRET")
    System.delete_env("NEBU_INTERNAL_SECRET_FILE")

    on_exit(fn ->
      case previous_app_env do
        nil -> :ok
        val -> Application.put_env(:nebu_http, :admin_secret_at_rest, val)
      end

      case previous_secret do
        nil -> System.delete_env("NEBU_INTERNAL_SECRET")
        val -> System.put_env("NEBU_INTERNAL_SECRET", val)
      end

      case previous_secret_file do
        nil -> System.delete_env("NEBU_INTERNAL_SECRET_FILE")
        val -> System.put_env("NEBU_INTERNAL_SECRET_FILE", val)
      end
    end)

    fun.()
  end

  # ─── story admin-forms-gate-sweep D4 (follow-up de, Kassandra design review): the stored credentials belong to the stored endpoint ───

  describe "admin-forms-gate-sweep D4: stored credentials only for the stored endpoint" do
    setup do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_ENDPOINT" => "93.184.216.34:9000",
          "NEBU_MINIO_BUCKET" => "stored-bucket",
          "NEBU_S3_REGION" => "us-east-1",
          "NEBU_MINIO_USE_SSL" => "true",
          "NEBU_MINIO_ACCESS_KEY" => "STORED-ACCESS-KEY",
          "NEBU_MINIO_SECRET_KEY" => "stored-secret-key"
        }
      end)

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
        send(test_pid, {:test_connection_called, candidate})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:nebu_http, :media_storage_test_connection_fun) end)
      :ok
    end

    defp candidate(overrides \\ %{}) do
      Map.merge(%{endpoint: "93.184.216.34:9000", bucket: "stored-bucket", region: "us-east-1", use_ssl: true, access_key: nil, secret_key: nil}, overrides)
    end

    test "blank keys + the stored endpoint and scheme: the stored credentials are used (unchanged behaviour)" do
      assert :ok = StorageConfig.test_connection(candidate())
      assert_received {:test_connection_called, c}
      assert c.access_key == "STORED-ACCESS-KEY" and c.secret_key == "stored-secret-key"
    end

    test "the STORED endpoint is compared trimmed (blanks around the stored value do not break the match)" do
      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_ENDPOINT" => "  93.184.216.34:9000 ", "NEBU_MINIO_USE_SSL" => "true", "NEBU_MINIO_ACCESS_KEY" => "STORED-ACCESS-KEY", "NEBU_MINIO_SECRET_KEY" => "stored-secret-key"}
      end)

      assert :ok = StorageConfig.test_connection(candidate())
      assert_received {:test_connection_called, %{access_key: "STORED-ACCESS-KEY"}}
    end

    test "blank keys + ANOTHER endpoint: :secret_required, the test function is never called" do
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(%{endpoint: "93.184.216.35:9000"}))
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(%{endpoint: "93.184.216.34:9001"}))
      refute_received {:test_connection_called, _}
    end

    test "blank keys + the same endpoint but the scheme flipped (use_ssl): refused too" do
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(%{use_ssl: false}))
      refute_received {:test_connection_called, _}
    end

    test "ONE blank key counts as blank: a typed key for another endpoint never picks up the stored other one" do
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(%{endpoint: "93.184.216.35:9000", access_key: "typed-access"}))
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(%{endpoint: "93.184.216.35:9000", secret_key: "typed-secret"}))
      refute_received {:test_connection_called, _}
    end

    test "typed access AND secret key work for another endpoint and never mix with the stored ones" do
      assert :ok = StorageConfig.test_connection(candidate(%{endpoint: "93.184.216.35:9000", access_key: "typed-access", secret_key: "typed-secret"}))
      assert_received {:test_connection_called, c}
      assert c.access_key == "typed-access" and c.secret_key == "typed-secret"
    end

    test "the IAM / STS endpoints are not part of the comparison (the test never contacts them)" do
      assert :ok = StorageConfig.test_connection(candidate(%{iam_endpoint: "https://iam.other.example", sts_endpoint: "https://sts.other.example"}))
      assert_received {:test_connection_called, %{access_key: "STORED-ACCESS-KEY"}}
    end
  end
end
