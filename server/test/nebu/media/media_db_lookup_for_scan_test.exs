defmodule Nebu.Media.DBLookupForScanTest do
  @moduledoc """
  Real-Postgres regression test for `media-security-admin-control/
  4c-infected-scanfailed-audit-bridge` — `Nebu.Media.DB.lookup_for_scan/1`'s
  SELECT was extended (alongside `storage_key`/`aes_key_hex`/`nonce_hex`/
  `compressed`, added by Story 4b) to also return `filename`/`file_hash`/
  `uploader_user_id`, which `Nebu.Workers.MediaScanWorker`'s new audit-bridge
  metadata enrichment (AC4/AC5) needs. Story 4b's own worker test
  (`media_scan_worker_test.exs`) fully seams this function out via `FakeDB`,
  so — mirroring `media_db_scan_metadata_test.exs`'s own precedent for
  `update_scan_metadata/2` — this file proves the REAL SQL against a live
  database, not just the fake's assumed shape.

  Requires a live `Nebu.Repo` connection — run via `make test-integration` /
  `mix test --include integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Media.DB
  alias Nebu.Media.StateMachine

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "lookup_for_scan_#{@run_id}_#{suffix}"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL, e.g. `make test-integration`")
    end

    :ok
  end

  test "lookup_for_scan/1 returns filename, file_hash, and uploader_user_id alongside the crypto/compression fields" do
    id = media_id("full")

    {:ok, ^id} =
      StateMachine.create_quarantined(%{
        media_id: id,
        server_name: "test.local",
        uploader_user_id: "@uploader:test.local"
      })

    :ok =
      DB.persist_upload(%{
        media_id: id,
        storage_key: "storage/#{id}",
        file_hash: "sha256-fixture-abc123",
        compressed: true,
        content_type: "application/octet-stream",
        filename: "quarantine-fixture.bin",
        aes_key_hex: String.duplicate("ab", 32),
        nonce_hex: String.duplicate("cd", 12),
        file_size: 1234
      })

    assert {:ok, row} = DB.lookup_for_scan(id)

    assert row.storage_key == "storage/#{id}"
    assert row.compressed == true
    assert row.filename == "quarantine-fixture.bin"
    assert row.file_hash == "sha256-fixture-abc123"
    assert row.uploader_user_id == "@uploader:test.local"
  end

  test "lookup_for_scan/1 returns nil filename/file_hash for a genesis row that never completed persist_upload" do
    id = media_id("genesis")

    {:ok, ^id} =
      StateMachine.create_quarantined(%{
        media_id: id,
        server_name: "test.local",
        uploader_user_id: "@uploader2:test.local"
      })

    assert {:ok, row} = DB.lookup_for_scan(id)

    assert row.filename == nil
    assert row.file_hash == nil
    assert row.uploader_user_id == "@uploader2:test.local"
  end

  test "lookup_for_scan/1 returns {:error, :not_found} for an unknown media_id" do
    assert {:error, :not_found} = DB.lookup_for_scan(media_id("nonexistent"))
  end
end
