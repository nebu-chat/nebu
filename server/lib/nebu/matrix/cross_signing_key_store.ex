defmodule Nebu.Matrix.CrossSigningKeyStore do
  @moduledoc """
  The Matrix cross-signing key DIRECTORY (story: cross-signing-readback).

  Stores and serves a user's cross-signing keys — `master_key`,
  `self_signing_key`, and `user_signing_key` — published via
  `POST /_matrix/client/v3/keys/device_signing/upload` and read back via
  `POST /_matrix/client/v3/keys/query`. Signatures added via
  `POST /_matrix/client/v3/keys/signatures/upload` are merged into the relevant
  stored key object's `signatures` map.

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018 — no Ecto
  schema, no Repository/Service layer). PostgreSQL-backed rather than ETS so the
  directory is cluster-correct (ADR-020: an upload and a later query may land on
  different nodes) and survives restarts (read-on-start: every read hits the
  committed Postgres row).

  IMPORTANT — this is ORTHOGONAL to end-to-end encryption (ADR-011): persisting
  and echoing these public cross-signing keys encrypts nothing. The server never
  decrypts and never gains a private part. E2EE is only enabled when a client
  sends an `m.room.encryption` state event, which Nebu rejects.
  """

  @key_specs [
    {"master_key", "master_key_json", "master"},
    {"self_signing_key", "self_signing_key_json", "self_signing"},
    {"user_signing_key", "user_signing_key_json", "user_signing"}
  ]

  @doc """
  Upserts a user's cross-signing keys. `keys` is the upload body shape
  `%{"master_key" => obj, "self_signing_key" => obj, "user_signing_key" => obj}`;
  any of the three may be absent or nil (stored as SQL NULL). Sets the
  consume-once `cross_signing_changed` flag so the next incremental `/sync`
  surfaces the user in `device_lists.changed`.
  """
  @spec put_keys(String.t(), map()) :: :ok
  def put_keys(user_id, keys) when is_binary(user_id) and is_map(keys) do
    now = now_ms()

    {:ok, _} =
      query(
        """
        INSERT INTO cross_signing_keys
          (user_id, master_key_json, self_signing_key_json, user_signing_key_json,
           cross_signing_changed, created_at, updated_at)
        VALUES ($1, $2, $3, $4, TRUE, $5, $5)
        ON CONFLICT (user_id) DO UPDATE
          SET master_key_json       = EXCLUDED.master_key_json,
              self_signing_key_json = EXCLUDED.self_signing_key_json,
              user_signing_key_json = EXCLUDED.user_signing_key_json,
              cross_signing_changed = TRUE,
              updated_at            = EXCLUDED.updated_at
        """,
        [
          user_id,
          encode_key(keys["master_key"]),
          encode_key(keys["self_signing_key"]),
          encode_key(keys["user_signing_key"]),
          now
        ]
      )

    :ok
  end

  @doc """
  Returns a user's stored cross-signing keys as
  `%{"master_key" => obj|nil, "self_signing_key" => obj|nil, "user_signing_key" => obj|nil}`.
  A user with nothing stored yields a map with all-nil values.
  """
  @spec get_keys(String.t()) :: %{optional(String.t()) => map() | nil}
  def get_keys(user_id) when is_binary(user_id) do
    empty = %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}

    case safe_query(
           """
           SELECT master_key_json, self_signing_key_json, user_signing_key_json
           FROM cross_signing_keys
           WHERE user_id = $1
           """,
           [user_id]
         ) do
      {:ok, %{rows: [[mk, ssk, usk]]}} ->
        %{
          "master_key" => decode_key(mk),
          "self_signing_key" => decode_key(ssk),
          "user_signing_key" => decode_key(usk)
        }

      _ ->
        empty
    end
  end

  @doc """
  Bulk lookup for `/keys/query`. Returns, for each requested user that has stored
  cross-signing keys, `%{"master" => obj, "self_signing" => obj, "user_signing" => obj}`
  (absent keys omitted). Users with nothing stored are omitted from the result.
  Read path that never raises (mirrors `DeviceKeyStore`).
  """
  @spec query_cross_signing([String.t()]) :: %{optional(String.t()) => map()}
  def query_cross_signing(user_ids) when is_list(user_ids) do
    case user_ids do
      [] ->
        %{}

      _ ->
        case safe_query(
               """
               SELECT user_id, master_key_json, self_signing_key_json, user_signing_key_json
               FROM cross_signing_keys
               WHERE user_id = ANY($1)
               """,
               [user_ids]
             ) do
          {:ok, %{rows: rows}} ->
            Enum.reduce(rows, %{}, fn [uid, mk, ssk, usk], acc ->
              entry =
                %{}
                |> maybe_put("master", decode_key(mk))
                |> maybe_put("self_signing", decode_key(ssk))
                |> maybe_put("user_signing", decode_key(usk))

              if map_size(entry) > 0, do: Map.put(acc, uid, entry), else: acc
            end)

          _ ->
            %{}
        end
    end
  end

  @doc """
  Merges signatures into the stored cross-signing key object whose key-id matches
  `key_id`. `new_signatures` is the `signatures` map carried by the signed object.
  Returns `:ok` if a matching cross-signing key was updated, `:not_found` otherwise
  (caller then treats the key-id as a non-cross-signing key, e.g. a device key).
  """
  @spec merge_signatures(String.t(), String.t(), map()) :: :ok | :not_found
  def merge_signatures(user_id, key_id, new_signatures)
      when is_binary(user_id) and is_binary(key_id) and is_map(new_signatures) do
    stored = get_keys(user_id)

    case find_matching_key(stored, key_id) do
      nil ->
        :not_found

      {body_key, obj} ->
        merged = deep_merge_signatures(obj, new_signatures)
        :ok = persist_single(user_id, body_key, merged)
        :ok
    end
  end

  @doc """
  Returns the stored cross-signing key OBJECT whose `keys` map contains `key_id`
  (the part after `ed25519:`), or `nil` if the user has no such cross-signing key.
  Read-only — performs NO write. The caller (`signatures/upload`) uses this to
  validate the submitted object against the stored one BEFORE merging signatures,
  so a mismatch never mutates the directory (validate-then-persist).
  """
  @spec find_key_object(String.t(), String.t()) :: map() | nil
  def find_key_object(user_id, key_id) when is_binary(user_id) and is_binary(key_id) do
    case find_matching_key(get_keys(user_id), key_id) do
      {_body_key, obj} -> obj
      nil -> nil
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Find the stored cross-signing key object whose `keys` map contains key_id
  # (the part after "ed25519:"). Returns {upload_body_key, object} or nil.
  defp find_matching_key(stored, key_id) do
    Enum.find_value(@key_specs, fn {body_key, _col, _short} ->
      case stored[body_key] do
        %{"keys" => keys} = obj when is_map(keys) ->
          if Enum.any?(keys, fn {prop, _} -> key_id_of(prop) == key_id end), do: {body_key, obj}, else: nil

        _ ->
          nil
      end
    end)
  end

  # Re-persist a single cross-signing key object, preserving the other two.
  defp persist_single(user_id, body_key, obj) do
    current = get_keys(user_id)
    keys = Map.put(current, body_key, obj)
    put_keys_no_flag(user_id, keys)
  end

  # Like put_keys/2 but does NOT touch cross_signing_changed (a signature merge is
  # not itself a key change that needs a fresh device_lists.changed; the upload that
  # created the key already set the flag). Updates updated_at only.
  defp put_keys_no_flag(user_id, keys) do
    now = now_ms()

    {:ok, _} =
      query(
        """
        INSERT INTO cross_signing_keys
          (user_id, master_key_json, self_signing_key_json, user_signing_key_json,
           cross_signing_changed, created_at, updated_at)
        VALUES ($1, $2, $3, $4, FALSE, $5, $5)
        ON CONFLICT (user_id) DO UPDATE
          SET master_key_json       = EXCLUDED.master_key_json,
              self_signing_key_json = EXCLUDED.self_signing_key_json,
              user_signing_key_json = EXCLUDED.user_signing_key_json,
              updated_at            = EXCLUDED.updated_at
        """,
        [
          user_id,
          encode_key(keys["master_key"]),
          encode_key(keys["self_signing_key"]),
          encode_key(keys["user_signing_key"]),
          now
        ]
      )

    :ok
  end

  @doc """
  Reads and clears the consume-once `cross_signing_changed` flag for `user_id`.
  Returns `true` if the flag was set (and is now cleared), `false` otherwise.
  Used by the incremental `/sync` path to surface the user in `device_lists.changed`
  exactly once after a cross-signing key change. Atomic via `UPDATE ... RETURNING`
  so it is cluster-correct.
  """
  @spec consume_changed_flag(String.t()) :: boolean()
  def consume_changed_flag(user_id) when is_binary(user_id) do
    case safe_query(
           """
           UPDATE cross_signing_keys
           SET cross_signing_changed = FALSE
           WHERE user_id = $1 AND cross_signing_changed = TRUE
           RETURNING user_id
           """,
           [user_id]
         ) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end

  # Deep-merge new signatures into obj["signatures"] (per (signing_user, key_id)),
  # preserving existing signatures.
  defp deep_merge_signatures(obj, new_signatures) do
    existing = Map.get(obj, "signatures", %{})

    merged =
      Map.merge(existing, new_signatures, fn _signer, old_map, new_map ->
        Map.merge(old_map || %{}, new_map || %{})
      end)

    Map.put(obj, "signatures", merged)
  end

  # "ed25519:ABCDEF" -> "ABCDEF"; "ed25519:PUB...." -> "PUB....".
  @doc false
  def key_id_of(prop) when is_binary(prop) do
    case String.split(prop, ":", parts: 2) do
      [_algorithm, key_id] -> key_id
      _ -> prop
    end
  end

  @doc """
  Extracts the cross-signing key-ids (the `<pub>` part of each `ed25519:<pub>` in a
  key object's `keys` map) from an upload body. Used by the namespace MUST-guard.
  """
  @spec key_ids_in_upload(map()) :: [String.t()]
  def key_ids_in_upload(body) when is_map(body) do
    @key_specs
    |> Enum.flat_map(fn {body_key, _col, _short} ->
      case body[body_key] do
        %{"keys" => keys} when is_map(keys) -> Enum.map(Map.keys(keys), &key_id_of/1)
        _ -> []
      end
    end)
  end

  defp encode_key(nil), do: nil
  defp encode_key(obj) when is_map(obj), do: Jason.encode!(obj)

  defp decode_key(nil), do: nil
  defp decode_key(json) when is_binary(json), do: Jason.decode!(json)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
