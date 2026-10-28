defmodule Nebu.Matrix.SsoConfirm do
  @moduledoc """
  The confirmation step of the legacy SSO login for an https `redirectUrl` that is NOT listed (story
  `legacy-sso-redirect-confirmation`, epic SEC gate 3 finding G3-3, decisions D3, D7 - D10, D12). Matrix-private.

  The shared callback (`Nebu.Matrix.SsoLogin`) calls `begin/2` instead of minting a `loginToken` for such a
  target: the verified IdP login is parked in `Nebu.Matrix.SsoStore` (`:confirm` tag, key = the RAW SHA-256 digest
  of a browser-binding cookie, TTL 300 s) and the browser is sent (`303`) to `GET
  /_matrix/client/v3/login/sso/confirm`, which shows the page (`Nebu.Matrix.SsoConfirmPage`); `POST` on the same
  path decides. Only Continue mints the `loginToken` (30 s, the same store and the same `POST /login` redemption as
  today) and sends the browser to the target (`303`, never 302 / 307). Cancel consumes the entry and mints nothing.

  ## Browser binding and CSRF (D8, mirrors the OAuth consent page)

  The binding cookie value is 32 random bytes, base64url (43 characters). On https `__Host-nebu_sso_confirm`
  (`Path=/; Secure`), else `nebu_sso_confirm` (`Path=/_matrix/client/v3/login/sso/confirm`); always `HttpOnly;
  SameSite=Lax; Max-Age=300` (Strict would not be sent on the `303` that ends the IdP's cross-site redirect chain).
  On https ONLY the `__Host-` name is read (cookie tossing). The CSRF token is `base64url(SHA-256("nebu-sso-confirm-csrf:"
  <> cookie))`, rendered in the form, compared in constant time, nothing stored. The cookie is cleared on
  Continue, Cancel and every definite `invalid_state`; it stays on `forbidden`, `invalid_request` and
  `rate_limited` (nothing was consumed).

  ## Counting (story sso-confirm-bucket-order, follow-up `cv`) and POST checks, in this order, ALL before anything is consumed (D9)

  The binding cookie decides how a request is counted; no shared bucket is charged before it is classified, so a party without a live
  binding can never lock the page for the users who have one (the G3-2 collapse puts every client behind one address):

    1. no cookie, or a malformed one -> `400 invalid_state`, nothing charged, the store is not asked (GET and POST alike); a malformed cookie is
       cleared, a missing one is not (a cross-site POST carries no Lax cookie and must not delete the live one);
    2. a well-formed cookie -> `SsoStore.peek_confirm/1`:
       HIT (a live parked login) -> the PER-BINDING bucket `{"sso_confirm", hex(SHA-256(cookie))}` (refill 2/min, burst 60, GET and POST
       share it; exhausted: `429`, the cookie stays, nothing is consumed);
       MISS (unknown / expired / consumed) -> the PER-ADDRESS miss bucket `{"sso_confirm_miss", ip}` (refill 10/min, burst 600; exhausted:
       `429`, the cookie stays; else the definite `400 invalid_state`). It can only deny requests that carry an UNKNOWN cookie.
    3. POST only, in this order: form parse (`400 invalid_request`, `Nebu.OAuth.parse_form_post/1`) -> `decision` in `continue | cancel`
       (`400 invalid_request`) -> `Origin` + fetch metadata (`403 forbidden`) -> CSRF token (`403 forbidden`) ->
       `SsoStore.pop_confirm/1` (single use, BEFORE minting; a pop miss after a hit is `400 invalid_state`).

  Residual: a flood of well-formed random cookies still reaches the node-local `SsoStore` (an O(1) lookup, 5 s call timeout) and fills the
  miss bucket of its source; it denies no live binding (follow-up `di`: a signed cookie would avoid the lookup). The miss bucket throttles the ANSWER, not the store lookup, which
  runs first (it must, to tell a hit from a miss); an UNREACHABLE store (timeout, `noproc`) is a MISS too: such a request is charged to the miss bucket and answers
  `invalid_state` as before.

  ## Logging (D12)

  INFO `matrix SSO: redirect confirmation shown|confirmed|declined host=<host>` (the validated ASCII host, with
  `:port` when not 443) and two value-free WARNINGs. Never the loginToken, `id_token`, refresh token, cookie, its
  hash, the CSRF token, or the path, query or fragment of the redirect URL.
  """

  import Plug.Conn
  require Logger

  alias Nebu.Matrix.{SsoConfirmPage, SsoLogin, SsoRedirect, SsoStore}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  @confirm_path "/_matrix/client/v3/login/sso/confirm"
  @cookie_http "nebu_sso_confirm"
  @cookie_https "__Host-nebu_sso_confirm"
  @cookie_regex ~r/\A[A-Za-z0-9_-]{43}\z/
  @ttl_seconds 300
  # per-address bucket of the requests that carry an UNKNOWN cookie (the former single bucket's limits)
  @miss_per_hour 600
  # per-binding bucket (refill per minute, burst): the page, a reload and the decision need a handful of requests
  @binding_refill_per_min 2
  @binding_burst 60
  @retry_after_unavailable_s 5

  # ════════════════════════════════════════════════════════════════════════════
  # the callback side
  # ════════════════════════════════════════════════════════════════════════════

  @doc """
  Parks a verified IdP login for an UNLISTED https target and answers the callback with `303 Location:
  /_matrix/client/v3/login/sso/confirm` plus the binding cookie. `fields`: `:id_token`, `:oidc_refresh_token`
  (nil when none), `:redirect_url` (the RAW string), `:user_id` (derived for display only) and `:target` (the
  `{:confirmable, target}` map of `Nebu.Matrix.SsoRedirect.classify/1`). NO `loginToken` is minted. A full confirm
  store answers the `503 unavailable` page (WARNING, no cookie, nothing stored).
  """
  @spec begin(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def begin(conn, %{target: target} = fields) do
    value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    entry = %{
      id_token: fields.id_token,
      oidc_refresh_token: fields.oidc_refresh_token,
      redirect_url: fields.redirect_url,
      origin: target.origin,
      host: target.host,
      port: target.port,
      path: target.path,
      user_id: fields.user_id
    }

    case SsoStore.put_confirm(digest(value), entry, @ttl_seconds) do
      :ok ->
        Logger.info("matrix SSO: redirect confirmation shown host=#{SsoRedirect.host_label(target)}")
        conn |> put_cookie(value) |> SsoConfirmPage.see_other(@confirm_path)

      {:error, :store_full} ->
        Logger.warning("matrix SSO: confirmation store full")
        SsoConfirmPage.send_error(conn, 503, "unavailable", retry_after: @retry_after_unavailable_s)

      {:error, :unavailable} ->
        Logger.warning("matrix SSO: confirmation store unavailable")
        SsoConfirmPage.send_error(conn, 503, "unavailable", retry_after: @retry_after_unavailable_s)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # GET / POST /_matrix/client/v3/login/sso/confirm
  # ════════════════════════════════════════════════════════════════════════════

  @doc "Handles `GET` (render the page) and `POST` (decide) on the confirmation route. See the moduledoc."
  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    conn = fetch_cookies(conn)

    case binding_cookie(conn) do
      {:ok, cookie} -> classified(conn, cookie)
      # nothing is charged and the store is not asked. A MALFORMED cookie is cleared (it is of no use), a MISSING one is not: a cross-site
      # top-level POST carries no `SameSite=Lax` cookie, and its answer must not delete the live cookie of the user (SEC review L-1)
      :invalid -> invalid_state(conn)
      :none -> SsoConfirmPage.send_error(conn, 400, "invalid_state")
    end
  end

  # a well-formed cookie: a live entry (HIT) is counted per binding, an unknown one (MISS) per client address
  defp classified(conn, cookie) do
    case SsoStore.peek_confirm(digest(cookie)) do
      {:ok, entry} ->
        case RateLimit.take({"sso_confirm", binding_bucket(cookie)}, @binding_refill_per_min, @binding_burst) do
          :ok -> run(conn, cookie, entry)
          # nothing consumed, the cookie stays: the same browser can retry
          {:deny, retry_after_s} -> SsoConfirmPage.send_error(conn, 429, "rate_limited", retry_after: retry_after_s)
        end

      :error ->
        case RateLimit.take({"sso_confirm_miss", ClientIP.bucket(conn)}, @miss_per_hour / 60, @miss_per_hour) do
          :ok -> invalid_state(conn)
          {:deny, retry_after_s} -> SsoConfirmPage.send_error(conn, 429, "rate_limited", retry_after: retry_after_s)
        end
    end
  end

  defp run(conn, cookie, entry) do
    case conn.method do
      "GET" -> show(conn, cookie, entry)
      "POST" -> post(conn, cookie)
    end
  end

  # lower-case hex SHA-256 of the cookie: the bucket key never holds the cookie itself
  defp binding_bucket(cookie), do: Base.encode16(digest(cookie), case: :lower)

  # ── GET: the page (peek, mutates nothing, a reload is safe) ─────────────────

  defp show(conn, cookie, entry) do
    case SsoConfirmPage.send_page(conn, entry, csrf_token(cookie)) do
      {:ok, conn} -> conn
      _ -> invalid_state(conn)
    end
  end

  # ── POST: the decision (the cookie is proven live and counted; the checks below run before anything is consumed) ──

  defp post(conn, cookie) do
    with {:parse, {:ok, conn, params}} <- {:parse, Nebu.OAuth.parse_form_post(conn)},
         {:decision, decision} when decision in ["continue", "cancel"] <- {:decision, params["decision"]},
         {:origin, true} <- {:origin, request_origin_ok?(conn)},
         {:csrf, true} <- {:csrf, csrf_ok?(params["csrf_token"], cookie)} do
      decide(conn, cookie, decision)
    else
      {:parse, {:error, conn, _status, _description}} ->
        SsoConfirmPage.send_error(conn, 400, "invalid_request")

      {:decision, _unknown} ->
        SsoConfirmPage.send_error(conn, 400, "invalid_request")

      {check, _failed} when check in [:origin, :csrf] ->
        # ONE value-free WARNING (never the Origin value, headers, cookie or token); nothing consumed
        Logger.warning("matrix SSO: confirmation request refused (the origin, fetch-metadata or CSRF check failed)")
        SsoConfirmPage.send_error(conn, 403, "forbidden")
    end
  end

  defp decide(conn, cookie, decision) do
    case SsoStore.pop_confirm(digest(cookie)) do
      {:ok, entry} -> apply_decision(clear_cookie(conn), entry, decision)
      :error -> invalid_state(conn)
    end
  end

  # Continue: the entry is already consumed (popped BEFORE minting, never re-inserted). The loginToken is minted
  # exactly as the callback does for a listed target and the browser is sent to the target with `303`.
  defp apply_decision(conn, entry, "continue") do
    {opaque, stored} = SsoLogin.mint_login_token(entry.id_token, entry.oidc_refresh_token)

    case stored do
      :ok ->
        Logger.info("matrix SSO: redirect confirmation confirmed host=#{SsoRedirect.host_label(entry)}")
        SsoConfirmPage.see_other(conn, SsoLogin.append_login_token(entry.redirect_url, opaque))

      {:error, _full_or_unavailable} ->
        Logger.warning("matrix SSO: login token store full or unavailable")
        SsoConfirmPage.send_error(conn, 503, "unavailable", retry_after: @retry_after_unavailable_s)
    end
  end

  defp apply_decision(conn, entry, "cancel") do
    Logger.info("matrix SSO: redirect confirmation declined host=#{SsoRedirect.host_label(entry)}")
    SsoConfirmPage.send_cancelled(conn)
  end

  # A definite `invalid_state` (no / malformed / unknown / expired / consumed entry): the cookie is of no use any more.
  defp invalid_state(conn), do: conn |> clear_cookie() |> SsoConfirmPage.send_error(400, "invalid_state")

  # ════════════════════════════════════════════════════════════════════════════
  # Origin, fetch metadata, CSRF
  # ════════════════════════════════════════════════════════════════════════════

  # Fetch metadata through the OAuth facade (`:lenient`: absent allowed, a present header must be exactly the value
  # of a user-activated top-level form navigation, each at most once) AND the local Origin rule.
  defp request_origin_ok?(conn) do
    origin_ok?(conn) and Nebu.OAuth.check_fetch_metadata(conn, :lenient) == :ok
  end

  # No `Origin` -> ok; `Origin: null` -> ok only with `Sec-Fetch-Site: same-origin`; one `Origin` -> must equal the
  # request's own origin (scheme + the `Host` header: correct HERE, it is a same-origin test of a request that must
  # carry the `__Host-` cookie this very origin set); several -> refused.
  defp origin_ok?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      ["null"] -> same_origin_fetch?(conn)
      [origin] -> single_origin_ok?(conn, normalize_origin(origin))
      _several -> false
    end
  end

  # Code review MIN-2: behind a reverse proxy the `Host` the server sees may differ from the one the browser used
  # (the reference nginx sets `Host $host`, which drops the port). One `Origin` is therefore accepted when it equals
  # the Host-derived origin, OR `https://<server_name>`, OR the browser itself says `Sec-Fetch-Site: same-origin`
  # (a cross-site request still fails the fetch-metadata rule below, whatever its Origin).
  defp single_origin_ok?(_conn, :invalid), do: false

  defp single_origin_ok?(conn, origin) do
    origin == own_origin(conn) or origin in SsoRedirect.server_name_origins() or same_origin_fetch?(conn)
  end

  defp same_origin_fetch?(conn), do: get_req_header(conn, "sec-fetch-site") == ["same-origin"]

  defp own_origin(conn) do
    case get_req_header(conn, "host") do
      [host] -> normalize_origin(Nebu.Web.RequestScheme.scheme(conn) <> "://" <> host)
      _ -> :none
    end
  end

  defp normalize_origin(origin) do
    case Regex.run(~r/\A(https?):\/\/([^\/:?#@\s]+)(?::([0-9]{1,5}))?\z/i, origin) do
      [_, scheme, host | port] ->
        scheme = String.downcase(scheme)
        port = port |> List.first() |> then(&(&1 && String.to_integer(&1)))
        default = if scheme == "https", do: 443, else: 80
        scheme <> "://" <> String.downcase(host) <> if(port in [nil, default], do: "", else: ":#{port}")

      _ ->
        :invalid
    end
  end

  defp csrf_ok?(token, cookie) when is_binary(token), do: Plug.Crypto.secure_compare(token, csrf_token(cookie))
  defp csrf_ok?(_token, _cookie), do: false

  # Derived from the cookie (256 bits, only this browser knows it): the page renders it on every request although
  # nothing is stored. Domain-separated from the OAuth consent page. Never logged, never in a URL.
  defp csrf_token(cookie), do: :crypto.hash(:sha256, "nebu-sso-confirm-csrf:" <> cookie) |> Base.url_encode64(padding: false)

  # The store key: the RAW digest of the cookie value (the cookie itself is never stored).
  defp digest(cookie), do: :crypto.hash(:sha256, cookie)

  # ════════════════════════════════════════════════════════════════════════════
  # the binding cookie (D8)
  # ════════════════════════════════════════════════════════════════════════════

  defp https?(conn), do: Nebu.Web.RequestScheme.https?(conn)

  defp cookie_name(conn), do: if(https?(conn), do: @cookie_https, else: @cookie_http)

  defp put_cookie(conn, value) do
    opts = [max_age: @ttl_seconds, http_only: true, same_site: "Lax"]

    if https?(conn),
      do: put_resp_cookie(conn, @cookie_https, value, [path: "/", secure: true] ++ opts),
      else: put_resp_cookie(conn, @cookie_http, value, [path: @confirm_path] ++ opts)
  end

  defp clear_cookie(conn) do
    if https?(conn),
      do: delete_resp_cookie(conn, @cookie_https, path: "/", secure: true, http_only: true, same_site: "Lax"),
      else: delete_resp_cookie(conn, @cookie_http, path: @confirm_path, http_only: true, same_site: "Lax")
  end

  # On https ONLY the `__Host-` name is read (an unprefixed cookie is ignored); a missing or malformed value is
  # `invalid_state`.
  defp binding_cookie(conn) do
    case conn.req_cookies[cookie_name(conn)] do
      value when is_binary(value) -> if Regex.match?(@cookie_regex, value), do: {:ok, value}, else: :invalid
      _ -> :none
    end
  end
end
