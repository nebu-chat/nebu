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

  ## The own key change in `/sync` (story sync-token-per-device, D9)

  `put_keys/2` stamps `changed_pos` from the sequence `sync_global_pos_seq` (shared with `account_data.stream_pos`)
  next to the consume-once `cross_signing_changed` flag, in a transaction that first takes the per-user lock
  `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))` (the SAME key as
  `AccountDataStore.put/3`: for one user the position order is the commit order). A DEVICE-bound `/sync` lists the
  own user in `device_lists.changed` when `changed_pos` is above the device's `sync_tokens.cross_signing_pos`
  (`changed_since?/2`, nothing is consumed: every device, the uploader included, sees the change once). The flag is
  read-and-cleared only by DEVICE-LESS requests (`consume_changed_flag/1`). A signature merge moves neither. A key
  upload sends no `/sync` wake-up (the entry is delivered with the next response).

  ## Writers decide on the locked read (story cross-signing-upload-races, follow-up `cq` (g))

  Every writer that DECIDES on the stored keys (the first-upload / stored-keys branch and the OAuth replacement of
  `POST /keys/device_signing/upload`, the signature merge of `POST /keys/signatures/upload`) reads them with
  `lock_keys/1`, inside the transaction that also writes: the `cross_signing_keys` row lock (`FOR UPDATE`), then the
  per-user `sync_global|` advisory lock, and only THEN the read (row -> advisory -> read). That is the documented
  order of the erasure (`Nebu.Compliance.UserDeletion`, step 4a: row locks, then the advisory lock), so the writers
  and the erasure do not form a lock cycle, with ONE exception (the absent-then-present window, below). Every writer of the key columns (`put_keys/2`, the merge, the erasure DELETE) holds the advisory lock
  when it writes, and under Read Committed the read after the advisory lock sees every commit of the previous holder,
  so the decision stays valid until the caller commits: two concurrent first uploads store one key set (the row of an
  absent user locks nothing, the advisory lock serialises them), and a signature merge never writes back a stale
  merge base. `get_keys/1` (error-blind, unlocked) is a plain read and never the base of a write decision.

  The absent-then-present window (accepted residual): the row lock of `lock_keys/1` locks nothing when the row does
  not exist yet. When a signature merge took that empty row lock and waits for the advisory lock while a first upload
  commits the row, and an erasure of the same user then locks the new row and also waits for the advisory lock, the
  merge can get the advisory lock first and then wait for the row in its write (`put_keys_no_flag/2`) while the
  erasure waits for the merge's advisory lock: a cycle. PostgreSQL detects it and aborts one side (`40P01`): either
  the erasure fails closed (rolled back, audited, retried by the operator) or the merge answers 500. Three actors of
  one user in a window of milliseconds; it cannot be closed without flipping the lock order everywhere (advisory
  first), which story cross-signing-upload-races rejected. A first upload has the same window: when its row lock
  found no row and a row with a NULL master (e.g. a partial first upload with only a self-signing key) is committed
  before it gets the advisory lock, its read still sees no master, and the first-upload upsert of `put_keys/2` takes
  the row lock only after the advisory lock (advisory -> row) against an erasure that holds the row and waits for the
  advisory lock. PostgreSQL resolves it the same way (`40P01`: the erasure fails closed, or the upload answers 500).
  Pre-existing and accepted. (A row that already exists when `lock_keys/1` runs is held from the start, and a
  committed row WITH a master leads to no write, so neither opens the window.)

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
  consume-once `cross_signing_changed` flag (device-less `/sync`) and draws a new
  `changed_pos` (device-bound `/sync`, also for identical keys), under the per-user
  `sync_global|` advisory lock in one transaction (nested in the caller's transaction
  when there is one: the lock then lives until that commits). A failed write returns
  `{:error, reason}`.
  """
  @spec put_keys(String.t(), map()) :: :ok | {:error, term()}
  def put_keys(user_id, keys) when is_binary(user_id) and is_map(keys) do
    now = now_ms()

    result =
      Nebu.Repo.transaction(fn ->
        with {:ok, _} <- query("SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))", [user_id]),
             {:ok, %{num_rows: n}} <-
               query(
                 """
                 INSERT INTO cross_signing_keys
                   (user_id, master_key_json, self_signing_key_json, user_signing_key_json,
                    cross_signing_changed, changed_pos, created_at, updated_at)
                 SELECT $1::text, $2::text, $3::text, $4::text, TRUE, nextval('sync_global_pos_seq'), $5::bigint, $5::bigint
                 WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = $1::text AND deletion_status IS NOT NULL)
                 ON CONFLICT (user_id) DO UPDATE
                   SET master_key_json       = EXCLUDED.master_key_json,
                       self_signing_key_json = EXCLUDED.self_signing_key_json,
                       user_signing_key_json = EXCLUDED.user_signing_key_json,
                       cross_signing_changed = TRUE,
                       changed_pos           = nextval('sync_global_pos_seq'),
                       updated_at            = EXCLUDED.updated_at
                 """,
                 [
                   user_id,
                   encode_key(keys["master_key"]),
                   encode_key(keys["self_signing_key"]),
                   encode_key(keys["user_signing_key"]),
                   now
                 ]
               ),
             # story gdpr-erasure-global-data (D10): an erased (or being erased) user's upload stores nothing
             :ok <- if(n == 0, do: {:error, :user_erased}, else: :ok) do
          :ok
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
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
  The ERROR-AWARE, LOCKED read of a user's stored keys: the only read a cross-signing writer may decide on (story
  cross-signing-upload-races, D1; it replaces the row-only `get_keys_for_update/1` of story oauth-authorize-freshness,
  FR16 (2), gate ak). Must be called inside a `Nebu.Repo.transaction/1`: the locks live until it ends. In this order:

    1. the `cross_signing_keys` row lock (`SELECT 1 ... FOR UPDATE`; locks the row when it exists, nothing otherwise),
    2. the per-user advisory lock `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))` (the key of
       `put_keys/2`, the signature merge and the erasure),
    3. the read of the three key columns.

  Row -> advisory -> read is the order of the erasure, so the two do not form a cycle (except the absent-then-present
  window of the signature merge, see the moduledoc); no writer changes the key columns without the advisory lock, so
  the result stays valid until the caller commits.

  `{:ok, keys}` (the `get_keys/1` shape; all-nil for a user with nothing stored) or `{:error, reason}`: unlike
  `get_keys/1`, whose errors look like "no master stored" (the UIA-free first-upload branch!), a failed lock, a failed
  read or an undecodable row is an error here. Never raises on a database or decode error.
  """
  @spec lock_keys(String.t()) :: {:ok, %{optional(String.t()) => map() | nil}} | {:error, term()}
  def lock_keys(user_id) when is_binary(user_id) do
    with {:ok, _} <- query("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [user_id]),
         {:ok, _} <- query("SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))", [user_id]),
         {:ok, result} <-
           query("SELECT master_key_json, self_signing_key_json, user_signing_key_json FROM cross_signing_keys WHERE user_id = $1", [user_id]) do
      case result do
        %{rows: [[mk, ssk, usk]]} ->
          {:ok, %{"master_key" => decode_key(mk), "self_signing_key" => decode_key(ssk), "user_signing_key" => decode_key(usk)}}

        %{rows: []} ->
          {:ok, %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}}
      end
    end
  rescue
    # an undecodable row (or a raising connection): an error, never an all-nil "no master stored"
    e -> {:error, e}
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
  (caller then treats the key-id as a non-cross-signing key, e.g. a device key). A merge into the
  keys of an erased user (story gdpr-erasure-global-data) stores nothing and answers `:not_found`.

  `signed_object` is the object the caller submitted (`POST /keys/signatures/upload`): its parts other than
  `signatures` and `unsigned` must equal the stored object under `key_id`, otherwise nothing is written and the
  answer is `:not_found` (validate-then-persist). It is REQUIRED: there is no merge path without that comparison.

  Story cross-signing-upload-races (D4): ONE transaction. `lock_keys/1` (row lock -> advisory lock -> read), the key is
  found by its id IN THAT READ, the object comparison is made against the LOCKED object, the signatures are
  deep-merged and all three columns are written from the locked read. A concurrent cross-signing reset or a concurrent
  merge is therefore never overwritten with a stale merge base. A failed locked read or a failed write raises
  (`"cross-signing signature merge failed"`, the request answers 500), never "nothing stored".
  """
  @spec merge_signatures(String.t(), String.t(), map(), map()) :: :ok | :not_found
  def merge_signatures(user_id, key_id, new_signatures, signed_object)
      when is_binary(user_id) and is_binary(key_id) and is_map(new_signatures) and is_map(signed_object) do
    result =
      Nebu.Repo.transaction(fn ->
        with {:ok, stored} <- lock_keys(user_id),
             {body_key, obj} <- find_matching_key(stored, key_id),
             true <- same_object?(obj, signed_object) do
          merged = deep_merge_signatures(obj, new_signatures)

          case put_keys_no_flag(user_id, Map.put(stored, body_key, merged)) do
            :ok -> :ok
            :refused -> :not_found
            {:error, reason} -> Nebu.Repo.rollback(reason)
          end
        else
          # no such cross-signing key, or a different object under the same key id: nothing is written
          nil -> :not_found
          false -> :not_found
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      # a failed locked read or write is a crash of the request (500), never a stale or empty merge base; the
      # message carries no statement, value, key id or signature
      {:error, _reason} -> raise "cross-signing signature merge failed"
    end
  end

  # The validate-then-persist comparison: everything but `signatures` and `unsigned` must be equal.
  defp same_object?(stored, submitted), do: comparable(stored) == comparable(submitted)

  defp comparable(obj), do: obj |> Map.delete("signatures") |> Map.delete("unsigned")

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

  # The write of a signature merge. Like put_keys/2 but does NOT touch cross_signing_changed (a signature merge is
  # not itself a key change that needs a fresh device_lists.changed; the upload that created the key already set
  # the flag) and draws no changed_pos. Updates updated_at only. Returns :ok | :refused | {:error, reason}.
  #
  # story gdpr-erasure-global-data (D18 (b)): the third writer of `cross_signing_keys` (`POST /keys/signatures/upload`; the handler answers
  # M_FORBIDDEN for every user other than the caller, so only the caller's own row is ever merged and locked) follows the locking and erasure protocol of put_keys/2: the per-user
  # `sync_global|` advisory lock (so its statement starts after a running erasure committed) and the `deletion_status` predicate
  # (a refused write is `:refused` -> `:not_found`, nothing stored).
  #
  # story cross-signing-upload-races (D4): the MERGE BASE is read under the same lock. It runs ONLY inside the transaction of
  # merge_signatures/4, after `lock_keys/1` (the cross_signing_keys row lock -> the sync_global| advisory lock -> the read, the order
  # of the erasure), and `keys` are the three columns of THAT read with the merged object. A cross-signing reset that committed
  # before the read is therefore never overwritten in the columns the merge did not touch. The advisory lock statement below repeats
  # a lock lock_keys/1 already holds (re-entrant in the same transaction). The row lock is a repeat too, EXCEPT in the
  # absent-then-present window (the row did not exist at the row lock of lock_keys/1 and a first upload committed it before the
  # advisory lock was granted): then this statement (and the upsert itself) takes the row lock only now, after the advisory lock, and
  # can wait for an erasure that holds the row and waits for the advisory lock; PostgreSQL resolves that cycle with 40P01 (the
  # erasure fails closed or the merge answers 500). Accepted residual, see the moduledoc; it cannot be closed without flipping the
  # lock order.
  defp put_keys_no_flag(user_id, keys) do
    now = now_ms()

    with {:ok, _} <- query("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [user_id]),
         {:ok, _} <- query("SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))", [user_id]),
         {:ok, %{num_rows: n}} <-
           query(
             """
             INSERT INTO cross_signing_keys
               (user_id, master_key_json, self_signing_key_json, user_signing_key_json,
                cross_signing_changed, created_at, updated_at)
             SELECT $1::text, $2::text, $3::text, $4::text, FALSE, $5::bigint, $5::bigint
             WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = $1::text AND deletion_status IS NOT NULL)
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
           ) do
      if n == 0, do: :refused, else: :ok
    end
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

  @doc """
  DEVICE-bound `/sync` (story sync-token-per-device, D9): `{changed_pos, changed_pos > pos}` for the user's row
  (`{0, false}` without a row). One row by primary key; never clears the flag and never moves a position.
  Never raises: a failed read is `{pos, false}` (the device's position does not advance, so the change is reported
  by a later sync).
  """
  @spec changed_since?(String.t(), non_neg_integer()) :: {non_neg_integer(), boolean()}
  def changed_since?(user_id, pos) when is_binary(user_id) and is_integer(pos) do
    case safe_query("SELECT changed_pos FROM cross_signing_keys WHERE user_id = $1", [user_id]) do
      {:ok, %{rows: [[changed_pos]]}} -> {changed_pos, changed_pos > pos}
      {:ok, %{rows: []}} -> {0, false}
      _ -> {pos, false}
    end
  end

  # Deep-merge new signatures into obj["signatures"] (per (signing_user, key_id)),
  # preserving existing signatures.
  #
  # story cross-signing-upload-races (fix cycle 2, Kassandra D-1): the STORED `signatures` value comes from the user's own upload, which
  # does not validate its shape, so it may be malformed ("x", or `{"@me": "x"}`). A stored value that is not a map, and a stored
  # per-signer value that is not a map, count as no signatures (they are dropped), so the merge never crashes (a crash report would
  # carry the submitted signer key ids and signatures into the error log) and its result is always a map of maps.
  defp deep_merge_signatures(obj, new_signatures) do
    merged =
      Map.merge(signature_map(Map.get(obj, "signatures")), signature_map(new_signatures), fn _signer, old_map, new_map ->
        Map.merge(old_map, new_map)
      end)

    Map.put(obj, "signatures", merged)
  end

  # only the per-signer entries that are maps; anything that is not a map is an empty signature map
  defp signature_map(sigs) when is_map(sigs), do: for({signer, per_signer} <- sigs, is_map(per_signer), into: %{}, do: {signer, per_signer})
  defp signature_map(_sigs), do: %{}

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
