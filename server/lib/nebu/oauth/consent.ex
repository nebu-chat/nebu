defmodule Nebu.OAuth.Consent do
  @moduledoc """
  The consent step of the authorization code flow (epic oauth-broker, story oauth-authorize-freshness,
  ADR-033 "Consent, freshness and refresh serialization", FR1, FR5-FR8, FR11, FR12, FR17, FR18): the user's
  decision, taken on a Nebu page BEFORE any authorization code exists.

  After the verified IdP login `Nebu.OAuth.Authorize` persists a consent row (`Nebu.OAuth.ConsentStore`)
  and answers `303 Location: /oauth2/consent` with the consent cookie; this module serves that route. It
  is the ONLY caller of `Nebu.OAuth.CodeStore.insert/1`: no code exists without the user's click.

  ## Routes (`Nebu.Web.Router` -> `Nebu.OAuth.Http`, action `:consent`; handled by `handle/1`)

    * `GET /oauth2/consent` renders the page from the LIVE row of the cookie (`Nebu.OAuth.ConsentPage`);
      it mutates nothing, so a reload is safe (PRG).
    * `POST /oauth2/consent` (`csrf_token`, `decision=allow|deny`) decides.
    * any other method (a preflight `OPTIONS` included) => `405` page (`Allow: GET, POST`); any sub-path
      => `404` page. Browser navigation: no CORS at all.

  ## Order of a request

  live predicate (`Nebu.OAuth.Config.live_state/0`: disabled / invalid issuer => `404` page, unreadable
  config => `503` page, both before a rate-limit token or any DB access) => route => per-IP bucket
  `{"oauth_consent", ip}` (600/h; a rate-limited request keeps the cookie and consumes nothing) => the
  request. A POST checks, ALL BEFORE the row is consumed and in this order: `Nebu.OAuth.FormPost.parse/1`
  and the `decision` value (`400 invalid_request`), `Nebu.OAuth.BrowserPost` (Origin and fetch metadata,
  `403 forbidden`), the consent cookie (missing / malformed `400 invalid_state`), the CSRF token (`403
  forbidden`). A refused POST logs ONE value-free WARNING and consumes nothing.

  ## Binding and CSRF (FR8)

  Cookie `__Host-nebu_oauth_consent` (`Path=/; Secure`) on an https request, else `nebu_oauth_consent`
  (`Path=/oauth2/consent`); `HttpOnly; SameSite=Lax; Max-Age=300` (Strict would not be sent on the `303`
  that ends the IdP's cross-site redirect chain). The value is 256 random bits; the row is keyed by its
  SHA-256. The CSRF token is `base64url(SHA-256("nebu-oauth-consent-csrf:" <> cookie))`, compared in
  constant time, nothing stored. One consent per browser: a second flow overwrites the cookie, so the first
  flow's Allow is `invalid_state`.

  ## Outcomes (FR12, FR18)

  Both decisions CONSUME the row atomically (one `DELETE ... RETURNING`: of N parallel Allows exactly one
  wins) and answer `303 See Other` (never 302 / 307) to the redirect URI of the row, in its response mode,
  with `state` and `iss` (RFC 9207). `deny` => `error=access_denied` with a fixed ASCII description. `allow`
  => the client must still be `approved` (else the `403 client_rejected` page; a revoked client counts as
  rejected), the device holder is checked AGAIN (FR11), then the code is minted. A consumed / expired /
  unknown row is the `400 invalid_state` page. The client only ever sees a `code` or a fixed-description
  `access_denied` / `server_error`; `device_in_use`, `invalid_state`, `forbidden` and `client_rejected` are
  user pages, never redirects.

  ## Device holder (FR11)

  `device_check/3` (also used at the callback): a device id held by a live session of ANOTHER app is
  REFUSED (a recorded Nebu policy, stricter than the spec); the same app (equal `client_id` or equal
  deduped identity, `Nebu.OAuth.ClientStore.client_identity/1`) continues its session; a legacy or
  session-less device is replaced after Allow.

  ## Logging (FR17)

  INFO `OAuth consent: allowed|denied|refused ...` with ids only; never the cookie, CSRF token, code,
  state, nonce, verifier, claims, names or the redirect URI.
  """

  import Plug.Conn
  require Logger

  alias Nebu.OAuth.{Authorize, AuthorizeRequest, BrowserPost, ClientStore, CodeStore, Config, ConsentPage, ConsentStore, FormPost, Pages}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  @cookie_http "nebu_oauth_consent"
  @cookie_https "__Host-nebu_oauth_consent"
  @cookie_path_http "/oauth2/consent"
  @cookie_regex ~r/\A[A-Za-z0-9_-]{43}\z/

  @per_ip_per_hour 600
  @unavailable_retry_after_s 5

  # ════════════════════════════════════════════════════════════════════════════
  # entry point of /oauth2/consent*
  # ════════════════════════════════════════════════════════════════════════════

  @doc """
  Handles one `/oauth2/consent*` request (the router forwards the prefix, so `conn.path_info` is the part
  after `/oauth2/consent`). See the moduledoc for the order of the checks.
  """
  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    case Config.live_state() do
      {:live, issuer} -> route(fetch_cookies(conn), issuer)
      :unknown -> Pages.send_page(conn, 503, "unavailable", retry_after: @unavailable_retry_after_s)
      :off -> Pages.send_page(conn, 404, "unavailable")
    end
  end

  defp route(%Plug.Conn{path_info: []} = conn, issuer) do
    case conn.method do
      "GET" -> rate_limited(conn, fn -> show(conn) end)
      "POST" -> rate_limited(conn, fn -> post(conn, issuer) end)
      _other -> Pages.send_page(conn, 405, "method_not_allowed", allow: "GET, POST")
    end
  end

  defp route(conn, _issuer), do: Pages.send_page(conn, 404, "not_found")

  defp rate_limited(conn, run) do
    case RateLimit.take({"oauth_consent", ClientIP.bucket(conn)}, @per_ip_per_hour / 60, @per_ip_per_hour) do
      :ok -> run.()
      # nothing consumed, the cookie stays: the same browser can retry
      {:deny, retry_after_s} -> Pages.send_page(conn, 429, "rate_limited", retry_after: retry_after_s)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # GET: the page
  # ════════════════════════════════════════════════════════════════════════════

  defp show(conn) do
    with {:ok, cookie} <- consent_cookie(conn),
         {:ok, row} <- peek(cookie),
         {:ok, client} <- approved_client(row.client_id),
         {:ok, device} <- device_for_page(row) do
      page = %{
        user_id: row.user_id,
        client_metadata: client.metadata,
        redirect_uri: row.redirect_uri,
        device_id: row.device_id,
        device: device,
        login_fresh: row.login_fresh,
        csrf_token: csrf_token(cookie)
      }

      case ConsentPage.send_page(conn, page) do
        {:ok, conn} ->
          conn

        # the redirect target cannot be turned into a valid CSP source: nothing consumed, no code
        :error ->
          Logger.error("OAuth consent: the redirect target of a consent request is unusable client_id=#{row.client_id}")
          Pages.send_page(conn, 500, "server_error")
      end
    else
      {:page, status, code} -> Pages.send_page(conn, status, code)
      {:refused, :device_in_use} -> Pages.send_page(conn, 403, "device_in_use")
    end
  end

  defp peek(cookie) do
    case ConsentStore.peek(cookie) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:page, 400, "invalid_state"}
      {:error, :storage} -> {:page, 503, "unavailable"}
    end
  end

  defp device_for_page(row) do
    case device_check(row.user_id, row.device_id, row.client_id) do
      {:ok, device} -> {:ok, device}
      :refused -> {:refused, :device_in_use}
      :unavailable -> {:page, 503, "unavailable"}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # POST: the decision
  # ════════════════════════════════════════════════════════════════════════════

  defp post(conn, issuer) do
    with {:parse, {:ok, conn, params}} <- {:parse, FormPost.parse(conn)},
         {:decision, decision} when decision in ["allow", "deny"] <- {:decision, params["decision"]},
         {:origin, :ok} <- {:origin, BrowserPost.check(conn, issuer)},
         {:cookie, {:ok, cookie}} <- {:cookie, consent_cookie(conn)},
         {:csrf, true} <- {:csrf, csrf_ok?(params["csrf_token"], cookie)} do
      decide(conn, issuer, cookie, decision)
    else
      {:parse, {:error, conn, _status, _description}} ->
        Pages.send_page(conn, 400, "invalid_request")

      {:decision, _unknown} ->
        Pages.send_page(conn, 400, "invalid_request")

      {:cookie, {:page, status, code}} ->
        Pages.send_page(clear_cookie(conn), status, code)

      {check, _failed} when check in [:origin, :csrf] ->
        # ONE value-free WARNING (never the Origin value, headers, cookie or token); nothing consumed
        Logger.warning("OAuth consent: request refused (the origin, fetch-metadata or CSRF check failed)")
        Pages.send_page(conn, 403, "forbidden")
    end
  end

  defp csrf_ok?(token, cookie) when is_binary(token), do: Plug.Crypto.secure_compare(token, csrf_token(cookie))
  defp csrf_ok?(_token, _cookie), do: false

  defp decide(conn, issuer, cookie, decision) do
    case ConsentStore.consume(cookie) do
      {:ok, row} ->
        conn = clear_cookie(conn)

        with {:ok, _client} <- approved_client(row.client_id),
             {:ok, _target} <- usable_target(row) do
          if decision == "deny", do: deny(conn, issuer, row), else: allow(conn, issuer, row)
        else
          {:page, status, code} ->
            Logger.info("OAuth consent: refused client_id=#{row.client_id} reason=#{code}")
            Pages.send_page(conn, status, code)
        end

      # a DEFINITE outcome (the row is gone or never was): the cookie is of no use any more
      {:error, reason} when reason in [:expired, :not_found] ->
        Logger.info("OAuth consent: refused reason=invalid_state")
        Pages.send_page(clear_cookie(conn), 400, "invalid_state")

      # the store could not be read: the row may still be there, so the cookie stays and a retry works
      {:error, :storage} ->
        Logger.error("OAuth consent: the consent store is unavailable")
        Pages.send_page(conn, 503, "unavailable", retry_after: @unavailable_retry_after_s)
    end
  end

  # A redirect target the page could not turn into a valid CSP source is not redirected to either (the same
  # rule as the GET): nothing is issued, the user sees the server_error page.
  defp usable_target(row) do
    case ConsentPage.target(row.redirect_uri) do
      {:ok, target} -> {:ok, target}
      :error -> {:page, 500, "server_error"}
    end
  end

  defp deny(conn, issuer, row) do
    Logger.info("OAuth consent: denied client_id=#{row.client_id} user_id=#{row.user_id} device_id=#{row.device_id}")
    error_redirect(conn, issuer, row, "access_denied")
  end

  defp allow(conn, issuer, row) do
    case device_check(row.user_id, row.device_id, row.client_id) do
      {:ok, device} -> mint(conn, issuer, row, device)
      :refused -> refuse_device(conn, row)
      :unavailable -> Pages.send_page(conn, 503, "unavailable", retry_after: @unavailable_retry_after_s)
    end
  end

  defp holder_client_id({:same_client, %{client_id: client_id}}), do: client_id
  defp holder_client_id(_device), do: nil

  # FR11, re-checked at Allow: the holder may have changed since the callback.
  defp refuse_device(conn, row) do
    Logger.info("OAuth consent: refused client_id=#{row.client_id} user_id=#{row.user_id} device_id=#{row.device_id} reason=device_in_use")
    Pages.send_page(conn, 403, "device_in_use")
  end

  defp mint(conn, issuer, row, device) do
    attrs =
      Map.take(row, [:client_id, :redirect_uri, :code_challenge, :device_id, :user_id, :scope, :scope_prefix, :response_mode])
      |> Map.merge(%{
        client_nonce: row.client_nonce,
        openid_requested: row.openid_requested,
        idp_rt_enc: row.idp_rt_enc,
        auth_time: row.auth_time,
        # L-1: the holder the user saw and accepted; the token endpoint re-checks it under the device lock
        device_holder_checked: true,
        device_holder_client_id: holder_client_id(device)
      })

    case CodeStore.insert(attrs) do
      {:ok, code} ->
        Logger.info("OAuth consent: allowed client_id=#{row.client_id} user_id=#{row.user_id} device_id=#{row.device_id}")
        params = [{"code", code}] ++ state_param(row.client_state) ++ [{"iss", issuer}]
        redirect(conn, AuthorizeRequest.redirect_location(row.redirect_uri, row.response_mode, params))

      {:error, reason} ->
        Logger.error("OAuth consent: could not issue the authorization code client_id=#{row.client_id}: #{log_reason(reason)}")
        error_redirect(conn, issuer, row, "server_error")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # the device holder (FR11), shared with the callback
  # ════════════════════════════════════════════════════════════════════════════

  @doc """
  Who holds `device_id` of `user_id` relative to `client_id` (FR11): `{:ok, :new}` (nobody),
  `{:ok, {:same_client, holder}}` (a live session of the SAME app: equal `client_id`, or equal deduped
  identity, so a DCR re-registration of the same app is not refused), `{:ok, {:replace, holder}}` (a legacy
  session, or a device without a live session: replaced after Allow), `:refused` (a live OAuth session of
  ANOTHER app: a recorded Nebu policy, stricter than the spec, RFC 9700 4.11 / RFC 6749 10.12) or
  `:unavailable` (the holder or an identity could not be read: never "no holder").
  """
  @spec device_check(String.t(), String.t(), String.t()) ::
          {:ok, :new | {:same_client | :replace, map()}} | :refused | :unavailable
  def device_check(user_id, device_id, client_id) do
    case Nebu.Matrix.oauth_device_holder(user_id, device_id) do
      {:ok, :none} ->
        {:ok, :new}

      {:ok, %{auth_api: "oauth", client_id: holder_client} = holder} ->
        case same_app?(client_id, holder_client) do
          true -> {:ok, {:same_client, holder}}
          false -> :refused
          :error -> :unavailable
        end

      {:ok, holder} ->
        {:ok, {:replace, holder}}

      {:error, :unavailable} ->
        :unavailable
    end
  end

  defp same_app?(client_id, client_id), do: true

  defp same_app?(client_id, other) do
    with {:ok, %{} = a} <- ClientStore.client_identity(client_id),
         {:ok, %{} = b} <- ClientStore.client_identity(other) do
      a == b
    else
      # no client_uri on either side: only an equal client_id counts
      {:ok, nil} -> false
      {:error, _} -> :error
    end
  end

  # The client of a consent row must still be approved (a revoked / rejected client counts as rejected).
  defp approved_client(client_id) do
    case ClientStore.fetch_by_client_id(client_id) do
      {:ok, %{status: "approved"} = client} -> {:ok, client}
      {:ok, nil} -> {:page, 400, "invalid_state"}
      {:ok, _not_approved} -> {:page, 403, "client_rejected"}
      {:error, _} -> {:page, 503, "unavailable"}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # cookie and CSRF token (FR8)
  # ════════════════════════════════════════════════════════════════════════════

  @doc false
  @spec cookie_name(Plug.Conn.t()) :: String.t()
  def cookie_name(conn), do: if(https?(conn), do: @cookie_https, else: @cookie_http)

  @doc """
  Sets the consent cookie `value` (256 random bits, base64url) on the callback's `303`: `HttpOnly;
  SameSite=Lax; Max-Age=300`, `__Host-` + `Path=/` + `Secure` on https, else `Path=/oauth2/consent`.
  """
  @spec put_cookie(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_cookie(conn, value) do
    opts = [max_age: ConsentStore.ttl_seconds(), http_only: true, same_site: "Lax"]

    if https?(conn),
      do: put_resp_cookie(conn, @cookie_https, value, [path: "/", secure: true] ++ opts),
      else: put_resp_cookie(conn, @cookie_http, value, [path: @cookie_path_http] ++ opts)
  end

  @doc "A fresh consent cookie value: 32 random bytes, base64url without padding (43 characters)."
  @spec new_cookie_value() :: String.t()
  def new_cookie_value, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp clear_cookie(conn) do
    if https?(conn),
      do: delete_resp_cookie(conn, @cookie_https, path: "/", secure: true, http_only: true, same_site: "Lax"),
      else: delete_resp_cookie(conn, @cookie_http, path: @cookie_path_http, http_only: true, same_site: "Lax")
  end

  # On https ONLY the `__Host-` name is read (an unprefixed cookie is ignored: cookie tossing from a sibling
  # subdomain); a missing or malformed value is `invalid_state`.
  defp consent_cookie(conn) do
    case conn.req_cookies[cookie_name(conn)] do
      value when is_binary(value) -> if Regex.match?(@cookie_regex, value), do: {:ok, value}, else: {:page, 400, "invalid_state"}
      _ -> {:page, 400, "invalid_state"}
    end
  end

  # Derived from the cookie (256 bits, only this browser knows it): the page can render it on every request
  # although nothing is stored. Never logged, never in a URL.
  defp csrf_token(cookie), do: :crypto.hash(:sha256, "nebu-oauth-consent-csrf:" <> cookie) |> Base.url_encode64(padding: false)

  defp https?(conn), do: Nebu.Web.RequestScheme.https?(conn)

  # ════════════════════════════════════════════════════════════════════════════
  # redirects to the client
  # ════════════════════════════════════════════════════════════════════════════

  defp error_redirect(conn, issuer, row, error) do
    params =
      [{"error", error}, {"error_description", Authorize.error_description(error)}] ++
        state_param(row.client_state) ++ [{"iss", issuer}]

    redirect(conn, AuthorizeRequest.redirect_location(row.redirect_uri, row.response_mode, params))
  end

  defp state_param(state) when is_binary(state) and state != "", do: [{"state", state}]
  defp state_param(_state), do: []

  # `303 See Other` (never 302 / 307): the browser follows it with a GET, whatever the POST was.
  defp redirect(conn, location) do
    conn
    |> Pages.put_flow_headers()
    |> put_resp_header("location", location)
    |> send_resp(303, "")
  end

  # Never `inspect/1` a store error (may carry row data).
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason(other) when is_atom(other), do: inspect(other)
  defp log_reason({tag, _detail}) when is_atom(tag), do: inspect(tag)
  defp log_reason(_other), do: "unexpected error"
end
