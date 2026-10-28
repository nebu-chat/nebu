defmodule Nebu.OAuth.CodeStore do
  @moduledoc """
  Nebu authorization codes (`oauth_codes`, migration 000041) — epic oauth-broker, story
  oauth-authorize-idp-delegation-code (D16, D17, AC8, AC9).

  ADR-018: inline SQL. A code is `Base.url_encode64(32 random bytes, padding: false)` (256 bit);
  ONLY `code_hash` = lowercase hex SHA-256 of it is stored (high-entropy input, no salt needed),
  the plaintext exists only in the client redirect. TTL 60 s (CHECK in the table).

  ## Consumption (D17, for the story-3 token endpoint)

  `UPDATE oauth_codes SET used_at = now() WHERE code_hash = $1 AND used_at IS NULL AND
  expires_at > now() RETURNING ...` is the single-use gate: exactly one of N concurrent consumers
  (any node of the cluster) gets the row. On 0 rows ONE follow-up SELECT tells a reuse
  (`used_at` set => `{:error, {:reused, row}}`, story 3 then revokes the session derived from the
  code by `(user_id, device_id, client_id)`) from an unknown or expired-unused code
  (`{:error, :invalid}`). Used and expired codes are kept until 24 h after their expiry (reuse
  detection; RLS refuses an earlier DELETE), then purged.

  Test seam: `:nebu_http, :oauth_repo` (same as `Nebu.OAuth.ClientStore`).
  """

  @ttl_seconds 60

  @purge_batch 1000
  @purge_max_batches 20

  @columns ~w(code_hash client_id redirect_uri code_challenge device_id user_id scope scope_prefix
              response_mode client_nonce openid_requested idp_rt_enc auth_time created_at
              expires_at used_at device_holder_checked device_holder_client_id)a

  @select_list Enum.map_join(@columns, ", ", &Atom.to_string/1)

  @sql_insert """
  INSERT INTO oauth_codes
    (code_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix,
     response_mode, client_nonce, openid_requested, idp_rt_enc, auth_time, expires_at,
     device_holder_checked, device_holder_client_id)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, now() + ($14::int * interval '1 second'), $15, $16)
  """

  @sql_consume """
  UPDATE oauth_codes SET used_at = now()
  WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now()
  RETURNING #{@select_list}
  """

  @sql_by_hash "SELECT #{@select_list} FROM oauth_codes WHERE code_hash = $1"

  # Batched, `FOR UPDATE SKIP LOCKED` (the `ClientStore.purge_expired_pending/1` pattern): purgers on
  # several nodes split the work. Only codes expired more than 24 h ago match (and only those may
  # be deleted by the runtime role, RLS).
  @sql_purge """
  DELETE FROM oauth_codes
  WHERE code_hash IN (
    SELECT code_hash FROM oauth_codes
    WHERE expires_at < now() - interval '24 hours'
    ORDER BY expires_at
    LIMIT $1
    FOR UPDATE SKIP LOCKED
  )
  """

  @doc "A fresh authorization code: 32 random bytes, base64url without padding (43 chars)."
  @spec generate() :: String.t()
  def generate, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "Lowercase hex SHA-256 — the stored form of a code (D16)."
  @spec hash(String.t()) :: String.t()
  def hash(code) when is_binary(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

  @doc """
  Issues a code for `attrs` (`client_id`, `redirect_uri`, `code_challenge`, `device_id`,
  `user_id`, `scope`, `scope_prefix`, `response_mode`, `client_nonce`, `openid_requested`,
  `idp_rt_enc` (already encrypted or nil), `auth_time` (unix seconds or nil)); optional
  `device_holder_checked` / `device_holder_client_id` (story oauth-authorize-freshness L-1: the OAuth app that
  held the device when the user clicked Allow, nil = none or a legacy session; re-checked when the code is
  redeemed). Returns
  `{:ok, plaintext_code}` — the only place the plaintext exists — or `{:error, reason}`.
  """
  @spec insert(map()) :: {:ok, String.t()} | {:error, term()}
  def insert(attrs) do
    code = generate()

    params = [
      hash(code),
      attrs.client_id,
      attrs.redirect_uri,
      attrs.code_challenge,
      attrs.device_id,
      attrs.user_id,
      attrs.scope,
      attrs.scope_prefix,
      attrs.response_mode,
      Map.get(attrs, :client_nonce),
      Map.get(attrs, :openid_requested, false) == true,
      Map.get(attrs, :idp_rt_enc),
      to_datetime(Map.get(attrs, :auth_time)),
      @ttl_seconds,
      Map.get(attrs, :device_holder_checked, false) == true,
      Map.get(attrs, :device_holder_client_id)
    ]

    case query(@sql_insert, params) do
      {:ok, %{num_rows: 1}} -> {:ok, code}
      {:ok, other} -> {:error, {:unexpected_result, other.num_rows}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Consumes `code` exactly once (D17): `{:ok, row}` (atom keys = every column, `idp_rt_enc` still
  encrypted), `{:error, {:reused, row}}` for a code that was already used, `{:error, :invalid}`
  for an unknown or expired-unused code (or non-binary input), `{:error, :storage}` when the
  database is unavailable.
  """
  @spec consume(term()) :: {:ok, map()} | {:error, :invalid | :storage | {:reused, map()}}
  def consume(code) when is_binary(code) and code != "" do
    code_hash = hash(code)

    with {:ok, %{rows: []}} <- query(@sql_consume, [code_hash]),
         {:ok, %{rows: rows}} <- query(@sql_by_hash, [code_hash]) do
      case rows do
        [row] ->
          row = to_map(row)
          if row.used_at, do: {:error, {:reused, row}}, else: {:error, :invalid}

        [] ->
          {:error, :invalid}
      end
    else
      {:ok, %{rows: [row]}} -> {:ok, to_map(row)}
      {:error, _} -> {:error, :storage}
    end
  end

  def consume(_code), do: {:error, :invalid}

  @doc """
  Deletes codes expired more than 24 h ago, in batches of #{@purge_batch} (at most
  #{@purge_max_batches} per call). `{:ok, deleted}` or `{:error, reason}`.
  """
  @spec purge_expired() :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired, do: do_purge(0, 0)

  defp do_purge(total, @purge_max_batches), do: {:ok, total}

  defp do_purge(total, batches) do
    case query(@sql_purge, [@purge_batch]) do
      {:ok, %{num_rows: n}} when n >= @purge_batch -> do_purge(total + n, batches + 1)
      {:ok, %{num_rows: n}} -> {:ok, total + n}
      {:error, _} = error -> error
    end
  end

  defp to_map(row), do: @columns |> Enum.zip(row) |> Map.new()

  defp to_datetime(seconds) when is_integer(seconds) do
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
