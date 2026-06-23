defmodule Nebu.Admin.DB do
  @moduledoc """
  PostgreSQL queries for Admin gRPC RPCs (Story 9.1).

  All queries support the DB dependency-injection pattern used throughout the
  event_dispatcher app — tests override this module via:

      Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)

  This module owns the queries for:
    - User management (list, get, set_is_active, set_system_role)
    - Room management (list, get, archive_room_atomic)
    - Server config (get, upsert)

  PII note: display_name_encrypted (Tier 1) and email_encrypted (Tier 2) are
  AES-256-GCM encrypted in the DB. This module returns the raw encrypted bytes;
  decryption and masking happen in the gRPC server handler.
  """

  # ─── User operations ─────────────────────────────────────────────────────────

  @doc """
  Returns {users_list, next_cursor} for paginated user listing.

  Cursor is the last user_id seen (opaque, lexicographic).
  search is applied as ILIKE on display_name_encrypted (plaintext not available here;
  the server layer must handle search after decryption if needed — at MVP, search is
  passed through as-is and filtering is done post-decryption).

  Returns {list_of_user_maps, next_cursor_string}.
  """
  @spec list_users(pos_integer(), String.t(), String.t()) :: {list(map()), String.t()}
  def list_users(limit, cursor, _search) do
    # Fetch limit+1 rows to detect if there is a next page.
    fetch_limit = limit + 1

    rows =
      if cursor == "" do
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT user_id,
                 display_name_encrypted,
                 display_name_nonce,
                 email_encrypted,
                 email_nonce,
                 email_ephemeral_pub,
                 is_active,
                 system_role,
                 created_at
          FROM users
          ORDER BY user_id
          LIMIT $1
          """,
          [fetch_limit]
        )
      else
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT user_id,
                 display_name_encrypted,
                 display_name_nonce,
                 email_encrypted,
                 email_nonce,
                 email_ephemeral_pub,
                 is_active,
                 system_role,
                 created_at
          FROM users
          WHERE user_id > $1
          ORDER BY user_id
          LIMIT $2
          """,
          [cursor, fetch_limit]
        )
      end

    users = Enum.map(rows.rows, &row_to_user_map/1)
    has_more = length(users) > limit
    page = Enum.take(users, limit)
    next = if has_more, do: List.last(page).user_id, else: ""
    {page, next}
  end

  @doc """
  Returns {:ok, user_map} or {:error, :not_found}.
  """
  @spec get_user(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_user(user_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT user_id,
               display_name_encrypted,
               display_name_nonce,
               email_encrypted,
               email_nonce,
               email_ephemeral_pub,
               is_active,
               system_role,
               created_at
        FROM users
        WHERE user_id = $1
        LIMIT 1
        """,
        [user_id]
      )

    case result.rows do
      [] -> {:error, :not_found}
      [row] -> {:ok, row_to_user_map(row)}
    end
  end

  @doc """
  Sets is_active for user_id. Returns :ok or {:error, :not_found}.
  """
  @spec set_is_active(String.t(), boolean()) :: :ok | {:error, :not_found | term()}
  def set_is_active(user_id, is_active) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "UPDATE users SET is_active = $1 WHERE user_id = $2",
        [is_active, user_id]
      )

    case result.num_rows do
      0 -> {:error, :not_found}
      _ -> :ok
    end
  end

  @doc """
  Updates system_role for user_id. Returns :ok or {:error, :not_found}.
  """
  @spec set_system_role(String.t(), String.t()) :: :ok | {:error, :not_found | term()}
  def set_system_role(user_id, role) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "UPDATE users SET system_role = $1 WHERE user_id = $2",
        [role, user_id]
      )

    case result.num_rows do
      0 -> {:error, :not_found}
      _ -> :ok
    end
  end

  # ─── Room operations ──────────────────────────────────────────────────────────

  @doc """
  Returns {rooms_list, next_cursor} for paginated room listing.

  status_filter: "active" | "archived" | "stale" | "all" | "" (all).

  Story rm2: the filter value is mapped to a FIXED SQL WHERE fragment (never
  string-interpolated — SQL-injection safe). Unknown values fall back to "all".
  "stale" = `status='active'` AND 0 members with `left_at IS NULL` (correlated
  subquery `= 0`), the same subquery used for `member_count`.
  """
  @spec list_rooms(pos_integer(), String.t(), String.t(), String.t()) :: {list(map()), String.t()}
  def list_rooms(limit, cursor, status_filter, _search) do
    fetch_limit = limit + 1

    # Fixed WHERE fragments per filter value; the filter STRING is never interpolated.
    # Each fragment references the empty-members correlated subquery for "stale".
    {status_clause, status_params} =
      case status_filter do
        "active" -> {"status = $S", ["active"]}
        "archived" -> {"status = $S", ["archived"]}
        "stale" ->
          {"status = 'active' AND " <>
             "(SELECT COUNT(*) FROM room_members m WHERE m.room_id = r.room_id AND m.left_at IS NULL) = 0",
           []}

        # "all" / "" / anything unknown → no status restriction (fallback to all).
        _ -> {nil, []}
      end

    cursor_clause = if cursor == "", do: nil, else: "room_id > $C"

    # Compose the WHERE clause from the fixed fragments, then number the placeholders
    # left-to-right ($1, $2, ...) so params line up regardless of which clauses apply.
    where_parts = Enum.reject([cursor_clause, status_clause], &is_nil/1)

    where_sql =
      case where_parts do
        [] -> ""
        parts -> "WHERE " <> Enum.join(parts, " AND ")
      end

    # Param order: cursor (if any), then status params (if any), then the LIMIT.
    base_params =
      (if(cursor == "", do: [], else: [cursor])) ++ status_params ++ [fetch_limit]

    sql =
      number_placeholders("""
      SELECT room_id, name, status,
             (SELECT COUNT(*) FROM room_members WHERE room_id = r.room_id AND left_at IS NULL) AS member_count,
             created_at
      FROM rooms r
      #{where_sql}
      ORDER BY room_id
      LIMIT $L
      """)

    rows = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, base_params)
    rooms = Enum.map(rows.rows, &row_to_room_map/1)
    has_more = length(rooms) > limit
    page = Enum.take(rooms, limit)
    next = if has_more, do: List.last(page).room_id, else: ""
    {page, next}
  end

  # Replaces the named placeholders ($C cursor, $S status, $L limit) with sequential
  # positional placeholders ($1, $2, ...) in left-to-right order. The named tokens are
  # literal constants in the SQL above — no user input is interpolated here.
  defp number_placeholders(sql) do
    sql
    |> String.graphemes()
    |> number_placeholders_acc([], 0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp number_placeholders_acc([], acc, _n), do: acc

  defp number_placeholders_acc(["$", marker | rest], acc, n) when marker in ["C", "S", "L"] do
    number_placeholders_acc(rest, [Integer.to_string(n + 1), "$" | acc], n + 1)
  end

  defp number_placeholders_acc([ch | rest], acc, n) do
    number_placeholders_acc(rest, [ch | acc], n)
  end

  @doc """
  Returns {:ok, room_map} or {:error, :not_found}.
  """
  @spec get_room(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_room(room_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT r.room_id, r.name, r.status,
               (SELECT COUNT(*) FROM room_members m WHERE m.room_id = r.room_id AND m.left_at IS NULL) AS member_count,
               COALESCE(r.max_members, 0),
               COALESCE(r.visibility, 'private'),
               r.created_at,
               COALESCE(r.is_auto_join, false)
        FROM rooms r
        WHERE r.room_id = $1
        LIMIT 1
        """,
        [room_id]
      )

    case result.rows do
      [] -> {:error, :not_found}
      [row] -> {:ok, row_to_room_detail_map(row)}
    end
  end

  @doc """
  Atomically sets rooms.status='archived' using SELECT FOR UPDATE inside an Ecto transaction.
  Returns :ok | {:error, :not_found} | {:error, :already_archived}.

  This is the Story 9.1 AC:4 implementation — Core owns the DB write atomically.
  The previous archive_room/2 handler only terminated the GenServer (pre-9.1 contract).
  """
  @spec archive_room_atomic(String.t()) :: :ok | {:error, :not_found | term()}
  def archive_room_atomic(room_id) do
    result =
      Nebu.Repo.transaction(fn ->
        # SELECT FOR UPDATE to prevent concurrent archive operations
        status_result =
          Ecto.Adapters.SQL.query!(
            Nebu.Repo,
            "SELECT status FROM rooms WHERE room_id = $1 FOR UPDATE",
            [room_id]
          )

        case status_result.rows do
          [] ->
            Nebu.Repo.rollback(:not_found)

          [["archived"]] ->
            # Idempotent — already archived, return ok
            :ok

          [[_other_status]] ->
            Ecto.Adapters.SQL.query!(
              Nebu.Repo,
              "UPDATE rooms SET status = 'archived' WHERE room_id = $1",
              [room_id]
            )

            :ok
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story rm5-personal-guards-optout: get_personal_room_owner/1 ────────────

  @doc """
  Returns the owner `user_id` of the personal self-room `room_id`, if any.

  A personal room is the room recorded in `users.personal_room_id`. The archive
  guard in EventDispatcher.Server.archive_room/2 uses this to reject archival of
  ANY user's personal room server-side (not UI-only — SEC finding from this story).

  The lookup is an exact-match on the indexed `personal_room_id` column with the
  value bound as a parameter (ADR-018 — never interpolated), so it is injection-safe.

  Returns `{:ok, user_id}` when some user owns `room_id` as their personal room.
  Returns `{:error, :not_found}` when no user has this room as their personal room.
  Returns `{:error, reason}` on DB error.
  """
  @spec get_personal_room_owner(String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def get_personal_room_owner(room_id) do
    case Ecto.Adapters.SQL.query(
           Nebu.Repo,
           "SELECT user_id FROM users WHERE personal_room_id = $1",
           [room_id]
         ) do
      {:ok, %{rows: [[user_id] | _]}} -> {:ok, user_id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story admin-auto-join-rooms: update_room_auto_join/2 ───────────────────

  @doc """
  Sets rooms.is_auto_join for `room_id`.

  Returns :ok on success (whether room exists or not — UPDATE may affect 0 rows).
  Returns {:error, reason} on DB error.

  Story admin-auto-join-rooms: called by update_room_settings/2 in EventDispatcher.Server
  when the is_auto_join field is present in UpdateRoomSettingsRequest.
  """
  @spec update_room_auto_join(String.t(), boolean()) :: :ok | {:error, term()}
  def update_room_auto_join(room_id, is_auto_join) do
    case Ecto.Adapters.SQL.query(
           Nebu.Repo,
           "UPDATE rooms SET is_auto_join = $2 WHERE room_id = $1",
           [room_id, is_auto_join]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story rm1-room-visibility: update_room_visibility/2 ──────────────────────

  @doc """
  Sets rooms.visibility for `room_id` to `visibility` ("public" | "private").

  The `visibility` value is bound as a parameter (ADR-018 — never interpolated). The
  caller (EventDispatcher.Server.update_room_settings/2) is responsible for validating
  it against the {"public","private"} allowlist before reaching this query; the
  `rooms_visibility_check` CHECK constraint is a defence-in-depth backstop.

  The `AND visibility != $2` guard makes the write a no-op when the value is unchanged
  (so an unchanged save touches 0 rows and emits no needless audit churn upstream).

  Returns :ok on success (whether the room exists or the value was already set —
  UPDATE may affect 0 rows). Returns {:error, reason} on DB error.

  Story rm1-room-visibility: called by update_room_settings/2 in EventDispatcher.Server
  when the visibility field is a valid "public"/"private" value.
  """
  @spec update_room_visibility(String.t(), String.t()) :: :ok | {:error, term()}
  def update_room_visibility(room_id, visibility) do
    case Ecto.Adapters.SQL.query(
           Nebu.Repo,
           "UPDATE rooms SET visibility = $2 WHERE room_id = $1 AND visibility != $2",
           [room_id, visibility]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Spaces S5: Space operations ───────────────────────────────────────────────

  @doc """
  Returns {spaces_list, next_cursor} for paginated Space listing.

  Mirrors list_rooms/4 but scoped to `room_type = 'm.space'`. Each map carries the
  member count (current room_members) and the child count (distinct, currently-linked
  `m.space.child` edges — an unlinked edge has empty content and is excluded), plus
  the is_auto_join flag for the inline toggle (Spaces S5 AC1).

  status_filter: "active" | "archived" | "" (all). Cursor is the last room_id seen.
  """
  @spec list_spaces(pos_integer(), String.t(), String.t(), String.t()) :: {list(map()), String.t()}
  def list_spaces(limit, cursor, status_filter, _search) do
    fetch_limit = limit + 1

    # The child-count subquery counts distinct m.space.child state_keys whose LATEST
    # content is a non-empty object (an empty {} content is the S2 unlink). It mirrors
    # the get_space_children/1 "drop empty" semantics so the list count matches the
    # detail page. All values are bound parameters (ADR-018, no interpolation).
    base = """
    SELECT r.room_id,
           COALESCE(r.name, '') AS name,
           r.status,
           (SELECT COUNT(*) FROM room_members m
              WHERE m.room_id = r.room_id AND m.left_at IS NULL) AS member_count,
           (SELECT COUNT(*) FROM (
              SELECT DISTINCT ON (e.state_key) e.state_key,
                CASE WHEN jsonb_typeof(e.content) = 'object' THEN e.content::text
                     ELSE (e.content#>>'{}') END AS content_text
              FROM events e
              WHERE e.room_id = r.room_id
                AND e.event_type = 'm.space.child'
                AND e.state_key IS NOT NULL
              ORDER BY e.state_key, e.origin_server_ts DESC
            ) latest
            WHERE latest.content_text IS NOT NULL
              AND latest.content_text <> '{}') AS child_count,
           COALESCE(r.is_auto_join, false) AS is_auto_join
    FROM rooms r
    WHERE r.room_type = 'm.space'
    """

    {sql, params} =
      cond do
        cursor == "" && status_filter == "" ->
          {base <> " ORDER BY r.room_id LIMIT $1", [fetch_limit]}

        cursor == "" && status_filter != "" ->
          {base <> " AND r.status = $1 ORDER BY r.room_id LIMIT $2", [status_filter, fetch_limit]}

        cursor != "" && status_filter == "" ->
          {base <> " AND r.room_id > $1 ORDER BY r.room_id LIMIT $2", [cursor, fetch_limit]}

        true ->
          {base <> " AND r.room_id > $1 AND r.status = $2 ORDER BY r.room_id LIMIT $3",
           [cursor, status_filter, fetch_limit]}
      end

    rows = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params)
    spaces = Enum.map(rows.rows, &row_to_space_map/1)
    has_more = length(spaces) > limit
    page = Enum.take(spaces, limit)
    next = if has_more, do: List.last(page).room_id, else: ""
    {page, next}
  end

  @doc """
  Returns {:ok, space_map} for a single Space (room_type='m.space') or
  {:error, :not_found}. Includes name, topic (latest m.room.topic), status, member
  count, and is_auto_join. Spaces S5 (AC3).
  """
  @spec get_space(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_space(room_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT r.room_id,
               COALESCE(r.name, '') AS name,
               r.status,
               (SELECT COUNT(*) FROM room_members m
                  WHERE m.room_id = r.room_id AND m.left_at IS NULL) AS member_count,
               COALESCE(r.is_auto_join, false) AS is_auto_join,
               (SELECT (e.content #>> '{topic}')
                  FROM events e
                  WHERE e.room_id = r.room_id
                    AND e.event_type = 'm.room.topic'
                    AND e.state_key = ''
                  ORDER BY e.origin_server_ts DESC
                  LIMIT 1) AS topic
        FROM rooms r
        WHERE r.room_id = $1 AND r.room_type = 'm.space'
        LIMIT 1
        """,
        [room_id]
      )

    case result.rows do
      [] -> {:error, :not_found}
      [row] -> {:ok, row_to_space_detail_map(row)}
    end
  end

  # ─── Server config operations ─────────────────────────────────────────────────

  @doc """
  Returns {:ok, config_map} with server config keys.
  MUST NOT include oidc_client_secret (security invariant — it is AES-256-GCM
  encrypted in the DB and only the Go Gateway has the decryption key).
  """
  @spec get_server_config() :: {:ok, map()} | {:error, term()}
  def get_server_config do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT key, value FROM server_config
        WHERE key != 'oidc_client_secret'
        """,
        []
      )

    config =
      result.rows
      |> Enum.map(fn [k, v] -> {k, v} end)
      |> Map.new()

    {:ok, config}
  end

  @doc """
  Upserts one or more server_config key-value pairs.
  Returns :ok.
  """
  @spec upsert_server_config(map()) :: :ok | {:error, term()}
  def upsert_server_config(changes) do
    now = System.system_time(:millisecond)

    Enum.each(changes, fn {key, value} ->
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO server_config (key, value, set_at)
        VALUES ($1, $2, $3)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
        """,
        [key, to_string(value), now]
      )
    end)

    # story oidc-claim-boot-cache: this is the SINGLE central write point for
    # server_config.oidc_user_id_claim (claim_mapping_live, bootstrap save, and the
    # gRPC SetServerConfig path all route through here). When the change touches
    # that key, invalidate the node-local claim cache and broadcast across the
    # cluster (ADR-020) through the Matrix Public API — never reaching into the
    # Matrix-domain cache module directly. A change that does not touch the key is
    # a no-op (no stale-claim risk, no needless re-read).
    if Map.has_key?(stringify_keys(changes), "oidc_user_id_claim") do
      Nebu.Matrix.invalidate_oidc_claim_cache()
    end

    :ok
  end

  # changes keys arrive as either atoms (admin LiveView) or strings (gRPC path);
  # normalise to strings so the oidc_user_id_claim presence check is robust.
  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # ─── Room member operations (Story 9.18) ─────────────────────────────────────

  @doc """
  Returns {:ok, member_rows} for the given room_id.

  Queries room_members LEFT JOIN users to fetch all current (left_at IS NULL)
  members for the room, ordered by joined_at ASC.

  LEFT JOIN (not INNER): an admin can add a member who has no `users` row yet —
  e.g. a user added to a room before their first OIDC login provisions them. An
  INNER JOIN silently dropped such members from the admin member list (they were
  invisible until first login). The LEFT JOIN keeps them; display_name_encrypted/
  _nonce are then nil, which decrypt_display_name/1 (server.ex) maps to "".

  Each row is a map with keys:
    :user_id, :display_name_encrypted, :display_name_nonce, :joined_at

  Returns {:ok, []} when the room has no current members — not an error.

  PII note: display_name_encrypted is Tier 1 PII. Decryption is performed in the
  gRPC handler (server.ex), not here. This module returns raw encrypted bytes.
  """
  @spec list_room_members(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_room_members(room_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT rm.user_id, u.display_name_encrypted, u.display_name_nonce,
               rm.joined_at
        FROM room_members rm
        LEFT JOIN users u ON u.user_id = rm.user_id
        WHERE rm.room_id = $1 AND rm.left_at IS NULL
        ORDER BY rm.joined_at ASC
        """,
        [room_id]
      )

    rows =
      Enum.map(result.rows, fn [user_id, dn_enc, dn_nonce, joined_at] ->
        %{
          user_id: user_id,
          display_name_encrypted: dn_enc,
          display_name_nonce: dn_nonce,
          joined_at: joined_at
        }
      end)

    {:ok, rows}
  end

  # ─── Private helpers ──────────────────────────────────────────────────────────

  defp row_to_user_map([user_id, display_name_encrypted, display_name_nonce, email_encrypted, email_nonce, email_ephemeral_pub, is_active, system_role, created_at]) do
    %{
      user_id: user_id,
      display_name_encrypted: display_name_encrypted,
      display_name_nonce: display_name_nonce,
      email_encrypted: email_encrypted,
      email_nonce: email_nonce,
      email_ephemeral_pub: email_ephemeral_pub,
      is_active: is_active,
      system_role: system_role || "user",
      created_at: created_at || 0
    }
  end

  defp row_to_room_map([room_id, name, status, member_count, created_at]) do
    raw_status = status || "active"
    count = member_count || 0

    %{
      room_id: room_id,
      name: name || "",
      # Story rm2: effective status — an "active" room with 0 active members is "stale".
      status: room_effective_status(raw_status, count),
      member_count: count,
      created_at: created_at || 0
    }
  end

  @doc """
  Story rm2 — computes a room's EFFECTIVE status from its raw `status` and active
  `member_count`. An `"active"` room with 0 active members is `"stale"`; otherwise the
  raw status is returned unchanged (`"active"` / `"archived"`).

  Pure (no DB) — also the test seam for the row→map effective-status mapping (AC2).
  """
  @spec room_effective_status(String.t(), non_neg_integer()) :: String.t()
  def room_effective_status("active", 0), do: "stale"
  def room_effective_status(status, _member_count), do: status

  defp row_to_room_detail_map([room_id, name, status, member_count, max_members, visibility, created_at, is_auto_join]) do
    count = member_count || 0

    %{
      room_id: room_id,
      name: name || "",
      # Story rm2: effective status — stale = active + 0 active members.
      status: room_effective_status(status || "active", count),
      member_count: count,
      max_members: max_members || 0,
      visibility: visibility || "private",
      created_at: created_at || 0,
      is_auto_join: is_auto_join || false
    }
  end

  # Legacy 7-column variant — kept for backward compatibility with existing tests
  # that seed a 7-column row. Returns is_auto_join: false. (Grouped with the 8-column
  # clause above per Elixir's same-name/arity grouping rule.)
  defp row_to_room_detail_map([room_id, name, status, member_count, max_members, visibility, created_at]) do
    count = member_count || 0

    %{
      room_id: room_id,
      name: name || "",
      status: room_effective_status(status || "active", count),
      member_count: count,
      max_members: max_members || 0,
      visibility: visibility || "private",
      created_at: created_at || 0,
      is_auto_join: false
    }
  end

  defp row_to_space_map([room_id, name, status, member_count, child_count, is_auto_join]) do
    %{
      room_id: room_id,
      name: name || "",
      status: status || "active",
      member_count: member_count || 0,
      child_count: child_count || 0,
      is_auto_join: is_auto_join || false
    }
  end

  defp row_to_space_detail_map([room_id, name, status, member_count, is_auto_join, topic]) do
    %{
      room_id: room_id,
      name: name || "",
      status: status || "active",
      member_count: member_count || 0,
      is_auto_join: is_auto_join || false,
      topic: topic || ""
    }
  end

end
