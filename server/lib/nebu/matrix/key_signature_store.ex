defmodule Nebu.Matrix.KeySignatureStore do
  @moduledoc """
  `POST /keys/signatures/upload` (story key-query-hardening, epic e2ee-client-support, REQ-2026-014): who may sign what (D5), the Ed25519 verification of every
  signature (D6) and where a stored signature goes. Plain module, inline SQL (ADR-018), PostgreSQL only (cluster safe, ADR-020). The HTTP side is
  `Nebu.Matrix.HttpKeyQuery`.

  ## Who may sign what (D5)

  The caller C may upload a signature on

    * (a) one of C's own DEVICE keys, signed by C's self-signing key: merged into the stored device key object (as before, now verified),
    * (b) C's own MASTER key, signed by one of C's devices: merged into the stored master key object (`CrossSigningKeyStore.merge_signatures/4`),
    * (c) the MASTER key of ANOTHER user X (the object sits under X's id), signed by C's user-signing key, only when C and X share a room in which BOTH are joined
      (the predicate of `KeyClaimStore`): stored in `cross_signing_user_signatures` (migration 000061), apart from the key object, per (signer, target user,
      target key).

  Everything else is refused per entry with `:forbidden`: a foreign device, a foreign self-signing or user-signing key, C's own self-signing or user-signing key
  through this endpoint, a foreign master key without a shared joined room. The sharing check runs BEFORE any lookup of the target, and a user who is
  unknown, a user who shares no room and a user whose key is not the one named all end in the identical `:forbidden` (no existence oracle).

  ## Verification (D6)

  The message is the canonical JSON (`Nebu.Matrix.CanonicalJson.encode_strict/1`: UTF-8, keys sorted by code point, no whitespace, integers in
  [-(2^53)+1, 2^53-1], no floats) of the submitted object WITHOUT `signatures` and WITHOUT `unsigned`; the signature is the unpadded base64 of 64 bytes; the verifying
  key is the 32 byte unpadded base64 public key the caller stored under the key id named by the signature (`signatures[C]["ed25519:<id>"]`): the stored
  self-signing key for (a), the stored ed25519 key of one of the caller's devices for (b), the stored user-signing key for (c). A valid signature by another
  key of the caller (a device key on a device, the self-signing key on the master key, ...) is NOT enough. The submitted object must also equal the stored key
  object apart from `signatures` and `unsigned`. A bad signature, an unknown signing key id or a changed object is `:invalid_signature` and nothing is stored for
  the entry; a malformed object or `signatures` member, or no signature by the caller, is `:invalid_param`. Only the signatures of the caller are ever stored.

  The signatures are verified BEFORE any lock is taken (no row lock is held across an Ed25519 verification); the write re-reads the target under its lock and
  re-checks the object, so a concurrent key replacement is never overwritten.

  ## Locks (the order of the device-key directory: `devices` -> `device_keys` -> stream row)

    * (a) `device_keys` row `FOR UPDATE`, then the stream stamp of the caller (only when the stored object changed);
    * (b) the lock protocol of `CrossSigningKeyStore.merge_signatures/4` (row, advisory, read);
    * (c) the per-user `sync_global|<user>` advisory locks of the signer and the target (sorted, so two signers who sign each other cannot cycle), then the
      writes. They are the fence of the erasure: the erasure holds the advisory lock of the erased user until it commits, so an insert either lands before its
      DELETE or waits and finds `deletion_status` set (and stores nothing). A replaced master key of the target (`CrossSigningKeyStore.put_keys/2` holds the
      same advisory lock and drops the rows of the old key in its transaction) cannot interleave with the insert.

  ## Device-list stream (D10)

  A stored cross-user signature stamps the SIGNER's own key row of `device_list_changes` (the signer's other devices see the change in `device_lists.changed` and
  re-query), never the target (the signature is invisible to everybody else). An identical signature stored again changes nothing and stamps nothing.

  Nothing in an error or a log line carries a key id, an object or a signature.
  """

  require Logger

  alias Nebu.Matrix.{CanonicalJson, CrossSigningKeyStore, DeviceListStore}

  # signatures by the caller on ONE object; a bound before any verification (an object that names more is `:invalid_param`). Only the CALLER's signatures are
  # ever verified (those of other users are ignored, not verified, not stored), so one request costs at most 200 objects x 4 = 800 Ed25519 verifications.
  @max_signatures_per_object 4
  @max_id_bytes 255

  @type reason :: :invalid_param | :forbidden | :invalid_signature

  @doc """
  Processes the entries `[{user_id, key_id, signed_object}]` of an upload for `caller` and returns `{:ok, failures}` with `failures` a list of
  `{user_id, key_id, reason}` (valid entries are applied, partial success), or `{:error, :internal}` when a database error stopped the request.
  """
  @spec process(String.t(), [{String.t(), String.t(), term()}]) :: {:ok, [{String.t(), String.t(), reason()}]} | {:error, :internal}
  def process(_caller, []), do: {:ok, []}

  def process(caller, entries) when is_binary(caller) and is_list(entries) do
    with {:ok, own} <- load_own(caller) do
      Enum.reduce_while(entries, {:ok, []}, fn {user_id, key_id, obj}, {:ok, failures} ->
        case upload(caller, own, user_id, key_id, obj) do
          :ok -> {:cont, {:ok, failures}}
          {:error, :internal} -> {:halt, {:error, :internal}}
          {:error, reason} -> {:cont, {:ok, [{user_id, key_id, reason} | failures]}}
        end
      end)
    end
  rescue
    e ->
      Logger.error("keys/signatures/upload: the request failed (#{error_kind(e)})")
      {:error, :internal}
  catch
    :exit, _reason ->
      Logger.error("keys/signatures/upload: the request failed (exit)")
      {:error, :internal}
  end

  # ── the caller's own keys (read once per request: the uploads change signatures only, never keys) ──

  defp load_own(caller) do
    sql = """
    SELECT 'd'::text, device_id, device_keys_json, NULL::text FROM device_keys WHERE user_id = $1
    UNION ALL
    SELECT 'c', master_key_json, self_signing_key_json, user_signing_key_json FROM cross_signing_keys WHERE user_id = $1
    """

    case query(sql, [caller]) do
      {:ok, %{rows: rows}} ->
        devices = for ["d", did, json, _] <- rows, into: %{}, do: {did, Jason.decode!(json)}

        {master, ssk, usk} =
          case Enum.find(rows, &match?(["c" | _], &1)) do
            ["c", mk, ssk, usk] -> {decode(mk), decode(ssk), decode(usk)}
            nil -> {nil, nil, nil}
          end

        {:ok, %{devices: devices, master: master, ssk: ssk, usk: usk}}

      {:error, error} ->
        Logger.error("keys/signatures/upload: reading the own keys failed (#{error_kind(error)})")
        {:error, :internal}
    end
  end

  # ── one entry ──

  defp upload(caller, own, user_id, key_id, obj) do
    with {:ok, sigs} <- check_shape(caller, user_id, key_id, obj) do
      if user_id == caller, do: upload_own(caller, own, key_id, obj, sigs), else: upload_foreign(caller, own, user_id, key_id, obj, sigs)
    end
  end

  # a malformed entry is the same answer whatever the state is; `sigs` are the signatures of the CALLER (a map prop => signature)
  defp check_shape(caller, user_id, key_id, obj) do
    with true <- valid_id?(user_id) and valid_id?(key_id),
         true <- is_map(obj),
         %{} = all <- Map.get(obj, "signatures"),
         true <- Enum.all?(all, fn {_signer, per} -> is_map(per) end),
         %{} = mine <- Map.get(all, caller),
         true <- map_size(mine) in 1..@max_signatures_per_object do
      {:ok, mine}
    else
      _ -> {:error, :invalid_param}
    end
  end

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..@max_id_bytes and not String.contains?(id, <<0>>)

  # (a) / (b), and the refusals of the own self-signing and user-signing key
  defp upload_own(caller, own, key_id, obj, sigs) do
    case own_target(own, key_id) do
      {:device, stored} ->
        with :ok <- verify(obj, stored, sigs, self_signing_keys(own)), do: write_device(caller, key_id, obj, sigs)

      {:master, stored} ->
        with :ok <- verify(obj, stored, sigs, device_keys(own)) do
          case CrossSigningKeyStore.merge_signatures(caller, key_id, %{caller => sigs}, obj) do
            :ok -> :ok
            :not_found -> {:error, :invalid_signature}
          end
        end

      :forbidden ->
        {:error, :forbidden}

      :none ->
        {:error, :invalid_signature}
    end
  end

  # the device key id wins over a cross-signing key id (the order of the earlier merge)
  defp own_target(own, key_id) do
    cond do
      Map.has_key?(own.devices, key_id) -> {:device, Map.fetch!(own.devices, key_id)}
      has_key_id?(own.master, key_id) -> {:master, own.master}
      has_key_id?(own.ssk, key_id) or has_key_id?(own.usk, key_id) -> :forbidden
      true -> :none
    end
  end

  defp has_key_id?(%{"keys" => keys}, key_id) when is_map(keys), do: Enum.any?(Map.keys(keys), &(CrossSigningKeyStore.key_id_of(&1) == key_id))
  defp has_key_id?(_obj, _key_id), do: false

  # the public key value of the key named `key_id` (the smallest property when several share the id, so the choice is deterministic)
  defp key_value_of(%{"keys" => keys}, key_id) when is_map(keys) do
    keys |> Enum.filter(fn {prop, value} -> CrossSigningKeyStore.key_id_of(prop) == key_id and is_binary(value) end) |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> List.first()
  end

  defp key_value_of(_obj, _key_id), do: nil

  # the keys a signature of the caller may be verified with: prop ("ed25519:<id>") => public key
  defp self_signing_keys(%{ssk: %{"keys" => keys}}) when is_map(keys), do: keys
  defp self_signing_keys(_own), do: %{}

  defp user_signing_keys(%{usk: %{"keys" => keys}}) when is_map(keys), do: keys
  defp user_signing_keys(_own), do: %{}

  defp device_keys(%{devices: devices}) do
    for {did, %{"keys" => keys}} <- devices, is_map(keys), pub = Map.get(keys, "ed25519:" <> did), is_binary(pub), into: %{}, do: {"ed25519:" <> did, pub}
  end

  # (c): the sharing check and the lookup of the master key are ONE statement, and every refusal is the identical `:forbidden`
  defp upload_foreign(caller, own, user_id, key_id, obj, sigs) do
    sql = """
    SELECT c.master_key_json FROM cross_signing_keys c
     WHERE c.user_id = $2
       AND EXISTS (SELECT 1 FROM room_members o JOIN room_members m ON m.room_id = o.room_id
                    WHERE o.user_id = $2 AND o.left_at IS NULL AND m.user_id = $1 AND m.left_at IS NULL)
    """

    case query(sql, [caller, user_id]) do
      {:ok, %{rows: [[master_json]]}} when is_binary(master_json) ->
        master = Jason.decode!(master_json)

        if has_key_id?(master, key_id) do
          with :ok <- verify(obj, master, sigs, user_signing_keys(own)), do: write_cross_user(caller, user_id, key_id, obj, sigs)
        else
          # a device, the self-signing or the user-signing key of the other user (or an unknown key id)
          {:error, :forbidden}
        end

      {:ok, _no_row} ->
        {:error, :forbidden}

      {:error, error} ->
        Logger.error("keys/signatures/upload: the lookup failed (#{error_kind(error)})")
        {:error, :internal}
    end
  end

  # ── verification (D6): no lock is held ──

  # `stored`: the stored key object; `sigs`: prop => signature of the caller; `keys`: prop => public key the caller may sign with
  defp verify(obj, stored, sigs, keys) do
    strip = fn o -> Map.drop(o, ["signatures", "unsigned"]) end

    with true <- strip.(stored) === strip.(obj),
         {:ok, message} <- CanonicalJson.encode_strict(strip.(obj)),
         true <- Enum.all?(sigs, fn {prop, signature} -> verify_one(message, signature, Map.get(keys, prop)) end) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_one(message, signature, public_key) when is_binary(signature) and is_binary(public_key) do
    with {:ok, sig} <- Base.decode64(signature, padding: false),
         64 <- byte_size(sig),
         {:ok, pub} <- Base.decode64(public_key, padding: false),
         32 <- byte_size(pub) do
      :crypto.verify(:eddsa, :none, message, sig, [pub, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp verify_one(_message, _signature, _public_key), do: false

  # ── writes ──

  # (a) merge the signatures of the caller into the stored device key object under the row lock; the object is compared again under the lock
  defp write_device(caller, device_id, obj, sigs) do
    result =
      Nebu.Repo.transaction(fn ->
        case query("SELECT device_keys_json FROM device_keys WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [caller, device_id]) do
          {:ok, %{rows: [[json]]}} ->
            stored = Jason.decode!(json)

            if Map.drop(stored, ["signatures", "unsigned"]) === Map.drop(obj, ["signatures", "unsigned"]) do
              merged = merge_signatures(Map.get(stored, "signatures"), %{caller => sigs})

              if Map.get(stored, "signatures") === merged and not Map.has_key?(stored, "unsigned"),
                do: :ok,
                else: store_device_json(caller, device_id, stored |> Map.delete("unsigned") |> Map.put("signatures", merged) |> Jason.encode!())
            else
              # the device re-uploaded its keys in between: the signed object is not the stored one any more
              Nebu.Repo.rollback(:invalid_signature)
            end

          {:ok, %{rows: []}} ->
            Nebu.Repo.rollback(:invalid_signature)

          {:error, error} ->
            Nebu.Repo.rollback({:db, error})
        end
      end)

    outcome(result)
  end

  defp store_device_json(caller, device_id, new_json) do
    case query("UPDATE device_keys SET device_keys_json = $3, updated_at = $4 WHERE user_id = $1 AND device_id = $2", [caller, device_id, new_json, now_ms()]) do
      {:ok, _} -> DeviceListStore.stamp_keys!(Nebu.Repo, caller)
      {:error, error} -> Nebu.Repo.rollback({:db, error})
    end
  end

  @advisory "SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))"

  @upsert """
  INSERT INTO cross_signing_user_signatures (user_id, target_user_id, target_key_id, target_key, signing_key_id, signature, updated_at)
  SELECT $1::text, $2::text, $3::text, $7::text, $4::text, $5::text, $6::bigint
   WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id IN ($1::text, $2::text) AND deletion_status IS NOT NULL)
  ON CONFLICT (user_id, target_user_id, target_key_id) DO UPDATE
    SET target_key = EXCLUDED.target_key, signing_key_id = EXCLUDED.signing_key_id, signature = EXCLUDED.signature, updated_at = EXCLUDED.updated_at
  """

  # (c) one row per (signer, target user, target key), replaced idempotently
  defp write_cross_user(caller, target, key_id, obj, sigs) do
    # one signature per row: sorted, so the choice does not depend on the map order (every one of them verified)
    {signing_key_id, signature} = sigs |> Enum.sort() |> hd()
    [first, second] = Enum.sort([caller, target])

    result =
      Nebu.Repo.transaction(fn ->
        with {:ok, _} <- query(@advisory, [first]),
             {:ok, _} <- query(@advisory, [second]),
             {:ok, %{rows: [[master_json]]}} <- query("SELECT master_key_json FROM cross_signing_keys WHERE user_id = $1", [target]),
             true <- is_binary(master_json),
             master = Jason.decode!(master_json),
             true <- has_key_id?(master, key_id) and Map.drop(master, ["signatures", "unsigned"]) === Map.drop(obj, ["signatures", "unsigned"]),
             # the row is bound to the key itself (id AND public key value), see migration 000061
             target_key when is_binary(target_key) <- key_value_of(master, key_id),
             {:ok, %{rows: existing}} <-
               query("SELECT signing_key_id, signature FROM cross_signing_user_signatures WHERE user_id = $1 AND target_user_id = $2 AND target_key_id = $3", [caller, target, key_id]),
             {:ok, %{num_rows: n}} <- query(@upsert, [caller, target, key_id, signing_key_id, signature, now_ms(), target_key]),
             true <- n > 0 do
          # D10: the SIGNER's key row is stamped (not the target's), and only when the stored signature changed
          if existing != [[signing_key_id, signature]], do: DeviceListStore.stamp_keys!(Nebu.Repo, caller)
          :ok
        else
          {:error, error} -> Nebu.Repo.rollback({:db, error})
          # the master key was replaced in between, the target has none, or one of the two users is erased: nothing is stored
          _ -> Nebu.Repo.rollback(:invalid_signature)
        end
      end)

    outcome(result)
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, :invalid_signature}), do: {:error, :invalid_signature}

  defp outcome({:error, {:db, error}}) do
    Logger.error("keys/signatures/upload: the write failed (#{error_kind(error)})")
    {:error, :internal}
  end

  defp outcome({:error, _other}), do: {:error, :internal}

  # the stored `signatures` may be malformed (the key upload does not validate its shape): a value or a per-signer value that is not a map counts as none
  defp merge_signatures(existing, new) do
    Map.merge(signature_map(existing), signature_map(new), fn _signer, old, added -> Map.merge(old, added) end)
  end

  defp signature_map(sigs) when is_map(sigs), do: for({signer, per} <- sigs, is_map(per), into: %{}, do: {signer, per})
  defp signature_map(_sigs), do: %{}

  defp decode(nil), do: nil
  defp decode(json) when is_binary(json), do: Jason.decode!(json)

  defp now_ms, do: System.system_time(:millisecond)

  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)

  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"
end
