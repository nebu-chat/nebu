defmodule Nebu.Matrix.Search.DB do
  @moduledoc """
  PostgreSQL persistence for full-text search queries.

  Story 11.2: defines the canonical SQL contract for membership-scoped search.
  Story 11.3: wires this module to the SearchMessages gRPC handler.

  Uses raw SQL via Ecto.Adapters.SQL.query/3 — consistent with Nebu.Matrix.Room.DB pattern.
  Membership filter: left_at IS NULL (NOT membership = 'join' — there is no membership column).
  Encrypted rooms (rooms with a m.room.encryption state event) are excluded from search results.
  Story state-writer-redaction (D6): redacted events are excluded (NOT EXISTS a writer-made redaction of the row), and so is every
  `m.replace` edit whose ORIGINAL is redacted (security cycle 1, Kassandra #2: "Remove" on an edited message removes its text from
  search too; the edits themselves stay served elsewhere, the spec does not redact them).
  """

  # Story history-visibility-enforcement (D9): every result is filtered by the ONE visibility fragment of `Nebu.Matrix.Room.DB`
  # for the viewer `$1` (the trusted session user) over ALL rooms of the membership gate (the same `left_at IS NULL` rows), in the
  # same statement; ranking, LIMIT / OFFSET and the exclusions are unchanged, so `next_batch` and the count follow the filtered set.
  @hv_in "WITH hv_in AS (SELECT ARRAY(SELECT room_id FROM room_members WHERE user_id = $1 AND left_at IS NULL) AS rooms, $1::text AS viewer),"

  @sql_search_messages """
  #{@hv_in}
  #{Nebu.Matrix.Room.DB.history_visibility_sql()}
  SELECT
    e.event_id,
    e.room_id,
    e.sender,
    e.event_type,
    e.content,
    e.origin_server_ts,
    ts_rank_cd(e.search_vector, websearch_to_tsquery('pg_catalog.simple', $2)) AS rank
  FROM events e
  #{Nebu.Matrix.Room.DB.history_visibility_join()}
  WHERE
    e.search_vector @@ websearch_to_tsquery('pg_catalog.simple', $2)
    AND e.event_type = 'm.room.message'
    AND e.room_id IN (
      SELECT room_id FROM room_members
      WHERE user_id = $1 AND left_at IS NULL
    )
    AND NOT EXISTS (
      SELECT 1 FROM events enc
      WHERE enc.room_id = e.room_id
        AND enc.event_type = 'm.room.encryption'
        AND (enc.state_key = '' OR enc.state_key IS NULL)
    )
    AND NOT EXISTS (SELECT 1 FROM events r WHERE r.room_id = e.room_id AND r.redacts = e.event_id)
    AND NOT (
      COALESCE(e.content->'m.relates_to'->>'rel_type', '') = 'm.replace'
      AND EXISTS (SELECT 1 FROM events r WHERE r.room_id = e.room_id AND r.redacts = e.content->'m.relates_to'->>'event_id')
    )
    AND #{Nebu.Matrix.Room.DB.history_visibility_predicate()}
  ORDER BY rank DESC, e.origin_server_ts DESC
  LIMIT $3
  OFFSET $4
  """

  # with a room filter the fragment reads only the filtered rooms of the gate (results outside `$5` are never kept)
  @sql_search_messages_with_room_filter """
  WITH hv_in AS (SELECT ARRAY(SELECT room_id FROM room_members WHERE user_id = $1 AND left_at IS NULL AND room_id = ANY($5)) AS rooms, $1::text AS viewer),
  #{Nebu.Matrix.Room.DB.history_visibility_sql()}
  SELECT
    e.event_id,
    e.room_id,
    e.sender,
    e.event_type,
    e.content,
    e.origin_server_ts,
    ts_rank_cd(e.search_vector, websearch_to_tsquery('pg_catalog.simple', $2)) AS rank
  FROM events e
  #{Nebu.Matrix.Room.DB.history_visibility_join()}
  WHERE
    e.search_vector @@ websearch_to_tsquery('pg_catalog.simple', $2)
    AND e.event_type = 'm.room.message'
    AND e.room_id IN (
      SELECT room_id FROM room_members
      WHERE user_id = $1 AND left_at IS NULL
    )
    AND NOT EXISTS (
      SELECT 1 FROM events enc
      WHERE enc.room_id = e.room_id
        AND enc.event_type = 'm.room.encryption'
        AND (enc.state_key = '' OR enc.state_key IS NULL)
    )
    AND NOT EXISTS (SELECT 1 FROM events r WHERE r.room_id = e.room_id AND r.redacts = e.event_id)
    AND NOT (
      COALESCE(e.content->'m.relates_to'->>'rel_type', '') = 'm.replace'
      AND EXISTS (SELECT 1 FROM events r WHERE r.room_id = e.room_id AND r.redacts = e.content->'m.relates_to'->>'event_id')
    )
    AND #{Nebu.Matrix.Room.DB.history_visibility_predicate()}
    AND e.room_id = ANY($5)
  ORDER BY rank DESC, e.origin_server_ts DESC
  LIMIT $3
  OFFSET $4
  """

  @doc """
  Returns the canonical SQL string used for membership-scoped full-text search.

  This function exists primarily to support structural testing (AC2): callers can
  inspect the SQL to verify that membership enforcement happens at the SQL layer
  (a subquery on room_members WHERE left_at IS NULL) and not as an application-layer
  post-filter.
  """
  @spec sql_search_messages() :: String.t()
  def sql_search_messages, do: @sql_search_messages

  @doc """
  Story history-visibility-enforcement (security cycle 1 / 2, INFO-8): the search read under the request statement timeout of
  `Nebu.Matrix.Room.DB.with_read_timeout/1` (one transaction, `SET LOCAL statement_timeout = '2s'`). Not part of a behaviour:
  callers must guard with `function_exported?/3`.
  """
  @spec with_read_timeout((-> term())) :: term()
  def with_read_timeout(fun) when is_function(fun, 0), do: Nebu.Matrix.Room.DB.with_read_timeout(fun)

  @doc """
  Executes a full-text search scoped to rooms where `user_id` is an active member
  (left_at IS NULL). Encrypted rooms (rooms that have an m.room.encryption state event)
  are excluded.

  SECURITY: `user_id` MUST come from the validated session (gRPC metadata or JWT claim),
  never from the request payload. Passing a caller-supplied user_id bypasses all
  membership enforcement and enables cross-room IDOR.

  Parameters:
    - user_id: the Matrix user ID of the searcher (from session, NOT from request body)
    - term: the search term (passed through websearch_to_tsquery)
    - limit: max results to return (caller should clamp to ≤ 100)
    - offset: pagination offset (caller should validate ≥ 0)

  Returns `{:ok, [map()]}` on success where each map has string keys:
    event_id, room_id, sender, event_type, content, origin_server_ts, rank

  Returns `{:error, reason}` on DB error.
  """
  @spec search_messages(String.t(), String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_messages(user_id, term, limit, offset) do
    search_messages(user_id, term, limit, offset, [])
  end

  @doc """
  Executes a full-text search scoped to rooms where `user_id` is an active member,
  optionally filtered to a specific subset of rooms (room_filter).

  When `room_filter` is non-empty, results are further restricted to those rooms.
  The membership subquery still runs — room_filter is an intersection, not a replacement.

  CRITICAL: The membership subquery (WHERE user_id = $1 AND left_at IS NULL) MUST always
  run. room_filter only adds an extra constraint (AND e.room_id = ANY($5)). Never replace
  the membership subquery with the room_filter — that would allow IDOR.

  Parameters:
    - user_id: the Matrix user ID of the searcher (from session, NOT from request body)
    - term: the search term (passed through websearch_to_tsquery)
    - limit: max results to return (caller should clamp to ≤ 100)
    - offset: pagination offset (caller should validate ≥ 0)
    - room_filter: optional list of room_ids to restrict results to ([] = no filter)

  Returns `{:ok, [map()]}` on success where each map has string keys:
    event_id, room_id, sender, event_type, content, origin_server_ts, rank

  Returns `{:error, reason}` on DB error.
  """
  @spec search_messages(String.t(), String.t(), pos_integer(), non_neg_integer(), [String.t()]) ::
          {:ok, [map()]} | {:error, term()}
  def search_messages(user_id, term, limit, offset, room_filter) when is_list(room_filter) do
    {sql, params} =
      if room_filter == [] do
        {@sql_search_messages, [user_id, term, limit, offset]}
      else
        {@sql_search_messages_with_room_filter, [user_id, term, limit, offset, room_filter]}
      end

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, params) do
      {:ok, %{columns: cols, rows: rows}} ->
        results = Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
