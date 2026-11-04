defmodule Nebu.Matrix.KeyQueryStore do
  @moduledoc """
  `POST /keys/query` (story key-query-hardening, epic e2ee-client-support, REQ-2026-014). Plain module, inline SQL (ADR-018), PostgreSQL only (cluster safe, ADR-020).

  ## Visibility (D1) and no oracle

  The caller V sees the device keys, the master key and the self-signing key of a requested user X only when X is V, or V and X share a room in which BOTH
  are currently joined (`room_members.left_at IS NULL` on both sides: the predicate of `KeyClaimStore` and `DeviceListStore`). Every other X (not shared,
  invite-only, left, unknown, keyless, remote, malformed id) is left out, so the answer is byte-identical for all of them: ONE statement serves every request
  (the visibility join is part of it, there is no early return per user and no state-dependent status), and `failures` is always empty (it is keyed by server name,
  Nebu has no federation).

  The user-signing key (D2) is returned to its owner only, and only when the owner queried itself.

  ## Signatures on the master key (D4)

  A viewer V sees on the master key of X the signatures made by X's own keys (the self signatures, the signatures of X's devices) and the signatures made by V
  (the cross-user signatures of `cross_signing_user_signatures`, read for the viewer as signer only), never a signature by a third user. A stored cross-user
  signature is shown only while its target key is still a key of the CURRENT master key of X (a replaced master key drops its rows, this check also covers a
  row that a concurrent replacement left behind).
  """

  @sql """
  WITH vis AS MATERIALIZED (
         SELECT DISTINCT r.u AS user_id FROM unnest($2::text[]) AS r(u)
          WHERE r.u = $1
             OR EXISTS (SELECT 1 FROM room_members o JOIN room_members m ON m.room_id = o.room_id
                         WHERE o.user_id = r.u AND o.left_at IS NULL AND m.user_id = $1 AND m.left_at IS NULL))
  SELECT 'd'::text, dk.user_id, dk.device_id, dk.device_keys_json, d.display_name, NULL::text
    FROM device_keys dk JOIN devices d USING (user_id, device_id) JOIN vis ON vis.user_id = dk.user_id
  UNION ALL
  SELECT 'c', c.user_id, c.master_key_json, c.self_signing_key_json, c.user_signing_key_json, NULL
    FROM cross_signing_keys c JOIN vis ON vis.user_id = c.user_id
  UNION ALL
  SELECT 's', s.target_user_id, s.target_key_id, s.signing_key_id, s.signature, s.target_key
    FROM cross_signing_user_signatures s JOIN vis ON vis.user_id = s.target_user_id
   WHERE s.user_id = $1
  """

  @doc """
  The answer maps of `/keys/query` for `caller`: `requested` is the `device_keys` member of the request (`%{user_id => [device ids]}`, an empty list selects
  every device). `{:ok, %{device_keys, master_keys, self_signing_keys, user_signing_keys}}` with the visible users only, or `{:error, reason}`.
  """
  @spec query(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def query(caller, requested) when is_binary(caller) and is_map(requested) do
    # a NUL cannot be stored in text: such an id names nobody (dropped for every caller alike, not a state dependent branch)
    ids = requested |> Map.keys() |> Enum.filter(&(is_binary(&1) and not String.contains?(&1, <<0>>)))

    # a request that names nobody (an empty `device_keys`) is answered without a statement: the decision depends on the request only, never on any state
    if ids == [] do
      {:ok, build(caller, requested, [])}
    else
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql, [caller, ids]) do
        {:ok, %{rows: rows}} -> {:ok, build(caller, requested, rows)}
        {:error, error} -> {:error, error}
      end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp build(caller, requested, rows) do
    devices =
      Enum.reduce(rows, %{}, fn
        ["d", uid, did, json, name, _], acc -> put_device(acc, requested, uid, did, json, name)
        _row, acc -> acc
      end)

    cross = for ["c", uid, mk, ssk, usk, _] <- rows, into: %{}, do: {uid, {decode(mk), decode(ssk), decode(usk)}}

    sigs =
      Enum.reduce(rows, %{}, fn
        ["s", uid, key_id, signing_key_id, signature, target_key], acc ->
          entry = {key_id, target_key, signing_key_id, signature}
          Map.update(acc, uid, [entry], &[entry | &1])

        _row, acc -> acc
      end)

    %{
      device_keys: devices,
      master_keys: collect(cross, 0, fn uid, obj -> master_for(caller, uid, obj, Map.get(sigs, uid, [])) end),
      self_signing_keys: collect(cross, 1, fn _uid, obj -> obj end),
      # D2: the user-signing key is visible to its owner only (and only when the owner queried itself)
      user_signing_keys: cross |> collect(2, fn _uid, obj -> obj end) |> Map.take([caller])
    }
  end

  defp put_device(acc, requested, uid, did, json, name) do
    wanted = Map.get(requested, uid)

    if is_list(wanted) and wanted != [] and did not in wanted do
      acc
    else
      info = json |> Jason.decode!() |> Map.put("unsigned", unsigned(name))
      Map.update(acc, uid, %{did => info}, &Map.put(&1, did, info))
    end
  end

  defp unsigned(nil), do: %{}
  defp unsigned(name), do: %{"device_display_name" => name}

  defp collect(cross, index, fun) do
    Enum.reduce(cross, %{}, fn {uid, keys}, acc ->
      case elem(keys, index) do
        nil -> acc
        obj -> Map.put(acc, uid, fun.(uid, obj))
      end
    end)
  end

  # D4: the signatures of the master key of `uid` for `caller`: the own signatures of `uid` and the ones made by the caller
  defp master_for(caller, uid, obj, cross_sigs) do
    own = signer_map(Map.get(obj, "signatures"), uid)
    # the row is bound to the KEY, not only to its id: a replacement keeping the id with another public key shows no stale signature
    pairs = master_key_pairs(obj)

    visible =
      if caller == uid do
        own
      else
        mine = for {key_id, target_key, signing_key_id, signature} <- cross_sigs, {key_id, target_key} in pairs, into: %{}, do: {signing_key_id, signature}
        if map_size(mine) == 0, do: own, else: Map.put(own, caller, mine)
      end

    if map_size(visible) == 0 and not Map.has_key?(obj, "signatures"), do: obj, else: Map.put(obj, "signatures", visible)
  end

  # only the signatures of the owner of the key, as a map of maps (empty when there are none)
  defp signer_map(sigs, uid) when is_map(sigs) do
    case Map.get(sigs, uid) do
      per when is_map(per) -> %{uid => per}
      _ -> %{}
    end
  end

  defp signer_map(_sigs, _uid), do: %{}

  defp master_key_pairs(%{"keys" => keys}) when is_map(keys), do: for({prop, key} <- keys, is_binary(key), do: {Nebu.Matrix.CrossSigningKeyStore.key_id_of(prop), key})
  defp master_key_pairs(_obj), do: []

  defp decode(nil), do: nil
  defp decode(json) when is_binary(json), do: Jason.decode!(json)
end
