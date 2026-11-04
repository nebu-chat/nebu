defmodule Nebu.Matrix.RoomKeyBackupStore do
  @moduledoc """
  Durable, PostgreSQL-backed store for the Matrix CS v1.18 "Server-side key backups"
  (story server-side-key-backup, epic e2ee-client-support).

  Backs `/_matrix/client/v3/room_keys/version[/{version}]` and `/room_keys/keys[/{roomId}[/{sessionId}]]`
  (see `Nebu.Matrix.HttpRoomKeys` for the HTTP side: request validation, status codes, response shapes).

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018, no Ecto schema, no Repository/Service layer).
  The state lives ONLY in `room_key_backup_versions` and `room_key_backup_sessions` (ADR-020: a request may land on any
  node): `count` and `etag` are computed from those rows on every call, nothing is cached in a process.

  ## Opacity (ADR-011)

  `auth_data` and the `session_data` blobs are stored as JSON text and never decrypted, interpreted or logged; the
  server only checks well-formedness and size (in the handler). ADR-011 stays: storing a backup enables no E2EE room.

  ## Versions

  A version is a per-user counter (decimal string, the first is `"1"`, strictly increasing). The newest non-deleted
  version is the CURRENT one. A deleted version stays as a soft-delete MARKER (`deleted_at` set, no `algorithm` /
  `auth_data`), so a number is never reused and a repeated DELETE is idempotent. At most 10 live versions per user.
  Every statement is scoped by `user_id`: version numbers of different users coincide, and another user's version
  looks non-existent.

  ## Writes

  Every write runs in one transaction under the per-user advisory lock
  `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))` (the key of `AccountDataStore.put/3`,
  `CrossSigningKeyStore.put_keys/2` and the GDPR erasure): the version number, the quotas and the merge are decided on
  the locked state, and the erasure serialises with a write in flight. The creating writers (`create_version/3`,
  `put_sessions/3`) refuse a user whose erasure is under way (`{:error, :user_erased}`).

  The lock is a TRY-lock (`pg_try_advisory_xact_lock`): a busy lock is `{:error, :lock_busy}` AT ONCE (answered `429 M_LIMIT_EXCEEDED`), no
  waiter ever holds a pooled database connection, and the request stores nothing. Reads take no lock. `SET LOCAL lock_timeout`
  (default 2000 ms, `config :nebu, :room_keys_lock_timeout_ms`) stays only as the safety net of ROW locks: a writer that cannot get a row
  in time is `{:error, :lock_timeout}` (SQLSTATE 55P03, answered 429 as well).

  ## Quotas (all decided under the lock; a refused request stores nothing)

    * 10 live versions per user, and at most 1000 version rows per user INCLUDING the soft-delete markers
      (`:room_keys_max_version_rows_per_user`): a create / delete loop cannot grow the table without limit;
    * 100 000 sessions per version (`:room_keys_max_sessions_per_version`);
    * an aggregate byte budget per user over all live versions: for every stored session `octet_length(room_id) + octet_length(session_id) + 128`
      plus the compact JSON bytes of its `session_data`, plus the `auth_data` of every live version, default 64 MiB (`:room_keys_max_bytes_per_user`). It is checked AFTER the
      write inside the transaction (so a replacement counts only its size delta) and rolled back when exceeded; a delete
      frees its bytes. The check sums the user's rows (bounded by the budget itself).

  ## Merge rule of a re-uploaded session (spec order)

  1. `is_verified` differs: the verified one is kept;
  2. else the lower `first_message_index`;
  3. if equal the lower `forwarded_count`;
  4. a full tie keeps the stored session.

  A replace does not change the `count`; the `etag` (a per-version counter) changes whenever the stored set changes.

  Nothing here raises for an expected condition: every function returns `{:ok, _}` / `:ok` or `{:error, reason}`; a
  database fault is `{:error, exception}` (the caller logs its KIND only: a Postgrex message can quote row data).
  """

  @max_versions 10
  @default_max_sessions 100_000
  # aggregate bytes per user (64 MiB since cycle 2), version rows per user incl. markers, and the lock timeout of the writers
  @default_max_bytes 64 * 1024 * 1024
  @row_overhead_bytes 128
  @default_max_version_rows 1000
  @default_lock_timeout_ms 2000

  @type scope :: :all | {:room, String.t()} | {:session, String.t(), String.t()}
  @type entry :: %{
          room_id: String.t(),
          session_id: String.t(),
          first_message_index: non_neg_integer(),
          forwarded_count: non_neg_integer(),
          is_verified: boolean(),
          session_data: map()
        }

  @doc "The quota of live backup versions per user."
  @spec max_versions() :: pos_integer()
  def max_versions, do: @max_versions

  @doc """
  Creates a new backup version for `user_id` and returns its number (a decimal string).

  `{:error, :version_quota}` when the user already has 10 live versions (nothing is deleted silently),
  `{:error, :user_erased}` for a user whose erasure is under way.
  """
  @spec create_version(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, :version_quota | :user_erased | term()}
  def create_version(user_id, algorithm, auth_data) when is_binary(user_id) and is_binary(algorithm) and is_map(auth_data) do
    now = now_ms()

    transact(fn ->
      with {:ok, _} <- lock_user(user_id),
           :ok <- ensure_not_erased(user_id),
           {:ok, %{rows: [[rows]]}} <- query("SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1", [user_id]),
           :ok <- if(rows >= max_version_rows(), do: {:error, :version_rows_quota}, else: :ok),
           {:ok, %{rows: [[live]]}} <-
             query("SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL", [user_id]),
           :ok <- if(live >= @max_versions, do: {:error, :version_quota}, else: :ok),
           # the next number counts the soft-delete markers too: a number is never reused
           {:ok, %{rows: [[version]]}} <-
             query(
               """
               INSERT INTO room_key_backup_versions (user_id, version, algorithm, auth_data, etag, created_at, updated_at)
               SELECT $1::text, COALESCE(max(version), 0) + 1, $2::text, $3::text, 0, $4::bigint, $4::bigint
               FROM room_key_backup_versions
               WHERE user_id = $1::text
               RETURNING version
               """,
               [user_id, algorithm, Jason.encode!(auth_data), now]
             ),
           :ok <- ensure_byte_budget(user_id) do
        {:ok, Integer.to_string(version)}
      end
    end)
  end

  @doc """
  Reads a live version: `:current` (the newest non-deleted one) or a version number. `{:ok, info}` with
  `algorithm`, `auth_data` (decoded), `count`, `etag` and `version`, or `{:error, :not_found}` (unknown, deleted,
  malformed or another user's version, or no backup at all). Count and etag come from ONE statement (one snapshot).
  """
  @spec get_version(String.t(), :current | String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_version(user_id, :current) when is_binary(user_id), do: read_version(user_id, nil)

  def get_version(user_id, version) when is_binary(user_id) and is_binary(version) do
    case parse_version(version) do
      {:ok, v} -> read_version(user_id, v)
      :error -> {:error, :not_found}
    end
  end

  defp read_version(user_id, version) do
    sql = """
    SELECT v.version, v.algorithm, v.auth_data, v.etag,
           (SELECT count(*) FROM room_key_backup_sessions s WHERE s.user_id = v.user_id AND s.version = v.version)
    FROM room_key_backup_versions v
    WHERE v.user_id = $1 AND v.deleted_at IS NULL AND ($2::bigint IS NULL OR v.version = $2::bigint)
    ORDER BY v.version DESC
    LIMIT 1
    """

    case query(sql, [user_id, version]) do
      {:ok, %{rows: [[v, algorithm, auth_data, etag, count]]}} ->
        with {:ok, auth_data} <- Jason.decode(auth_data) do
          {:ok, %{version: Integer.to_string(v), algorithm: algorithm, auth_data: auth_data, count: count, etag: Integer.to_string(etag)}}
        end

      {:ok, _} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Replaces the `auth_data` of a live version (any live version, not only the current one). The algorithm cannot change
  (`{:error, :algorithm_mismatch}`); `{:error, :not_found}` for a version that is not live.
  """
  @spec update_version(String.t(), String.t(), String.t(), map()) :: :ok | {:error, :not_found | :algorithm_mismatch | term()}
  def update_version(user_id, version, algorithm, auth_data) when is_binary(user_id) and is_binary(version) do
    with {:ok, v} <- version_or_not_found(version),
         {:ok, :ok} <-
           transact(fn ->
             with {:ok, _} <- lock_user(user_id),
                  {:ok, %{rows: rows}} <-
                    query(
                      "SELECT algorithm FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND deleted_at IS NULL FOR UPDATE",
                      [user_id, v]
                    ) do
               case rows do
                 [[^algorithm]] ->
                   with {:ok, _} <-
                          query(
                            "UPDATE room_key_backup_versions SET auth_data = $3, updated_at = $4 WHERE user_id = $1 AND version = $2",
                            [user_id, v, Jason.encode!(auth_data), now_ms()]
                          ),
                        :ok <- ensure_byte_budget(user_id),
                        do: {:ok, :ok}

                 [[_other]] ->
                   {:error, :algorithm_mismatch}

                 [] ->
                   {:error, :not_found}
               end
             end
           end) do
      :ok
    end
  end

  @doc """
  Deletes a version and all its sessions, leaving the soft-delete marker. Idempotent: a version that was deleted before is `:ok`;
  `{:error, :not_found}` only for a number that never existed (for this user).
  """
  @spec delete_version(String.t(), String.t()) :: :ok | {:error, :not_found | term()}
  def delete_version(user_id, version) when is_binary(user_id) and is_binary(version) do
    with {:ok, v} <- version_or_not_found(version),
         {:ok, :ok} <-
           transact(fn ->
             with {:ok, _} <- lock_user(user_id),
                  {:ok, %{rows: rows}} <-
                    query("SELECT deleted_at FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 FOR UPDATE", [user_id, v]) do
               case rows do
                 [] ->
                   {:error, :not_found}

                 [[nil]] ->
                   # the sessions first: the foreign key has no cascade
                   with {:ok, _} <- query("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [user_id, v]),
                        {:ok, _} <-
                          query(
                            """
                            UPDATE room_key_backup_versions
                            SET algorithm = NULL, auth_data = NULL, etag = etag + 1, deleted_at = $3, updated_at = $3
                            WHERE user_id = $1 AND version = $2
                            """,
                            [user_id, v, now_ms()]
                          ),
                        do: {:ok, :ok}

                 [[_deleted_at]] ->
                   {:ok, :ok}
               end
             end
           end) do
      :ok
    end
  end

  @doc """
  Stores a batch of sessions in the CURRENT version `version` (merge rule in the moduledoc), the whole batch or nothing.
  Returns `{:ok, %{count: n, etag: s}}`.

    * `{:error, :not_found}`: the user has no backup;
    * `{:error, {:wrong_version, current}}`: `version` is not the current one (older, deleted, unknown, malformed, another
      user's); `current` is the number of the current version;
    * `{:error, :session_quota}`: the batch would pass the per-version cap (`config :nebu, :room_keys_max_sessions_per_version`,
      default 100 000);
    * `{:error, :user_erased}`.
  """
  @spec put_sessions(String.t(), String.t(), [entry()]) ::
          {:ok, %{count: non_neg_integer(), etag: String.t()}}
          | {:error, :not_found | {:wrong_version, String.t()} | :session_quota | :user_erased | term()}
  def put_sessions(user_id, version, entries) when is_binary(user_id) and is_binary(version) and is_list(entries) do
    transact(fn ->
      with {:ok, _} <- lock_user(user_id),
           :ok <- ensure_not_erased(user_id),
           {:ok, current} <- current_version(user_id),
           :ok <- ensure_current(version, current),
           :ok <- store_entries(user_id, current, entries),
           :ok <- ensure_byte_budget(user_id) do
        count_etag(user_id, current)
      end
    end)
  end

  @doc """
  Reads the sessions of a live version (any live version) as the complete JSON RESPONSE BODY, as iodata: `:all` is
  `{"rooms":{room_id:{"sessions":{session_id: key_backup_data}}}}` (`{"rooms":{}}` when nothing is stored), `{:room, room_id}` is
  `{"sessions":{...}}`, `{:session, room_id, session_id}` one `key_backup_data` (`first_message_index`, `forwarded_count`,
  `is_verified`, `session_data`).

  The stored `session_data` JSON text is SPLICED into the body, never decoded and re-encoded (the blobs are opaque, and a whole
  version stays at about one copy in memory instead of three).

  `{:error, :not_found}` when the version is not live, `{:error, :session_not_found}` for a missing single session.
  """
  @spec get_sessions(String.t(), String.t(), scope()) :: {:ok, iodata()} | {:error, :not_found | :session_not_found | term()}
  def get_sessions(user_id, version, scope) when is_binary(user_id) and is_binary(version) do
    with {:ok, v} <- version_or_not_found(version),
         {:ok, %{rows: rows}} <- read_sessions(user_id, v, scope) do
      # one row per stored session; a live version without a matching session yields a single row of NULLs (LEFT JOIN)
      rows = Enum.reject(rows, fn [room_id | _] -> is_nil(room_id) end)
      shape_sessions(scope, rows)
    end
  rescue
    e -> {:error, e}
  end

  # One statement per scope: the version row (live, this user) LEFT JOINed with its session rows (this user): no row at all
  # means "no such live version", a row of NULLs means "live but nothing stored", and both reads see ONE snapshot.
  defp read_sessions(user_id, v, :all) do
    query(
      """
      SELECT s.room_id, s.session_id, s.first_message_index, s.forwarded_count, s.is_verified, s.session_data
      FROM room_key_backup_versions v
      LEFT JOIN room_key_backup_sessions s ON s.user_id = v.user_id AND s.version = v.version
      WHERE v.user_id = $1 AND v.version = $2 AND v.deleted_at IS NULL
      ORDER BY s.room_id, s.session_id
      """,
      [user_id, v]
    )
    |> require_version_row()
  end

  defp read_sessions(user_id, v, {:room, room_id}) do
    query(
      """
      SELECT s.room_id, s.session_id, s.first_message_index, s.forwarded_count, s.is_verified, s.session_data
      FROM room_key_backup_versions v
      LEFT JOIN room_key_backup_sessions s ON s.user_id = v.user_id AND s.version = v.version AND s.room_id = $3
      WHERE v.user_id = $1 AND v.version = $2 AND v.deleted_at IS NULL
      """,
      [user_id, v, room_id]
    )
    |> require_version_row()
  end

  defp read_sessions(user_id, v, {:session, room_id, session_id}) do
    query(
      """
      SELECT s.room_id, s.session_id, s.first_message_index, s.forwarded_count, s.is_verified, s.session_data
      FROM room_key_backup_versions v
      LEFT JOIN room_key_backup_sessions s ON s.user_id = v.user_id AND s.version = v.version AND s.room_id = $3 AND s.session_id = $4
      WHERE v.user_id = $1 AND v.version = $2 AND v.deleted_at IS NULL
      """,
      [user_id, v, room_id, session_id]
    )
    |> require_version_row()
  end

  defp require_version_row({:ok, %{rows: []}}), do: {:error, :not_found}
  defp require_version_row(other), do: other

  # The response body as IODATA: the stored `session_data` JSON text is SPLICED in, never decoded and re-encoded (one copy in memory, not three)
  defp shape_sessions(:all, rows) do
    rooms =
      rows
      |> Enum.chunk_by(fn [room_id | _] -> room_id end)
      |> Enum.map(fn [[room_id | _] | _] = group -> [Jason.encode!(room_id), ~s(:{"sessions":{), sessions_iodata(group), "}}"] end)
      |> Enum.intersperse(",")

    {:ok, ["{\"rooms\":{", rooms, "}}"]}
  end

  defp shape_sessions({:room, _}, rows), do: {:ok, ["{\"sessions\":{", sessions_iodata(rows), "}}"]}

  defp shape_sessions({:session, _, _}, [[_, _ | data]]), do: {:ok, key_backup_data_iodata(data)}
  defp shape_sessions({:session, _, _}, []), do: {:error, :session_not_found}

  defp sessions_iodata(rows) do
    rows |> Enum.map(fn [_, session_id | data] -> [Jason.encode!(session_id), ":", key_backup_data_iodata(data)] end) |> Enum.intersperse(",")
  end

  defp key_backup_data_iodata([first_message_index, forwarded_count, is_verified, session_data]) do
    [
      ~s({"first_message_index":),
      Integer.to_string(first_message_index),
      ~s(,"forwarded_count":),
      Integer.to_string(forwarded_count),
      ~s(,"is_verified":),
      to_string(is_verified),
      ~s(,"session_data":),
      session_data,
      "}"
    ]
  end

  @doc """
  Deletes sessions of a live version (any live version): all, one room's or one session. `{:ok, %{count: n, etag: s}}` with the state
  AFTER the delete (deleting nothing is `:ok` and leaves the etag alone), `{:error, :not_found}` when the version is not live.
  """
  @spec delete_sessions(String.t(), String.t(), scope()) :: {:ok, %{count: non_neg_integer(), etag: String.t()}} | {:error, :not_found | term()}
  def delete_sessions(user_id, version, scope) when is_binary(user_id) and is_binary(version) do
    with {:ok, v} <- version_or_not_found(version) do
      transact(fn ->
        with {:ok, _} <- lock_user(user_id),
             :ok <- ensure_live(user_id, v),
             {:ok, %{num_rows: deleted}} <- delete_scope(user_id, v, scope),
             :ok <- if(deleted > 0, do: bump_etag(user_id, v), else: :ok) do
          count_etag(user_id, v)
        end
      end)
    end
  end

  defp delete_scope(user_id, v, :all), do: query("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [user_id, v])

  defp delete_scope(user_id, v, {:room, room_id}),
    do: query("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3", [user_id, v, room_id])

  defp delete_scope(user_id, v, {:session, room_id, session_id}),
    do: query("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3 AND session_id = $4", [user_id, v, room_id, session_id])

  # ── writes: merge and quota ─────────────────────────────────────────────────

  defp store_entries(_user_id, _v, []), do: :ok

  defp store_entries(user_id, v, entries) do
    rooms = Enum.map(entries, & &1.room_id)
    session_ids = Enum.map(entries, & &1.session_id)
    first_message_indexes = Enum.map(entries, & &1.first_message_index)
    forwarded_counts = Enum.map(entries, & &1.forwarded_count)
    verified = Enum.map(entries, & &1.is_verified)
    blobs = Enum.map(entries, &Jason.encode!(&1.session_data))

    with :ok <- ensure_session_quota(user_id, v, rooms, session_ids),
         # the merge rule in ONE statement: the conflict branch replaces the stored row only when the new one wins; a tie updates nothing
         {:ok, %{rows: [[changed]]}} <-
           query(
             """
             WITH upserted AS (
               INSERT INTO room_key_backup_sessions AS s
                 (user_id, version, room_id, session_id, first_message_index, forwarded_count, is_verified, session_data, updated_at)
               SELECT $1::text, $2::bigint, i.room_id, i.session_id, i.fmi, i.fwd, i.ver, i.data, $9::bigint
               FROM unnest($3::text[], $4::text[], $5::bigint[], $6::bigint[], $7::boolean[], $8::text[]) AS i(room_id, session_id, fmi, fwd, ver, data)
               ON CONFLICT (user_id, version, room_id, session_id) DO UPDATE
                 SET first_message_index = EXCLUDED.first_message_index,
                     forwarded_count     = EXCLUDED.forwarded_count,
                     is_verified         = EXCLUDED.is_verified,
                     session_data        = EXCLUDED.session_data,
                     updated_at          = EXCLUDED.updated_at
                 WHERE (EXCLUDED.is_verified AND NOT s.is_verified)
                    OR (EXCLUDED.is_verified = s.is_verified
                        AND (EXCLUDED.first_message_index < s.first_message_index
                             OR (EXCLUDED.first_message_index = s.first_message_index AND EXCLUDED.forwarded_count < s.forwarded_count)))
               RETURNING 1
             )
             SELECT count(*) FROM upserted
             """,
             [user_id, v, rooms, session_ids, first_message_indexes, forwarded_counts, verified, blobs, now_ms()]
           ) do
      if changed > 0, do: bump_etag(user_id, v), else: :ok
    end
  end

  # existing sessions + the sessions of the batch that are not stored yet (a replace does not count) must stay within the cap
  defp ensure_session_quota(user_id, v, rooms, session_ids) do
    with {:ok, %{rows: [[existing]]}} <-
           query("SELECT count(*) FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [user_id, v]),
         {:ok, %{rows: [[fresh]]}} <-
           query(
             """
             SELECT count(*)
             FROM unnest($3::text[], $4::text[]) AS i(room_id, session_id)
             WHERE NOT EXISTS (SELECT 1 FROM room_key_backup_sessions s
                               WHERE s.user_id = $1 AND s.version = $2 AND s.room_id = i.room_id AND s.session_id = i.session_id)
             """,
             [user_id, v, rooms, session_ids]
           ) do
      if existing + fresh > max_sessions(), do: {:error, :session_quota}, else: :ok
    end
  end

  # read at REQUEST time (a seam for the tests and for operators)
  defp max_sessions do
    case Application.get_env(:nebu, :room_keys_max_sessions_per_version, @default_max_sessions) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_sessions
    end
  end

  # ── versions ────────────────────────────────────────────────────────────────

  # a version is a decimal string without a leading zero that fits an int64 (`"01"` does not alias `"1"`)
  defp parse_version(version) when is_binary(version) do
    if Regex.match?(~r/\A[1-9][0-9]{0,17}\z/, version), do: {:ok, String.to_integer(version)}, else: :error
  end

  defp version_or_not_found(version) do
    case parse_version(version) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, :not_found}
    end
  end

  # the number of the newest non-deleted version; `{:error, :not_found}` when the user has no backup
  defp current_version(user_id) do
    case query("SELECT max(version) FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL", [user_id]) do
      {:ok, %{rows: [[nil]]}} -> {:error, :not_found}
      {:ok, %{rows: [[current]]}} -> {:ok, current}
      {:error, _} = err -> err
    end
  end

  # a key write names the current version; anything else tells the client which one is current
  defp ensure_current(version, current) do
    if parse_version(version) == {:ok, current}, do: :ok, else: {:error, {:wrong_version, Integer.to_string(current)}}
  end

  defp ensure_live(user_id, v) do
    case query("SELECT 1 FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND deleted_at IS NULL", [user_id, v]) do
      {:ok, %{rows: [_ | _]}} -> :ok
      {:ok, _} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # count and etag of a version, read inside the writing transaction (the per-user lock is held)
  defp count_etag(user_id, v) do
    case query(
           """
           SELECT (SELECT count(*) FROM room_key_backup_sessions s WHERE s.user_id = v.user_id AND s.version = v.version), v.etag
           FROM room_key_backup_versions v
           WHERE v.user_id = $1 AND v.version = $2
           """,
           [user_id, v]
         ) do
      {:ok, %{rows: [[count, etag]]}} -> {:ok, %{count: count, etag: Integer.to_string(etag)}}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp bump_etag(user_id, v) do
    with {:ok, _} <-
           query("UPDATE room_key_backup_versions SET etag = etag + 1, updated_at = $3 WHERE user_id = $1 AND version = $2", [user_id, v, now_ms()]),
         do: :ok
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  # The per-user lock is a TRY-lock: a waiter would hold one of the 10 pooled connections, so a busy lock is `{:error, :lock_busy}` at once (answered 429).
  # `SET LOCAL lock_timeout` (`set_config(.., true)` is the parameterised form, it ends with the transaction) stays only as the safety net of the ROW locks
  # (`FOR UPDATE`) behind it: a wait that runs out is `{:error, :lock_timeout}` (see `query/2`), answered 429 as well.
  defp lock_user(user_id) do
    with {:ok, _} <- query("SELECT set_config('lock_timeout', $1::text, true)", ["#{lock_timeout_ms()}ms"]),
         {:ok, %{rows: [[locked?]]}} <- query("SELECT pg_try_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))", [user_id]) do
      if locked?, do: {:ok, :locked}, else: {:error, :lock_busy}
    end
  end

  defp lock_timeout_ms, do: positive_env(:room_keys_lock_timeout_ms, @default_lock_timeout_ms)
  defp max_bytes, do: positive_env(:room_keys_max_bytes_per_user, @default_max_bytes)
  defp max_version_rows, do: positive_env(:room_keys_max_version_rows_per_user, @default_max_version_rows)

  defp positive_env(key, default) do
    case Application.get_env(:nebu, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  # Per stored session its room id and session id bytes, a fixed row overhead and the canonical bytes of its session_data, plus the auth_data of every live
  # version of the user, decided on the locked state AFTER the write of the request (so a replace counts only its delta); over the budget the transaction
  # rolls back and nothing is stored. A scan of the user's rows (bounded by the budget): an O(1) counter column is a recorded follow-up.
  defp ensure_byte_budget(user_id) do
    with {:ok, %{rows: [[sessions]]}} <-
           query(
             """
             SELECT COALESCE(sum(octet_length(room_id) + octet_length(session_id) + $2::bigint + octet_length(session_data)), 0)::bigint
             FROM room_key_backup_sessions
             WHERE user_id = $1
             """,
             [user_id, @row_overhead_bytes]
           ),
         {:ok, %{rows: [[auth]]}} <-
           query("SELECT COALESCE(sum(octet_length(auth_data)), 0)::bigint FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL", [user_id]) do
      if sessions + auth > max_bytes(), do: {:error, :bytes_quota}, else: :ok
    end
  end

  # a user whose erasure is under way (or done) writes nothing (story gdpr-erasure-global-data: the same rule as the account data)
  defp ensure_not_erased(user_id) do
    case query("SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NOT NULL", [user_id]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, _} -> {:error, :user_erased}
      {:error, _} = err -> err
    end
  end

  # `fun` returns `{:ok, value}` (commit) or `{:error, reason}` (rollback); a raising connection is an `{:error, exception}` as well
  defp transact(fun) do
    Nebu.Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Nebu.Repo.rollback(reason)
      end
    end)
  rescue
    e -> {:error, e}
  end

  defp now_ms, do: System.system_time(:millisecond)

  # SQLSTATE 55P03 (`lock_not_available`: the `lock_timeout` of the transaction ran out, on the advisory lock or on a row lock behind it) is a
  # condition of its own, not a database fault
  defp query(sql, params) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, params) do
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> {:error, :lock_timeout}
      other -> other
    end
  end
end
