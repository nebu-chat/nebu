defmodule Nebu.Matrix.RoomAccountDataStore do
  @moduledoc """
  Durable, PostgreSQL-backed store for per-user ROOM-scoped Matrix account data
  (story `room-account-data-and-read-markers`, epic matrix-spec-gaps).

  Backs:

      PUT/GET /_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}
      POST    /_matrix/client/v3/rooms/{roomId}/read_markers      (`m.fully_read`)

  and `rooms.join.<roomId>.account_data.events` of `GET /_matrix/client/v3/sync`.
  Reused by story `room-tags` (`m.tag`, via the atomic `update/4`): the store is type-agnostic.

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018). PostgreSQL-backed
  so a PUT on node A is visible to `/sync` on node B (ADR-020) and survives restarts.

  ## Opacity (ADR-011)

  `content_json` holds the value VERBATIM (the exact bytes the client PUT, TEXT not
  jsonb). The server never interprets it (only `/sync` decodes it to shape the
  envelope).

  ## Change position (per-DEVICE incremental `/sync`)

  Every insert/update stamps the row with `stream_pos` from a global sequence. `/sync`
  delivers the rows of the user with `stream_pos > since_pos`, where `since_pos` is
  carried in the `since`/`next_batch` token (see `Nebu.Web.Router.Protected`). There is
  no consume-once flag, so any number of devices each receive every change exactly once.
  Writers take a per-user advisory lock before drawing the position, so for one user
  the position order equals the commit order: a reader that observed position N can
  never later see a smaller position appear.

  ## Limits

    * `max_bytes/0` — one body (default 65_536; config `:nebu, :room_account_data_max_bytes`,
      env `NEBU_ROOM_ACCOUNT_DATA_MAX_BYTES`)
    * `max_rows_per_user/0` — rows per user (default 1_000; config
      `:nebu, :room_account_data_max_rows_per_user`, env
      `NEBU_ROOM_ACCOUNT_DATA_MAX_ROWS_PER_USER`). Overwriting an existing row is always
      allowed at the cap.
    * `max_total_bytes/0` — sum of the stored `content_json` bytes per user (default
      4_194_304; config `:nebu, :room_account_data_max_total_bytes`, env
      `NEBU_ROOM_ACCOUNT_DATA_MAX_TOTAL_BYTES`). An overwrite counts its NEW size minus
      the OLD size; a write that does not increase the total is always allowed.

  The server-managed type `m.fully_read` (written only by `POST /read_markers`, tiny,
  one row per room) is EXEMPT from both the row and the total cap and is not counted
  against them, so a user at the cap can still advance read markers.
  """

  @default_max_bytes 65_536
  @default_max_rows 1_000
  @default_max_total_bytes 4_194_304
  @exempt_type "m.fully_read"

  @doc "Maximum size in bytes of one account-data content body."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:nebu, :room_account_data_max_bytes, @default_max_bytes)

  @doc "Maximum number of room-account-data rows one user may store."
  @spec max_rows_per_user() :: pos_integer()
  def max_rows_per_user,
    do: Application.get_env(:nebu, :room_account_data_max_rows_per_user, @default_max_rows)

  @doc "Maximum total bytes of room-account-data content one user may store."
  @spec max_total_bytes() :: pos_integer()
  def max_total_bytes,
    do: Application.get_env(:nebu, :room_account_data_max_total_bytes, @default_max_total_bytes)

  @doc """
  Stores `json_body` (opaque, pre-validated JSON object text) for `{user, room, type}`.

  Upsert; draws a fresh `stream_pos` on every call. Returns `:ok`,
  `{:error, :limit_exceeded}` when the per-user row cap would be exceeded by a NEW row or the
  total-bytes cap would be exceeded by the write (`m.fully_read` is exempt from both),
  or `{:error, reason}` on a DB failure. Wakes long-polling `/sync` requests of the user.
  """
  @spec put(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :limit_exceeded | term()}
  def put(user_id, room_id, type, json_body)
      when is_binary(user_id) and is_binary(room_id) and is_binary(type) and is_binary(json_body) do
    result =
      Nebu.Repo.transaction(fn ->
        lock_user(user_id)
        upsert!(user_id, room_id, type, json_body)
      end)

    finish_write(result, user_id, room_id)
  end

  @doc """
  Atomic read-modify-write of ONE `{user, room, type}` event (story `room-tags`).

  In ONE transaction under the same per-user advisory lock as `put/4`: reads the current
  content (`nil` when no row exists), calls `fun.(current_json_or_nil)` and writes the result
  with exactly the cap logic of `put/4` (row cap only for a NEW row, total-bytes cap, a fresh
  `stream_pos`), then wakes long-polling `/sync` requests. Concurrent `update/4` calls of one
  user serialise, so none is lost (no get -> merge -> put outside the lock).

  `fun` runs INSIDE the transaction holding the lock: keep it pure and fast. It returns

    * `{:ok, new_json}` — store `new_json` (opaque, pre-validated JSON text);
    * `:unchanged` — write nothing (no row is created, no `stream_pos` drawn, no wake-up).

  Returns `:ok`, `{:error, :too_large}` when `new_json` exceeds `max_bytes/0` AND is larger than the
  current content (a shrinking write is always allowed),
  `{:error, :limit_exceeded}` (see `put/4`) or `{:error, reason}` on a DB failure.
  """
  @spec update(String.t(), String.t(), String.t(), (String.t() | nil -> {:ok, String.t()} | :unchanged)) ::
          :ok | {:error, :limit_exceeded | :too_large | term()}
  def update(user_id, room_id, type, fun)
      when is_binary(user_id) and is_binary(room_id) and is_binary(type) and is_function(fun, 1) do
    result =
      Nebu.Repo.transaction(fn ->
        lock_user(user_id)

        current =
          case query(
                 "SELECT content_json FROM user_room_account_data WHERE user_id = $1 AND room_id = $2 AND type = $3",
                 [user_id, room_id, type]
               ) do
            {:ok, %{rows: [[body]]}} -> body
            {:ok, %{rows: []}} -> nil
            {:error, reason} -> Nebu.Repo.rollback(reason)
          end

        case fun.(current) do
          {:ok, new_json} when is_binary(new_json) ->
            # The per-event cap only applies when the event GROWS: an operator who lowered
            # the cap must still be able to shrink (e.g. delete a tag from) an oversize event.
            if byte_size(new_json) > max_bytes() and byte_size(new_json) > byte_size(current || ""),
              do: Nebu.Repo.rollback(:too_large),
              else: upsert!(user_id, room_id, type, new_json)

          :unchanged ->
            :unchanged
        end
      end)

    case result do
      {:ok, :unchanged} -> :ok
      other -> finish_write(other, user_id, room_id)
    end
  end

  defp finish_write(result, user_id, room_id) do
    case result do
      {:ok, :ok} ->
        notify_sync(user_id, room_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_user(user_id) do
    {:ok, _} = query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [user_id])
    :ok
  end

  # Upsert under the caller's transaction + advisory lock. Returns :ok or rolls back with
  # `:limit_exceeded` / the DB error.
  defp upsert!(user_id, room_id, type, json_body) do
    now = System.system_time(:millisecond)

    # The WHERE guard admits the write when the type is exempt ($7), or when
    #   (the row already exists (overwrite) OR the user is still below the row cap)
    #   AND (the write does not grow the total OR the new total stays within the
    #        byte cap; an overwrite counts NEW minus OLD size).
    # 0 returned rows => a cap refused the write. The sums run under the advisory
    # lock, so concurrent writers cannot overshoot. `m.fully_read` rows are not counted.
    case query(
           """
           INSERT INTO user_room_account_data
             (user_id, room_id, type, content_json, created_at, updated_at)
           SELECT $1::text, $2::text, $3::text, $4::text, $5::bigint, $5::bigint
           WHERE $7::boolean
              OR ((EXISTS (SELECT 1 FROM user_room_account_data
                           WHERE user_id = $1 AND room_id = $2 AND type = $3)
                   OR (SELECT count(*) FROM user_room_account_data
                       WHERE user_id = $1 AND type <> '#{@exempt_type}') < $6::bigint)
                  AND (octet_length($4::text) <=
                         COALESCE((SELECT octet_length(content_json) FROM user_room_account_data
                                   WHERE user_id = $1 AND room_id = $2 AND type = $3), 0)
                       OR (SELECT COALESCE(SUM(octet_length(content_json)), 0)
                           FROM user_room_account_data
                           WHERE user_id = $1 AND type <> '#{@exempt_type}')
                          - COALESCE((SELECT octet_length(content_json) FROM user_room_account_data
                                      WHERE user_id = $1 AND room_id = $2 AND type = $3), 0)
                          + octet_length($4::text) <= $8::bigint))
           ON CONFLICT (user_id, room_id, type) DO UPDATE
             SET content_json = EXCLUDED.content_json,
                 stream_pos   = nextval('user_room_account_data_pos_seq'),
                 updated_at   = EXCLUDED.updated_at
           RETURNING stream_pos
           """,
           [user_id, room_id, type, json_body, now, max_rows_per_user(), type == @exempt_type, max_total_bytes()]
         ) do
      {:ok, %{rows: [[_pos]]}} -> :ok
      {:ok, %{rows: []}} -> Nebu.Repo.rollback(:limit_exceeded)
      {:error, reason} -> Nebu.Repo.rollback(reason)
    end
  end

  @doc "Returns `{:ok, json_body}` or `:error` when nothing is stored for `{user, room, type}`."
  @spec get(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def get(user_id, room_id, type) do
    case safe_query(
           "SELECT content_json FROM user_room_account_data WHERE user_id = $1 AND room_id = $2 AND type = $3",
           [user_id, room_id, type]
         ) do
      {:ok, %{rows: [[body]]}} -> {:ok, body}
      _ -> :error
    end
  end

  @doc "`true` when `event_id` exists in `room_id` (used to validate `m.fully_read` targets)."
  @spec event_in_room?(String.t(), String.t()) :: boolean()
  def event_in_room?(room_id, event_id) do
    case safe_query("SELECT 1 FROM events WHERE event_id = $1 AND room_id = $2", [event_id, room_id]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  @doc """
  `true` when the user has at least one row with `stream_pos > since_pos`. Cheap pre-check
  so a long-poll `/sync` returns immediately instead of waiting for a wake-up it missed.
  """
  @spec pending?(String.t(), non_neg_integer()) :: boolean()
  def pending?(user_id, since_pos) do
    case safe_query(
           "SELECT 1 FROM user_room_account_data WHERE user_id = $1 AND stream_pos > $2 LIMIT 1",
           [user_id, since_pos]
         ) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  @doc """
  Room account data for `/sync`, in ONE statement (one snapshot).

  Returns `{latest_pos, entries}` where `latest_pos` is the user's highest `stream_pos`
  (the position to embed in the new `next_batch`) and `entries` is
  `[{room_id, type, content_map}]` for rooms the user is currently joined to, containing
  rows with `stream_pos > since_pos` plus ALL rows of `full_rooms` (rooms newly joined in
  this sync response, which the client has never seen). `since_pos` 0 delivers everything.

  Never raises (DB down / not started → `{since_pos, []}`).
  """
  @spec list_for_sync(String.t(), non_neg_integer(), [String.t()]) ::
          {non_neg_integer(), [{String.t(), String.t(), map()}]}
  def list_for_sync(user_id, since_pos, full_rooms \\ []) do
    sql = """
    WITH latest AS (
      SELECT COALESCE(MAX(stream_pos), 0) AS pos FROM user_room_account_data WHERE user_id = $1
    )
    SELECT l.pos, r.room_id, r.type, r.content_json
    FROM latest l
    LEFT JOIN user_room_account_data r
      ON r.user_id = $1
     AND (r.stream_pos > $2 OR r.room_id = ANY($3::text[]))
     AND r.room_id IN (SELECT room_id FROM room_members WHERE user_id = $1 AND left_at IS NULL)
    ORDER BY r.stream_pos
    """

    case safe_query(sql, [user_id, since_pos, full_rooms]) do
      {:ok, %{rows: rows}} ->
        latest = rows |> List.first() |> Kernel.||([0]) |> hd()

        entries =
          for [_pos, room_id, type, json] <- rows, is_binary(room_id) do
            {room_id, type, decode(json)}
          end

        # since_pos above the user's real maximum (forged, or stale after the rows were
        # removed) is clamped to `latest`, so it cannot suppress later writes forever.
        {latest, entries}

      _ ->
        {since_pos, []}
    end
  end

  # Wake long-polling /sync requests of this user (they join the "user:<id>" :pg group
  # in do_incremental_sync). The woken sync re-reads account data after returning.
  defp notify_sync(user_id, room_id) do
    for pid <- :pg.get_members("user:#{user_id}"), do: send(pid, {:account_data_changed, room_id})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)

  defp safe_query(sql, params) do
    if Process.whereis(Nebu.Repo) do
      query(sql, params)
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  end
end
