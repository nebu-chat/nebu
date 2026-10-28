defmodule Nebu.OAuth.AuthzStore do
  @moduledoc """
  Persistence of pending authorization requests (`oauth_authz_requests`, migration 000041) — epic
  oauth-broker, story oauth-authorize-idp-delegation-code (D2, D3, D19, AC6, AC9).

  ADR-018: inline SQL, no ORM. ADR-020 (cluster safety): this table — not the node-local
  `SsoStore` — is the flow state between `GET /oauth2/authorize` and the IdP callback, so any node
  can complete a flow and a node restart loses nothing.

    * `insert/1` — one row, `expires_at = now() + 600 s`, with the live-row soft cap INSIDE the
      INSERT (`INSERT ... SELECT ... WHERE (SELECT count(*) ... WHERE expires_at > now()) < cap`,
      the `ClientStore.register/1` idiom; READ COMMITTED lets N concurrent inserts overshoot by
      at most N-1, acceptable for an abuse cap). Two caps (story oauth-dcr-abuse-hardening, AH10):
      300 live rows per source (`source_key`, `Nebu.OAuth.SourceKey`: one client can no longer
      exhaust the table for everybody) and the global 10 000 as a memory bound. A refused request
      never makes room by deleting another row (no eviction): the only deletes of this module are
      `consume/1` and `purge_expired/0`.
    * `consume/1` — ONE atomic `DELETE ... RETURNING ..., (expires_at > now()) AS live`: exactly
      one of N concurrent callbacks for the same state (any node) gets the row; an expired row is
      consumed too (and reported as expired).
    * `purge_expired/0` — batched delete of expired rows (AC9/AC11).

  The key is `state_hash` = lowercase hex SHA-256 of the IdP-leg state (`hash/1`); the plaintext
  state is never stored. Test seam: `:nebu_http, :oauth_repo` (same as `Nebu.OAuth.ClientStore`).
  """

  @ttl_seconds 600
  @live_cap 10_000
  # Per-source cap (story oauth-dcr-abuse-hardening, AH10, gate item h): at most this many live rows
  # per `source_key` (`Nebu.OAuth.SourceKey`); the global cap above stays as a memory bound.
  @source_live_cap 300

  @purge_batch 1000
  @purge_max_batches 20

  @columns ~w(client_id redirect_uri code_challenge device_id scope scope_prefix response_mode
              client_state client_nonce openid_requested idp_code_verifier_enc idp_nonce
              browser_binding_hash)a

  @sql_insert """
  INSERT INTO oauth_authz_requests
    (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix,
     response_mode, client_state, client_nonce, openid_requested, idp_code_verifier_enc, idp_nonce,
     browser_binding_hash, expires_at, source_key)
  SELECT $1::text, $2::text, $3::text, $4::text, $5::text, $6::text, $7::text, $8::text, $9::text,
         $10::text, $11::boolean, $12::text, $13::text, $14::text,
         now() + ($15::int * interval '1 second'), $17::text
  WHERE (SELECT count(*) FROM oauth_authz_requests WHERE expires_at > now()) < $16::bigint
    AND ($17::text IS NULL
         OR (SELECT count(*) FROM oauth_authz_requests
             WHERE source_key = $17::text AND expires_at > now()) < $18::bigint)
  """

  @sql_source_live "SELECT count(*) FROM oauth_authz_requests WHERE source_key = $1::text AND expires_at > now()"

  @sql_consume """
  DELETE FROM oauth_authz_requests WHERE state_hash = $1
  RETURNING client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, response_mode,
            client_state, client_nonce, openid_requested, idp_code_verifier_enc, idp_nonce,
            browser_binding_hash, extract(epoch FROM created_at)::bigint, (expires_at > now()) AS live
  """

  # No `FOR UPDATE SKIP LOCKED` here (unlike the code purge): the runtime role has no UPDATE
  # privilege / policy on this table (rows are never updated), and a row lock needs one. Concurrent
  # purgers are still safe: a DELETE that finds a row already deleted by another purger skips it.
  @sql_purge """
  DELETE FROM oauth_authz_requests
  WHERE state_hash IN (
    SELECT state_hash FROM oauth_authz_requests
    WHERE expires_at < now()
    ORDER BY expires_at
    LIMIT $1
  )
  """

  @doc "Lowercase hex SHA-256 — the row key of an IdP-leg state (D2)."
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc """
  Persists a validated, delegated authorization request. `attrs` carries `:state_hash` and every
  column of `@columns` (`client_state` / `client_nonce` may be `nil`).

  Optional `:source_key` (`Nebu.OAuth.SourceKey.for_conn/1`): a request is refused while #{@source_live_cap}
  live rows of the same source exist (`:source_cap` seam, `nil` = no source = not counted). Live
  rows are never evicted to make room.

  `:ok`, `{:error, :capacity}` when #{@live_cap} live requests exist overall or the source is at its
  cap, `{:error, :invalid}` when
  PostgreSQL refuses a value as data (SQLSTATE class 22), `{:error, reason}` otherwise.
  """
  @spec insert(map()) :: :ok | {:error, :capacity | :invalid | term()}
  def insert(%{state_hash: state_hash} = attrs) do
    params = [state_hash | Enum.map(@columns, &Map.get(attrs, &1))] ++
        [
          @ttl_seconds,
          Map.get(attrs, :cap, @live_cap),
          Map.get(attrs, :source_key),
          Map.get(attrs, :source_cap, @source_live_cap)
        ]

    case query(@sql_insert, params) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :capacity}
      {:error, %Postgrex.Error{postgres: %{pg_code: "22" <> _}}} -> {:error, :invalid}
      {:error, %DBConnection.EncodeError{}} -> {:error, :invalid}
      {:error, _} = error -> error
    end
  end

  @doc """
  `true` when `source_key` currently has at least the per-source cap of live rows: lets the caller tell
  a PER-SOURCE refusal from the global cap after `insert/1` answered `{:error, :capacity}` (only used
  to pick the log line; `false` for `nil` or when the count cannot be read). Same `:source_cap` seam.
  """
  @spec source_capped?(String.t() | nil, keyword()) :: boolean()
  def source_capped?(source_key, opts \\ [])
  def source_capped?(nil, _opts), do: false

  def source_capped?(source_key, opts) when is_binary(source_key) do
    case query(@sql_source_live, [source_key]) do
      {:ok, %{rows: [[n]]}} -> n >= Keyword.get(opts, :source_cap, @source_live_cap)
      _ -> false
    end
  end

  @doc """
  Atomically consumes the request of an IdP-leg `state`: `{:ok, row}` (atom keys, the
  `@columns` plus `created_at` as unix seconds: the time the login was requested, the reference of the
  freshness check, story oauth-authorize-freshness FR2), `{:error, :expired}` (the row existed but was expired — it is consumed anyway),
  `{:error, :not_found}` (unknown or already consumed) or `{:error, :storage}`.
  """
  @spec consume(String.t()) :: {:ok, map()} | {:error, :expired | :not_found | :storage}
  def consume(state) when is_binary(state) do
    case query(@sql_consume, [hash(state)]) do
      {:ok, %{rows: [row]}} ->
        {values, [live]} = Enum.split(row, length(@columns) + 1)
        if live, do: {:ok, (@columns ++ [:created_at]) |> Enum.zip(values) |> Map.new()}, else: {:error, :expired}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :storage}
    end
  end

  @doc """
  Deletes expired requests (`expires_at < now()`) in batches of #{@purge_batch} (at most
  #{@purge_max_batches} batches per call). `{:ok, deleted}` or `{:error, reason}`.
  """
  @spec purge_expired() :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired, do: do_purge(0, 0)

  defp do_purge(total, @purge_max_batches), do: {:ok, total}

  defp do_purge(total, batches) do
    case query(@sql_purge, [@purge_batch]) do
      {:ok, %{num_rows: n}} when n >= @purge_batch -> do_purge(total + n, batches + 1)
      {:ok, %{num_rows: n}} -> {:ok, total + n}
      # another purger (other node) is deleting the same batch right now: leave it to that one
      {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} -> {:ok, total}
      {:error, _} = error -> error
    end
  end

  defp repo, do: Application.get_env(:nebu_http, :oauth_repo, Nebu.Repo)

  defp query(sql, params) do
    Ecto.Adapters.SQL.query(repo(), sql, params)
  rescue
    e in [RuntimeError, ArgumentError, UndefinedFunctionError, DBConnection.ConnectionError, DBConnection.EncodeError] ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
