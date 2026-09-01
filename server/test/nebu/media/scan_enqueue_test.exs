defmodule Nebu.Media.ScanEnqueueTest do
  @moduledoc """
  Real-Postgres integration test proving `Nebu.Media.ScanEnqueue.enqueue/1`
  genuinely inserts an Oban job for `Nebu.Workers.MediaScanWorker` on the
  `:media_scan` queue with `%{"media_id" => media_id}` args
  (media-security-admin-control/4b-media-scan-worker, Technical Requirements
  — "Job enqueue call site").

  `Nebu.Media.ScanEnqueue`'s own moduledoc (pre-4b) explicitly assigns this
  story the job of swapping its no-op body for a real `Oban.insert/1` call —
  "the call site in `Nebu.Media` (the `:media_scan_enqueue_module` seam) does
  not need to change, only this module's internals." This test exercises the
  real module directly (NOT through the `:media_scan_enqueue_module` seam —
  every HTTP-handler-level test already fakes that seam out via
  `Nebu.Web.MediaFakes.ScanEnqueue`, so nothing else in the suite would ever
  catch a regression in `ScanEnqueue`'s own real internals).

  Requires a live `Nebu.Repo` connection (real `oban_jobs` table, migration
  `000026_oban_jobs` from Story 2e) — run via `make test-integration` /
  `mix test --include integration`, same convention as
  `media_scan_failed_enum_value_test.exs`. No `Ecto.Sandbox` isolation is used
  in this codebase (media ids/run suffixes provide uniqueness instead), same
  as that file.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  @moduletag :integration

  alias Nebu.Media.ScanEnqueue

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "scan_enqueue_#{@run_id}_#{suffix}"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    :ok
  end

  test "enqueue/1 inserts a real Oban job for MediaScanWorker on the :media_scan queue" do
    id = media_id("clean")

    assert :ok = ScanEnqueue.enqueue(id)

    assert_enqueued worker: Nebu.Workers.MediaScanWorker, args: %{"media_id" => id}, queue: "media_scan"
  end
end
