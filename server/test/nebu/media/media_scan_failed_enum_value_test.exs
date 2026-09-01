defmodule Nebu.Media.ScanFailedEnumValueTest do
  @moduledoc """
  Real-Postgres integration tests proving `'scan_failed'` is genuinely
  usable as a `media_state` value once the 000028 migration has run —
  not merely visible in a static SQL file
  (media-security-admin-control/4a-scan-failed-enum-migration, AC1/AC6).

  Requires a live `Nebu.Repo` connection against a database migrated with
  this story's `000028_media_scan_failed_state.up.sql` — run via
  `make test-integration` / `mix test --include integration`, same
  convention as `state_machine_test.exs` / `media_state_transitions_immutability_test.exs`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Repo

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "sf_enum_#{@run_id}_#{suffix}"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    :ok
  end

  # --- Acceptance Test 5 ------------------------------------------------------

  test "scan_failed is a queryable member of the media_state enum after migration" do
    %Postgrex.Result{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT unnest(enum_range(NULL::media_state))::text",
        []
      )

    values = Enum.map(rows, fn [v] -> v end)

    assert "scan_failed" in values,
           "media_state enum must include 'scan_failed' after 000028 has run, got: #{inspect(values)}"

    original_eight = ~w(reserved quarantined scanning released infected admin_blocked deleted hard_deleted)

    for original <- original_eight do
      assert original in values,
             "original media_state value #{inspect(original)} must still be present after adding scan_failed, got: #{inspect(values)}"
    end

    # `ALTER TYPE ... ADD VALUE` (no explicit BEFORE/AFTER) appends the new
    # value at the end — the original 8 values must keep their relative
    # ordering to each other (no reorder), even if 'scan_failed' lands last.
    original_positions_in_result =
      values
      |> Enum.with_index()
      |> Enum.filter(fn {v, _idx} -> v in original_eight end)
      |> Enum.map(fn {v, _idx} -> v end)

    assert original_positions_in_result == original_eight,
           "the original 8 media_state values must keep their exact relative order, " <>
             "got #{inspect(original_positions_in_result)}"
  end

  # --- Acceptance Test 6 ------------------------------------------------------

  test "a media_files row can be inserted with state = 'scan_failed'" do
    mid = media_id("insertable")

    on_exit(fn ->
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM media_files WHERE media_id = $1", [mid])
    end)

    result =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        INSERT INTO media_files
          (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
           uploader_user_id, uploaded_at, deleted, state)
        VALUES ($1, 'test.local', 'application/octet-stream', 0, 'aeskeyhex', 'noncehex',
                '@tester:test.local', $2, false, 'scan_failed')
        """,
        [mid, System.system_time(:millisecond)]
      )

    assert {:ok, %Postgrex.Result{num_rows: 1}} = result,
           "inserting a media_files row with state = 'scan_failed' must succeed once the value " <>
             "has actually committed (guards against an uncommitted ADD VALUE inside a still-open " <>
             "transaction in some pooled-connection edge case), got: #{inspect(result)}"

    %Postgrex.Result{rows: [[persisted_state]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT state FROM media_files WHERE media_id = $1", [mid])

    assert persisted_state == "scan_failed"
  end
end
