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

  ## Incremental `/sync` change marker

  Each row carries a consume-once `changed` boolean (mirrors
  `cross_signing_keys.cross_signing_changed`): set TRUE on every `put/3`. An
  INCREMENTAL `/sync` reads-and-clears the changed rows via `UPDATE ... RETURNING`
  (`list_changed_and_clear/1`) so it delivers only entries changed since the
  client's `since` token. An INITIAL `/sync` returns ALL rows and clears their
  flags (`list_all_and_clear/1`).
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

  Idempotent — a second call for the same key overwrites the previous value. Sets
  the consume-once `changed` flag so the next incremental `/sync` surfaces this
  entry exactly once.
  """
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(user_id, type, json_body)
      when is_binary(user_id) and is_binary(type) and is_binary(json_body) do
    now = now_ms()

    {:ok, _} =
      query(
        """
        INSERT INTO account_data (user_id, type, content_json, changed, created_at, updated_at)
        VALUES ($1, $2, $3, TRUE, $4, $4)
        ON CONFLICT (user_id, type) DO UPDATE
          SET content_json = EXCLUDED.content_json,
              changed      = TRUE,
              updated_at   = EXCLUDED.updated_at
        """,
        [user_id, type, json_body, now]
      )

    :ok
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

  # ── helpers ────────────────────────────────────────────────────────────────

  defp decode_rows(rows) do
    Enum.map(rows, fn [type, json] -> {type, Jason.decode!(json)} end)
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
