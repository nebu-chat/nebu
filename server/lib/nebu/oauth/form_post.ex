defmodule Nebu.OAuth.FormPost do
  @moduledoc """
  The form-POST plumbing shared by the OAuth endpoints that take an
  `application/x-www-form-urlencoded` body: `POST /oauth2/token` (`Nebu.OAuth.Token`) and
  `POST /oauth2/revoke` (`Nebu.OAuth.Revoke`). EXTRACTED from `Nebu.OAuth.Token` (story
  oauth-token-revocation-logout, R1): a move, not a copy — the behaviour of the token endpoint is
  byte-identical.

  ## `parse/1` (AC2 steps 1-5, T23 / R8)

    1. a non-empty query string => `invalid_request` (credentials never belong in URLs)
    2. `Content-Type` not `application/x-www-form-urlencoded` (case-insensitive, parameters such
       as `charset` allowed) => 400
    3. body > 16 KiB => 413; read error => 400. The raw body is read exactly once, here
       (`Nebu.Web.Plugs.JsonBody` skips these paths, so `conn.body_params` stays `Unfetched` and
       `RequestLogger` never captures the request body)
    4. malformed form encoding => 400
    5. duplicated parameter, control character or invalid UTF-8 => 400; afterwards empty values are
       dropped (RFC 6749 3.1: empty = omitted)

  ## Responses

  `json/3`, `oauth_error/4` and `server_error/3` carry the token-endpoint envelope: `Content-Type:
  application/json`, `Cache-Control: no-store`, `Pragma: no-cache`, `Access-Control-Allow-Origin: *`
  and never `Access-Control-Allow-Credentials` (T32). Every 4xx is the RFC 6749 5.2 shape (never
  `errcode`); every 5xx is `Retry-After` + the body `{}` WITHOUT an `error` member (T20, oracle C1).
  """

  import Plug.Conn

  alias Nebu.OAuth.TokenRequest

  @max_body 16_384

  @doc "Parses the form body: `{:ok, conn, params}` or `{:error, conn, status, description}`."
  @spec parse(Plug.Conn.t()) :: {:ok, Plug.Conn.t(), %{String.t() => String.t()}} | {:error, Plug.Conn.t(), pos_integer(), String.t()}
  def parse(conn) do
    with :ok <- check_query(conn),
         :ok <- check_content_type(conn),
         {:ok, body, conn} <- read_form(conn),
         {:ok, pairs} <- parse_pairs(conn, body),
         {:ok, params} <- validate(conn, pairs) do
      {:ok, conn, params}
    else
      {:error, %Plug.Conn{}, _status, _description} = error -> error
      {:error, status, description} -> {:error, conn, status, description}
    end
  end

  defp check_query(%Plug.Conn{query_string: qs}) when qs in [nil, ""], do: :ok
  defp check_query(_conn), do: {:error, 400, "Parameters must be sent in the request body, not in the URL."}

  defp check_content_type(conn) do
    if conn |> get_req_header("content-type") |> List.first() |> TokenRequest.valid_content_type?(),
      do: :ok,
      else: {:error, 400, "The request body must be application/x-www-form-urlencoded."}
  end

  defp read_form(conn) do
    case read_body(conn, length: @max_body, read_length: @max_body) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, conn, 413, "The request body is too large."}
      {:error, _reason} -> {:error, conn, 400, "The request body could not be read."}
    end
  end

  defp parse_pairs(conn, body) do
    case Nebu.OAuth.AuthorizeRequest.parse_query(body) do
      {:ok, pairs} -> {:ok, pairs}
      {:error, :malformed} -> {:error, conn, 400, "The request body is not valid form encoding."}
    end
  end

  defp validate(conn, pairs) do
    case TokenRequest.validate_params(pairs) do
      {:ok, params} -> {:ok, params}
      {:error, :invalid_request} -> {:error, conn, 400, "The request contains a duplicated or invalid parameter."}
    end
  end

  @doc "RFC 6749 5.2 error. `description == nil` (429) => only `{\"error\": code}`."
  @spec oauth_error(Plug.Conn.t(), pos_integer(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def oauth_error(conn, status, code, description) do
    body =
      if description,
        do: %{"error" => code, "error_description" => description},
        else: %{"error" => code}

    json(conn, status, body)
  end

  @doc "T20 / oracle C1: every 5xx is `Retry-After` + `{}` (no `error` member)."
  @spec server_error(Plug.Conn.t(), pos_integer(), pos_integer()) :: Plug.Conn.t()
  def server_error(conn, status, retry_after_s) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> json(status, %{})
  end

  @doc "JSON response with the OAuth form-endpoint envelope (see the moduledoc)."
  @spec json(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> delete_resp_header("access-control-allow-credentials")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
