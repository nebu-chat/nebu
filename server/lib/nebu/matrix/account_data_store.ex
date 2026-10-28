defmodule Nebu.Matrix.AccountDataStore do
  @moduledoc """
  Durable, PostgreSQL-backed store for per-user GLOBAL Matrix account data
  (story: account-data-durability).

  Backs:

      PUT /_matrix/client/v3/user/{userId}/account_data/{type}
      GET /_matrix/client/v3/user/{userId}/account_data/{type}

  and the top-level `account_data.events` of `GET /_matrix/client/v3/sync`.

  ## Why PostgreSQL (was ETS)

  This data was a volatile, node-local ETS stub. Element stores its secret-storage
  / recovery material in GLOBAL account data — `m.secret_storage.default_key`,
  `m.secret_storage.key.<id>`, and the client-encrypted private cross-signing keys
  (`m.cross_signing.master` / `.self_signing` / `.user_signing`). If that is lost on
  a server restart or never delivered via `/sync`, Element treats recovery as not
  configured and re-prompts setup. Durability + `/sync` delivery closes that gap.

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018 — no Ecto schema,
  no Repository/Service layer). PostgreSQL-backed so the store is cluster-correct
  (ADR-020: a PUT and a later `/sync` may land on different nodes) and survives
  restarts (read-on-start: every read hits the committed Postgres row). ADR-002
  (ETS for volatile data) does NOT apply here — this data must be durable.

  ## Opacity (ADR-011)

  `content_json` holds the value VERBATIM — the exact bytes the client PUT. For the
  secret-storage / cross-signing types it is client-encrypted; the server never
  parses or decrypts it. Stored as TEXT (not jsonb) to guarantee a byte-for-byte
  round-trip. Persisting / echoing this encrypts nothing — E2EE stays OFF.

  ## Incremental `/sync` delivery (story sync-token-per-device, D9 / D11)

  Every row carries a POSITION `stream_pos`, drawn from the sequence `sync_global_pos_seq` (shared with
  `cross_signing_keys.changed_pos`) on every insert AND every update by `put/3`, so an overwrite is a new change.
  A DEVICE-bound `/sync` delivers the rows above the device's `sync_tokens.account_data_pos` (`list_since/2`) and
  ends its long-poll at once when such a row exists (`pending_since?/2`); nothing is consumed, so every device of
  the user (the writer included) receives every change once.

  `put/3` runs in a transaction that first takes the per-user lock
  `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))` (the same key as
  `CrossSigningKeyStore.put_keys/2`, namespaced so it never serialises against room account data): for one user the
  position order is the commit order, so a reader never passes a lower position that is still uncommitted. AFTER the
  commit it wakes the user's waiting `/sync` requests on every node (`{:account_data_changed, nil}` to the members of
  the `:pg` group `user:<id>`, `:pg.get_members/1`).

  The consume-once `changed` boolean is still SET by every `put/3`; only DEVICE-LESS requests (an unbound raw IdP
  JWT: such clients cannot be told apart) read-and-clear it, with `list_changed_and_clear/1` (incremental) and
  `list_all_and_clear/1` (initial), as before. Device-bound requests never touch it.
  """

  @doc """
  Kept for the `Nebu.Application.start/2` call site. The backing table is now a
  PostgreSQL migration (`000011_account_data`), not an ETS table, so there is
  nothing to create at boot. No-op, returns `:ok`.
  """
  @spec init_table() :: :ok
  def init_table, do: :ok

  @doc """
  Stores `json_body` (a pre-encoded JSON string, opaque) keyed by `{user_id, type}`.

  Idempotent — a second call for the same key overwrites the previous value. Every call (an identical body too) draws
  a new `stream_pos` and sets the consume-once `changed` flag, in one transaction under the per-user `sync_global|`
  advisory lock. After the commit the user's waiting `/sync` requests are woken (cluster-wide). A failed write returns
  `{:error, reason}`: nothing is stored and nobody is woken.

  Must NOT be called inside a surrounding transaction: the wake-up is sent when this function's own transaction
  returns, which is only the commit when it is the outermost one (nested, the wake would precede the outer commit and
  the per-user lock would be held until then).
  """
  @spec put(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def put(user_id, type, json_body)
      when is_binary(user_id) and is_binary(type) and is_binary(json_body) do
    now = now_ms()

    result =
      Nebu.Repo.transaction(fn ->
        with {:ok, _} <- lock_user(user_id),
             {:ok, %{num_rows: n}} <-
               query(
                 """
                 INSERT INTO account_data (user_id, type, content_json, changed, stream_pos, created_at, updated_at)
                 SELECT $1::text, $2::text, $3::text, TRUE, nextval('sync_global_pos_seq'), $4::bigint, $4::bigint
                 WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = $1::text AND deletion_status IS NOT NULL)
                 ON CONFLICT (user_id, type) DO UPDATE
                   SET content_json = EXCLUDED.content_json,
                       changed      = TRUE,
                       stream_pos   = nextval('sync_global_pos_seq'),
                       updated_at   = EXCLUDED.updated_at
                 """,
                 [user_id, type, json_body, now]
               ),
             # story gdpr-erasure-global-data (D10): an erased (or being erased) user's write stores nothing
             :ok <- if(n == 0, do: {:error, :user_erased}, else: :ok) do
          :ok
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        notify_sync(user_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # a pool checkout / connection failure raises out of Repo.transaction/1: still an {:error, _}, never a crash
    e -> {:error, e}
  end

  @doc """
  Retrieves the stored opaque JSON body for `{user_id, type}`.

  Returns `{:ok, json_body}` when found, `:error` when no entry exists. Read-only —
  does NOT touch the `changed` flag (a GET is not a sync checkpoint).
  """
  @spec get(String.t(), String.t()) :: {:ok, String.t()} | :error
  def get(user_id, type) when is_binary(user_id) and is_binary(type) do
    case safe_query(
           "SELECT content_json FROM account_data WHERE user_id = $1 AND type = $2",
           [user_id, type]
         ) do
      {:ok, %{rows: [[body]]}} -> {:ok, body}
      _ -> :error
    end
  end

  @doc """
  INITIAL `/sync`: returns ALL of the user's global account data as
  `[{type, content_map}, …]` (content decoded from the stored opaque JSON into the
  map the client originally sent — decoding here is shaping for the `/sync`
  envelope, not interpreting the value). Clears the `changed` flag on every returned
  row so a subsequent incremental sync does not re-deliver them.

  Read-path that never raises (DB down / not started → empty list), so `/sync`
  degrades gracefully instead of crashing the request.
  """
  @spec list_all_and_clear(String.t()) :: [{String.t(), map()}]
  def list_all_and_clear(user_id) when is_binary(user_id) do
    case safe_query(
           """
           UPDATE account_data
           SET changed = FALSE
           WHERE user_id = $1
           RETURNING type, content_json
           """,
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> decode_rows(rows)
      _ -> []
    end
  end

  @doc """
  INCREMENTAL `/sync`: reads-and-clears the rows whose consume-once `changed` flag
  is set, returning only those as `[{type, content_map}, …]`. Atomic via
  `UPDATE ... RETURNING` (cluster-correct). Unchanged entries are omitted.

  Read-path that never raises (DB down / not started → empty list).
  """
  @spec list_changed_and_clear(String.t()) :: [{String.t(), map()}]
  def list_changed_and_clear(user_id) when is_binary(user_id) do
    case safe_query(
           """
           UPDATE account_data
           SET changed = FALSE
           WHERE user_id = $1 AND changed = TRUE
           RETURNING type, content_json
           """,
           [user_id]
         ) do
      {:ok, %{rows: rows}} -> decode_rows(rows)
      _ -> []
    end
  end

  @doc """
  DEVICE-bound `/sync` (D9): the user's rows with `stream_pos > pos` as `{latest_pos, [{type, content_map}, …]}`,
  oldest change first; `pos = 0` returns every row. `latest_pos` is the highest position read (`pos` when nothing is
  newer, so `0` for a user without rows). Does NOT touch the `changed` flag (reading is not consuming).

  Never raises: a failed read is `{pos, []}`, so the caller's position does not advance and the rows are read again
  by the next sync (failure direction "deliver again", never "miss").
  """
  @spec list_since(String.t(), non_neg_integer()) :: {non_neg_integer(), [{String.t(), map()}]}
  def list_since(user_id, pos) when is_binary(user_id) and is_integer(pos) and pos >= 0 do
    case list_since_checked(user_id, pos) do
      {:ok, latest, entries} -> {latest, entries}
      :error -> {pos, []}
    end
  end

  @doc """
  `list_since/2` with the failed read made visible: `{:ok, latest_pos, entries}` or `:error` (a database error; never
  raises on one). The `/sync` route needs the distinction for an INITIAL-SHAPED answer: a failed read there delivered
  nothing, so the device's `account_data_pos` must go back to 0 instead of staying where it was (story
  sync-token-per-device, review m1: otherwise a client that reset its state would miss the older rows for good).
  """
  @spec list_since_checked(String.t(), non_neg_integer()) :: {:ok, non_neg_integer(), [{String.t(), map()}]} | :error
  def list_since_checked(user_id, pos) when is_binary(user_id) and is_integer(pos) and pos >= 0 do
    case safe_query(
           "SELECT type, content_json, stream_pos FROM account_data WHERE user_id = $1 AND stream_pos > $2 ORDER BY stream_pos",
           [user_id, pos]
         ) do
      {:ok, %{rows: rows}} ->
        latest = Enum.reduce(rows, pos, fn [_type, _json, p], acc -> max(p, acc) end)
        {:ok, latest, Enum.map(rows, fn [type, json, _p] -> {type, Jason.decode!(json)} end)}

      _ ->
        :error
    end
  end

  @doc """
  DEVICE-bound `/sync` (D11): `true` when a row of the user has a position above `pos`, i.e. a change this device has
  not been sent yet (the pre-check that answers the long-poll at once). Does not touch the flag. Never raises (a
  failed read is `false`: the request long-polls as before).
  """
  @spec pending_since?(String.t(), non_neg_integer()) :: boolean()
  def pending_since?(user_id, pos) when is_binary(user_id) and is_integer(pos) and pos >= 0 do
    case safe_query("SELECT 1 FROM account_data WHERE user_id = $1 AND stream_pos > $2 LIMIT 1", [user_id, pos]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp decode_rows(rows) do
    Enum.map(rows, fn [type, json] -> {type, Jason.decode!(json)} end)
  end

  # The per-user write lock of the GLOBAL sync positions: one key for account_data AND cross_signing_keys (see
  # `CrossSigningKeyStore.put_keys/2`), held until the surrounding transaction ends.
  defp lock_user(user_id),
    do: query("SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))", [user_id])

  # Wakes the user's waiting /sync requests on EVERY node (cluster-safety: :pg.get_members/1). Called only after the
  # commit, so a woken request reads the new row. Never raises: the wake-up must not fail a stored PUT.
  defp notify_sync(user_id) do
    for pid <- :pg.get_members("user:#{user_id}"), do: send(pid, {:account_data_changed, nil})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)

  # Read-path query that never raises (DB down / not started → empty result), so
  # /sync degrades gracefully instead of crashing the request.
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
