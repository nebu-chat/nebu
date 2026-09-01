defmodule Nebu.Media.CompressionTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/12-gzip-compression-at-rest`
  (AC1-AC7, unit tests 1-7; tests 8-9 integration — see "Grounding note" below).

  `Nebu.Media.Storage.compress/1` does not exist yet — every unit test below
  (tests 1-7) is expected to fail with `** (UndefinedFunctionError)` calling
  `Nebu.Media.Storage.compress/1` until the dev-story implements it in
  `server/lib/nebu/media/storage.ex` (AC1). This is the valid RED state for
  this story. Pure-function tests, no DB/Repo/Plug.Conn involved (mirrors the
  plain-module test style of `state_machine_test.exs`, not the HTTP-handler
  `Nebu.Web.Media*Test` style) — `async: true` is safe here.

  ## Grounding note on tests 8/9 (deviation from the story's own Technical
  Requirements — verified against the actual tree, not assumed)

  The story text describes tests 8/9 as exercising `Nebu.Workers.MediaScanWorker`
  (Story 4b) via `Oban.Testing.perform_job/3`, calling 4b "a landed dependency."
  That claim does NOT hold against the current tree:

    * `server/lib/nebu/workers/` does not exist at all; the only worker-shaped
      modules in the codebase are `Nebu.Compliance.SessionExpiryWorker` and
      `Nebu.Matrix.Session.RefreshWorker`, both plain `GenServer`s with
      `Process.send_after` ticks — neither is an Oban worker.
    * `Nebu.Media.ClamAV` (Story 3) does not exist under `server/lib/nebu/media/`.
    * `:oban` is absent from `server/mix.exs` and `server/mix.lock`.
    * Story 4b's own AC1 states, in its own words: "Oban is not yet a dependency
      of this codebase" and explicitly identifies 4b as "where the Oban
      dependency... are introduced" for the whole codebase.
    * `_bmad-output/nebu/epics/media-security-admin-control/pipeline-state.yaml`
      confirms only 1a/1b/1c are committed so far — story 12 is running ahead
      of 2b/3/4a/4b in build order.

  Writing tests 8/9 as literally specified (`use Oban.Testing` /
  `Oban.Testing.perform_job/3` against `Nebu.Workers.MediaScanWorker`) would not
  produce a meaningful "missing implementation" RED — `use Oban.Testing` expands
  at compile time and would raise `** (CompileError) module Oban.Testing is not
  loaded`, which aborts compilation of this ENTIRE file and takes tests 1-7 down
  with it (a strictly worse failure mode than a clean per-test RED). So tests
  8/9 are scaffolded below with their exact required names, `@tag :skip`, and a
  `flunk/1` documenting exactly what to wire up and un-skip once Story 4b lands.
  This is a deliberate deviation from the story's test list, made because the
  story's own grounding claim about 4b/Oban does not match the actual tree —
  per this story's explicit instruction not to blindly trust that section.

  ## media-security-admin-control/4b-media-scan-worker: un-skipped

  `:oban` is now a dependency (Story 2e, commit `a2498fda`), `Nebu.Media.ClamAV`
  exists (Story 3), and `Nebu.Workers.MediaScanWorker` is this story's own
  not-yet-implemented worker — `server/test/nebu/workers/media_scan_worker_test.exs`
  is the RED-phase test file for the worker itself (call order, decrypt,
  state-transition, broadcast). Tests 8/9 below are un-skipped and now exercise
  `Storage.compress/1`'s OWN output through the real
  `Oban.Testing.perform_job/3` -> `MediaScanWorker.perform/1` ->
  `ClamAV.scan_binary/1` path end-to-end, closing the loop this story's own
  Dependencies section describes ("the decompression step (AC4) is the
  inverse of 12's compression step"). Requires a live `Nebu.Repo` (real
  `oban_jobs` table) — tagged `:integration`, same convention as
  `media_scan_failed_enum_value_test.exs`; forces `async: false` for the
  whole module (Oban.Testing + a shared `Nebu.Repo` connection is not safe
  under `async: true`), same as every other module in this suite that mixes
  DB-backed and pure-function tests.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  alias Nebu.Media.Storage
  alias Nebu.Workers.MediaScanWorker

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  defp media_id(suffix), do: "compression_#{@run_id}_#{suffix}"

  @json_fixture Jason.encode!(%{
                  "type" => "m.room.message",
                  "content" => %{
                    "body" =>
                      String.duplicate("The quick brown fox jumps over the lazy dog. ", 200),
                    "msgtype" => "m.text"
                  },
                  "sender" => "@alice:example.org",
                  "room_id" => "!abcdefghijk:example.org"
                })

  # AC1/AC2/AC3 — highly-compressible text/JSON shrinks and is reported as compressed.
  test "compress/1 on a highly-compressible JSON/text payload returns {gzipped, true} and the gzipped bytes are smaller than the original" do
    {bytes, compressed?} = Storage.compress(@json_fixture)

    assert compressed? == true
    assert byte_size(bytes) < byte_size(@json_fixture)
    assert bytes == :zlib.gzip(@json_fixture)
  end

  # AC3 — incompressible random bytes: gzip framing overhead means it never shrinks.
  test "compress/1 on incompressible random bytes returns {original, false} because gzip framing overhead makes the compressed form not smaller" do
    original = :crypto.strong_rand_bytes(4096)

    # Sanity check on the fixture itself: confirm gzip really doesn't shrink
    # this input in this environment, otherwise the test would be meaningless.
    assert byte_size(:zlib.gzip(original)) >= byte_size(original)

    {bytes, compressed?} = Storage.compress(original)

    assert compressed? == false
    assert bytes == original
  end

  # AC3 — already-compressed-format-shaped payload (JPEG/MP4/PDF-with-media
  # stand-in): high-entropy binary, gzip cannot meaningfully shrink noise.
  test "compress/1 on an already-compressed-format-shaped payload (high-entropy binary standing in for JPEG/MP4) returns {original, false}, never grows what gets stored" do
    original = :crypto.strong_rand_bytes(2 * 1024 * 1024)

    {bytes, compressed?} = Storage.compress(original)

    assert compressed? == false
    assert bytes == original
    assert byte_size(bytes) == byte_size(original)
  end

  # AC3 — strict "<" comparison: a tie (== ) must NOT be treated as "smaller".
  test "compress/1 tie case: byte_size(gzipped) == byte_size(original) returns {original, false}, not the gzip variant" do
    tie_input =
      Enum.find_value(1..2000, fn n ->
        candidate = String.duplicate("a", n)
        if byte_size(:zlib.gzip(candidate)) == byte_size(candidate), do: candidate
      end)

    refute is_nil(tie_input),
           "expected to find at least one repeated-byte input (length 1..2000) where " <>
             "byte_size(:zlib.gzip(x)) == byte_size(x) in this OTP/zlib build, to exercise " <>
             "the strict '>=' tie branch of AC3 — none found"

    # Reconfirm the tie property directly (independent of compress/1, which
    # doesn't exist yet) so a future zlib/OTP upgrade that shifts the crossover
    # point fails loudly here rather than silently testing the wrong branch.
    assert byte_size(:zlib.gzip(tie_input)) == byte_size(tie_input)

    {bytes, compressed?} = Storage.compress(tie_input)

    assert compressed? == false
    assert bytes == tie_input
  end

  # AC3 — empty input is not special-cased; gzip's fixed overhead means
  # byte_size(gzip("")) > 0, so it falls into the same ">=" branch.
  test "compress/1 on empty binary input returns {\"\", false}" do
    assert byte_size(:zlib.gzip("")) > 0

    {bytes, compressed?} = Storage.compress("")

    assert bytes == ""
    assert compressed? == false
  end

  # AC6/AC7 — compressed branch round-trip: :zlib.gunzip/1 (the same call
  # MediaScanWorker's maybe_gunzip/2 will make) must reconstruct every
  # highly-compressible fixture exactly.
  test "round-trip byte-identity: compressed branch — :zlib.gunzip/1 applied to compress/1's gzipped output reconstructs the original bytes exactly" do
    fixtures = [
      {"repeated-text blob",
       String.duplicate("nebu media compression story 12 gzip round-trip fixture. ", 500)},
      {"JSON fixture",
       Jason.encode!(%{
         "a" => String.duplicate("x", 1000),
         "b" => [1, 2, 3, 4, 5],
         "nested" => %{"c" => "d"}
       })},
      {"larger synthetic log file",
       Enum.map_join(1..2000, "\n", fn i ->
         "2026-07-13T00:00:00Z INFO request_id=#{i} status=200 " <>
           "path=/_matrix/client/v3/sync latency_ms=#{rem(i, 50)}"
       end)}
    ]

    for {name, fixture} <- fixtures do
      {bytes, compressed?} = Storage.compress(fixture)

      assert compressed? == true,
             "expected fixture #{inspect(name)} to compress (compressed?=true), got false"

      assert :zlib.gunzip(bytes) == fixture,
             "gunzip of compress/1's output did not reconstruct fixture #{inspect(name)} byte-for-byte"
    end
  end

  # AC7 — uncompressed branch round-trip: the "compression" step is a no-op
  # passthrough, so the returned bytes must equal the original exactly.
  test "round-trip byte-identity: uncompressed branch — compress/1's returned bytes for an incompressible input equal the original input exactly, byte for byte" do
    original = :crypto.strong_rand_bytes(8192)

    {bytes, compressed?} = Storage.compress(original)

    assert compressed? == false
    assert bytes == original
  end

  # ---------------------------------------------------------------------
  # Integration tests 8/9 — BLOCKED on Story 4b (Nebu.Workers.MediaScanWorker)
  # and the :oban dependency, neither of which exists in this tree yet. See
  # the "Grounding note" in the moduledoc above for the full explanation.
  # Un-skip and implement against Oban.Testing.perform_job/3 +
  # Nebu.Workers.MediaScanWorker once Story 4b lands.
  # ---------------------------------------------------------------------

  @tag :integration
  test "integration: Nebu.Workers.MediaScanWorker's maybe_gunzip/2 path correctly decompresses this story's compress/1 output" do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL, e.g. `make test-integration`")
    end

    id = media_id("gunzip")
    original = String.duplicate("compression round-trip fixture via the real scan worker. ", 300)

    {bytes_to_store, compressed?} = Storage.compress(original)
    assert compressed? == true

    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    ciphertext = Nebu.Media.Crypto.encrypt(bytes_to_store, key, nonce)

    Application.put_env(:nebu_http, :media_state_machine_module, Nebu.Web.MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_db_module, Nebu.Web.MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, Nebu.Web.MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_clamav_module, Nebu.Web.MediaFakes.ClamAV)

    Application.put_env(:nebu_http, :media_lookup_for_scan_fun, fn ^id ->
      {:ok,
       %{
         storage_key: id,
         aes_key_hex: Base.encode16(key, case: :lower),
         nonce_hex: Base.encode16(nonce, case: :lower),
         compressed: true
       }}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn ^id -> {:ok, ciphertext} end)

    test_pid = self()

    Application.put_env(:nebu_http, :media_clamav_scan_fun, fn scanned_bytes ->
      send(test_pid, {:scanned, scanned_bytes})
      {:ok, :clean}
    end)

    on_exit(fn ->
      for k <- [
            :media_state_machine_module,
            :media_db_module,
            :media_storage_module,
            :media_clamav_module,
            :media_lookup_for_scan_fun,
            :media_storage_get_fun,
            :media_clamav_scan_fun
          ],
          do: Application.delete_env(:nebu_http, k)
    end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => id})
    assert_received {:scanned, ^original}
  end

  @tag :integration
  test "integration: an incompressible upload (compressed: false) reaches ClamAV.scan_binary/1 unchanged, with no gunzip applied" do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL, e.g. `make test-integration`")
    end

    id = media_id("no-gunzip")
    original = :crypto.strong_rand_bytes(4096)

    {bytes_to_store, compressed?} = Storage.compress(original)
    assert compressed? == false
    assert bytes_to_store == original

    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    ciphertext = Nebu.Media.Crypto.encrypt(bytes_to_store, key, nonce)

    Application.put_env(:nebu_http, :media_state_machine_module, Nebu.Web.MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_db_module, Nebu.Web.MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, Nebu.Web.MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_clamav_module, Nebu.Web.MediaFakes.ClamAV)

    Application.put_env(:nebu_http, :media_lookup_for_scan_fun, fn ^id ->
      {:ok,
       %{
         storage_key: id,
         aes_key_hex: Base.encode16(key, case: :lower),
         nonce_hex: Base.encode16(nonce, case: :lower),
         compressed: false
       }}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn ^id -> {:ok, ciphertext} end)

    test_pid = self()

    Application.put_env(:nebu_http, :media_clamav_scan_fun, fn scanned_bytes ->
      send(test_pid, {:scanned, scanned_bytes})
      {:ok, :clean}
    end)

    on_exit(fn ->
      for k <- [
            :media_state_machine_module,
            :media_db_module,
            :media_storage_module,
            :media_clamav_module,
            :media_lookup_for_scan_fun,
            :media_storage_get_fun,
            :media_clamav_scan_fun
          ],
          do: Application.delete_env(:nebu_http, k)
    end)

    assert :ok = perform_job(MediaScanWorker, %{"media_id" => id})
    assert_received {:scanned, ^original}
  end
end
