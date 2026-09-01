defmodule Nebu.Workers.MediaScanWorkerTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/4b-media-scan-worker`
  (AC1-AC10, Acceptance Tests 1-8 as written in the story file), plus a
  dedicated table-driven AC8 regression guard (Acceptance Test 5).

  ALL tests in this module are expected to FAIL until
  `Nebu.Workers.MediaScanWorker` is implemented. Failing reason: `perform_job/2,3`
  (from `Oban.Testing`) builds a job via `Oban.Testing.build_job/3`, which
  asserts `Code.ensure_loaded?(Nebu.Workers.MediaScanWorker) and
  implements_worker?(...)` BEFORE ever calling `perform/1` — see
  `deps/oban/lib/oban/testing.ex` `assert_valid_worker/1`. Since the module
  does not exist yet, every test below fails with an `ExUnit.AssertionError`
  ("Expected worker to be a module that implements the Oban.Worker behaviour")
  raised from inside `perform_job/2,3` itself — never reaching this test
  file's own assertions. This requires no live Postgres/`Nebu.Repo` connection
  for that specific failure (mirrors
  `media_reserved_upload_cleanup_worker_test.exs`'s own RED-phase note), so
  this file is exercised correctly by the plain `mix test` unit suite once
  compiled; a handful of assertions below (state-transition/broadcast/DB calls)
  only start to matter once the module exists and compiles, at which point
  they drive the GREEN implementation.

  ## Corrected story assumptions baked into these tests (grounded against the
  actual tree, not the story's own illustrative/stale sketch — same kind of
  correction Story 2e's and Story 4a's own ATDD already made and documented):

    * AC1/AC2 (Oban dependency + `oban_jobs` schema + `Nebu.Application`
      supervisor entry) are ALREADY DONE — Story 2e (commit `a2498fda`)
      bootstrapped Oban ahead of this story landing. `mix.exs` already has
      `{:oban, "~> 2.18"}`; migration `000026_oban_jobs` already exists;
      `Nebu.Application` already starts `Oban` after `Nebu.Repo`; `config.exs`
      already has a `config :nebu, Oban, repo:, shutdown_grace_period:,
      plugins: [Lifeline, Pruner, Cron], queues: [media_cleanup: [limit: 10]]`
      block. This story's ONLY remaining AC1/AC2 work is adding a
      `media_scan: [limit: 10]` entry to the existing `queues:` list — there
      is no test below for that (a config-file-only change, not something a
      unit test meaningfully asserts; `ci-gate`'s real `make redeploy` +
      `make test-integration` run is what proves Oban actually boots the
      `:media_scan` queue without crashing).
    * ALL app-env seams this worker reads are under the `:nebu_http`
      namespace (`Application.get_env(:nebu_http, key, default)`), NOT
      `:nebu` as the story's illustrative worker code shows — confirmed via
      `Nebu.Media`, `Nebu.Workers.MediaReservedUploadCleanupWorker`, and
      `server/test/nebu/media/media_fakes.exs`.
    * `Nebu.Media.Crypto.decrypt/3` has NO app-env seam in this codebase (it
      is a pure, deterministic AES-256-GCM function — see
      `server/lib/nebu/media/crypto.ex`). The worker calls it DIRECTLY, not
      through an injectable seam. These tests therefore exercise the REAL
      `Nebu.Media.Crypto.decrypt/3` against fixtures built with
      `Nebu.Web.MediaTestSupport.encrypt_like_go/1` (the same helper the
      download/range/thumbnail tests already use to stage encrypted-at-rest
      blobs) — this both proves the worker's decrypt call is wired correctly
      AND avoids inventing a Crypto seam the codebase does not have.
    * `aes_key_hex`/`nonce_hex` are stored as HEX STRINGS on `media_files`
      (`Base.encode16/2`), but `Nebu.Media.Crypto.decrypt/3` requires raw
      32-/12-byte binaries — the worker's `lookup_for_scan/1` result must be
      hex-decoded (`Base.decode16!(hex, case: :lower)`) before the
      `Crypto.decrypt/3` call. Fixture rows below carry the SAME hex-encoded
      shape `Nebu.Media.DB.lookup_for_scan/1` will genuinely return in
      production, so a dev-story implementation that forgets to hex-decode
      fails these tests immediately (a `:decrypt_failed` result, not a
      round-trip match).
    * `Nebu.Media.DB` (server/lib/nebu/media/db.ex) gains two new functions
      this story introduces: `lookup_for_scan/1` (returns
      `{:ok, %{storage_key:, aes_key_hex:, nonce_hex:, compressed:}}` or
      `{:error, :not_found}`) and `update_scan_metadata/2` (`UPDATE
      media_files SET scan_metadata = $2 WHERE media_id = $1`, returns `:ok`
      or `{:error, reason}`). Both are exercised here through the SAME
      `:media_db_module` seam `Nebu.Media.DB` already serves as the
      production default for (see its own moduledoc) — a test-private
      `FakeDB` module below stands in for it, mirroring
      `Nebu.Web.MediaFakes.DB`'s function-closure-over-app-env convention
      rather than duplicating it, since this worker needs a richer
      call-log than the shared fake carries.
    * Real module APIs the worker calls (already implemented — this worker is
      purely a CALLER of each):
        - `Nebu.Media.ClamAV.scan_binary/1` -> `{:ok, :clean}
          | {:ok, {:infected, signature}} | {:error, reason}` — faked here
          via a NEW `:media_clamav_module` seam (this module has no seam
          today; the worker introduces the first one).
        - `Nebu.Media.StateMachine.transition/4` -> `{:ok, to_state}
          | {:error, {:invalid_transition, from, to}} | {:error, :invalid_actor}
          | {:error, :not_found}` — faked here via the EXISTING
          `:media_state_machine_module` seam, using a test-private
          `FakeStateMachine` (not the shared `Nebu.Web.MediaFakes.StateMachine`,
          which has no call-log) — mirrors
          `media_reserved_upload_cleanup_worker_test.exs`'s own precedent of
          a bespoke Agent-backed fake for worker-level tests.
    * Broadcast contract (Story 2d, confirmed authoritative against the real
      `server/lib/nebu/media/download_stall.ex` code, not just the story
      prose): topic `"media:\#{media_id}"` on `Nebu.PubSub` (the app's main
      registry, NOT `Nebu.Admin.PubSub`), payload
      `{:media_state_transition, media_id, new_state}`.
    * Acceptance Test 4's story text mentions "asserts no further Oban job for
      this `media_id` is enqueued (Oban's own `discard` semantics —
      `assert_enqueued`/queue-inspection shows no pending retry)" —
      `Oban.Testing.perform_job/2,3` executes the job via
      `Executor.new(job, safe: false, ack: false)` (see
      `deps/oban/lib/oban/testing.ex`), i.e. it NEVER writes to the real
      `oban_jobs` table at all (no insert, no ack) — there is no queue state
      to inspect for a job that was never enqueued for real in the first
      place. This adaptation (same class of correction 2e's own ATDD made)
      keeps the assertion to what `perform_job/3`'s return value and this
      worker's own side effects (state transition + broadcast) actually prove:
      that `perform/1` returns `{:discard, reason}` — which is the exact
      contract Oban's real queue engine consults to decide "discard, do not
      retry" for a job enqueued for real in production.

  ## Test-double seams and fakes

  `FakeStateMachine`, `FakeClamAV`, `FakeStorage` (thin wrapper delegating to
  the shared `Nebu.Web.MediaFakes.Storage`), and `FakeDB` are test-private.
  A single shared `@call_order` Agent records `:storage_get` /
  `:clamav_scan_binary` tags in call order (Acceptance Test 8) — Crypto/gunzip
  correctness is proven behaviorally instead (content-based), since neither
  has a call-log seam in production.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Workers.MediaScanWorker

  @sm_calls :media_scan_test_sm_calls
  @sm_overrides :media_scan_test_sm_overrides
  @clamav_calls :media_scan_test_clamav_calls
  @db_update_calls :media_scan_test_db_update_calls
  @call_order :media_scan_test_call_order

  # ─── FakeStateMachine (test-private, mirrors the 2e worker test convention) ──

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine.transition/4."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_scan_test_sm_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      overrides = Agent.get(Process.whereis(:media_scan_test_sm_overrides), & &1)

      case Map.fetch(overrides, {media_id, to_state}) do
        {:ok, forced} -> forced
        :error -> {:ok, to_state}
      end
    end
  end

  # ─── FakeClamAV (test-private — new seam this worker introduces) ───────────

  defmodule FakeClamAV do
    @moduledoc """
    Test-private fake for `Nebu.Media.ClamAV.scan_binary/1`. `health_check/0`
    (media-security-admin-control/10d-scan-kill-switch: the worker now calls
    this unconditionally before the scan pipeline) always reports healthy
    here — this file exercises the ordinary scan path, not the kill-switch,
    which has its own dedicated `media_scan_worker_kill_switch_test.exs`.
    """

    def scan_binary(bytes) do
      Agent.update(Process.whereis(:media_scan_test_clamav_calls), fn calls ->
        [bytes | calls]
      end)

      Agent.update(Process.whereis(:media_scan_test_call_order), fn order ->
        [:clamav_scan_binary | order]
      end)

      fun = Application.get_env(:nebu_http, :media_clamav_scan_fun)
      if fun, do: fun.(bytes), else: {:error, :no_fun_configured}
    end

    def health_check, do: %{healthy: true, changed_at: DateTime.utc_now()}
  end

  # ─── FakeDB (test-private — new lookup_for_scan/update_scan_metadata seam) ──

  defmodule FakeDB do
    @moduledoc "Test-private fake for the new Nebu.Media.DB scan-worker functions."

    def lookup_for_scan(media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_for_scan_fun)
      if fun, do: fun.(media_id), else: {:error, :not_found}
    end

    def update_scan_metadata(media_id, metadata) do
      Agent.update(Process.whereis(:media_scan_test_db_update_calls), fn calls ->
        [{media_id, metadata} | calls]
      end)

      fun = Application.get_env(:nebu_http, :media_update_scan_metadata_fun)
      if fun, do: fun.(media_id, metadata), else: :ok
    end
  end

  # ─── FakeStorage (delegates to the shared MediaFakes.Storage, adds call_order) ──

  defmodule FakeStorage do
    @moduledoc "Test-private wrapper so Storage.get/1 also feeds @call_order."

    def get(key) do
      Agent.update(Process.whereis(:media_scan_test_call_order), fn order ->
        [:storage_get | order]
      end)

      Nebu.Web.MediaFakes.Storage.get(key)
    end
  end

  # ─── Setup / Teardown ───────────────────────────────────────────────────────

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @sm_calls)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @sm_overrides)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @clamav_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @db_update_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @call_order)

    ensure_pubsub_started!()

    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_clamav_module, FakeClamAV)
    Application.put_env(:nebu_http, :media_db_module, FakeDB)
    Application.put_env(:nebu_http, :media_storage_module, FakeStorage)

    on_exit(fn ->
      for name <- [@sm_calls, @sm_overrides, @clamav_calls, @db_update_calls, @call_order] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: Agent.stop(pid)
        end
      end

      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_clamav_module)
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_lookup_for_scan_fun)
      Application.delete_env(:nebu_http, :media_clamav_scan_fun)
      Application.delete_env(:nebu_http, :media_update_scan_metadata_fun)
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  # ─── 10e AC2 helpers (Trace-Map metadata capture) ──────────────────────────
  #
  # Mirrors clamav_test.exs's own 10e AC1 helpers and
  # request_logger_test.exs's M2 regression: attach the REAL
  # Nebu.Web.LogStore.Handler, subscribe to "operational_logs", and inspect
  # the broadcast entry's top-level :route_template/:request_id fields
  # (Handler.parse_log_event/1 extracts these OUT of :metadata into their own
  # columns).
  defp attach_log_capture! do
    ensure_pubsub_started!()
    :ok = Nebu.Web.LogStore.attach_handler()
    Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")
  end

  defp drain_log_entries(acc \\ []) do
    receive do
      msg -> drain_log_entries([msg | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  defp scan_worker_entries_for(media_id, entries) do
    Enum.filter(entries, fn
      %{route_template: "/media/scan_worker", request_id: ^media_id} -> true
      _ -> false
    end)
  end

  defp topic(media_id), do: "media:#{media_id}"

  defp sm_calls, do: Process.whereis(@sm_calls) |> Agent.get(&Enum.reverse/1)
  defp clamav_calls, do: Process.whereis(@clamav_calls) |> Agent.get(&Enum.reverse/1)
  defp db_update_calls, do: Process.whereis(@db_update_calls) |> Agent.get(&Enum.reverse/1)
  defp call_order, do: Process.whereis(@call_order) |> Agent.get(&Enum.reverse/1)

  defp seed_scan_row(media_id, plaintext, opts \\ []) do
    compressed? = Keyword.get(opts, :compressed, false)
    stored_plaintext = if compressed?, do: :zlib.gzip(plaintext), else: plaintext

    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(stored_plaintext)

    Application.put_env(:nebu_http, :media_lookup_for_scan_fun, fn ^media_id ->
      {:ok,
       %{
         storage_key: media_id,
         aes_key_hex: key_hex,
         nonce_hex: nonce_hex,
         compressed: compressed?
       }}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn ^media_id -> {:ok, ciphertext} end)

    :ok
  end

  defp set_scan_result(fun), do: Application.put_env(:nebu_http, :media_clamav_scan_fun, fun)

  # ─── Test 1 (AC3, AC5) — clean scan releases and broadcasts ────────────────

  test "clean scan transitions quarantined media to released and broadcasts on media:\#{id}" do
    media_id = "media-clean-1"
    plaintext = "hello clean world"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:ok, :clean} end)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    calls = sm_calls()
    assert Enum.any?(calls, fn {id, to, actor, _meta} -> id == media_id and to == :scanning and actor == {:system, nil} end)
    assert Enum.any?(calls, fn {id, to, actor, _meta} -> id == media_id and to == :released and actor == {:system, nil} end)

    assert_receive {:media_state_transition, ^media_id, :released}
  end

  # ─── Test 2 (AC6) — infected scan persists signature and broadcasts ────────

  test "infected scan transitions to infected, persists the ClamAV signature, and broadcasts" do
    media_id = "media-infected-1"
    plaintext = "eicar-like payload"
    signature = "Eicar-Test-Signature"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:ok, {:infected, signature}} end)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert Enum.any?(sm_calls(), fn {id, to, _actor, meta} ->
             id == media_id and to == :infected and meta[:clamav_signature] == signature
           end)

    assert Enum.any?(db_update_calls(), fn {id, meta} ->
             id == media_id and meta[:clamav_signature] == signature
           end)

    assert_receive {:media_state_transition, ^media_id, :infected}
  end

  # ─── Test 3 (AC9) — transient error retries, later clean attempt releases ──

  test "a transient scanner error retries, then a clean result on a later attempt releases the file" do
    media_id = "media-retry-then-clean-1"
    plaintext = "retry then clean"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:error, :clamd_timeout} end)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert {:error, :clamd_timeout} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 1, max_attempts: 5)

    assert Enum.any?(sm_calls(), fn {id, to, _actor, _meta} -> id == media_id and to == :quarantined end)
    refute_receive {:media_state_transition, ^media_id, _}, 50

    set_scan_result(fn ^plaintext -> {:ok, :clean} end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 2, max_attempts: 5)

    assert_receive {:media_state_transition, ^media_id, :released}
    refute_receive {:media_state_transition, ^media_id, _}, 50
  end

  # ─── Test 4 (AC9) — exhausted retries discard to scan_failed ───────────────

  test "exhausted retries (attempt == max_attempts) transitions to scan_failed, broadcasts, and the job is discarded rather than retried again" do
    media_id = "media-exhausted-1"
    plaintext = "always fails"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:error, :clamd_down} end)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert {:discard, :clamd_down} =
             perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 5, max_attempts: 5)

    assert Enum.any?(sm_calls(), fn {id, to, actor, meta} ->
             id == media_id and to == :scan_failed and actor == {:system, nil} and
               is_binary(meta[:reason])
           end)

    assert_receive {:media_state_transition, ^media_id, :scan_failed}
  end

  # ─── Test 5 (AC8) — none of the three terminal outcomes silently misses its broadcast ──

  test "all three terminal outcomes (released, infected, scan_failed) broadcast on media:\#{id} — none of them is silently missing the broadcast" do
    scenarios = [
      {"media-bcast-released", fn plaintext -> fn ^plaintext -> {:ok, :clean} end end, :released,
       attempt: 1, max_attempts: 5},
      {"media-bcast-infected",
       fn plaintext -> fn ^plaintext -> {:ok, {:infected, "sig"}} end end, :infected,
       attempt: 1, max_attempts: 5},
      {"media-bcast-scan-failed", fn plaintext -> fn ^plaintext -> {:error, :down} end end,
       :scan_failed, attempt: 5, max_attempts: 5}
    ]

    for {media_id, scan_fun_builder, expected_state, opts} <- scenarios do
      plaintext = "payload for #{media_id}"
      seed_scan_row(media_id, plaintext)
      set_scan_result(scan_fun_builder.(plaintext))

      Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

      perform_job(MediaScanWorker, %{"media_id" => media_id}, opts)

      assert_receive {:media_state_transition, ^media_id, ^expected_state},
                     500,
                     "expected exactly one broadcast for #{media_id} -> #{expected_state}, got none"

      refute_receive {:media_state_transition, ^media_id, _}, 50,
                     "expected exactly one broadcast for #{media_id}, got a second one"
    end
  end

  # ─── Test 6 (AC7) — file_too_large is a skip, not a scan failure ──────────

  test "file_too_large is a skip, not a scan failure: transitions to released with scan_metadata skipped: size_limit, and broadcasts, with zero retries" do
    media_id = "media-too-large-1"
    plaintext = "irrelevant, clamav rejects on size before ever looking at content"

    seed_scan_row(media_id, plaintext)
    set_scan_result(fn ^plaintext -> {:error, :file_too_large} end)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert Enum.any?(sm_calls(), fn {id, to, _actor, meta} ->
             id == media_id and to == :released and meta[:skipped] == "size_limit"
           end)

    assert_receive {:media_state_transition, ^media_id, :released}
  end

  # ─── Test 7 (AC3) — no-op when media_id is no longer scannable ────────────

  test "perform/1 with a media_id no longer in a scannable state (e.g. already admin_blocked) is a no-op, not a crash or a retry" do
    media_id = "media-not-scannable-1"

    Agent.update(Process.whereis(@sm_overrides), fn overrides ->
      Map.put(overrides, {media_id, :scanning}, {:error, {:invalid_transition, :admin_blocked, :scanning}})
    end)

    Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

    assert clamav_calls() == [], "scan_binary/1 must never be called once the entry transition is rejected"
    refute_receive {:media_state_transition, ^media_id, _}, 50
  end

  # ─── Test 8 (AC4) — decrypt/decompress pipeline order and correctness ─────

  test "decrypt/decompress pipeline: worker calls Storage.get, then Crypto.decrypt, then conditionally :zlib.gunzip, before calling scan_binary/1" do
    media_id_compressed = "media-pipeline-compressed"
    media_id_plain = "media-pipeline-plain"

    compressible_plaintext = String.duplicate("nebu media scan pipeline fixture. ", 200)
    plain_bytes = :crypto.strong_rand_bytes(256)

    seed_scan_row(media_id_compressed, compressible_plaintext, compressed: true)

    received_compressed = self()

    set_scan_result(fn bytes ->
      send(received_compressed, {:scanned_bytes, media_id_compressed, bytes})
      {:ok, :clean}
    end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id_compressed})

    assert_received {:scanned_bytes, ^media_id_compressed, ^compressible_plaintext},
                     "expected the worker to gunzip the decrypted bytes before scanning when compressed: true"

    assert call_order() == [:storage_get, :clamav_scan_binary]

    # Reset the shared call_order/agents for the second (uncompressed) sub-case.
    Agent.update(Process.whereis(@call_order), fn _ -> [] end)

    seed_scan_row(media_id_plain, plain_bytes, compressed: false)

    set_scan_result(fn bytes ->
      send(received_compressed, {:scanned_bytes, media_id_plain, bytes})
      {:ok, :clean}
    end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id_plain})

    assert_received {:scanned_bytes, ^media_id_plain, ^plain_bytes},
                     "expected the raw decrypted bytes unchanged (no gunzip) when compressed: false"

    assert call_order() == [:storage_get, :clamav_scan_binary]
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10e-trace-map-war-room-integration (AC2):
  # scan-start/scan-result(clean/infected)/scan-error-retry Logger calls must
  # carry route_template: "/media/scan_worker" AND request_id: media_id (the
  # media UUID reused AS the correlation key — see the story's Technical
  # Requirements for why this, not a fresh UUID, is correct for a
  # non-HTTP-originated event stream). Only identifiers go into metadata —
  # never file bytes/filename/Matrix content (this worker never even HAS the
  # original filename — see Story 1a/4b).
  #
  # ## Why these MUST FAIL right now
  #
  # None of `perform/1`'s helpers (`scan_and_transition/3`, `release/2`,
  # `infect/2`, `scan_error/4`) call `Logger.info/2`/`Logger.warning/2` with
  # this metadata today — this worker currently has NO Logger.* calls with
  # route_template/request_id at all (only the pre-existing
  # `Logger.warning/1` bare-string calls for internal bookkeeping failures).
  # Every assertion below fails today (no matching broadcast entry is ever
  # received).
  # ══════════════════════════════════════════════════════════════════════════

  describe "10e AC2: MediaScanWorker events carry Trace-Map metadata correlated by media_id" do
    # code-review cycle 2 (MAJOR-2): scan-start/scan-result:released now log
    # via Logger.info/2 (per AC2's exact spec), not Logger.warning/2 — this
    # level bump is required so this describe block's tests can actually
    # observe them; config/test.exs's primary Logger level (:warning) would
    # otherwise silently drop them before they ever reach
    # Nebu.Web.LogStore.Handler. Mirrors request_logger_test.exs's own
    # Logger.configure(level: :info)/on_exit restore idiom, scoped narrowly to
    # just this describe block.
    setup do
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    test "a clean scan logs an operational entry with route_template \"/media/scan_worker\" and request_id == media_id" do
      media_id = "media-clean-logtest-#{System.unique_integer([:positive])}"
      plaintext = "hello clean world for log test"

      seed_scan_row(media_id, plaintext)
      set_scan_result(fn ^plaintext -> {:ok, :clean} end)

      attach_log_capture!()

      assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

      matching = scan_worker_entries_for(media_id, drain_log_entries())

      assert matching != [],
             "expected at least one operational_logs entry with route_template " <>
               "\"/media/scan_worker\" and request_id == #{inspect(media_id)} for the clean " <>
               "scan result, got none"
    end

    test "an infected scan logs an operational entry with route_template \"/media/scan_worker\" and request_id == media_id" do
      media_id = "media-infected-logtest-#{System.unique_integer([:positive])}"
      plaintext = "eicar-like payload for log test"
      signature = "Eicar-Test-Signature"

      seed_scan_row(media_id, plaintext)
      set_scan_result(fn ^plaintext -> {:ok, {:infected, signature}} end)

      attach_log_capture!()

      assert :ok = perform_job(MediaScanWorker, %{"media_id" => media_id})

      matching = scan_worker_entries_for(media_id, drain_log_entries())

      assert matching != [],
             "expected an operational_logs entry with route_template \"/media/scan_worker\" " <>
               "and request_id == #{inspect(media_id)} for the infected scan result, got none"
    end

    test "a scanner error retry logs an operational entry with route_template \"/media/scan_worker\" and request_id == media_id" do
      media_id = "media-retry-logtest-#{System.unique_integer([:positive])}"
      plaintext = "retry then log test"

      seed_scan_row(media_id, plaintext)
      set_scan_result(fn ^plaintext -> {:error, :clamd_timeout} end)

      attach_log_capture!()

      assert {:error, :clamd_timeout} =
               perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 1, max_attempts: 5)

      matching = scan_worker_entries_for(media_id, drain_log_entries())

      assert matching != [],
             "expected an operational_logs entry with route_template \"/media/scan_worker\" " <>
               "and request_id == #{inspect(media_id)} for the scan-error retry, got none"
    end

    test "exhausted retries (scan_failed) log an operational entry with route_template \"/media/scan_worker\" and request_id == media_id" do
      media_id = "media-exhausted-logtest-#{System.unique_integer([:positive])}"
      plaintext = "always fails for log test"

      seed_scan_row(media_id, plaintext)
      set_scan_result(fn ^plaintext -> {:error, :clamd_down} end)

      attach_log_capture!()

      assert {:discard, :clamd_down} =
               perform_job(MediaScanWorker, %{"media_id" => media_id}, attempt: 5, max_attempts: 5)

      matching = scan_worker_entries_for(media_id, drain_log_entries())

      assert matching != [],
             "expected an operational_logs entry with route_template \"/media/scan_worker\" " <>
               "and request_id == #{inspect(media_id)} for the exhausted-retries scan_failed " <>
               "path, got none"
    end
  end
end
