defmodule Nebu.Workers.MediaScanWorkerKillSwitchTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/10d-scan-kill-switch`
  (AC1-AC9, Acceptance Tests 1-5 as written in the story file). Acceptance
  Tests 6-8 (the `AuditWriter.@known_actions` allowlist regression test and
  the `Nebu.Media.Config` default/validation tests) live in
  `Nebu.Compliance.AuditWriterMediaActionsTest` and `Nebu.Media.ConfigTest`
  respectively — mirroring the 4b/4c split already established in this repo
  (`media_scan_worker_test.exs` vs `media_scan_worker_audit_bridge_test.exs`
  vs `audit_writer_media_actions_test.exs`).

  ALL tests in this module are expected to FAIL until
  `Nebu.Workers.MediaScanWorker.scan_and_transition/3` gains the health-check
  branch this story adds. Failing reason: `FakeClamAV.health_check/0` is
  exercised via a NEW `:media_clamav_module` health_check call the CURRENT
  worker code never makes — the fake's `scan_binary/1` is called for every
  scenario today (no branch exists yet), so the "scan_binary/1 must never be
  called" assertions in Tests 1/2/3 below fail against the CURRENT
  implementation, and the live-config/audit assertions fail because no
  `media_unscanned_release` audit call is ever made and no
  `:media_config_module` seam is read at all yet.

  ## Corrected assumptions baked into these tests (grounded against the
  actual tree, not the story's own illustrative pseudocode)

    * `Nebu.Media.ClamAV.health_check/0` returns `%{healthy: boolean(),
      changed_at: DateTime.t()}` (Story 3, extended by 10b) — NOT the bare
      `:healthy` / `:unhealthy` atom the story's own illustrative
      `clamav_healthy?/0` sketch shows. These tests fake `health_check/0` to
      return that same map shape; the dev-story implementation must pattern
      match `%{healthy: bool}`, not `== :healthy`.
    * The kill-switch config seam is `Application.get_env(:nebu_http,
      :media_config_module, Nebu.Media.Config)` — the `:nebu_http` namespace,
      not `:nebu` as the story's pseudocode shows — confirmed against
      `Nebu.Workers.MediaAlertsCheckerWorker` (Story 10c), which already
      establishes this exact `media_config()` private-function convention
      for reading `Nebu.Media.Config.get/0` from a worker.
    * The scan-attempt entry point the story calls `scan_and_transition/3` is
      confirmed to still be named exactly that in the current
      `media_scan_worker.ex` (unchanged by 4c/10a/10b/10c) — this story's
      health-check branch is inserted at its top, before the existing `with`
      chain.
    * Test 5 (live policy change) drives the REAL `Nebu.Media.Config` module
      (not a bespoke fake) via its own `:media_config_loader`/
      `:media_config_writer` fun-seams (same technique
      `config_test.exs` already uses) — this is the only way to genuinely
      prove `Nebu.Media.Config.upsert/1` propagates to the very next
      `MediaScanWorker` job without an intervening cache-implementation fake
      papering over a caching bug.

  ## Test-double seams and fakes

  `FakeStateMachine`, `FakeClamAV`, `FakeDB`, `FakeStorage`, `FakeAuditWriter`
  mirror `media_scan_worker_audit_bridge_test.exs`'s bespoke Agent-backed
  pattern exactly (test-private, not the shared `Nebu.Web.MediaFakes`).
  `FakeClamAV.health_check/0` is new here — controlled via a
  `:media_clamav_health_fun` app-env fun, default `%{healthy: true,
  changed_at: DateTime.utc_now()}` (so any test that doesn't care about the
  kill-switch continues to exercise the ordinary scan path unchanged).
  `FakeMediaConfig` (also new) implements the `:media_config_module` seam for
  Tests 1-4 with a controllable `scan_kill_switch` value via
  `:media_scan_kill_switch_fun`.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  alias Nebu.Media.Config
  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Workers.MediaScanWorker

  @sm_calls :media_scan_ks_test_sm_calls
  @sm_overrides :media_scan_ks_test_sm_overrides
  @clamav_calls :media_scan_ks_test_clamav_calls
  @audit_calls :media_scan_ks_test_audit_calls
  @fixtures :media_scan_ks_test_fixtures

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine.transition/4."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_scan_ks_test_sm_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      overrides = Agent.get(Process.whereis(:media_scan_ks_test_sm_overrides), & &1)

      case Map.fetch(overrides, {media_id, to_state}) do
        {:ok, forced} -> forced
        :error -> {:ok, to_state}
      end
    end
  end

  defmodule FakeClamAV do
    @moduledoc """
    Test-private fake for `Nebu.Media.ClamAV.scan_binary/1` AND the new
    `health_check/0` call this story's branch introduces.
    """

    def scan_binary(bytes) do
      Agent.update(Process.whereis(:media_scan_ks_test_clamav_calls), fn calls ->
        [{:scan_binary, bytes} | calls]
      end)

      fun = Application.get_env(:nebu_http, :media_clamav_scan_fun)
      if fun, do: fun.(bytes), else: {:error, :no_fun_configured}
    end

    def health_check do
      Agent.update(Process.whereis(:media_scan_ks_test_clamav_calls), fn calls ->
        [:health_check | calls]
      end)

      fun =
        Application.get_env(:nebu_http, :media_clamav_health_fun, fn ->
          %{healthy: true, changed_at: DateTime.utc_now()}
        end)

      fun.()
    end
  end

  defmodule FakeDB do
    @moduledoc "Test-private fake for Nebu.Media.DB's scan-worker functions."

    def lookup_for_scan(media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_for_scan_fun)
      if fun, do: fun.(media_id), else: {:error, :not_found}
    end

    def update_scan_metadata(_media_id, _metadata), do: :ok
  end

  defmodule FakeStorage do
    @moduledoc """
    Test-private wrapper delegating to the shared MediaFakes.Storage, with a
    call-log so tests can assert the kill-switch branch skips the storage
    fetch entirely (AC4/AC5's "never even fetched" — the wasted-S3-round-trip
    rationale the story's Technical Requirements gives for checking health
    FIRST, before the existing `with` chain).
    """

    def get(key) do
      Agent.update(Process.whereis(:media_scan_ks_test_clamav_calls), fn calls ->
        [:storage_get | calls]
      end)

      Nebu.Web.MediaFakes.Storage.get(key)
    end
  end

  defmodule FakeAuditWriter do
    @moduledoc "Test-private fake for Nebu.Compliance.AuditWriter.log/6."

    def log(actor_user_id, action, target_type, target_id, metadata, outcome, _error_detail \\ nil) do
      Agent.update(Process.whereis(:media_scan_ks_test_audit_calls), fn calls ->
        [
          %{
            actor_user_id: actor_user_id,
            action: action,
            target_type: target_type,
            target_id: target_id,
            metadata: metadata,
            outcome: outcome
          }
          | calls
        ]
      end)

      :ok
    end
  end

  defmodule FakeMediaConfig do
    @moduledoc """
    Test-private fake for the `:media_config_module` seam (Tests 1-4 only —
    Test 5 uses the REAL `Nebu.Media.Config` module instead, see moduledoc).
    """

    def get do
      fun =
        Application.get_env(:nebu_http, :media_scan_kill_switch_fun, fn -> "fail_closed" end)

      %{scan_kill_switch: fun.()}
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @sm_calls)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @sm_overrides)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @clamav_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @audit_calls)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @fixtures)

    Application.put_env(:nebu_http, :media_lookup_for_scan_fun, fn media_id ->
      case Agent.get(Process.whereis(@fixtures), &Map.fetch(&1, media_id)) do
        {:ok, %{row: row}} -> {:ok, row}
        :error -> {:error, :not_found}
      end
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn media_id ->
      case Agent.get(Process.whereis(@fixtures), &Map.fetch(&1, media_id)) do
        {:ok, %{ciphertext: ciphertext}} -> {:ok, ciphertext}
        :error -> {:error, :not_found}
      end
    end)

    ensure_pubsub_started!()

    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_clamav_module, FakeClamAV)
    Application.put_env(:nebu_http, :media_db_module, FakeDB)
    Application.put_env(:nebu_http, :media_storage_module, FakeStorage)
    Application.put_env(:nebu_http, :media_audit_writer_module, FakeAuditWriter)
    Application.put_env(:nebu_http, :media_config_module, FakeMediaConfig)

    on_exit(fn ->
      for name <- [@sm_calls, @sm_overrides, @clamav_calls, @audit_calls, @fixtures] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
        end
      end

      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_clamav_module)
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_audit_writer_module)
      Application.delete_env(:nebu_http, :media_config_module)
      Application.delete_env(:nebu_http, :media_lookup_for_scan_fun)
      Application.delete_env(:nebu_http, :media_clamav_scan_fun)
      Application.delete_env(:nebu_http, :media_clamav_health_fun)
      Application.delete_env(:nebu_http, :media_scan_kill_switch_fun)
      Application.delete_env(:nebu_http, :media_config_source)
      Application.delete_env(:nebu_http, :media_config_loader)
      Application.delete_env(:nebu_http, :media_config_writer)
      Application.delete_env(:compliance, :repo)

      if pid = Process.whereis(Nebu.Media.Config) do
        if Process.alive?(pid), do: (try do GenServer.stop(pid) catch :exit, _ -> :ok end)
      end
    end)

    :ok
  end

  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  defp topic(media_id), do: "media:#{media_id}"

  defp sm_calls, do: Process.whereis(@sm_calls) |> Agent.get(&Enum.reverse/1)
  defp clamav_calls, do: Process.whereis(@clamav_calls) |> Agent.get(&Enum.reverse/1)
  defp audit_calls, do: Process.whereis(@audit_calls) |> Agent.get(&Enum.reverse/1)

  defp seed_scan_row(media_id, plaintext, opts \\ []) do
    compressed? = Keyword.get(opts, :compressed, false)
    stored_plaintext = if compressed?, do: :zlib.gzip(plaintext), else: plaintext

    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(stored_plaintext)

    filename = Keyword.get(opts, :filename, "test-fixture.bin")
    file_hash = Keyword.get(opts, :file_hash, "sha256-fixture-hash")
    uploader_id = Keyword.get(opts, :uploader_id, "@uploader:test.local")

    row = %{
      storage_key: media_id,
      aes_key_hex: key_hex,
      nonce_hex: nonce_hex,
      compressed: compressed?,
      filename: filename,
      file_hash: file_hash,
      uploader_user_id: uploader_id
    }

    # Registered into a shared fixtures map (keyed by media_id) rather than
    # overwriting a single-clause `fn ^media_id -> ...` app-env closure, so
    # more than one media_id can be seeded concurrently within a single test
    # (needed by Test 5's two-invocation live-policy-change scenario).
    Agent.update(Process.whereis(@fixtures), fn fixtures ->
      Map.put(fixtures, media_id, %{row: row, ciphertext: ciphertext})
    end)

    :ok
  end

  defp set_scan_result(fun), do: Application.put_env(:nebu_http, :media_clamav_scan_fun, fun)

  defp set_clamav_health(healthy?) do
    Application.put_env(:nebu_http, :media_clamav_health_fun, fn ->
      %{healthy: healthy?, changed_at: DateTime.utc_now()}
    end)
  end

  defp set_kill_switch(policy) do
    Application.put_env(:nebu_http, :media_scan_kill_switch_fun, fn -> policy end)
  end

  # ─── Acceptance Test 1 (AC4, AC7) ───────────────────────────────────────────

  test "fail-open releases unscanned with an audit entry when ClamAV is down" do
    media_id = "media-ks-fail-open-1"
    plaintext = "irrelevant — scan_binary/1 must never be called"

    seed_scan_row(media_id, plaintext,
      filename: "unscanned.bin",
      file_hash: "sha256-unscanned",
      uploader_id: "@uploader-ks1:test.local"
    )

    set_clamav_health(false)
    set_kill_switch("fail_open")

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    refute Enum.any?(clamav_calls(), &match?({:scan_binary, _}, &1)),
           "scan_binary/1 must never be called when the kill-switch fires fail-open"

    refute :storage_get in clamav_calls(),
           "Storage.get/1 must never be called when the kill-switch fires fail-open " <>
             "(AC4: skips fetch/decrypt/decompress/scan_binary entirely — avoids a " <>
             "wasted S3 round-trip)"

    assert Enum.any?(sm_calls(), fn {id, to, actor, _meta} ->
             id == media_id and to == :scanning and actor == {:system, nil}
           end)

    assert Enum.any?(sm_calls(), fn {id, to, actor, meta} ->
             id == media_id and to == :released and actor == {:system, nil} and
               meta[:unscanned] == true
           end)

    assert_receive {:media_state_transition, ^media_id, :released}

    assert [entry] = audit_calls()
    assert entry.action == "media_unscanned_release"
    assert entry.target_type == "media"
    assert entry.target_id == media_id
    assert entry.outcome == "success"
    assert entry.metadata[:reason] == "clamav_unavailable"
    assert entry.metadata[:media_id] == media_id
    assert entry.metadata[:filename] == "unscanned.bin"
    assert entry.metadata[:sha256] == "sha256-unscanned"
    assert entry.metadata[:uploader_id] == "@uploader-ks1:test.local"
  end

  # ─── Acceptance Test 2 (AC5) ─────────────────────────────────────────────────

  test "fail-closed holds and retries when ClamAV is down" do
    media_id = "media-ks-fail-closed-1"
    plaintext = "irrelevant — scan_binary/1 must never be called"

    seed_scan_row(media_id, plaintext)
    set_clamav_health(false)
    set_kill_switch("fail_closed")

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert {:error, :clamav_unavailable} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 1, max_attempts: 5)

    refute Enum.any?(clamav_calls(), &match?({:scan_binary, _}, &1)),
           "scan_binary/1 must never be called when the kill-switch holds fail-closed"

    refute :storage_get in clamav_calls(),
           "Storage.get/1 must never be called when the kill-switch holds fail-closed " <>
             "(AC5: 'without ever having fetched them')"

    assert Enum.any?(sm_calls(), fn {id, to, _actor, _meta} -> id == media_id and to == :quarantined end)
    refute_receive {:media_state_transition, ^media_id, _}, 50
    assert audit_calls() == []
  end

  # ─── Acceptance Test 3 (AC5) ─────────────────────────────────────────────────

  test "fail-closed transitions to scan_failed and audit-logs media_scan_failed after max_attempts exhausted while ClamAV stays down" do
    media_id = "media-ks-fail-closed-exhausted-1"
    plaintext = "irrelevant — scan_binary/1 must never be called"

    seed_scan_row(media_id, plaintext,
      filename: "held.bin",
      file_hash: "sha256-held",
      uploader_id: "@uploader-ks3:test.local"
    )

    set_clamav_health(false)
    set_kill_switch("fail_closed")

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert {:discard, :clamav_unavailable} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 5, max_attempts: 5)

    refute Enum.any?(clamav_calls(), &match?({:scan_binary, _}, &1))
    refute :storage_get in clamav_calls()

    assert Enum.any?(sm_calls(), fn {id, to, actor, _meta} ->
             id == media_id and to == :scan_failed and actor == {:system, nil}
           end)

    assert_receive {:media_state_transition, ^media_id, :scan_failed}

    assert [entry] = audit_calls()
    assert entry.action == "media_scan_failed"
    assert entry.outcome == "failure"
    assert entry.target_id == media_id
  end

  # ─── Acceptance Test 4 (AC8) ─────────────────────────────────────────────────

  test "normal scanning behavior is unaffected when ClamAV is healthy regardless of policy" do
    scenarios =
      for policy <- ["fail_open", "fail_closed"],
          outcome <- [:clean, :infected] do
        {policy, outcome}
      end

    for {policy, outcome} <- scenarios do
      media_id = "media-ks-healthy-#{policy}-#{outcome}"
      plaintext = "healthy clamav, policy=#{policy}, outcome=#{outcome}, should scan normally"

      seed_scan_row(media_id, plaintext)
      set_clamav_health(true)
      set_kill_switch(policy)

      scan_result =
        case outcome do
          :clean -> {:ok, :clean}
          :infected -> {:ok, {:infected, "Eicar-Test-Signature"}}
        end

      set_scan_result(fn ^plaintext -> scan_result end)

      Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

      assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

      assert Enum.any?(clamav_calls(), &match?({:scan_binary, _}, &1)),
             "scan_binary/1 MUST be called when ClamAV is healthy, policy=#{policy}, outcome=#{outcome}"

      expected_state = if outcome == :clean, do: :released, else: :infected

      assert Enum.any?(sm_calls(), fn {id, to, _actor, _meta} -> id == media_id and to == expected_state end),
             "expected #{media_id} (policy=#{policy}) to reach #{expected_state} exactly like " <>
               "Story 4b's own (kill-switch-independent) outcome for a #{outcome} scan"

      assert_receive {:media_state_transition, ^media_id, ^expected_state}

      # No kill-switch-specific audit entry ("media_unscanned_release") may
      # ever fire on the healthy path — the kill-switch never engages here.
      refute Enum.any?(audit_calls(), &(&1.action == "media_unscanned_release"))

      # Reset per-iteration agents for the next scenario.
      Agent.update(Process.whereis(@clamav_calls), fn _ -> [] end)
      Agent.update(Process.whereis(@sm_calls), fn _ -> [] end)
      Agent.update(Process.whereis(@audit_calls), fn _ -> [] end)
    end
  end

  # ─── Acceptance Test 5 (AC6) — live policy change, no restart ──────────────

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by Nebu.Media.Config's own AuditWriter.log/6 call in upsert/1."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}
    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  test "policy change takes effect live between two worker invocations without a process restart" do
    # Use the REAL Nebu.Media.Config (not FakeMediaConfig) for this test only,
    # so the assertion genuinely proves Config's own ETS/ live-read
    # mechanism — not a test fake — is what the worker observes.
    Application.delete_env(:nebu_http, :media_config_module)
    Application.put_env(:compliance, :repo, FakeAuditRepo)

    {:ok, store} = Agent.start_link(fn -> %{"scan_kill_switch" => {"fail_closed", 0}} end)

    loader = fn -> Agent.get(store, fn rows -> Map.new(rows, fn {k, {v, _}} -> {k, v} end) end) end

    writer = fn key, value, set_at ->
      Agent.update(store, &Map.put(&1, key, {value, set_at}))
      :ok
    end

    Application.put_env(:nebu_http, :media_config_loader, loader)
    Application.put_env(:nebu_http, :media_config_writer, writer)

    case Config.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    media_id_1 = "media-ks-live-1"
    media_id_2 = "media-ks-live-2"
    plaintext = "live policy change fixture"

    seed_scan_row(media_id_1, plaintext)
    seed_scan_row(media_id_2, plaintext)
    set_clamav_health(false)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id_1))
    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id_2))

    # First invocation: config still says fail_closed.
    assert {:error, :clamav_unavailable} =
             perform_job(MediaScanWorker, %{"media_id" => media_id_1}, attempt: 1, max_attempts: 5)

    assert Enum.any?(sm_calls(), fn {id, to, _actor, _meta} -> id == media_id_1 and to == :quarantined end)
    refute_receive {:media_state_transition, ^media_id_1, _}, 50
    refute :storage_get in clamav_calls()

    # Flip the policy live via Config.upsert/1 — no process restart anywhere.
    assert :ok = Config.upsert("scan_kill_switch", "fail_open")

    # Second invocation, same unhealthy ClamAV: must now observe fail_open.
    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id_2}, attempt: 1, max_attempts: 5)

    assert Enum.any?(sm_calls(), fn {id, to, _actor, meta} ->
             id == media_id_2 and to == :released and meta[:unscanned] == true
           end)

    assert_receive {:media_state_transition, ^media_id_2, :released}

    assert Enum.any?(audit_calls(), fn entry ->
             entry.action == "media_unscanned_release" and entry.target_id == media_id_2
           end)
  end
end
