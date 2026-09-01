defmodule Nebu.Media.ConfigTest do
  @moduledoc """
  RED-phase ATDD tests for story `9a-media-config-table-module` (epic
  `media-security-admin-control`).

  ## What is under test

  A brand-new module `Nebu.Media.Config` (does not exist yet — every test in
  this file fails with `UndefinedFunctionError` until the dev agent implements
  `server/lib/nebu/media/config.ex`) is the SOLE public-API module (ADR-020)
  for the `media_config` table created by migration
  `000023_media_config.up.sql` (see "Migration number" note below).

    * AC1 — migration creates `media_config` (RLS + 3 policies, mirroring
      `server_config`'s shape). Verified directly against the dev DB as part
      of this ATDD step (not re-asserted here as an ExUnit test — see the
      pipeline report); this file covers AC2-AC6 only.
    * AC2 — `get/0`'s full 10-key catalog with config.exs-matching defaults.
    * AC3 — `get/0` / `upsert/2` public API shape.
    * AC4 — per-key write validation, reject-before-any-DB-call posture.
    * AC5 — ETS/`:pg`-backed cache invalidation + 60s TTL fallback.
    * AC6 — `media_config_updated` audit trail.

  ## Migration number

  Story 4a/4b had not claimed `000023` on disk at ATDD time (no
  `000023_*.up.sql` file existed anywhere in `priv/migrations/` when this file
  was written) — this story's migration therefore claims `000023`
  (`priv/migrations/000023_media_config.up.sql` /
  `.down.sql`), one earlier than the story's own "TBD, likely 000024" text
  anticipated. Applied and round-tripped (up → down → up) against the dev
  Postgres via `Nebu.Release.migrate/0` (docker compose) as part of this ATDD
  step; the schema/RLS/policies were confirmed correct via `\\d media_config`
  and a `pg_policy` query. Per the epic's "whichever lands first keeps its
  number" convention, this may be renumbered at merge time if another
  migration lands first.

  ## Why this suite avoids a live Postgres/`Nebu.Repo` entirely

  `mix test` (this project's `make test-unit-elixir`) does NOT set
  `NEBU_DB_URL` and `test/test_helper.exs` excludes `:integration`-tagged
  tests — `Nebu.Repo` is never started under plain `mix test`. Any test setup
  that touched real Postgres before the RED assertion would fail with a
  Repo-not-started error instead of the required `UndefinedFunctionError` —
  the WRONG reason. Every test below therefore drives `Nebu.Media.Config`
  entirely through injectable seams (no live DB anywhere), exactly like
  `session_expiry_worker_test.exs` (`FakeRepoW`) and `audit_writer_test.exs`
  (`FakeRepo`) already do for other modules that read/write Postgres
  directly. The migration itself was separately verified against the real dev
  DB (see above) — that is the ONLY place this ATDD step touches Postgres.

  ## Seam contract this file imposes on the dev-story implementation

  The story's own skeleton (Technical Requirements) fixes `get/0`'s and
  `upsert/2`'s OBSERVABLE behavior but leaves the DB read/write seam
  unspecified. Mirroring `Nebu.Web.OidcConfig`'s `:oidc_config_source` seam
  (explicitly cited by the story) and `Nebu.Matrix.OidcClaimCache`'s
  `:oidc_claim_reader` fun-seam idiom, this suite requires:

    * `Application.get_env(:nebu_http, :media_config_source)` — 0-arity fun.
      When set, `get/0` calls it directly and merges the returned STRING-keyed
      override map (only overridden keys) over the config.exs defaults —
      bypassing ETS/GenServer/DB entirely. Test-only fast path (tests 1, 3-7,
      9) for asserting default-catalog/validation behavior without a running
      cache process.
    * `Application.get_env(:nebu_http, :media_config_loader)` — 0-arity fun
      returning a STRING-keyed map of ALL currently persisted `media_config`
      overrides (typed Elixir terms, not raw TEXT — see note below). Consulted
      by the GenServer's DB-refresh step (populates ETS) AND by `upsert/2`'s
      old-value lookup. Defaults to a real `SELECT key, value FROM
      media_config` when unset (dev-story's job, not exercised here).
    * `Application.get_env(:nebu_http, :media_config_writer)` — arity-3 fun
      `fn key, value, set_at -> :ok | {:error, term()} end`, the actual
      persisted write (`INSERT ... ON CONFLICT (key) DO UPDATE`). Defaults to
      real SQL when unset.
    * `Nebu.Media.Config.pg_group/0` — exposed for tests/diagnostics, mirroring
      `Nebu.Web.OidcConfig.pg_group/0` / `Nebu.Matrix.OidcClaimCache.pg_group/0`.
    * `Nebu.Media.Config.refresh/0` — forces a synchronous DB re-read + `:pg`
      broadcast, mirroring `Nebu.Web.OidcConfig.refresh/1`.
    * The periodic TTL fallback (AC5, 60s) is driven by an internal
      `Process.send_after(self(), :ttl_tick, 60_000)` self-message loop. Tests
      drive it deterministically by sending `:ttl_tick` directly to the
      registered pid instead of sleeping 60s — the exact technique
      `session_expiry_worker_test.exs` already uses for its own periodic
      `:tick` message.
    * The `:pg` cluster-invalidation broadcast payload is `{:invalidate_media_config}`
      — a 1-tuple, mirroring `{:invalidate_oidc_config}` /
      `{:invalidate_oidc_claim_cache}` (the two existing `:pg`-broadcast
      payloads in this codebase; both are 1-tuples, not bare atoms).

  This suite deliberately does NOT require the loader/writer seams to
  round-trip through `media_config.value`'s raw TEXT-column string encoding
  (e.g. how `released_delete_after_days: nil` is represented as a NOT NULL TEXT
  value). That encoding is a real-SQL implementation detail the dev-story must
  solve against the actual migration (verified separately, see above); this
  suite's fakes operate on already-typed Elixir terms so it can fully exercise
  `Nebu.Media.Config`'s OWN validation/cache/audit logic without a live DB.

  ## AC10/AC11 cluster-invalidation test design note

  No dedicated `Nebu.Web.OidcConfig` test file exists in this codebase (the
  closest sibling covering an ETS/`persistent_term` +
  `:pg`-broadcast-invalidation cache is `Nebu.Matrix.OidcClaimCache`, tested by
  `oidc_claim_cache_test.exs`'s "AC4: an invalidation is broadcast to the `:pg`
  group and refreshes locally" test). That test's technique — the TEST PROCESS
  itself joins the cache's `:pg` group as a stand-in peer node and asserts it
  receives the broadcast — is the established convention this codebase already
  uses for exactly this class of problem, and is what tests 10/11 below reuse.
  A literal second, fully independent `Nebu.Media.Config` GenServer instance on
  the SAME node cannot be constructed for this test: AC5 mandates a
  `:protected` ETS table (write access restricted to the owning process), so a
  second same-node instance sharing the one hardcoded `@table` name would
  crash on its own cache refresh (not table-owner). Genuinely independent
  per-node caches only exist across REAL separate BEAM nodes in production;
  simulating that in-process would require spinning up a second distributed
  node (`:peer`) purely for this test, which this suite avoids for the same
  CI-reliability reasons the codebase's own precedent (`OidcClaimCache`) already
  avoided it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Media.Config

  @nonneg_int_keys ~w(
    max_upload_size_bytes
    max_file_size_bytes
    max_pending_per_user
    max_stall_ms
    deleted_days
    infected_days
    orphaned_hours
  )

  # media-security-admin-control/10c-media-alerts-triggers (dev-story,
  # required by the story's own guardrails/reconciliation notes): 9a's
  # @defaults gained four new alert-threshold keys, so get/0's full catalog
  # now always includes them too — this fixture is updated to match, keeping
  # the assertion's strength (full equality) unchanged.
  @default_catalog %{
    max_upload_size_bytes: 52_428_800,
    max_file_size_bytes: 104_857_600,
    max_pending_per_user: 20,
    max_stall_ms: 20_000,
    deleted_days: 30,
    infected_days: 90,
    orphaned_hours: 24,
    webhook_url: nil,
    released_delete_after_days: nil,
    mime_denylist: "",
    clamav_down_alert_minutes: 5,
    signature_stale_alert_hours: 48,
    backlog_depth_alert_threshold: 500,
    scan_failed_rate_alert_pct: 10,
    # media-security-admin-control/10d-scan-kill-switch (AC1): the fifteenth
    # catalog key — default MUST be "fail_closed" (see Dev Agent Guardrails,
    # Story 10d Summary). Adding this to the shared fixture intentionally
    # turns every `Config.get() == @default_catalog` equality assertion in
    # this file RED until the dev-story implementation adds this key to
    # `@defaults`, exactly like 10c's own alert-threshold keys did before it.
    scan_kill_switch: "fail_closed"
  }

  # ─── FakeAuditRepo ────────────────────────────────────────────────────────
  #
  # Reused shape from audit_writer_test.exs / session_expiry_worker_test.exs —
  # replaces Nebu.Repo for Nebu.Compliance.AuditWriter.log/6 via the SAME
  # `:compliance, :repo` seam those suites already use, so AC6's audit trail
  # can be asserted without touching PostgreSQL.

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter. Test-private."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      bucket = Application.get_env(:compliance, :__test_media_config_audit_bucket__)
      if bucket, do: Agent.update(bucket, fn rows -> [struct | rows] end)
      {:ok, struct}
    end

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  # ─── FailingFakeAuditRepo ─────────────────────────────────────────────────
  #
  # Code review (Cycle 1, m3): simulates AuditWriter.log/6 degrading to
  # {:error, :audit_write_failed} — its own documented "never raises, Repo
  # down" path — mirroring audit_writer_test.exs's own FailingFakeRepo
  # convention (transaction/1 catches insert!'s raise and converts it to an
  # {:error, _} tuple, exactly like a real Ecto.Repo.transaction/1 would for
  # an unstarted/missing Repo). Used only by the m3 regression test below to
  # assert Nebu.Media.Config.upsert/2 surfaces the failure via Logger.error
  # without rolling back the already-successful config write.

  defmodule FailingFakeAuditRepo do
    @moduledoc "In-process fake simulating a down audit Repo. Test-private."

    def transaction(fun) when is_function(fun, 0) do
      try do
        fun.()
        {:ok, nil}
      rescue
        _ -> {:error, :simulated_audit_failure}
      end
    end

    def insert(_struct, _opts \\ []), do: {:error, :simulated_audit_failure}

    def insert!(_struct, _opts \\ []) do
      raise "FailingFakeAuditRepo: simulated audit write failure"
    end
  end

  # ─── Setup / Teardown ─────────────────────────────────────────────────────

  setup do
    {:ok, audit_bucket} = Agent.start_link(fn -> [] end)
    Application.put_env(:compliance, :__test_media_config_audit_bucket__, audit_bucket)
    Application.put_env(:compliance, :repo, FakeAuditRepo)

    # `store` stands in for the media_config table row set: %{key => {value, set_at}}.
    {:ok, store} = Agent.start_link(fn -> %{} end)
    {:ok, calls} = Agent.start_link(fn -> %{loader: 0, writer: 0} end)

    loader = fn ->
      Agent.update(calls, &Map.update!(&1, :loader, fn n -> n + 1 end))
      Agent.get(store, fn rows -> Map.new(rows, fn {k, {v, _set_at}} -> {k, v} end) end)
    end

    writer = fn key, value, set_at ->
      Agent.update(calls, &Map.update!(&1, :writer, fn n -> n + 1 end))
      Agent.update(store, &Map.put(&1, key, {value, set_at}))
      :ok
    end

    Application.put_env(:nebu_http, :media_config_loader, loader)
    Application.put_env(:nebu_http, :media_config_writer, writer)

    on_exit(fn ->
      Application.delete_env(:compliance, :__test_media_config_audit_bucket__)
      Application.delete_env(:compliance, :repo)
      Application.delete_env(:nebu_http, :media_config_source)
      Application.delete_env(:nebu_http, :media_config_loader)
      Application.delete_env(:nebu_http, :media_config_writer)

      if pid = Process.whereis(Nebu.Media.Config) do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    {:ok, audit_bucket: audit_bucket, store: store, calls: calls}
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC2 — full key catalog with config.exs-matching defaults
  # ════════════════════════════════════════════════════════════════════════

  test "get/0 on a fresh media_config table (no rows) returns every catalog key with its config.exs default" do
    # No GenServer/DB involved at all — the :media_config_source seam bypasses
    # ETS/DB entirely and returns an empty override map, exactly like a fresh
    # media_config table with zero rows.
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    assert Config.get() == @default_catalog
  end

  # ════════════════════════════════════════════════════════════════════════
  # Code review (Cycle 0, M1 — MAJOR): build_catalog/1 crashed with KeyError
  # on any media_config row whose key falls outside this story's 10-key
  # catalog (e.g. a future Story 10c/10d key written by a newer node sharing
  # this table/loader in a rolling deploy, or a stray/manual row).
  # ════════════════════════════════════════════════════════════════════════

  test "get/0 ignores an unrecognized key returned by the loader instead of crashing (init/refresh/invalidate/ttl_tick all survive it)",
       %{store: store} do
    # Seed an unrecognized key BEFORE the GenServer starts, so init/1's own
    # do_refresh/0 call is exercised first, not merely a later :refresh.
    Agent.update(
      store,
      &Map.put(&1, "some_future_10c_key", {"1", System.system_time(:millisecond)})
    )

    ensure_started()
    assert Config.get() == @default_catalog

    # handle_call(:refresh, ...) path.
    assert :ok = Config.refresh()
    assert Config.get() == @default_catalog

    # handle_info({:invalidate_media_config}, ...) path (a peer's broadcast).
    pid = Process.whereis(Nebu.Media.Config)
    send(pid, {:invalidate_media_config})
    :sys.get_state(pid)
    assert Config.get() == @default_catalog

    # handle_info(:ttl_tick, ...) path (AC5's TTL fallback).
    send(pid, :ttl_tick)
    :sys.get_state(pid)
    assert Config.get() == @default_catalog
  end

  # ════════════════════════════════════════════════════════════════════════
  # F1 (pre-dev test-review gap) — AC1: media_config_update_mutable RLS
  # policy genuinely allows an UPDATE of the 10 catalog keys, not merely the
  # unconditionally-allowed first INSERT. Mirrors log_store_test.exs's own
  # AC3 precedent ("upsert_server_config accepts all 5 new keys, and a
  # SECOND upsert (an UPDATE) actually changes the stored value") — same
  # `@tag :integration` + `if Process.whereis(Nebu.Repo) do` guard, same
  # double-upsert-then-verify-via-direct-SQL shape, adapted to
  # `media_config`/`Nebu.Media.Config`.
  #
  # This test deliberately does NOT use the FakeAuditRepo/loader/writer
  # seams the file's `setup do` block injects for every other test in this
  # file — the whole point is to exercise Nebu.Media.Config's REAL,
  # un-injected DB read/write path against the real migration/RLS policy, so
  # the seams are cleared for this test's duration only.
  # ════════════════════════════════════════════════════════════════════════

  describe "AC1: media_config_update_mutable RLS policy" do
    @tag :integration
    test "upsert/2 accepts representative catalog keys, and a SECOND upsert (an UPDATE) actually changes the stored value" do
      if Process.whereis(Nebu.Repo) do
        # Bypass the fakes this file's `setup do` block just installed for
        # THIS test only — each ExUnit test gets its own setup/on_exit
        # invocation, so the next test's `setup do` re-installs fresh fakes
        # regardless of what we clear here.
        Application.delete_env(:nebu_http, :media_config_source)
        Application.delete_env(:nebu_http, :media_config_loader)
        Application.delete_env(:nebu_http, :media_config_writer)
        Application.delete_env(:compliance, :repo)

        keys_and_values = [
          {"max_upload_size_bytes", 10_000_000, 20_000_000},
          {"webhook_url", "https://93.184.216.34/hook-one", "https://93.184.216.34/hook-two"},
          {"mime_denylist", "application/x-msdownload",
           "application/x-msdownload,application/x-sh"}
        ]

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            for {key, _first, _second} <- keys_and_values do
              Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_config WHERE key = $1", [
                key
              ])
            end
          end
        end)

        for {key, first_value, second_value} <- keys_and_values do
          assert :ok = Nebu.Media.Config.upsert(key, first_value)

          {:ok, %{rows: [[stored_first]]}} =
            Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT value FROM media_config WHERE key = $1", [
              key
            ])

          assert stored_first == to_string(first_value)

          # THE REAL AC1 GOTCHA (mirrors log_store_test.exs's AC3 precedent
          # verbatim): a brand-new key's FIRST upsert always succeeds
          # unconditionally — it is an INSERT, allowed by
          # media_config_insert_only regardless of the
          # media_config_update_mutable allowlist. Only a SECOND upsert (now
          # an UPDATE via ON CONFLICT DO UPDATE) actually exercises the RLS
          # gate AC1 requires — if this key were missing from the
          # migration's media_config_update_mutable allowlist, this UPDATE
          # would silently affect 0 rows and the first value would survive.
          assert :ok = Nebu.Media.Config.upsert(key, second_value)

          {:ok, %{rows: [[stored_second]]}} =
            Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT value FROM media_config WHERE key = $1", [
              key
            ])

          assert stored_second == to_string(second_value),
                 "expected #{key}'s second upsert (an UPDATE) to change the stored value — " <>
                   "if #{key} is missing from media_config's media_config_update_mutable RLS " <>
                   "policy allowlist, this UPDATE silently affects 0 rows and the first value " <>
                   "survives"
        end
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # F2 (story 10c pre-dev test-review MAJOR-1 gap, same class as F1 above) —
  # story 10c's migration (000033_media_alerts) extends
  # media_config_update_mutable's allowlist with FOUR new keys
  # (clamav_down_alert_minutes, signature_stale_alert_hours,
  # backlog_depth_alert_threshold, scan_failed_rate_alert_pct). Every worker
  # test for 10c drives these keys exclusively via the
  # :media_config_source test-only fast path, which bypasses this RLS
  # allowlist entirely — a typo'd or omitted key in 000033's `ALTER POLICY
  # media_config_update_mutable ... USING (key IN (...))` list would go
  # completely uncaught otherwise, identical to the gap F1 above closes for
  # 9a's original 10 keys. Same double-upsert-then-verify-via-direct-SQL
  # shape, same `@tag :integration` + `if Process.whereis(Nebu.Repo) do`
  # guard, same "second upsert is an UPDATE, which is what the RLS policy
  # actually gates" reasoning.
  #
  # RED-phase note: this test fails until BOTH story 10c's migration
  # 000033 extends the allowlist with these four keys AND
  # Nebu.Media.Config's own @defaults/@key_to_atom/validation are extended
  # to recognize them (per the reconciliation notes — the RLS-policy change
  # alone is not sufficient, build_catalog/1's Map.take silently drops any
  # key not also in @defaults).
  # ════════════════════════════════════════════════════════════════════════

  describe "AC2 (story 10c): media_config_update_mutable RLS policy covers the four new alert-threshold keys" do
    @tag :integration
    test "upsert/2 accepts the four 10c alert-threshold keys, and a SECOND upsert (an UPDATE) actually changes the stored value" do
      if Process.whereis(Nebu.Repo) do
        Application.delete_env(:nebu_http, :media_config_source)
        Application.delete_env(:nebu_http, :media_config_loader)
        Application.delete_env(:nebu_http, :media_config_writer)
        Application.delete_env(:compliance, :repo)

        keys_and_values = [
          {"clamav_down_alert_minutes", 5, 10},
          {"signature_stale_alert_hours", 48, 72},
          {"backlog_depth_alert_threshold", 500, 750},
          {"scan_failed_rate_alert_pct", 10, 15}
        ]

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            for {key, _first, _second} <- keys_and_values do
              Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_config WHERE key = $1", [
                key
              ])
            end
          end
        end)

        for {key, first_value, second_value} <- keys_and_values do
          assert :ok = Nebu.Media.Config.upsert(key, first_value)

          {:ok, %{rows: [[stored_first]]}} =
            Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT value FROM media_config WHERE key = $1", [
              key
            ])

          assert stored_first == to_string(first_value)

          # THE REAL AC2 GOTCHA (mirrors F1's precedent verbatim): a
          # brand-new key's FIRST upsert always succeeds unconditionally —
          # it is an INSERT, allowed by media_config_insert_only regardless
          # of the media_config_update_mutable allowlist. Only a SECOND
          # upsert (an UPDATE via ON CONFLICT DO UPDATE) actually exercises
          # the RLS gate story 10c's migration must extend — if this key
          # were missing from (or typo'd in) 000033's
          # media_config_update_mutable allowlist, this UPDATE would
          # silently affect 0 rows and the first value would survive.
          assert :ok = Nebu.Media.Config.upsert(key, second_value)

          {:ok, %{rows: [[stored_second]]}} =
            Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT value FROM media_config WHERE key = $1", [
              key
            ])

          assert stored_second == to_string(second_value),
                 "expected #{key}'s second upsert (an UPDATE) to change the stored value — " <>
                   "if #{key} is missing from (or typo'd in) media_config's " <>
                   "media_config_update_mutable RLS policy allowlist (story 10c's own " <>
                   "migration extension), this UPDATE silently affects 0 rows and the first " <>
                   "value survives"
        end
      end
    end
  end

  describe "AC2 (story 10d): media_config_update_mutable RLS policy covers scan_kill_switch" do
    @tag :integration
    test "upsert/2 accepts scan_kill_switch, and a SECOND upsert (an UPDATE) actually changes the stored value" do
      if Process.whereis(Nebu.Repo) do
        Application.delete_env(:nebu_http, :media_config_source)
        Application.delete_env(:nebu_http, :media_config_loader)
        Application.delete_env(:nebu_http, :media_config_writer)
        Application.delete_env(:compliance, :repo)

        key = "scan_kill_switch"

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_config WHERE key = $1", [key])
          end
        end)

        assert :ok = Nebu.Media.Config.upsert(key, "fail_open")

        {:ok, %{rows: [[stored_first]]}} =
          Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT value FROM media_config WHERE key = $1", [
            key
          ])

        assert stored_first == "fail_open"

        # THE REAL AC2 GOTCHA (mirrors 10c's F1 precedent verbatim): a
        # brand-new key's FIRST upsert always succeeds unconditionally — it
        # is an INSERT, allowed by media_config_insert_only regardless of
        # the media_config_update_mutable allowlist. Only a SECOND upsert
        # (an UPDATE via ON CONFLICT DO UPDATE) actually exercises the RLS
        # gate this story's own migration must extend — if scan_kill_switch
        # were missing from (or typo'd in) that migration's
        # media_config_update_mutable allowlist, this UPDATE would silently
        # affect 0 rows and the first value would survive.
        assert :ok = Nebu.Media.Config.upsert(key, "fail_closed")

        {:ok, %{rows: [[stored_second]]}} =
          Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT value FROM media_config WHERE key = $1", [
            key
          ])

        assert stored_second == "fail_closed",
               "expected scan_kill_switch's second upsert (an UPDATE) to change the stored " <>
                 "value — if scan_kill_switch is missing from (or typo'd in) media_config's " <>
                 "media_config_update_mutable RLS policy allowlist (story 10d's own migration " <>
                 "extension), this UPDATE silently affects 0 rows and the first value survives"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC3/AC5 — upsert/2 persists; get/0 reflects it via the real cache path
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/1 persists a valid value and get/0 reflects it on the next read", %{store: store} do
    ensure_started()
    :ok = Config.refresh()

    assert :ok = Config.upsert("max_upload_size_bytes", 999_999)

    assert {999_999, set_at} = Agent.get(store, &Map.get(&1, "max_upload_size_bytes"))
    assert is_integer(set_at)
    assert Config.get().max_upload_size_bytes == 999_999

    # https URL to a public host — a literal IP so no real DNS lookup is
    # needed (mirrors url_preview_test.exs's use of a literal public IP for
    # its "not blocked" SSRF case).
    assert :ok = Config.upsert("webhook_url", "https://93.184.216.34/hook")

    assert {"https://93.184.216.34/hook", _} = Agent.get(store, &Map.get(&1, "webhook_url"))
    assert Config.get().webhook_url == "https://93.184.216.34/hook"
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC4 — per-key write validation
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/1 rejects a negative integer value for every non-negative-integer key without writing a row", %{
    store: store,
    calls: calls
  } do
    for key <- @nonneg_int_keys do
      assert {:error, _reason} = Config.upsert(key, -1),
             "expected upsert(#{inspect(key)}, -1) to be rejected"

      refute Map.has_key?(Agent.get(store, & &1), key),
             "no row must be written for rejected key #{inspect(key)}"
    end

    assert Agent.get(calls, & &1) == %{loader: 0, writer: 0},
           "no DB call (loader or writer) may happen for a rejected value"
  end

  test "upsert/1 rejects nil for every non-negative-integer key except released_delete_after_days" do
    for key <- @nonneg_int_keys do
      assert {:error, _reason} = Config.upsert(key, nil),
             "expected upsert(#{inspect(key)}, nil) to be rejected — nil is only valid for released_delete_after_days"
    end

    # released_delete_after_days: nil is the explicit "disabled" value and MUST
    # succeed — this is a real write, so the cache/audit machinery must be up.
    ensure_started()
    :ok = Config.refresh()

    assert :ok = Config.upsert("released_delete_after_days", nil)
    assert Config.get().released_delete_after_days == nil
  end

  test "upsert/1 rejects a non-https webhook_url" do
    assert {:error, _reason} = Config.upsert("webhook_url", "http://example.com/hook")
  end

  test "upsert/1 rejects a webhook_url pointing at a private/link-local address" do
    # Same blocked-address fixtures as url_preview_test.exs's SSRF coverage
    # (169.254.169.254 = cloud metadata; 127.0.0.1 = loopback), reused via the
    # shared Nebu.Media.SSRF check.
    for url <- ["https://127.0.0.1/hook", "https://169.254.169.254/hook"] do
      assert {:error, _reason} = Config.upsert("webhook_url", url),
             "expected #{url} to be rejected by Nebu.Media.SSRF.check/1"
    end
  end

  test "upsert/1 rejects an unknown config key", %{calls: calls} do
    assert {:error, :unknown_config_key} = Config.upsert("not_a_real_key", "1")

    assert Agent.get(calls, & &1) == %{loader: 0, writer: 0},
           "no DB call (loader or writer) may happen for an unknown key"
  end

  # ════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10d-scan-kill-switch (AC1, AC4, Acceptance
  # Tests 7-8): scan_kill_switch validation + default.
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/1 rejects an invalid scan_kill_switch value", %{calls: calls} do
    assert {:error, _reason} = Config.upsert("scan_kill_switch", "sometimes")

    assert Agent.get(calls, & &1) == %{loader: 0, writer: 0},
           "no DB call (loader or writer) may happen for an invalid scan_kill_switch value"
  end

  test "upsert/1 accepts both fail_open and fail_closed for scan_kill_switch" do
    ensure_started()
    :ok = Config.refresh()

    assert :ok = Config.upsert("scan_kill_switch", "fail_open")
    :ok = Config.refresh()
    assert Config.get().scan_kill_switch == "fail_open"

    assert :ok = Config.upsert("scan_kill_switch", "fail_closed")
    :ok = Config.refresh()
    assert Config.get().scan_kill_switch == "fail_closed"
  end

  test "a fresh media_config table with no scan_kill_switch row defaults to fail_closed" do
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    assert Config.get().scan_kill_switch == "fail_closed"
  end

  # ════════════════════════════════════════════════════════════════════════
  # F4 (pre-dev test-review gap) — AC4: mime_denylist MUST be a
  # comma-separated string of syntactically plausible MIME-type-prefix
  # tokens (non-empty, no embedded whitespace per token); "" is valid
  # (denylist disabled).
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/1 accepts a valid single-token mime_denylist and get/0 reflects it" do
    ensure_started()
    :ok = Config.refresh()

    assert :ok = Config.upsert("mime_denylist", "application/x-msdownload")
    assert Config.get().mime_denylist == "application/x-msdownload"
  end

  test "upsert/1 accepts a valid multi-token comma-separated mime_denylist" do
    ensure_started()
    :ok = Config.refresh()

    assert :ok = Config.upsert("mime_denylist", "application/x-msdownload,application/x-sh")
    assert Config.get().mime_denylist == "application/x-msdownload,application/x-sh"
  end

  test "upsert/1 accepts the empty string as an explicit mime_denylist write (denylist disabled)" do
    ensure_started()
    :ok = Config.refresh()

    # Pre-seed a non-empty value first so the "" assertion below cannot pass
    # merely because "" happens to already be the unwritten-row default
    # (AC2) — it must be accepted as a genuine, explicit write.
    assert :ok = Config.upsert("mime_denylist", "application/x-msdownload")
    assert Config.get().mime_denylist == "application/x-msdownload"

    assert :ok = Config.upsert("mime_denylist", "")
    assert Config.get().mime_denylist == ""
  end

  test "upsert/1 rejects a mime_denylist token with embedded whitespace without writing a row", %{
    store: store
  } do
    for denylist <- [
          # space after the comma
          "application/x-msdownload, application/x-sh",
          # space inside a single token
          "application/ x-sh"
        ] do
      assert {:error, _reason} = Config.upsert("mime_denylist", denylist),
             "expected #{inspect(denylist)} to be rejected — embedded whitespace per token is invalid"

      refute Map.has_key?(Agent.get(store, & &1), "mime_denylist"),
             "no row must be written for rejected mime_denylist #{inspect(denylist)}"
    end
  end

  test "upsert/1 rejects a malformed/implausible mime_denylist token without writing a row", %{
    store: store
  } do
    for denylist <- [
          # no "/" at all — not a plausible MIME-type-prefix token
          "notamimetype",
          # trailing double comma yields an empty token
          "application/x-sh,,"
        ] do
      assert {:error, _reason} = Config.upsert("mime_denylist", denylist),
             "expected #{inspect(denylist)} to be rejected — not a plausible MIME-type-prefix token list"

      refute Map.has_key?(Agent.get(store, & &1), "mime_denylist"),
             "no row must be written for rejected mime_denylist #{inspect(denylist)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC6 — audit trail
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/1 writes a media_config_updated audit-log entry with old_value and new_value on success", %{
    audit_bucket: audit_bucket,
    store: store
  } do
    ensure_started()

    # Pre-seed an existing override so old_value is unambiguous (rather than
    # the "no prior row" case, whose old_value semantics AC6 does not pin down).
    now = System.system_time(:millisecond)
    Agent.update(store, &Map.put(&1, "max_pending_per_user", {15, now}))
    :ok = Config.refresh()
    assert Config.get().max_pending_per_user == 15

    assert :ok = Config.upsert("max_pending_per_user", 42)

    rows = Agent.get(audit_bucket, & &1)
    assert length(rows) == 1, "expected exactly one audit row, got #{length(rows)}"

    [row] = rows
    assert row.action == "media_config_updated"
    assert row.outcome == "success"

    assert row.metadata == %{key: "max_pending_per_user", old_value: 15, new_value: 42}
  end

  test "upsert/1 with an invalid value writes no audit-log entry", %{audit_bucket: audit_bucket} do
    assert {:error, _reason} = Config.upsert("max_pending_per_user", -5)
    assert Agent.get(audit_bucket, & &1) == []
  end

  # ════════════════════════════════════════════════════════════════════════
  # Code review (Cycle 0, m3 — MINOR): upsert/2 discarded AuditWriter.log/6's
  # return value and always returned :ok even when the audit write itself
  # degraded to {:error, :audit_write_failed} (Repo down). The config write
  # is NOT rolled back in that case (see the story's Dev Agent Record m2
  # note) — the failure must be surfaced via Logger.error instead.
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/1 logs the audit-write failure but still returns :ok, and the config value is still written",
       %{store: store} do
    Application.put_env(:compliance, :repo, FailingFakeAuditRepo)

    log =
      capture_log(fn ->
        assert :ok = Config.upsert("max_pending_per_user", 7)
      end)

    assert log =~ "media_config_updated audit write failed",
           "expected Nebu.Media.Config to log the audit failure with its own context; got: #{log}"

    assert {7, _set_at} = Agent.get(store, &Map.get(&1, "max_pending_per_user")),
           "the config write must NOT be rolled back when only the audit write fails"
  end

  # ════════════════════════════════════════════════════════════════════════
  # Code review (Cycle 0, m4 — MINOR): upsert/2 had no actor parameter — every
  # media_config_updated entry was attributed to the fixed @audit_actor
  # constant. Story 9b's admin settings UI needs to attribute changes to the
  # specific admin who made them.
  # ════════════════════════════════════════════════════════════════════════

  test "upsert/3 with a custom actor attributes the audit row to that actor", %{
    audit_bucket: audit_bucket
  } do
    assert :ok = Config.upsert("mime_denylist", "application/x-msdownload", "admin:alice")

    rows = Agent.get(audit_bucket, & &1)
    assert length(rows) == 1, "expected exactly one audit row, got #{length(rows)}"

    [row] = rows
    assert row.actor_user_id == "admin:alice"
  end

  test "upsert/2 (no actor given) still defaults to the system actor, unchanged from before", %{
    audit_bucket: audit_bucket
  } do
    assert :ok = Config.upsert("orphaned_hours", 12)

    [row] = Agent.get(audit_bucket, & &1)
    assert row.actor_user_id == "system:media_config"
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC5 — cluster-wide cache invalidation via :pg + 60s TTL fallback
  # ════════════════════════════════════════════════════════════════════════

  test "a second GenServer node's cache reflects an upsert via the :pg broadcast without calling get/0 a second time on the writing node" do
    ensure_started()
    :ok = Config.refresh()

    ensure_pg()
    :pg.join(Config.pg_group(), self())
    on_exit(fn -> :pg.leave(Config.pg_group(), self()) end)

    assert :ok = Config.upsert("mime_denylist", "application/x-msdownload")

    # The peer (this test process, standing in for a second cluster node —
    # see moduledoc "AC10/AC11 cluster-invalidation test design note") receives
    # the SAME invalidation broadcast a real second node's own
    # Nebu.Media.Config instance would receive and react to via its own
    # handle_info/2 clause. We never call get/0 a second time on the writing
    # node to observe this — the assertion is purely on the broadcast delivery.
    assert_receive {:invalidate_media_config}, 500
  end

  test "a node that misses the :pg broadcast still serves the new value within the TTL fallback window", %{
    store: store
  } do
    ensure_started()
    :ok = Config.refresh()
    assert Config.get().deleted_days == 30

    # Simulate a DB change this node's cache did NOT learn about via broadcast
    # (e.g. a missed :invalidate_media_config message during a network
    # partition) by mutating the underlying store directly, bypassing upsert/1.
    Agent.update(store, &Map.put(&1, "deleted_days", {45, System.system_time(:millisecond)}))

    # Still stale — no refresh has happened yet.
    assert Config.get().deleted_days == 30

    # Drive the GenServer's internal TTL-fallback tick directly instead of
    # sleeping the real 60s TTL — the same technique
    # session_expiry_worker_test.exs uses for its own periodic :tick message.
    pid = Process.whereis(Nebu.Media.Config)
    send(pid, :ttl_tick)
    # :sys.get_state/1 blocks until the handle_info(:ttl_tick, _) callback has
    # fully completed, so no sleep is needed to observe its effect.
    :sys.get_state(pid)

    assert Config.get().deleted_days == 45,
           "expected the TTL fallback tick to re-read the DB and pick up the missed change"
  end

  test "other modules reading via Nebu.Media.Config.get/0 observe a live value immediately after upsert on the SAME node" do
    ensure_started()
    :ok = Config.refresh()

    assert :ok = Config.upsert("orphaned_hours", 48)
    assert Config.get().orphaned_hours == 48
  end

  # ════════════════════════════════════════════════════════════════════════
  # F2 (pre-dev test-review gap) — AC5: the supervised holder restarts and
  # repopulates its ETS cache after a crash. Mirrors
  # oidc_claim_cache_test.exs's "AC6: the supervised holder restarts and
  # repopulates after a kill" — monitor the current pid, kill it, poll for a
  # NEW pid under the same registered name (proving the surrounding OTP
  # supervisor restarted it, not merely that some other code kept it alive),
  # then assert a subsequent read repopulates correctly.
  # ════════════════════════════════════════════════════════════════════════

  test "the supervised holder restarts and repopulates its ETS cache after a kill" do
    ensure_started()
    :ok = Config.refresh()

    assert Config.get() == @default_catalog

    pid = Process.whereis(Nebu.Media.Config)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    # The surrounding OTP supervisor restarts it under the same registered
    # name. A bare, unsupervised start_link/1 (like ensure_started/0's own
    # fallback path) would never come back on its own after :kill — only
    # supervision makes this happen, which is exactly the AC5 behavior this
    # test is meant to require.
    new_pid = wait_for_restart(pid)
    assert is_pid(new_pid) and new_pid != pid

    # A subsequent get/0 repopulates transparently from the injected
    # :media_config_loader seam (the store Agent is still empty here, so
    # this must equal the config.exs default catalog again) — no manual
    # admin action should be required to recover the correct catalog after
    # a crash.
    assert Config.get() == @default_catalog
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp ensure_started do
    case Config.start_link([]) do
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

  # Adapted from oidc_claim_cache_test.exs's own wait_for_restart/2.
  defp wait_for_restart(old_pid, attempts \\ 50)
  defp wait_for_restart(_old_pid, 0), do: flunk("Nebu.Media.Config did not restart after being killed")

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(Nebu.Media.Config) do
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
end
