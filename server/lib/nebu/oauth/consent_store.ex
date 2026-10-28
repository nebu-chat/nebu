defmodule Nebu.OAuth.ConsentStore do
  @moduledoc """
  The consent state between the verified IdP login and the user's click (`oauth_consent_requests`,
  migration 000045) — epic oauth-broker, story oauth-authorize-freshness (FR6).

  ADR-018: inline SQL, no ORM. ADR-020 (cluster safety): this table is the ONLY state of the consent
  step, so any node can render the page and take the decision, and a node restart loses nothing.

    * `insert/1` — one row, `expires_at = now() + 300 s` (a CHECK caps it at 5 minutes), with the
      live-row soft caps (global #{10_000}, per user #{5}, per source #{20}) INSIDE the INSERT (`INSERT ... SELECT ... WHERE (SELECT count(*) ... WHERE
      expires_at > now()) < cap`, the `Nebu.OAuth.AuthzStore` idiom; READ COMMITTED lets N concurrent
      inserts overshoot by at most N-1, acceptable for an abuse cap). A refused request never makes room by
      deleting another row (no eviction).
    * `peek/1` — the LIVE row of a cookie, read only (the `GET` page; reload safe, nothing is consumed).
    * `consume/1` — ONE atomic `DELETE ... RETURNING ..., (expires_at > now()) AS live`: of N concurrent
      decisions for the same cookie (any node) exactly one gets the row; an expired row is consumed too
      (and reported as expired).
    * `purge_expired/0` — batched delete of expired rows.

  The key is `binding_hash` = lowercase hex SHA-256 of the 256-bit consent cookie (`hash/1`); the plaintext
  cookie is never stored (a database read leak yields no usable cookie), and neither is a CSRF token (it is
  derived from the cookie). The IdP refresh token is stored SecretBox-encrypted only. Rows are never
  updated (no UPDATE grant, no UPDATE policy).

  Test seam: `:nebu_http, :oauth_repo` (same as `Nebu.OAuth.ClientStore`).
  """

  @ttl_seconds 300
  @live_cap 10_000
  # L-2 (security review cycle 1): per user and per source (`Nebu.OAuth.SourceKey`) live rows, so one account or
  # one client address cannot use up the global cap. A user with several abandoned flows waits at most 5 minutes.
  @user_live_cap 5
  @source_live_cap 20
  # an `auth_time` claim beyond this (year 2100) or before the epoch is not a time: stored as NULL (never fresh)
  @max_auth_time 4_102_444_800

  @purge_batch 1000
  @purge_max_batches 20

  @columns ~w(client_id redirect_uri code_challenge device_id user_id scope scope_prefix response_mode
              client_state client_nonce openid_requested idp_rt_enc auth_time login_fresh created_at)a
  @insert_columns @columns -- [:created_at]

  @select_list "client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, response_mode, " <>
                 "client_state, client_nonce, openid_requested, idp_rt_enc, extract(epoch FROM auth_time)::bigint, " <>
                 "login_fresh, extract(epoch FROM created_at)::bigint"

  @sql_insert """
  INSERT INTO oauth_consent_requests
    (binding_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix,
     response_mode, client_state, client_nonce, openid_requested, idp_rt_enc, auth_time, login_fresh,
     created_at, expires_at, source_key)
  SELECT $1::text, $2::text, $3::text, $4::text, $5::text, $6::text, $7::text, $8::text, $9::text,
         $10::text, $11::text, $12::boolean, $13::text, $14::timestamptz, $15::boolean,
         now(), now() + ($16::int * interval '1 second'), $19::text
  WHERE (SELECT count(*) FROM oauth_consent_requests WHERE expires_at > now()) < $17::bigint
    AND (SELECT count(*) FROM oauth_consent_requests WHERE user_id = $6::text AND expires_at > now()) < $18::bigint
    AND ($19::text IS NULL
         OR (SELECT count(*) FROM oauth_consent_requests
             WHERE source_key = $19::text AND expires_at > now()) < $20::bigint)
  """

  @sql_peek "SELECT #{@select_list} FROM oauth_consent_requests WHERE binding_hash = $1 AND expires_at > now()"

  @sql_consume """
  DELETE FROM oauth_consent_requests WHERE binding_hash = $1
  RETURNING #{@select_list}, (expires_at > now()) AS live
  """

  # No `FOR UPDATE SKIP LOCKED` (like `Nebu.OAuth.AuthzStore`): the runtime role has no UPDATE privilege
  # / policy on this table, and a row lock needs one. Concurrent purgers are still safe.
  @sql_purge """
  DELETE FROM oauth_consent_requests
  WHERE binding_hash IN (
    SELECT binding_hash FROM oauth_consent_requests
    WHERE expires_at < now()
    ORDER BY expires_at
    LIMIT $1
  )
  """

  @doc "Lowercase hex SHA-256 — the row key of a consent cookie value."
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc "Seconds a consent row stays live (the cookie's `Max-Age` is the same)."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Persists a consent request. `attrs`: `:binding_hash` and every column of the table (`client_state`,
  `client_nonce`, `idp_rt_enc` and `auth_time` (unix seconds) may be `nil`; `login_fresh` is a boolean).

  Optional `:source_key` (`Nebu.OAuth.SourceKey.for_conn/1`; `nil` = not counted per source).

  `:ok`, `{:error, :capacity}` when #{@live_cap} live rows exist overall, #{@user_live_cap} for the user or
  #{@source_live_cap} for the source (`:cap` / `:user_cap` / `:source_cap` seams), `{:error, :invalid}` when
  PostgreSQL refuses a value as data (SQLSTATE class 22 / 23), `{:error, reason}` otherwise.
  """
  @spec insert(map()) :: :ok | {:error, :capacity | :invalid | term()}
  def insert(%{binding_hash: binding_hash} = attrs) do
    params =
      [binding_hash] ++
        Enum.map(@insert_columns, fn
          :auth_time -> to_datetime(Map.get(attrs, :auth_time))
          :openid_requested -> Map.get(attrs, :openid_requested, false) == true
          :login_fresh -> Map.get(attrs, :login_fresh, false) == true
          key -> Map.get(attrs, key)
        end) ++
        [
          @ttl_seconds,
          Map.get(attrs, :cap, @live_cap),
          Map.get(attrs, :user_cap, @user_live_cap),
          Map.get(attrs, :source_key),
          Map.get(attrs, :source_cap, @source_live_cap)
        ]

    case query(@sql_insert, params) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :capacity}
      {:error, %Postgrex.Error{postgres: %{pg_code: "22" <> _}}} -> {:error, :invalid}
      {:error, %Postgrex.Error{postgres: %{pg_code: "23" <> _}}} -> {:error, :invalid}
      {:error, %DBConnection.EncodeError{}} -> {:error, :invalid}
      {:error, _} = error -> error
    end
  end

  @doc """
  The LIVE row of the consent cookie `cookie` (read only): `{:ok, row}` (atom keys = the table columns,
  `auth_time` / `created_at` as unix seconds), `{:error, :not_found}` (unknown, consumed or expired) or
  `{:error, :storage}`.
  """
  @spec peek(String.t()) :: {:ok, map()} | {:error, :not_found | :storage}
  def peek(cookie) when is_binary(cookie) do
    case query(@sql_peek, [hash(cookie)]) do
      {:ok, %{rows: [row]}} -> {:ok, to_map(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _} -> {:error, :storage}
    end
  end

  @doc """
  Atomically consumes the row of `cookie`: `{:ok, row}`, `{:error, :expired}` (the row existed but was
  expired; it is consumed anyway), `{:error, :not_found}` (unknown or already consumed) or
  `{:error, :storage}`.
  """
  @spec consume(String.t()) :: {:ok, map()} | {:error, :expired | :not_found | :storage}
  def consume(cookie) when is_binary(cookie) do
    case query(@sql_consume, [hash(cookie)]) do
      {:ok, %{rows: [row]}} ->
        {values, [live]} = Enum.split(row, length(@columns))
        if live, do: {:ok, to_map(values)}, else: {:error, :expired}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :storage}
    end
  end

  @doc """
  Deletes expired rows in batches of #{@purge_batch} (at most #{@purge_max_batches} batches per call).
  `{:ok, deleted}` or `{:error, reason}`.
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

  defp to_map(values), do: @columns |> Enum.zip(values) |> Map.new()

  # A claim outside a sane range (before the epoch, after the year 2100) is not a time: NULL (never fresh either way).
  defp to_datetime(seconds) when is_integer(seconds) and seconds >= 0 and seconds <= @max_auth_time do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp to_datetime(_), do: nil

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
