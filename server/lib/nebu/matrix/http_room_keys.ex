defmodule Nebu.Matrix.HttpRoomKeys do
  @moduledoc """
  HTTP side of the Matrix CS v1.18 "Server-side key backups" (`/_matrix/client/v3/room_keys/**`, story server-side-key-backup,
  epic e2ee-client-support): request validation, status codes and response shapes. The routes live in `Nebu.Web.Router.Protected`
  (which also charges the writes to their rate-limit tier); the SQL lives in `Nebu.Matrix.RoomKeyBackupStore`.

  An OPAQUE per-user store (ADR-011 stays: this enables no E2EE room): `auth_data` and the `session_data` blobs are never
  decrypted or interpreted, only checked for well-formedness (a JSON object) and size, and NEVER logged: a failing request logs
  the KIND of its error only (a Postgrex message can quote row data), and the `RequestLogger` captures no body of these routes.

  ## Errors

    * `400 M_MISSING_PARAM` a missing body member or `version` query parameter, `400 M_INVALID_PARAM` a mistyped or wrong value,
      `400 M_NOT_JSON` malformed JSON, `400 M_BAD_JSON` a JSON body that is not an object;
    * `413 M_TOO_LARGE` `session_data` above 8 KiB, `auth_data` above 16 KiB (compact JSON bytes), a body above 5 MiB;
    * `403 M_WRONG_ROOM_KEYS_VERSION` (with `current_version`) a key write to a version that is not the current one;
    * `403 M_FORBIDDEN` a quota: the 11th live version, too many version rows (markers included), a session above the per-version
      cap, the per-user byte budget (never `M_LIMIT_EXCEEDED` for a quota: clients retry that);
    * `429 M_LIMIT_EXCEEDED` (with `retry_after_ms`) a writer that found the per-user lock busy (a try-lock, at once) or
      whose row lock timed out, or a bulk read that found no slot (one per user, two per node);
    * `403 M_USER_DEACTIVATED` a creating write of a user whose erasure is under way;
    * `404 M_NOT_FOUND` an unknown version (another user's included) or no backup at all;
    * `500 M_UNKNOWN` a failed database operation (generic text).

  Every key write is validated completely before anything is stored: a request is stored whole or not at all.

  ## Order of a write request (see `Nebu.Web.Router.Protected`)

  Authentication, then the per-user write rate limit, and only THEN the body is read and parsed (`Nebu.Web.Plugs.JsonBody.parse_room_keys/1`,
  5 MiB limit): `JsonBody` leaves these bodies unfetched, so an anonymous or junk-credential request never makes the server read a body. The two
  bulk reads (`GET /keys`, `GET /keys/{room}`) have a rate-limit bucket of their own and a slot (`Nebu.Matrix.RoomKeysReadGate`: one in flight per
  user, two per node, a refusal is 429 before any database work); `GET /version` and `GET /version/{v}` share a light bucket; the single-session GET
  is not limited.
  """
  import Nebu.Matrix.Http, only: [send_json: 3, error: 4]
  require Logger

  alias Nebu.Matrix.RoomKeyBackupStore, as: Store

  # the one backup algorithm of the spec
  @algorithm "m.megolm_backup.v1.curve25519-aes-sha2"
  @max_session_data_bytes 8 * 1024
  @max_auth_data_bytes 16 * 1024
  @max_id_bytes 255
  @max_index 4_294_967_295

  # ── versions ────────────────────────────────────────────────────────────────

  @doc "`POST /room_keys/version`"
  @spec create_version(Plug.Conn.t()) :: Plug.Conn.t()
  def create_version(conn) do
    with {:ok, body} <- body_object(conn),
         {:ok, algorithm, auth_data} <- version_body(body),
         {:ok, version} <- Store.create_version(user(conn), algorithm, auth_data) do
      send_json(conn, 200, %{"version" => version})
    else
      {:error, reason} -> reply_error(conn, reason)
    end
  end

  @doc "`GET /room_keys/version` (the current version) and `GET /room_keys/version/{version}`"
  @spec get_version(Plug.Conn.t(), String.t() | nil) :: Plug.Conn.t()
  def get_version(conn, version \\ nil) do
    case Store.get_version(user(conn), version || :current) do
      {:ok, info} ->
        send_json(conn, 200, %{
          "algorithm" => info.algorithm,
          "auth_data" => info.auth_data,
          "count" => info.count,
          "etag" => info.etag,
          "version" => info.version
        })

      {:error, :not_found} ->
        error(conn, 404, "M_NOT_FOUND", "No backup found")

      {:error, reason} ->
        reply_error(conn, reason)
    end
  end

  @doc "`PUT /room_keys/version/{version}`: replaces the `auth_data` of a version"
  @spec update_version(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update_version(conn, version) do
    with {:ok, body} <- body_object(conn),
         {:ok, algorithm, auth_data} <- update_body(body),
         :ok <- body_version_matches(body, version),
         :ok <- Store.update_version(user(conn), version, algorithm, auth_data) do
      send_json(conn, 200, %{})
    else
      {:error, reason} -> reply_error(conn, reason)
    end
  end

  @doc "`DELETE /room_keys/version/{version}` (idempotent)"
  @spec delete_version(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete_version(conn, version) do
    case Store.delete_version(user(conn), version) do
      :ok -> send_json(conn, 200, %{})
      {:error, reason} -> reply_error(conn, reason)
    end
  end

  # ── keys ────────────────────────────────────────────────────────────────────

  @doc "`PUT /room_keys/keys[/{room}[/{session}]]`; `scope` is `:all`, `{:room, room}` or `{:session, room, session}`"
  @spec put_keys(Plug.Conn.t(), Store.scope()) :: Plug.Conn.t()
  def put_keys(conn, scope) do
    with {:ok, version} <- version_param(conn),
         :ok <- scope_ids(scope),
         {:ok, body} <- body_object(conn),
         {:ok, entries} <- parse_entries(scope, body),
         {:ok, %{count: count, etag: etag}} <- Store.put_sessions(user(conn), version, entries) do
      send_json(conn, 200, %{"count" => count, "etag" => etag})
    else
      # the user has no backup at all (an unknown version of a user who has one is the 403 below)
      {:error, :not_found} -> error(conn, 404, "M_NOT_FOUND", "No backup found")
      {:error, reason} -> reply_error(conn, reason)
    end
  end

  @doc "`GET /room_keys/keys[/{room}[/{session}]]`"
  @spec get_keys(Plug.Conn.t(), Store.scope()) :: Plug.Conn.t()
  def get_keys(conn, scope) do
    with {:ok, version} <- version_param(conn),
         :ok <- scope_ids(scope),
         {:ok, iodata} <- Store.get_sessions(user(conn), version, scope) do
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, iodata)
    else
      {:error, :not_found} -> error(conn, 404, "M_NOT_FOUND", "No backup found")
      {:error, :session_not_found} -> error(conn, 404, "M_NOT_FOUND", "Unknown key")
      {:error, reason} -> reply_error(conn, reason)
    end
  end

  @doc "`DELETE /room_keys/keys[/{room}[/{session}]]`"
  @spec delete_keys(Plug.Conn.t(), Store.scope()) :: Plug.Conn.t()
  def delete_keys(conn, scope) do
    with {:ok, version} <- version_param(conn),
         :ok <- scope_ids(scope),
         {:ok, %{count: count, etag: etag}} <- Store.delete_sessions(user(conn), version, scope) do
      send_json(conn, 200, %{"count" => count, "etag" => etag})
    else
      {:error, reason} -> reply_error(conn, reason)
    end
  end

  # ── answers ──────────────────────────────────────────────────────────────────

  defp user(conn), do: conn.assigns[:current_user]

  # a validation failure is `{status, errcode, message}`; the other reasons are the store's
  defp reply_error(conn, {status, errcode, message}) when is_integer(status), do: error(conn, status, errcode, message)
  defp reply_error(conn, :not_found), do: error(conn, 404, "M_NOT_FOUND", "Unknown backup version")
  defp reply_error(conn, :algorithm_mismatch), do: error(conn, 400, "M_INVALID_PARAM", "The algorithm of a backup cannot be changed")

  defp reply_error(conn, :version_quota),
    do: error(conn, 403, "M_FORBIDDEN", "Too many key backup versions (at most #{Store.max_versions()}); delete one first")

  defp reply_error(conn, :session_quota), do: error(conn, 403, "M_FORBIDDEN", "Too many sessions in this backup version")
  defp reply_error(conn, :bytes_quota), do: error(conn, 403, "M_FORBIDDEN", "The key backup of this account is full (storage budget exceeded)")
  # the cap counts the soft-delete markers, which only an operator prunes (docs/compliance/gdpr-deletion-runbook.md, "Pruning old key backup version markers")
  defp reply_error(conn, :version_rows_quota), do: error(conn, 403, "M_FORBIDDEN", "Too many key backup versions were created (deleted ones count): contact the server administrator")

  # the per-user lock is busy (a try-lock: answered at once) or a row lock was not granted in time: time-based conditions, the client may retry
  # (the shared 429 envelope: `retry_after_ms` in the body, `Retry-After` header)
  defp reply_error(conn, busy) when busy in [:lock_busy, :lock_timeout], do: Nebu.Web.Plugs.RateLimit.respond_limited(conn, 1)

  defp reply_error(conn, {:wrong_version, current}) do
    send_json(conn, 403, %{
      "errcode" => "M_WRONG_ROOM_KEYS_VERSION",
      "error" => "The version is not the current backup version",
      "current_version" => current
    })
  end

  defp reply_error(conn, :user_erased) do
    # a permanent condition, not a retryable 500 (the same answer as the account data writes of an erased user)
    Logger.info("room keys write refused: user_erased")
    error(conn, 403, "M_USER_DEACTIVATED", "This account has been deactivated")
  end

  defp reply_error(conn, reason) do
    # the kind of the failure only, never its details: a database error can quote the blob that failed to store
    Logger.error("room keys request failed: #{error_kind(reason)}")
    error(conn, 500, "M_UNKNOWN", "The key backup could not be accessed, please try again.")
  end

  # the kind of an error for the log: an exception's module or an atom, never its message
  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"

  # ── request validation ───────────────────────────────────────────────────────

  defp invalid(message), do: {:error, {400, "M_INVALID_PARAM", message}}

  # The JSON object of the request; a missing body is an empty object (the members are checked next). `JsonBody` has already answered
  # a body above the size cap (413), flagged a malformed one and wrapped a top-level array / scalar as `%{"_json" => _}`.
  defp body_object(conn) do
    cond do
      conn.assigns[:json_parse_error] == true -> {:error, {400, "M_NOT_JSON", "Request body is not valid JSON"}}
      is_struct(conn.body_params, Plug.Conn.Unfetched) -> {:ok, %{}}
      is_map(conn.body_params) and map_size(conn.body_params) == 1 and is_map_key(conn.body_params, "_json") -> {:error, {400, "M_BAD_JSON", "Request body must be a JSON object"}}
      is_map(conn.body_params) -> {:ok, conn.body_params}
      true -> {:ok, %{}}
    end
  end

  defp version_param(conn) do
    case conn.query_params["version"] do
      version when is_binary(version) and version != "" -> {:ok, version}
      _ -> {:error, {400, "M_MISSING_PARAM", "Missing the `version` query parameter"}}
    end
  end

  defp version_body(body) do
    with {:ok, algorithm} <- required(body, "algorithm", &is_binary/1),
         {:ok, auth_data} <- required(body, "auth_data", &is_map/1),
         :ok <- size_ok(auth_data, @max_auth_data_bytes, "auth_data") do
      if algorithm == @algorithm, do: {:ok, algorithm, auth_data}, else: invalid("Unsupported algorithm")
    end
  end

  defp update_body(body) do
    with {:ok, algorithm} <- required(body, "algorithm", &is_binary/1),
         {:ok, auth_data} <- required(body, "auth_data", &is_map/1),
         :ok <- size_ok(auth_data, @max_auth_data_bytes, "auth_data"),
         :ok <- optional(body, "version", &is_binary/1) do
      {:ok, algorithm, auth_data}
    end
  end

  # the optional `version` member of a PUT /version body must name the version of the path
  defp body_version_matches(body, version) do
    case Map.fetch(body, "version") do
      :error -> :ok
      {:ok, ^version} -> :ok
      {:ok, _other} -> invalid("The version in the body does not match the version in the path")
    end
  end

  defp required(body, key, valid?) do
    case Map.fetch(body, key) do
      :error -> {:error, {400, "M_MISSING_PARAM", "Missing #{key}"}}
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid("Invalid #{key}")
    end
  end

  defp optional(body, key, valid?) do
    case Map.fetch(body, key) do
      :error -> :ok
      {:ok, value} -> if valid?.(value), do: :ok, else: invalid("Invalid #{key}")
    end
  end

  # sizes are compact JSON bytes (not characters)
  defp size_ok(value, max, what) do
    if byte_size(Jason.encode!(value)) > max, do: {:error, {413, "M_TOO_LARGE", "#{what} is too large"}}, else: :ok
  end

  defp scope_ids(:all), do: :ok
  defp scope_ids({:room, room}), do: id_ok(room)
  defp scope_ids({:session, room, session}), do: with(:ok <- id_ok(room), do: id_ok(session))

  # a room or session id: 1..255 bytes of valid UTF-8 without NUL (Postgres TEXT cannot hold a NUL)
  defp id_ok(id) do
    if is_binary(id) and byte_size(id) in 1..@max_id_bytes and String.valid?(id) and not String.contains?(id, <<0>>),
      do: :ok,
      else: invalid("Invalid room or session id")
  end

  # the body of a key write as a flat list of validated entries (the whole request or nothing)
  defp parse_entries(:all, body) do
    with {:ok, rooms} <- required(body, "rooms", &is_map/1) do
      flat_map_ok(rooms, fn {room, room_body} ->
        with :ok <- id_ok(room),
             {:ok, sessions} <- sessions_member(room_body) do
          sessions_entries(room, sessions)
        end
      end)
    end
  end

  defp parse_entries({:room, room}, body) do
    with {:ok, sessions} <- sessions_member(body), do: sessions_entries(room, sessions)
  end

  defp parse_entries({:session, room, session}, body) do
    with {:ok, entry} <- entry(room, session, body), do: {:ok, [entry]}
  end

  defp sessions_member(room_body) when is_map(room_body), do: required(room_body, "sessions", &is_map/1)
  defp sessions_member(_room_body), do: invalid("Invalid sessions")

  defp sessions_entries(room, sessions) do
    flat_map_ok(sessions, fn {session, key_backup_data} ->
      with :ok <- id_ok(session), {:ok, entry} <- entry(room, session, key_backup_data), do: {:ok, [entry]}
    end)
  end

  defp entry(room, session, key_backup_data) when is_map(key_backup_data) do
    with {:ok, first_message_index} <- required(key_backup_data, "first_message_index", &index?/1),
         {:ok, forwarded_count} <- required(key_backup_data, "forwarded_count", &index?/1),
         {:ok, is_verified} <- required(key_backup_data, "is_verified", &is_boolean/1),
         {:ok, session_data} <- required(key_backup_data, "session_data", &is_map/1),
         :ok <- size_ok(session_data, @max_session_data_bytes, "session_data") do
      {:ok,
       %{
         room_id: room,
         session_id: session,
         first_message_index: first_message_index,
         forwarded_count: forwarded_count,
         is_verified: is_verified,
         session_data: session_data
       }}
    end
  end

  defp entry(_room, _session, _not_a_map), do: invalid("A session must be a JSON object")

  # a megolm index: an unsigned 32 bit integer (a float such as 5.0 is not one)
  defp index?(n), do: is_integer(n) and n >= 0 and n <= @max_index

  # maps `fun` (returning `{:ok, list}`) over `enumerable` and concatenates the lists; the first error wins
  defp flat_map_ok(enumerable, fun) do
    result =
      Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, list} -> {:cont, {:ok, Enum.reverse(list, acc)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, reversed} <- result, do: {:ok, Enum.reverse(reversed)}
  end
end
