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

  @doc """
  Upserts a device's IDENTITY row in `devices` (S1 device-registry-model).

  A device is a first-class entity, separate from the optional crypto-key blob it may publish.
  `opts` may include `:display_name`, `:last_seen_ts`, `:last_seen_ip`. On conflict each metadata
  field is COALESCE-updated (a `nil` opt never clears an existing value); `created_at` is set only
  on insert, `updated_at` on every write. Cluster-correct (ADR-020) — PostgreSQL-backed.
  """
  @spec upsert_device(String.t(), String.t(), keyword()) :: :ok
  def upsert_device(user_id, device_id, opts \\ [])
      when is_binary(user_id) and is_binary(device_id) do
    now = now_ms()
    display_name = Keyword.get(opts, :display_name)
    last_seen_ts = Keyword.get(opts, :last_seen_ts)
    last_seen_ip = Keyword.get(opts, :last_seen_ip)

    {:ok, _} =
      query(
        """
        INSERT INTO devices
          (user_id, device_id, display_name, last_seen_ts, last_seen_ip, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $6)
        ON CONFLICT (user_id, device_id) DO UPDATE
          SET display_name = COALESCE(EXCLUDED.display_name, devices.display_name),
              last_seen_ts = COALESCE(EXCLUDED.last_seen_ts, devices.last_seen_ts),
              last_seen_ip = COALESCE(EXCLUDED.last_seen_ip, devices.last_seen_ip),
              updated_at   = EXCLUDED.updated_at
        """,
        [user_id, device_id, display_name, last_seen_ts, last_seen_ip, now]
      )

    :ok
  end

  @doc """
  Upserts a device's signed identity-key object (the `device_keys` blob).

  AC2: uploading keys upserts the `devices` row FIRST (carrying display_name through), so the
  device IDENTITY exists in `devices` even before/independently of the key blob, then upserts the
  `device_keys` crypto row.
  """
  @spec put_device_keys(String.t(), String.t(), map(), keyword()) :: :ok
  def put_device_keys(user_id, device_id, device_keys, opts \\ [])
      when is_binary(user_id) and is_binary(device_id) and is_map(device_keys) do
    now = now_ms()
    display_name = Keyword.get(opts, :display_name)
    json = Jason.encode!(device_keys)

    # AC2: the device IDENTITY row is upserted first (device existence is independent of keys).
    # Ordering rationale (these two writes are NOT in a transaction): writing the devices row first
    # means the only possible intermediate state after a crash between the two writes is a valid
    # keyless device row (device row, no keys) — which AC1 explicitly permits — so no transaction
    # is required. The reverse order could leave a device_keys row with no devices row.
    :ok = upsert_device(user_id, device_id, display_name: display_name, last_seen_ts: now)

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
  #
  # The INNER JOIN onto `devices` intentionally requires a matching `devices` row for every
  # `device_keys` row. This can never hide a CURRENT key-bearing device, because:
  #   - migration 000010 backfilled a `devices` row for every legacy 000009 `device_keys` row, and
  #   - `put_device_keys/4` always upserts the `devices` row BEFORE the `device_keys` row.
  # So any device_keys row is guaranteed a devices row. The JOIN is defence-in-depth, not a filter:
  # AC3 already requires keyless devices (devices row, no device_keys row) be excluded from
  # /keys/query — which the JOIN's `device_keys` side naturally does. Do NOT loosen to a LEFT JOIN.
  @spec query_devices([String.t()]) :: %{optional(String.t()) => map()}
  def query_devices(user_ids) when is_list(user_ids) do
    case user_ids do
      [] ->
        %{}

      _ ->
        # AC3: join devices + device_keys, returning ONLY devices that have a device_keys row
        # (published keys). The device_display_name in `unsigned` is sourced from devices (the
        # join). Devices without keys MUST NOT appear; unknown users/devices are simply omitted.
        case safe_query(
               """
               SELECT dk.user_id, dk.device_id, dk.device_keys_json, d.display_name
               FROM device_keys dk
               JOIN devices d USING (user_id, device_id)
               WHERE dk.user_id = ANY($1)
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

  @doc """
  Lists a user's devices for `GET /devices`:
  `[%{device_id, display_name?, last_seen_ts?, last_seen_ip?}]`.

  AC4: sourced from `devices` so a KEYLESS device (no published keys) still appears.
  """
  @spec list_devices(String.t()) :: [map()]
  def list_devices(user_id) when is_binary(user_id) do
    case safe_query(
           "SELECT device_id, display_name, last_seen_ts, last_seen_ip, created_at FROM devices WHERE user_id = $1",
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &device_row/1)
      _ -> []
    end
  end

  # S2 AC5: how stale a device's last_seen_ts must be before an authenticated request
  # rewrites it. Spec-sanctioned throttle ("may be a few minutes out of date") so /sync
  # does not hammer the DB on every long-poll. 60s comfortably exceeds the test's
  # back-to-back /sync timing yet stays well under the spec's "few minutes".
  @last_seen_throttle_ms 60_000

  @doc """
  Best-effort, THROTTLED refresh of a device's `last_seen_ts`/`last_seen_ip` on
  authenticated activity (S2 AC5). Only writes when the existing `last_seen_ts` is older
  than the throttle window (or absent), so a burst of requests does not re-write on every
  call. NEVER raises — a registry write must not fail the /sync request it rides on. A
  no-op when the device row is unknown.
  """
  @spec touch_last_seen(String.t(), String.t(), String.t() | nil) :: :ok
  def touch_last_seen(user_id, device_id, last_seen_ip)
      when is_binary(user_id) and is_binary(device_id) do
    now = now_ms()
    cutoff = now - @last_seen_throttle_ms

    _ =
      safe_query(
        """
        UPDATE devices
           SET last_seen_ts = $3,
               last_seen_ip = COALESCE($4, last_seen_ip),
               updated_at   = $3
         WHERE user_id = $1 AND device_id = $2
           AND (last_seen_ts IS NULL OR last_seen_ts < $5)
        """,
        [user_id, device_id, now, last_seen_ip, cutoff]
      )

    :ok
  end

  @doc """
  Renames a device's `display_name`, scoped to the OWNING user (S3 AC2). Returns
  `:ok` when exactly the caller's device row was updated, `:error` when no such row
  exists for this user (unknown / another user's device → the caller maps to 404 —
  no IDOR, no existence oracle). Best-effort: never raises.
  """
  @spec rename_device(String.t(), String.t(), String.t() | nil) :: :ok | :error
  def rename_device(user_id, device_id, display_name)
      when is_binary(user_id) and is_binary(device_id) do
    now = now_ms()

    case safe_query(
           """
           UPDATE devices
              SET display_name = $3, updated_at = $4
            WHERE user_id = $1 AND device_id = $2
           """,
           [user_id, device_id, display_name, now]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> :error
    end
  end

  @doc """
  True when `device_id` exists in `devices` under a DIFFERENT user than `user_id`
  (S3 IDOR guard for delete). Lets a delete distinguish "absent for everyone"
  (idempotent → 200) from "owned by someone else" (→ 404). Read-path: never raises.
  """
  @spec belongs_to_other_user?(String.t(), String.t()) :: boolean()
  def belongs_to_other_user?(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    case safe_query(
           "SELECT 1 FROM devices WHERE device_id = $1 AND user_id <> $2 LIMIT 1",
           [device_id, user_id]
         ) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end

  @doc """
  Deletes ALL persisted state for a `(user_id, device_id)` (story
  s3-matrix-device-endpoints): the `devices` identity row plus its `device_keys`,
  `device_one_time_keys`, and `device_fallback_keys` material. Inline parameterised
  DELETEs, scoped to the OWNING user (never another user's device — no IDOR).
  Idempotent: deleting an absent device is a no-op. Best-effort: never raises.
  """
  @spec delete_device(String.t(), String.t()) :: :ok
  def delete_device(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    for table <- ["device_one_time_keys", "device_fallback_keys", "device_keys", "devices"] do
      _ =
        safe_query(
          "DELETE FROM #{table} WHERE user_id = $1 AND device_id = $2",
          [user_id, device_id]
        )
    end

    :ok
  end

  @doc "Returns one device for `GET /devices/{deviceId}`, or `nil` if unknown (sourced from `devices`)."
  @spec get_device(String.t(), String.t()) :: map() | nil
  def get_device(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case safe_query(
           "SELECT device_id, display_name, last_seen_ts, last_seen_ip, created_at FROM devices WHERE user_id = $1 AND device_id = $2",
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

  defp device_row([device_id, display_name, last_seen_ts, last_seen_ip, created_ts]) do
    # Matrix Device shape: optional fields are OMITTED when null (never serialised as null).
    # `created_ts` (S4 AC1 — the Admin UI shows when a device was first registered) is
    # the `devices.created_at` column surfaced under a stable key.
    %{"device_id" => device_id}
    |> maybe_put("display_name", display_name)
    |> maybe_put("last_seen_ts", last_seen_ts)
    |> maybe_put("last_seen_ip", last_seen_ip)
    |> maybe_put("created_ts", created_ts)
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
