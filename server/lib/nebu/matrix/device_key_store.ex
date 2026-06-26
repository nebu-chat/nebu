defmodule Nebu.Matrix.DeviceKeyStore do
  @moduledoc """
  The Matrix device-key DIRECTORY (bugfix: fix-device-key-registration).

  Stores and serves per-device identity keys, one-time keys (OTKs), and fallback
  keys published via `POST /_matrix/client/v3/keys/upload`, and read back via
  `POST /_matrix/client/v3/keys/query` / `GET /sync` / `GET /devices`.

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018 — no Ecto
  schema, no Repository/Service layer). PostgreSQL-backed rather than ETS so the
  directory is cluster-correct (ADR-020: an upload and a later query may land on
  different nodes) and survives restarts.

  IMPORTANT — this is ORTHOGONAL to end-to-end encryption (ADR-011): persisting
  and echoing these public keys encrypts nothing. E2EE is only enabled when a
  client sends an `m.room.encryption` state event, which Nebu rejects.
  """

  @doc "Upserts a device's signed identity-key object (the `device_keys` blob)."
  @spec put_device_keys(String.t(), String.t(), map(), keyword()) :: :ok
  def put_device_keys(user_id, device_id, device_keys, opts \\ [])
      when is_binary(user_id) and is_binary(device_id) and is_map(device_keys) do
    now = now_ms()
    display_name = Keyword.get(opts, :display_name)
    json = Jason.encode!(device_keys)

    {:ok, _} =
      query(
        """
        INSERT INTO device_keys
          (user_id, device_id, device_keys_json, display_name, last_seen_ts, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $6)
        ON CONFLICT (user_id, device_id) DO UPDATE
          SET device_keys_json = EXCLUDED.device_keys_json,
              display_name      = COALESCE(EXCLUDED.display_name, device_keys.display_name),
              last_seen_ts      = EXCLUDED.last_seen_ts,
              updated_at        = EXCLUDED.updated_at
        """,
        [user_id, device_id, json, display_name, now, now]
      )

    :ok
  end

  @doc """
  Stores one-time keys store-once (re-uploading the same key_id is a no-op).
  `one_time_keys` is the upload-body map `{"<algorithm>:<key_id>" => key}`.
  Returns `:ok`.
  """
  @spec store_one_time_keys(String.t(), String.t(), map()) :: :ok
  def store_one_time_keys(user_id, device_id, one_time_keys)
      when is_binary(user_id) and is_binary(device_id) and is_map(one_time_keys) do
    now = now_ms()

    Enum.each(one_time_keys, fn {prop, key} ->
      case split_algorithm(prop) do
        {algorithm, key_id} ->
          {:ok, _} =
            query(
              """
              INSERT INTO device_one_time_keys
                (user_id, device_id, algorithm, key_id, key_json, created_at)
              VALUES ($1, $2, $3, $4, $5, $6)
              ON CONFLICT (user_id, device_id, algorithm, key_id) DO NOTHING
              """,
              [user_id, device_id, algorithm, key_id, Jason.encode!(key), now]
            )

        :error ->
          :ok
      end
    end)

    :ok
  end

  @doc "Stores/replaces fallback keys (at most one per algorithm), marking them unused."
  @spec store_fallback_keys(String.t(), String.t(), map()) :: :ok
  def store_fallback_keys(user_id, device_id, fallback_keys)
      when is_binary(user_id) and is_binary(device_id) and is_map(fallback_keys) do
    now = now_ms()

    Enum.each(fallback_keys, fn {prop, key} ->
      case split_algorithm(prop) do
        {algorithm, _key_id} ->
          {:ok, _} =
            query(
              """
              INSERT INTO device_fallback_keys
                (user_id, device_id, algorithm, key_json, used, created_at)
              VALUES ($1, $2, $3, $4, FALSE, $5)
              ON CONFLICT (user_id, device_id, algorithm) DO UPDATE
                SET key_json = EXCLUDED.key_json, used = FALSE, created_at = EXCLUDED.created_at
              """,
              [user_id, device_id, algorithm, Jason.encode!(key), now]
            )

        :error ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Unclaimed one-time-key counts for a single device: `%{algorithm => count}`.
  An algorithm with zero unclaimed keys is omitted (matches the spec's
  "assume zero if absent").
  """
  @spec otk_counts(String.t(), String.t()) :: %{String.t() => non_neg_integer()}
  def otk_counts(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case safe_query(
           """
           SELECT algorithm, COUNT(*)::int
           FROM device_one_time_keys
           WHERE user_id = $1 AND device_id = $2 AND claimed_at IS NULL
           GROUP BY algorithm
           """,
           [user_id, device_id]
         ) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [alg, n] -> {alg, n} end)
      _ -> %{}
    end
  end

  @doc """
  Best-effort aggregate OTK counts across ALL of a user's devices. Used by `/sync`
  when the access token carries no `device_id` (raw OIDC JWT): for a single-device
  user this equals that device's count.
  """
  @spec otk_counts_for_user(String.t()) :: %{String.t() => non_neg_integer()}
  def otk_counts_for_user(user_id) when is_binary(user_id) do
    case safe_query(
           """
           SELECT algorithm, COUNT(*)::int
           FROM device_one_time_keys
           WHERE user_id = $1 AND claimed_at IS NULL
           GROUP BY algorithm
           """,
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [alg, n] -> {alg, n} end)
      _ -> %{}
    end
  end

  @doc "Algorithms for which the user (any device) has an unused fallback key."
  @spec unused_fallback_key_types_for_user(String.t()) :: [String.t()]
  def unused_fallback_key_types_for_user(user_id) when is_binary(user_id) do
    case safe_query(
           "SELECT DISTINCT algorithm FROM device_fallback_keys WHERE user_id = $1 AND used = FALSE",
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [alg] -> alg end)
      _ -> []
    end
  end

  @doc """
  Returns the stored device-key objects for the given users:
  `%{user_id => %{device_id => device_info}}`, where `device_info` is the uploaded
  `device_keys` object plus an `unsigned` property (spec §/keys/query). Users/devices
  with no published keys are simply omitted.
  """
  @spec query_devices([String.t()]) :: %{optional(String.t()) => map()}
  def query_devices(user_ids) when is_list(user_ids) do
    case user_ids do
      [] ->
        %{}

      _ ->
        case safe_query(
               """
               SELECT user_id, device_id, device_keys_json, display_name
               FROM device_keys
               WHERE user_id = ANY($1)
               """,
               [user_ids]
             ) do
          {:ok, %{rows: rows}} ->
            Enum.reduce(rows, %{}, fn [uid, did, json, display_name], acc ->
              info = decode_device_info(json, display_name)
              Map.update(acc, uid, %{did => info}, &Map.put(&1, did, info))
            end)

          _ ->
            %{}
        end
    end
  end

  @doc "Lists a user's devices for `GET /devices`: `[%{device_id, display_name?, last_seen_ts?}]`."
  @spec list_devices(String.t()) :: [map()]
  def list_devices(user_id) when is_binary(user_id) do
    case safe_query(
           "SELECT device_id, display_name, last_seen_ts FROM device_keys WHERE user_id = $1",
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &device_row/1)
      _ -> []
    end
  end

  @doc """
  Returns the user's device_id iff they have exactly one registered device, else `nil`.
  Used to attribute an OTK-only `/keys/upload` (no device_keys in the body) when the
  access token is a raw OIDC JWT that carries no device_id. Ambiguous (0 or >1 devices)
  → `nil` (the upload is then a safe no-op rather than mis-attributed).
  """
  @spec sole_device_id(String.t()) :: String.t() | nil
  def sole_device_id(user_id) when is_binary(user_id) do
    case safe_query("SELECT device_id FROM device_keys WHERE user_id = $1 LIMIT 2", [user_id]) do
      {:ok, %{rows: [[device_id]]}} -> device_id
      _ -> nil
    end
  end

  @doc "Returns one device for `GET /devices/{deviceId}`, or `nil` if unknown."
  @spec get_device(String.t(), String.t()) :: map() | nil
  def get_device(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case safe_query(
           "SELECT device_id, display_name, last_seen_ts FROM device_keys WHERE user_id = $1 AND device_id = $2",
           [user_id, device_id]
         ) do
      {:ok, %{rows: [row]}} -> device_row(row)
      _ -> nil
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp decode_device_info(json, display_name) do
    json
    |> Jason.decode!()
    |> Map.put("unsigned", unsigned(display_name))
  end

  defp unsigned(nil), do: %{}
  defp unsigned(display_name), do: %{"device_display_name" => display_name}

  defp device_row([device_id, display_name, last_seen_ts]) do
    %{"device_id" => device_id}
    |> maybe_put("display_name", display_name)
    |> maybe_put("last_seen_ts", last_seen_ts)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # "signed_curve25519:AAAAHQ" -> {"signed_curve25519", "AAAAHQ"}; nil/garbage -> :error.
  defp split_algorithm(prop) when is_binary(prop) do
    case String.split(prop, ":", parts: 2) do
      [algorithm, key_id] when algorithm != "" and key_id != "" -> {algorithm, key_id}
      _ -> :error
    end
  end

  defp split_algorithm(_), do: :error

  defp now_ms, do: System.system_time(:millisecond)

  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)

  # Read-path query that never raises (DB down / not started → empty result), so
  # /sync and /keys/query degrade gracefully instead of crashing the request.
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
