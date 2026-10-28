defmodule Nebu.OAuth.Revoke do
  @moduledoc """
  `POST /oauth2/revoke` (RFC 7009, Matrix CS API "Token revocation"; story
  oauth-token-revocation-logout, R1-R10, R21). Called by `Nebu.OAuth.Http`, which decides the only
  gate: an unreadable config (`:unknown`) is `503 {}`; every other state — also OAuth DISABLED or an
  invalid issuer — is live (R13: revoke can only delete sessions).

  ## Order (AC2, first failure wins)

  Steps 1-5 are `Nebu.OAuth.FormPost.parse/1` (query string, content type, 16 KiB body, form
  encoding, duplicates / control characters), shared with the token endpoint; then the rate limit
  `{"oauth_revoke", ip}` (60/min, burst 600), charged AFTER the parse (a request failing 1-5 is
  charged before its 4xx) and BEFORE any DB access (exhausted => `429 too_many_requests`); then
  `token` missing => `400 invalid_request`; a `token` that is not 64 lowercase hex => `200 {}` without
  DB access; otherwise `Nebu.Matrix.oauth_revoke_token/1` (the Matrix-domain revocation, ADR-020):
  `{:ok, :revoked | :unknown}` => `200 {}`, `{:error, :unavailable}` => `503 {}` + `Retry-After: 5`.

  ## Contract

    * NO client authentication (R4): `client_id` is optional, never looked up, only COMPARED with the
      stored one for the log line; `client_secret`, `token_type_hint` and every `Authorization` header
      are ignored; a missing or wrong `client_id` still revokes (Matrix spec: SHOULD still revoke).
      Consequently `401 invalid_client` and `400 unsupported_token_type` are unreachable (R7).
    * `200 {}` + `Content-Type: application/json` for a revoked AND for an unknown token: byte-identical
      (RFC 7009 2.2, R6, R10). Every 5xx is `Retry-After` + `{}` (T20).
    * Envelope = the token endpoint's (`FormPost.json/3`): `no-store`, `Pragma: no-cache`, CORS `*`
      on EVERY status, never `Access-Control-Allow-Credentials`, no cookie, no `WWW-Authenticate`.

  ## Logging (R21)

  INFO `OAuth revoke: outcome=revoked|ignored client_id_match=true|false|absent`, plus on `revoked`
  the user id, device id and the session's STORED client id. The PRESENTED `client_id` (attacker
  controlled), the token, the hint and any hash are never logged. WARNING: a failed revocation
  (exception type only). No audit rows.

  Test seam (compiled in only for `MIX_ENV=test`): `:nebu_http, :oauth_revoke_test_hook` (0-arity fun
  called first, inside the rescue).
  """

  import Plug.Conn
  require Logger

  alias Nebu.OAuth.{FormPost, TokenRequest}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  @rate_per_min 60
  @burst 600
  @retry_after_s 5

  @doc "Handles `POST /oauth2/revoke`. Never raises."
  @spec handle_revoke(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_revoke(conn) do
    test_hook()
    dispatch(conn)
  rescue
    e ->
      Logger.error("OAuth revoke: unexpected #{inspect(e.__struct__)}")
      FormPost.server_error(conn, 500, @retry_after_s)
  catch
    :exit, _ ->
      Logger.error("OAuth revoke: unexpected exit")
      FormPost.server_error(conn, 500, @retry_after_s)
  end

  @doc "405 for a non-POST method (also HEAD): `invalid_request` + `Allow: POST, OPTIONS`."
  @spec method_not_allowed(Plug.Conn.t()) :: Plug.Conn.t()
  def method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST, OPTIONS")
    |> FormPost.oauth_error(405, "invalid_request", "Method not allowed.")
  end

  defp dispatch(conn) do
    case FormPost.parse(conn) do
      {:ok, conn, params} ->
        case charge(conn) do
          :ok -> revoke(conn, params)
          {:deny, retry_after_s} -> limited(conn, retry_after_s)
        end

      {:error, conn, status, description} ->
        # junk is charged BEFORE its 4xx (the token-endpoint pattern); exhausted => 429 instead
        case charge(conn) do
          :ok -> FormPost.oauth_error(conn, status, "invalid_request", description)
          {:deny, retry_after_s} -> limited(conn, retry_after_s)
        end
    end
  end

  defp charge(conn), do: RateLimit.take({"oauth_revoke", ClientIP.bucket(conn)}, @rate_per_min, @burst)

  # A 429 on revoke logs nobody out (the client is already logging out).
  defp limited(conn, retry_after_s) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> FormPost.oauth_error(429, "too_many_requests", nil)
  end

  defp revoke(conn, params) do
    case params["token"] do
      token when is_binary(token) and token != "" ->
        presented_client = params["client_id"]

        if TokenRequest.valid_refresh_token_format?(token) do
          case Nebu.Matrix.oauth_revoke_token(token) do
            {:ok, :revoked, info} ->
              log_revoked(info, presented_client)
              ok(conn)

            {:ok, :unknown} ->
              log_ignored(presented_client)
              ok(conn)

            {:error, :unavailable} ->
              Logger.warning("OAuth revoke: revocation failed (storage unavailable)")
              FormPost.server_error(conn, 503, @retry_after_s)
          end
        else
          log_ignored(presented_client)
          ok(conn)
        end

      _ ->
        FormPost.oauth_error(conn, 400, "invalid_request", "The token parameter is required.")
    end
  end

  # RFC 7009 2.2 / oracle O3: 200 with the body `{}` and `Content-Type: application/json`.
  defp ok(conn), do: FormPost.json(conn, 200, %{})

  defp log_revoked(%{user_id: user_id, device_id: device_id, client_id: stored}, presented) do
    Logger.info(
      "OAuth revoke: outcome=revoked client_id_match=#{match(presented, stored)} " <>
        "user_id=#{user_id} device_id=#{device_id} client_id=#{stored}"
    )
  end

  # An ignored token has no stored client: a presented client_id can only be "absent" or "false".
  defp log_ignored(presented), do: Logger.info("OAuth revoke: outcome=ignored client_id_match=#{match(presented, nil)}")

  defp match(nil, _stored), do: "absent"
  defp match(presented, stored), do: presented == stored

  # Test-only seam, compile-time guarded (Dev Notes "Test-only seams").
  if Mix.env() == :test do
    defp test_hook do
      case Application.get_env(:nebu_http, :oauth_revoke_test_hook) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end
    end
  else
    defp test_hook, do: :ok
  end
end
