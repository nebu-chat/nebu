defmodule Nebu.Media.FilesStateBackfillTest do
  @moduledoc """
  Real-Postgres integration tests for the `media_files` state/storage_key
  backfill (ADR-031 / migration `000022_media_state_machine_foundation`, AC5–AC6).

  Requires a live `Nebu.Repo` connection — run via
  `make test-integration` / `mix test --include integration` (see
  `server/test/nebu/admin/search_users_db_test.exs` for the no-Sandbox
  convention: real connection, unique per-run ids, manual `on_exit` cleanup,
  `async: false`).

  These tests insert a "pre-migration-shaped" `media_files` row — i.e. only
  the 9 pre-existing columns (`media_id`, `server_name`, `content_type`,
  `file_size`, `aes_key_hex`, `nonce_hex`, `uploader_user_id`, `uploaded_at`,
  `deleted`), exactly as `Nebu.Media.DB.insert/1` does today — then replay the
  exact backfill statements the migration applies, to prove the backfill
  logic produces the state/storage_key the epic requires. This is
  necessarily how a one-time migration-time backfill is validated at
  integration level: the migration's `UPDATE ... WHERE deleted = true` /
  `UPDATE ... WHERE storage_key IS NULL` statements are idempotent and can be
  re-run against freshly-seeded rows to assert their effect.

  RED by design: the `state` / `storage_key` columns (and the `media_state`
  ENUM) do not exist until migration `000022_media_state_machine_foundation`
  lands. Every test here fails with a `Postgrex.Error` (undefined_column /
  undefined_object for the ENUM type) until that migration is applied to the
  test database.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Media.DB
  alias Nebu.Repo

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "mf_backfill_#{@run_id}_#{suffix}"

  defp insert_pre_migration_row!(media_id, deleted?) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted)
      VALUES ($1, 'test.local', 'application/octet-stream', 0, 'aeskeyhex', 'noncehex',
              '@tester:test.local', $2, $3)
      """,
      [media_id, System.system_time(:millisecond), deleted?]
    )
  end

  defp run_backfill!(media_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE media_files SET state = 'deleted' WHERE deleted = true AND media_id = $1",
      [media_id]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE media_files SET storage_key = media_id WHERE storage_key IS NULL AND media_id = $1",
      [media_id]
    )
  end

  defp fetch_state_and_storage_key!(media_id) do
    %Postgrex.Result{rows: [[state, storage_key]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT state, storage_key FROM media_files WHERE media_id = $1",
        [media_id]
      )

    {state, storage_key}
  end

  defp cleanup!(media_id) do
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM media_files WHERE media_id = $1", [media_id])
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    :ok
  end

  test "a pre-migration-shaped media_files row (deleted=false) backfills to state='released'" do
    mid = media_id("released")
    insert_pre_migration_row!(mid, false)
    on_exit(fn -> cleanup!(mid) end)

    run_backfill!(mid)

    {state, _storage_key} = fetch_state_and_storage_key!(mid)
    assert state == "released"
  end

  test "a pre-migration-shaped media_files row (deleted=true) backfills to state='deleted'" do
    mid = media_id("deleted")
    insert_pre_migration_row!(mid, true)
    on_exit(fn -> cleanup!(mid) end)

    run_backfill!(mid)

    {state, _storage_key} = fetch_state_and_storage_key!(mid)
    assert state == "deleted"
  end

  test "a pre-migration-shaped media_files row backfills storage_key to its own media_id" do
    mid = media_id("storage_key")
    insert_pre_migration_row!(mid, false)
    on_exit(fn -> cleanup!(mid) end)

    run_backfill!(mid)

    {_state, storage_key} = fetch_state_and_storage_key!(mid)
    assert storage_key == mid
  end

  test "a fresh INSERT into media_files after the migration still succeeds without specifying the new columns" do
    mid = media_id("fresh_insert")
    on_exit(fn -> cleanup!(mid) end)

    row = %{
      media_id: mid,
      server_name: "test.local",
      content_type: "application/octet-stream",
      file_size: 0,
      aes_key_hex: "aeskeyhex",
      nonce_hex: "noncehex",
      uploader_user_id: "@tester:test.local",
      uploaded_at: System.system_time(:millisecond)
    }

    assert :ok = DB.insert(row)

    {state, storage_key} = fetch_state_and_storage_key!(mid)
    assert state == "released"
    assert storage_key == nil
  end
end
