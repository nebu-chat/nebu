defmodule Nebu.Media.DBScanMetadataTest do
  @moduledoc """
  Real-Postgres regression test for
  `media-security-admin-control/4b-media-scan-worker` AC10 ("every state
  transition this worker performs writes exactly one media_state_transitions
  row ... this worker never issues a raw SQL UPDATE against
  media_files.state").

  Pre-dev test-review (MINOR-1) flagged that `Nebu.Workers.MediaScanWorkerTest`
  fully seams out `Nebu.Media.DB.update_scan_metadata/2`, so no test proves
  the REAL production SQL only touches `scan_metadata`, never `state` — this
  file closes that gap directly against a live database, mirroring
  `media_scan_failed_enum_value_test.exs`'s / `media_reserved_upload_cleanup_
  worker_test.exs`'s own real-DB regression-test convention.

  Requires a live `Nebu.Repo` connection — run via `make test-integration` /
  `mix test --include integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Media.DB
  alias Nebu.Media.StateMachine
  alias Nebu.Repo

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "scan_metadata_#{@run_id}_#{suffix}"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL, e.g. `make test-integration`")
    end

    :ok
  end

  test "update_scan_metadata/2's real SQL sets scan_metadata only, never touches state" do
    id = media_id("infected")

    {:ok, ^id} =
      StateMachine.create_quarantined(%{
        media_id: id,
        server_name: "test.local",
        uploader_user_id: "@uploader:test.local"
      })

    metadata = %{"clamav_signature" => "Eicar-Test-Signature", "scanned_at" => "2026-07-14T00:00:00Z"}

    assert :ok = DB.update_scan_metadata(id, metadata)

    %Postgrex.Result{rows: [[state, scan_metadata]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT state::text, scan_metadata FROM media_files WHERE media_id = $1",
        [id]
      )

    assert state == "quarantined",
           "update_scan_metadata/2 must never change media_files.state — expected it to stay " <>
             "'quarantined', got #{inspect(state)}"

    assert scan_metadata == metadata
  end
end
