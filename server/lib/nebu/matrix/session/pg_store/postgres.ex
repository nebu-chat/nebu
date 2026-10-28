defmodule Nebu.Matrix.Session.PgStore.Postgres do
  @moduledoc "PostgreSQL implementation of Nebu.Matrix.Session.PgStore."

  @behaviour Nebu.Matrix.Session.PgStore

  @upsert_since_token_sql """
  INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at)
  VALUES ($1, '', $2, $3, $4)
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET since_token   = EXCLUDED.since_token,
        last_event_id = EXCLUDED.last_event_id,
        updated_at    = EXCLUDED.updated_at
  """

  @upsert_since_token_device_sql """
  INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at)
  VALUES ($1, $2, $3, $4, $5)
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET since_token   = EXCLUDED.since_token,
        last_event_id = EXCLUDED.last_event_id,
        updated_at    = EXCLUDED.updated_at
  """

  # story sync-stream-position (D6 / D8): the era of the row and the previous generation's token are part of the lookup
  @get_since_token_sql """
  SELECT since_token, last_event_id, stream_version, generation, prev_since_token FROM sync_tokens WHERE user_id = $1 AND device_id = ''
  """

  @get_since_token_device_sql """
  SELECT since_token, last_event_id, stream_version, generation, prev_since_token FROM sync_tokens WHERE user_id = $1 AND device_id = $2
  """

  # story sync-token-per-device (D9): the two per-device delivery positions; the token upserts above never touch them
  @get_positions_sql """
  SELECT account_data_pos, cross_signing_pos FROM sync_tokens WHERE user_id = $1 AND device_id = $2
  """

  # story sync-stream-position (D8): the two positions of the generation the client's core token names (current or previous)
  @get_positions_for_token_sql """
  SELECT since_token, account_data_pos, cross_signing_pos, prev_since_token, prev_account_data_pos, prev_cross_signing_pos
  FROM sync_tokens WHERE user_id = $1 AND device_id = $2
  """

  # story sync-stream-position (D12): the token row of an initial sync / fallback, written without a token guard: generation 1, the
  # previous generation forgotten. The two delivery positions are left alone (the HTTP layer advances or rewinds them).
  # story gdpr-erasure-global-data (D5): only for a user whose `deletion_status` is NULL, so an initial sync in flight cannot re-create
  # the rows of an erased user. The `users` row is locked FOR SHARE in the same statement (READ COMMITTED): it conflicts with the
  # erasure's status UPDATE (FOR KEY SHARE would not), so a persist that races the erasure waits for its commit and then sees the new
  # status; persists of active users share the lock and do not block each other. 0 rows inserted = refused.
  @upsert_initial_sync_token_sql """
  INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at, stream_version, generation)
  SELECT $1, $2, $3, $4, $5, 1, 1
  WHERE EXISTS (SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NULL FOR SHARE)
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET since_token            = EXCLUDED.since_token,
        last_event_id          = EXCLUDED.last_event_id,
        updated_at             = EXCLUDED.updated_at,
        stream_version         = 1,
        generation             = 1,
        prev_since_token       = NULL,
        prev_account_data_pos  = NULL,
        prev_cross_signing_pos = NULL
  """

  # story sync-stream-position (D7 / D8): the guarded write of the next generation. The UPDATE takes the row lock itself and, after
  # a concurrent writer committed, re-checks the guard on the new row version (READ COMMITTED): it matches only while the base
  # token is still the row's current or previous token AND (code review cycle 0, MAJOR-1) the row is still at the generation the
  # request was built from ($7, NULL = no check): a concurrent request of the same device that committed first makes this one
  # stale (its cursors were read against rows the winner may have advanced), never a silent loss. It never inserts (a deleted
  # device stays deleted). The base becomes the previous generation, with the two positions it was built from (SET reads the row
  # as it was before this UPDATE).
  @advance_sync_generation_sql """
  UPDATE sync_tokens
     SET since_token            = $4,
         last_event_id          = $5,
         updated_at             = $6,
         stream_version         = 1,
         generation             = generation + 1,
         prev_since_token       = $3,
         prev_account_data_pos  = CASE WHEN since_token = $3 THEN account_data_pos ELSE prev_account_data_pos END,
         prev_cross_signing_pos = CASE WHEN since_token = $3 THEN cross_signing_pos ELSE prev_cross_signing_pos END
   WHERE user_id = $1 AND device_id = $2 AND (since_token = $3 OR prev_since_token = $3)
     AND ($7::bigint IS NULL OR generation = $7::bigint)
  RETURNING generation
  """

  # story sync-stream-position (D3 / D12): ONE statement for the cursor rows of a response, whatever the number of rooms: the
  # device's rows of rooms outside `keep` ($4) are deleted, the given rows ($5..) upserted with the new generation ($3) and their
  # base as the previous values. The two parts touch disjoint rows (every written room is in `keep`).
  @write_sync_cursors_sql """
  WITH dropped AS (
    DELETE FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 AND NOT (room_id = ANY($4::text[]))
  )
  INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker)
  SELECT $1, $2, r.room_id, $3, r.pos, r.class, r.invite_marker, r.prev_pos, r.prev_class, r.prev_invite_marker
  FROM unnest($5::text[], $6::bigint[], $7::text[], $8::bigint[], $9::bigint[], $10::text[], $11::bigint[])
       AS r(room_id, pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker)
  ON CONFLICT (user_id, device_id, room_id) DO UPDATE
    SET gen                = EXCLUDED.gen,
        pos                = EXCLUDED.pos,
        class              = EXCLUDED.class,
        invite_marker      = EXCLUDED.invite_marker,
        prev_pos           = EXCLUDED.prev_pos,
        prev_class         = EXCLUDED.prev_class,
        prev_invite_marker = EXCLUDED.prev_invite_marker
  """

  # GREATEST per column, only for the row that still holds the token of THIS response, never an INSERT
  @advance_positions_sql """
  UPDATE sync_tokens
     SET account_data_pos  = GREATEST(account_data_pos, $4),
         cross_signing_pos = GREATEST(cross_signing_pos, $5)
   WHERE user_id = $1 AND device_id = $2 AND since_token = $3
  """

  # an initial-shaped answer whose account data read failed: account_data_pos back to 0 (plain SET), same token guard
  @rewind_account_data_position_sql """
  UPDATE sync_tokens
     SET account_data_pos  = 0,
         cross_signing_pos = GREATEST(cross_signing_pos, $4)
   WHERE user_id = $1 AND device_id = $2 AND since_token = $3
  """

  @delete_sync_token_sql """
  DELETE FROM sync_tokens WHERE user_id = $1
  """

  @delete_sync_token_device_sql """
  DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = $2
  """

  @delete_session_sql """
  DELETE FROM sessions WHERE user_id = $1
  """

  @delete_session_device_sql """
  DELETE FROM sessions WHERE user_id = $1 AND device_id = $2
  """

  @impl Nebu.Matrix.Session.PgStore
  def persist_since_token(user_id, since_token, last_event_id) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)
    now_ms = Nebu.DB.Helpers.now_ms()

    case Ecto.Adapters.SQL.query(repo, @upsert_since_token_sql, [
           user_id,
           since_token,
           last_event_id,
           now_ms
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Nebu.Matrix.Session.PgStore
  def persist_since_token(user_id, device_id, since_token, last_event_id) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)
    now_ms = Nebu.DB.Helpers.now_ms()

    case Ecto.Adapters.SQL.query(repo, @upsert_since_token_device_sql, [
           user_id,
           device_id,
           since_token,
           last_event_id,
           now_ms
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Nebu.Matrix.Session.PgStore
  def get_since_token(user_id) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    query_token_row(repo, @get_since_token_sql, [user_id])
  end

  @impl Nebu.Matrix.Session.PgStore
  def get_since_token(user_id, device_id) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    query_token_row(repo, @get_since_token_device_sql, [user_id, device_id])
  end

  defp query_token_row(repo, sql, params) do
    case Ecto.Adapters.SQL.query(repo, sql, params) do
      {:ok, %{rows: [[since_token, last_event_id, stream_version, generation, prev_since_token]]}} ->
        {:ok,
         %{
           since_token: since_token,
           last_event_id: last_event_id,
           stream_version: stream_version,
           generation: generation,
           prev_since_token: prev_since_token
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Nebu.Matrix.Session.PgStore
  def get_positions(user_id, device_id) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    case Ecto.Adapters.SQL.query(repo, @get_positions_sql, [user_id, device_id]) do
      {:ok, %{rows: [[account_data_pos, cross_signing_pos]]}} -> {account_data_pos, cross_signing_pos}
      # no row, or a failed read: position 0 = deliver everything again (never miss)
      _ -> {0, 0}
    end
  rescue
    _ -> {0, 0}
  end

  @impl Nebu.Matrix.Session.PgStore
  def get_positions(user_id, device_id, core_token) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    case Ecto.Adapters.SQL.query(repo, @get_positions_for_token_sql, [user_id, device_id]) do
      # the PREVIOUS generation (D8): only for exactly its token; a previous generation written before its positions were known
      # (NULL) is position 0 (deliver again, never miss)
      {:ok, %{rows: [[current, _ad, _cs, prev, prev_ad, prev_cs]]}} when is_binary(core_token) and is_binary(prev) and core_token == prev and core_token != current ->
        {prev_ad || 0, prev_cs || 0}

      {:ok, %{rows: [[_current, account_data_pos, cross_signing_pos, _prev, _prev_ad, _prev_cs]]}} ->
        {account_data_pos, cross_signing_pos}

      # no row, or a failed read: position 0 = deliver everything again (never miss)
      _ ->
        {0, 0}
    end
  rescue
    _ -> {0, 0}
  end

  @doc """
  The ONE write of a `/sync` response (story sync-stream-position, D7 / D8 / D12): the token row and the device's cursor rows in
  ONE transaction. `spec` (story D21 (1)): `mode` (`:initial | :delta`), `new_token`, `last_event_id`, `base_token` (delta: the
  core token the request was built from), `rows` (`%{room_id, pos, class, invite_marker, base}`, `base` = `nil | %{pos, class,
  invite_marker}`: the value the request was built from, stored as the row's previous values), `keep` (the partition rooms) and,
  for a delta, `expected_generation` (the row's generation when the request read it; absent = not checked).

    * `:initial` (an initial sync or a fallback, no base) writes unconditionally: the token row of generation 1 without a previous
      token, and the device's cursor rows become exactly `rows`.
    * `:delta` writes only while the row's current or previous token is still `base_token` and the row is still at
      `expected_generation` (otherwise a concurrent request of the same device committed first, or the device is gone): the next
      generation, the base as the previous token, the given rows, and the device's rows of rooms outside `keep` deleted. A refused
      guard writes nothing and answers `:stale`.

  `:ok | :stale | {:error, reason}` (nothing written on an error). Never raises for a DB failure.
  """
  @impl Nebu.Matrix.Session.PgStore
  def persist_sync_position(user_id, device_id, %{mode: mode} = spec) when mode in [:initial, :delta] do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    result =
      repo.transaction(fn ->
        with {:ok, generation} <- write_token_row(repo, user_id, device_id, spec),
             {:ok, _} <- write_cursor_rows(repo, user_id, device_id, generation, cursor_keep(spec), spec.rows) do
          :ok
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, :stale} -> :stale
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp write_token_row(repo, user_id, device_id, %{mode: :initial} = spec) do
    params = [user_id, device_id, spec.new_token, spec.last_event_id, Nebu.DB.Helpers.now_ms()]

    # story gdpr-erasure-global-data (D5): 0 rows = the user is erased, being erased or has no `users` row: nothing is written and
    # it is not an error (the request is answered as before; the next one falls back to an initial sync, which is skipped as well)
    case query(repo, @upsert_initial_sync_token_sql, params) do
      {:ok, %{num_rows: 0}} -> {:ok, :skipped}
      {:ok, _} -> {:ok, 1}
      {:error, _} = err -> err
    end
  end

  defp write_token_row(repo, user_id, device_id, %{mode: :delta, base_token: base} = spec) when is_binary(base) and base != "" do
    # `expected_generation` absent (a caller of the first contract): the token guard alone
    params = [user_id, device_id, base, spec.new_token, spec.last_event_id, Nebu.DB.Helpers.now_ms(), Map.get(spec, :expected_generation)]

    case query(repo, @advance_sync_generation_sql, params) do
      {:ok, %{rows: [[generation]]}} -> {:ok, generation}
      {:ok, %{rows: []}} -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_token_row(_repo, _user_id, _device_id, %{mode: :delta}), do: {:error, :stale}

  # an initial sync replaces the device's rows: every room outside the new rows goes
  defp cursor_keep(%{mode: :initial, rows: rows}), do: Enum.map(rows, & &1.room_id)
  defp cursor_keep(%{mode: :delta, keep: keep}), do: keep

  defp write_cursor_rows(_repo, _user_id, _device_id, :skipped, _keep, _rows), do: {:ok, :skipped}

  defp write_cursor_rows(repo, user_id, device_id, generation, keep, rows) do
    base = fn row, key -> row.base && Map.fetch!(row.base, key) end

    query(repo, @write_sync_cursors_sql, [
      user_id,
      device_id,
      generation,
      keep,
      Enum.map(rows, & &1.room_id),
      Enum.map(rows, & &1.pos),
      Enum.map(rows, & &1.class),
      Enum.map(rows, & &1.invite_marker),
      Enum.map(rows, &base.(&1, :pos)),
      Enum.map(rows, &base.(&1, :class)),
      Enum.map(rows, &base.(&1, :invite_marker))
    ])
  end

  @impl Nebu.Matrix.Session.PgStore
  def advance_positions(user_id, device_id, since_token, account_data_pos, cross_signing_pos) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    case Ecto.Adapters.SQL.query(repo, @advance_positions_sql, [
           user_id,
           device_id,
           since_token,
           account_data_pos,
           cross_signing_pos
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @impl Nebu.Matrix.Session.PgStore
  def rewind_account_data_position(user_id, device_id, since_token, cross_signing_pos) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    case Ecto.Adapters.SQL.query(repo, @rewind_account_data_position_sql, [user_id, device_id, since_token, cross_signing_pos]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @impl Nebu.Matrix.Session.PgStore
  def invalidate_session(user_id) do
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    result =
      repo.transaction(fn ->
        with {:ok, _} <- query(repo, @delete_sync_token_sql, [user_id]),
             {:ok, _} <- query(repo, @delete_session_sql, [user_id]) do
          :ok
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        # Both DB deletes succeeded — now evict from ETS (atomicity: after TX commit)
        Nebu.Matrix.Session.EtsStore.delete_session(user_id)
        :ok

      {:error, reason} ->
        # Transaction rolled back — do NOT evict from ETS
        {:error, reason}
    end
  end

  @impl Nebu.Matrix.Session.PgStore
  def invalidate_session(user_id, device_id) do
    # AC4 (Story 9-22): Delete both sync_tokens and sessions rows for (user_id, device_id)
    # in a single transaction. Use the configurable :repo_module for testability.
    # ETS eviction is NOT performed here — per-device logout does not invalidate the
    # in-memory user session (another device may still be active).
    repo = Application.get_env(:session_manager, :repo_module, Nebu.Repo)

    result =
      repo.transaction(fn ->
        with {:ok, _} <- query(repo, @delete_sync_token_device_sql, [user_id, device_id]),
             {:ok, _} <- query(repo, @delete_session_device_sql, [user_id, device_id]) do
          :ok
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp query(repo, sql, params) do
    case Ecto.Adapters.SQL.query(repo, sql, params) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end
end
