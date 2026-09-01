defmodule Nebu.Workers.MediaScanWorkerAuditBridgeTest do
  @moduledoc """
  ATDD tests for `media-security-admin-control/
  4c-infected-scanfailed-audit-bridge` (AC1-AC9, Acceptance Tests 1-3, 5-6 —
  Acceptance Test 4, the `AuditWriter.@known_actions` allowlist regression
  test, lives in `Nebu.Compliance.AuditWriterMediaActionsTest`, mirroring the
  `member_added`/`member_removed` precedent).

  ## Real hook points (confirmed against Story 4b's landed code, not this
  story's own pre-4b draft prose)

  There is no separate Oban `discard/2` callback — `Nebu.Workers.
  MediaScanWorker` handles everything inside `perform/1`'s private helpers.
  The two audit-bridge call sites this story adds are:

    * the private `infect/2` (the `{:ok, {:infected, sig}}` branch of
      `scan_and_transition/3`), immediately after the `:infected`
      `media_state_transitions` write, `update_scan_metadata/2`, and the
      broadcast;
    * the private `scan_error/4`'s `attempt >= max_attempts` branch (what
      this story's original draft called "`discard/2`"), immediately after
      the `:scan_failed` `media_state_transitions` write and broadcast —
      `scan_error/4` itself returns `{:discard, reason}` here, there is no
      separate callback to hook.

  ## Seams / fakes

  Mirrors `Nebu.Workers.MediaScanWorkerTest`'s bespoke Agent-backed
  `FakeStateMachine`/`FakeClamAV`/`FakeDB`/`FakeStorage` pattern (not the
  shared `Nebu.Web.MediaFakes`), with `FakeDB.lookup_for_scan/1` extended to
  also carry `filename`/`file_hash`/`uploader_user_id` — the 3 columns this
  story added to the real `Nebu.Media.DB.lookup_for_scan/1` query (see
  `lib/nebu/media/db.ex`) for the audit-metadata enrichment `write_audit/4`
  performs. Adds a new `FakeAuditWriter` for the `:media_audit_writer_module`
  seam this story introduces (direct module seam, same style as the
  worker's existing `:media_clamav_module`/`:media_db_module` seams — not a
  `Nebu.Repo` swap, since `AuditWriter.log/6` is called directly).
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Workers.MediaScanWorker

  @sm_calls :media_scan_audit_test_sm_calls
  @sm_overrides :media_scan_audit_test_sm_overrides
  @clamav_calls :media_scan_audit_test_clamav_calls
  @db_update_calls :media_scan_audit_test_db_update_calls
  @audit_calls :media_scan_audit_test_audit_calls

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine.transition/4."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_scan_audit_test_sm_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      overrides = Agent.get(Process.whereis(:media_scan_audit_test_sm_overrides), & &1)

      case Map.fetch(overrides, {media_id, to_state}) do
        {:ok, forced} -> forced
        :error -> {:ok, to_state}
      end
    end
  end

  defmodule FakeClamAV do
    @moduledoc """
    Test-private fake for `Nebu.Media.ClamAV.scan_binary/1`. `health_check/0`
    (media-security-admin-control/10d-scan-kill-switch: the worker now calls
    this unconditionally before the scan pipeline) always reports healthy
    here — this file exercises the ordinary scan path, not the kill-switch,
    which has its own dedicated `media_scan_worker_kill_switch_test.exs`.
    """

    def scan_binary(bytes) do
      Agent.update(Process.whereis(:media_scan_audit_test_clamav_calls), fn calls ->
        [bytes | calls]
      end)

      fun = Application.get_env(:nebu_http, :media_clamav_scan_fun)
      if fun, do: fun.(bytes), else: {:error, :no_fun_configured}
    end

    def health_check, do: %{healthy: true, changed_at: DateTime.utc_now()}
  end

  defmodule FakeDB do
    @moduledoc """
    Test-private fake for Nebu.Media.DB's scan-worker functions —
    `lookup_for_scan/1`'s fixture shape now includes `filename`/`file_hash`/
    `uploader_user_id` (4c's extension of the real query).
    """

    def lookup_for_scan(media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_for_scan_fun)
      if fun, do: fun.(media_id), else: {:error, :not_found}
    end

    def update_scan_metadata(media_id, metadata) do
      Agent.update(Process.whereis(:media_scan_audit_test_db_update_calls), fn calls ->
        [{media_id, metadata} | calls]
      end)

      :ok
    end
  end

  defmodule FakeStorage do
    @moduledoc "Test-private wrapper delegating to the shared MediaFakes.Storage."

    def get(key), do: Nebu.Web.MediaFakes.Storage.get(key)
  end

  defmodule FakeAuditWriter do
    @moduledoc "Test-private fake for Nebu.Compliance.AuditWriter.log/6 — the :media_audit_writer_module seam this story introduces."

    def log(actor_user_id, action, target_type, target_id, metadata, outcome, _error_detail \\ nil) do
      Agent.update(Process.whereis(:media_scan_audit_test_audit_calls), fn calls ->
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

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @sm_calls)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @sm_overrides)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @clamav_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @db_update_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @audit_calls)

    ensure_pubsub_started!()

    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_clamav_module, FakeClamAV)
    Application.put_env(:nebu_http, :media_db_module, FakeDB)
    Application.put_env(:nebu_http, :media_storage_module, FakeStorage)
    Application.put_env(:nebu_http, :media_audit_writer_module, FakeAuditWriter)

    on_exit(fn ->
      for name <- [@sm_calls, @sm_overrides, @clamav_calls, @db_update_calls, @audit_calls] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: Agent.stop(pid)
        end
      end

      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_clamav_module)
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_audit_writer_module)
      Application.delete_env(:nebu_http, :media_lookup_for_scan_fun)
      Application.delete_env(:nebu_http, :media_clamav_scan_fun)
    end)

    :ok
  end

  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  defp audit_calls, do: Process.whereis(@audit_calls) |> Agent.get(&Enum.reverse/1)

  defp seed_scan_row(media_id, plaintext, opts \\ []) do
    compressed? = Keyword.get(opts, :compressed, false)
    stored_plaintext = if compressed?, do: :zlib.gzip(plaintext), else: plaintext

    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(stored_plaintext)

    filename = Keyword.get(opts, :filename, "test-fixture.bin")
    file_hash = Keyword.get(opts, :file_hash, "sha256-fixture-hash")
    uploader_id = Keyword.get(opts, :uploader_id, "@uploader:test.local")

    Application.put_env(:nebu_http, :media_lookup_for_scan_fun, fn ^media_id ->
      {:ok,
       %{
         storage_key: media_id,
         aes_key_hex: key_hex,
         nonce_hex: nonce_hex,
         compressed: compressed?,
         filename: filename,
         file_hash: file_hash,
         uploader_user_id: uploader_id
       }}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn ^media_id -> {:ok, ciphertext} end)

    :ok
  end

  defp set_scan_result(fun), do: Application.put_env(:nebu_http, :media_clamav_scan_fun, fun)

  # ─── Acceptance Tests 1, 2 (AC1, AC4, AC6) — :infected writes the bridge ───

  test "scanning -> :infected writes an audit_log entry via AuditWriter with action media_infected_detected" do
    media_id = "media-infected-audit-1"
    plaintext = "eicar-like payload"
    signature = "Eicar-Test-Signature"

    seed_scan_row(media_id, plaintext,
      filename: "eicar.txt",
      file_hash: "deadbeef01",
      uploader_id: "@uploader1:test.local"
    )

    set_scan_result(fn ^plaintext -> {:ok, {:infected, signature}} end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert [entry] = audit_calls()
    assert entry.action == "media_infected_detected"
    assert entry.target_type == "media"
    assert entry.target_id == media_id
    assert entry.outcome == "success"
    assert entry.metadata[:media_id] == media_id
    assert entry.metadata[:filename] == "eicar.txt"
    assert entry.metadata[:sha256] == "deadbeef01"
    assert entry.metadata[:uploader_id] == "@uploader1:test.local"
    assert entry.metadata[:clamav_signature] == signature
  end

  test "scanning -> :infected audit entry has outcome success (AC6 timestamp is a DB-column default, not story-specific code — see AuditLogEntry/audit_log.event_time)" do
    media_id = "media-infected-audit-2"
    plaintext = "eicar-like payload 2"
    signature = "Eicar-Test-Signature"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:ok, {:infected, signature}} end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert [entry] = audit_calls()
    assert entry.outcome == "success"
  end

  # ─── Acceptance Test 3 (AC1, AC5) — exhausted retries write the bridge ─────

  test "discard path (attempt == max_attempts) writes an audit_log entry with action media_scan_failed" do
    media_id = "media-exhausted-audit-1"
    plaintext = "always fails"

    seed_scan_row(media_id, plaintext,
      filename: "corrupt.bin",
      file_hash: "cafebabe02",
      uploader_id: "@uploader2:test.local"
    )

    set_scan_result(fn ^plaintext -> {:error, :clamd_down} end)

    assert {:discard, :clamd_down} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 5, max_attempts: 5)

    assert [entry] = audit_calls()
    assert entry.action == "media_scan_failed"
    assert entry.target_type == "media"
    assert entry.target_id == media_id
    assert entry.outcome == "failure"
    assert entry.metadata[:media_id] == media_id
    assert entry.metadata[:filename] == "corrupt.bin"
    assert entry.metadata[:sha256] == "cafebabe02"
    assert entry.metadata[:uploader_id] == "@uploader2:test.local"
    refute is_nil(entry.metadata[:reason])
  end

  # ─── Acceptance Test 5 (AC9) — routine transitions stay out of audit_log ───

  test "no audit_log entry is written for the routine quarantined -> scanning -> released transition" do
    media_id = "media-routine-clean-1"
    plaintext = "hello clean world"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:ok, :clean} end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert audit_calls() == []
  end

  test "no audit_log entry is written for a transient scan error retry (not yet exhausted)" do
    media_id = "media-routine-retry-1"
    plaintext = "retry then clean"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:error, :clamd_timeout} end)

    assert {:error, :clamd_timeout} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 1, max_attempts: 5)

    assert audit_calls() == []
  end

  test "no audit_log entry is written for the file_too_large skip-to-released path" do
    media_id = "media-routine-too-large-1"
    plaintext = "irrelevant, clamav rejects on size before ever looking at content"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:error, :file_too_large} end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert audit_calls() == []
  end

  test "no audit_log entry is written when the entry transition to :scanning is rejected (no-op)" do
    media_id = "media-routine-not-scannable-1"

    Agent.update(Process.whereis(@sm_overrides), fn overrides ->
      Map.put(overrides, {media_id, :scanning}, {:error, {:invalid_transition, :admin_blocked, :scanning}})
    end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert audit_calls() == []
  end

  # ─── Acceptance Test 6 (AC7) — no room_id key in metadata ──────────────────

  test "audit_log entry does not include a room_id key in metadata (infected)" do
    media_id = "media-no-room-id-infected"
    plaintext = "eicar-like payload"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:ok, {:infected, "sig"}} end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert [entry] = audit_calls()
    refute Map.has_key?(entry.metadata, :room_id)
    refute Map.has_key?(entry.metadata, "room_id")
  end

  test "audit_log entry does not include a room_id key in metadata (scan_failed)" do
    media_id = "media-no-room-id-failed"
    plaintext = "always fails"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:error, :clamd_down} end)

    assert {:discard, :clamd_down} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 5, max_attempts: 5)

    assert [entry] = audit_calls()
    refute Map.has_key?(entry.metadata, :room_id)
    refute Map.has_key?(entry.metadata, "room_id")
  end
end
