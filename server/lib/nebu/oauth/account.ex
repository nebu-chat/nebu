defmodule Nebu.OAuth.Account do
  @moduledoc """
  The account-management page `GET <issuer>/account` of Nebu's OAuth surface (epic oauth-broker, story
  oauth-account-management, ADR-033 "Account management and `m.oauth` (story 6)", decisions A1-A27):
  the page OAuth-aware Matrix clients (Element Web / X) deep-link to for the things they cannot do
  with User-Interactive Authentication — listing devices, signing a device out and approving the reset
  of the cross-signing identity — and which also serves LEGACY-only users (A13/A25).

  Server-rendered HTML (`Nebu.OAuth.AccountPages`, strict CSP, no JavaScript except the one pinned click-proof script of the reset page while it renders the approve form), signed in through the
  corporate IdP with the SAME IdP client and the SAME registered callback as the OAuth authorize flow
  (state tag `o2.acct.`), with a short-lived, DB-backed, hashed browser session
  (`Nebu.OAuth.AccountStore`; NOT a Matrix device, it never authenticates `/_matrix/*`).

  ## Routes (forwarded by `Nebu.Web.Router` to `Nebu.OAuth.Http`, action `:account`)

    * `GET /account` — every action, chosen by `action` / `device_id` (A5): `org.matrix.profile`,
      `org.matrix.devices_list`, `org.matrix.device_view`, `org.matrix.device_delete`,
      `org.matrix.cross_signing_reset`; an absent / unknown action (also the not advertised
      `org.matrix.account_deactivate`) is the default page (profile summary + device list)
    * `GET /account/reauth` — starts an IdP (re-)authentication for a return target (A10)
    * `POST /account/devices/delete`, `/account/cross_signing_reset/approve`, `.../decline`,
      `/account/logout` — state changes (A9, A10, A11)
    * anything else => 404 page; a wrong method (also `OPTIONS`) => 405 page with `Allow`

  ## Order of every request (A3, A19)

  live predicate (`Nebu.OAuth.Config.live_state/0`, the SAME as `auth_metadata` 200: disabled =>
  `404` page, unreadable config => `503` page, both before a rate-limit token or any DB access) =>
  per-IP bucket `{"oauth_account", ip}` (600/h, node-local abuse control only) => route.

  ## Browser session (A8, A9, A10, A11)

  A request without a valid session starts an IdP login (`prompt=login`, `max_age=0`, the shared
  callback): the login request is a DB row (`state_hash`, SecretBox-encrypted IdP verifier, nonce,
  browser-binding hash, the validated RETURN TARGET), the binding cookie is `nebu_acct_<16 hex>` (`__Host-nebu_acct_<16 hex>`, `Path=/; Secure`, on an https request, HY9). The
  callback consumes the row atomically, verifies the binding, completes the IdP login, resolves the
  Matrix user WITHOUT provisioning (`Nebu.Matrix.account_identity/1`), checks `auth_time` freshness
  and creates a NEW session (rotation: the presented old session is deleted); the redirect target
  comes ONLY from the row (open-redirect safe). Cookie `__Host-nebu_account` (`Path=/; Secure`) on an
  https request (also behind `X-Forwarded-Proto: https`), `nebu_account` (`Path=/account`) on plain
  http; `HttpOnly; SameSite=Lax`, no `Max-Age`.

  Every POST is CSRF-protected: a hidden `csrf_token` (derived from the session cookie, only its hash
  is stored; constant-time compare) is authoritative, and `Nebu.OAuth.BrowserPost` (the ONE copy of the
  Origin / fetch-metadata checks, shared with the consent page, story oauth-authorize-freshness FR8)
  adds defence in depth: an `Origin` header (when present) equal to the issuer origin, `Sec-Fetch-Site`
  absent or `same-origin`, and — for the destructive actions — fetch metadata that describes a
  user-activated top-level form navigation. Any failure => `403` page, nothing changed. CSRF is checked
  BEFORE freshness.

  What those checks do NOT stop (gate ag, E-3): `Origin: null` is accepted ONLY together with
  `Sec-Fetch-Site: same-origin` (a privacy-setting / sandbox fallback), and the navigation check stops
  `fetch()` / XHR (their mode and destination are not a document navigation) but NOT a scripted
  `form.submit()` on the same origin, which IS a top-level navigation. The pages carry no script (the reset page only the one pinned click-proof script, `script-src 'sha256-...'`) and a
  CSP without any other script source, so this needs a separate XSS-class bug on the origin. Story
  oauth-client-revocation (SO2) therefore requires the STRICT level for `POST /account/cross_signing_reset/approve`
  (all four fetch-metadata headers present, so a scripted submit without a user activation is refused; not on WebKit, where the
  script-set click proof replaces the user-activation header, ADR-033 SO9); a
  same-origin script that waits for any user click on the origin remains able to submit (ADR-033 SO7): only a separate origin for Element Web
  removes it.

  Destructive actions (device deletion, reset approval / decline) need a FRESH session (`now - auth_time <
  300 s`), else `303` with notice `stale` (the page shows a "Confirm it's you" link to `/account/reauth`).
  A session WITHOUT any `auth_time` (the IdP reports none, story oauth-authorize-freshness FR14, gate y,
  fail closed) is never fresh and is told apart: notice `freshness_unavailable` and NO reauth link (the IdP
  would not report a time next time either: a loop); viewing works. GET never mutates; a POST never renders
  its result (PRG `303`, the one exception is `POST /account/logout`).

  ## Logging (A21, A22)

  INFO lines name user / device only; WARNING for a missing `auth_time` (throttled to one per hour per node,
  FR14) and for a failed CSRF check (no values). NEVER logged: cookie values, CSRF tokens, state, IdP code / tokens / claims, UIA
  session ids, hashes.
  """

  import Plug.Conn
  require Logger

  alias Nebu.OAuth.{AccountPages, AccountStore, AuthorizeRequest, BrowserPost, ClientStore, Config, Freshness, FormPost, SourceKey}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  @callback_path "/_matrix/client/v3/login/sso/redirect/oidc"
  @binding_prefix "nebu_acct_"
  @host_binding_prefix "__Host-nebu_acct_"
  @binding_max_age 600

  @per_ip_per_hour 600
  @fresh_seconds 300
  @max_devices_rendered 500
  # `Nebu.Matrix.account_devices/1` reads at most this many rows
  @device_read_limit 5000
  @max_device_id_bytes 255
  @unavailable_retry_after_s 5

  @cookie_http "nebu_account"
  @cookie_https "__Host-nebu_account"

  @state_regex ~r/\Ao2\.acct\.[A-Za-z0-9_-]{43}\z/
  @cookie_regex ~r/\A[A-Za-z0-9_-]{43}\z/

  @profile "org.matrix.profile"
  @devices_list "org.matrix.devices_list"
  @device_view "org.matrix.device_view"
  @device_delete "org.matrix.device_delete"
  @reset "org.matrix.cross_signing_reset"
  @actions [@profile, @devices_list, @device_view, @device_delete, @reset]

  # Input aliases (never advertised; Element's fallbacks, oracle O2).
  @aliases %{
    "org.matrix.sessions_list" => @devices_list,
    "sessions_list" => @devices_list,
    "org.matrix.session_view" => @device_view,
    "session_view" => @device_view,
    "org.matrix.session_end" => @device_delete,
    "session_end" => @device_delete
  }

  @get_paths [[], ["reauth"]]
  @post_paths [["devices", "delete"], ["cross_signing_reset", "approve"], ["cross_signing_reset", "decline"], ["logout"]]

  # ════════════════════════════════════════════════════════════════════════════
  # entry point of /account*
  # ════════════════════════════════════════════════════════════════════════════

  @doc """
  Handles one `/account*` request (the router forwards the prefix, so `conn.path_info` is the part
  after `/account`). See the moduledoc for the order of the checks.
  """
  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    case Config.live_state() do
      {:live, issuer} -> rate_limited(fetch_cookies(conn), issuer)
      :unknown -> AccountPages.send_error(conn, 503, "unavailable", retry_after: @unavailable_retry_after_s)
      :off -> AccountPages.send_error(conn, 404, "unavailable")
    end
  end

  defp rate_limited(conn, issuer) do
    case RateLimit.take({"oauth_account", ClientIP.bucket(conn)}, @per_ip_per_hour / 60, @per_ip_per_hour) do
      :ok -> route(conn, issuer)
      {:deny, retry_after_s} -> AccountPages.send_error(conn, 429, "rate_limited", retry_after: retry_after_s)
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: []} = conn, issuer), do: show(conn, issuer)
  defp route(%Plug.Conn{method: "GET", path_info: ["reauth"]} = conn, issuer), do: reauth(conn, issuer)
  defp route(%Plug.Conn{method: "POST", path_info: path} = conn, issuer) when path in @post_paths, do: post(conn, issuer, path)

  defp route(%Plug.Conn{path_info: path} = conn, _issuer) when path in @get_paths,
    do: AccountPages.send_error(conn, 405, "method_not_allowed", allow: "GET")

  defp route(%Plug.Conn{path_info: path} = conn, _issuer) when path in @post_paths,
    do: AccountPages.send_error(conn, 405, "method_not_allowed", allow: "POST")

  defp route(conn, _issuer), do: AccountPages.send_error(conn, 404, "not_found")

  # ════════════════════════════════════════════════════════════════════════════
  # GET /account
  # ════════════════════════════════════════════════════════════════════════════

  defp show(conn, issuer) do
    request = parse_request(conn)

    case current_session(conn) do
      {:ok, session} -> render(conn, session, request)
      :none -> start_login(conn, issuer, return_target(request), [session_hash(conn)])
      {:error, reason} -> session_error(conn, reason)
    end
  end

  defp reauth(conn, issuer) do
    request = parse_request(conn)
    start_login(conn, issuer, return_target(request), [session_hash(conn)])
  end

  # ── request parsing (A5) ────────────────────────────────────────────────────

  # `%{action: canonical | nil, device_id: String.t() | nil, notice: code | nil}`; nil action = the
  # default page. A malformed encoding or a duplicated `action` / `device_id` => the default page with
  # the fixed notice `invalid_request` (never a 4xx that breaks a deep link, never the raw value echoed).
  defp parse_request(conn) do
    with {:ok, pairs} <- AuthorizeRequest.parse_query(conn.query_string),
         names = Enum.map(pairs, &elem(&1, 0)),
         true <- Enum.count(names, &(&1 == "action")) <= 1 and Enum.count(names, &(&1 == "device_id")) <= 1 do
      action = pairs |> List.keyfind("action", 0) |> value() |> canonical_action()
      device_id = pairs |> List.keyfind("device_id", 0) |> value()
      notice = pairs |> List.keyfind("notice", 0) |> value()

      %{
        action: action,
        device_id: if(valid_device_id?(device_id), do: device_id),
        notice: if(notice in AccountPages.notice_codes(), do: notice)
      }
    else
      _ -> %{action: nil, device_id: nil, notice: "invalid_request"}
    end
  end

  defp value({_name, v}), do: v
  defp value(nil), do: nil

  defp canonical_action(action) when action in @actions, do: action
  defp canonical_action(action) when is_binary(action), do: Map.get(@aliases, action)
  defp canonical_action(_action), do: nil

  defp valid_device_id?(id) when is_binary(id),
    do: byte_size(id) in 1..@max_device_id_bytes and String.valid?(id) and not Regex.match?(~r/\p{Cc}/u, id)

  defp valid_device_id?(_id), do: false

  # The validated return target recorded with a login request (A6): an action of the five, plus the
  # device id for the two device actions (without a valid one: the default page).
  defp return_target(%{action: action, device_id: device_id}) when action in [@device_view, @device_delete] do
    if device_id, do: {action, device_id}, else: {nil, nil}
  end

  defp return_target(%{action: action}) when action in [@profile, @devices_list, @reset], do: {action, nil}
  defp return_target(_request), do: {nil, nil}

  # ── pages ───────────────────────────────────────────────────────────────────

  defp render(conn, session, request) do
    base = %{user_id: session.user_id, display_name: session.display_name, csrf_token: session.csrf_token, notice: request.notice}
    # FR14: on the two pages with destructive actions a session without `auth_time` says why they are unavailable
    base_destructive = %{base | notice: request.notice || if(is_nil(session.auth_time), do: "freshness_unavailable")}

    case request.action do
      @profile ->
        AccountPages.send_page(conn, 200, :profile, Map.put(base, :action, @profile))

      @devices_list ->
        with_devices(conn, session, fn devices -> device_list_page(conn, base, devices, @devices_list) end)

      @device_view ->
        with_device(conn, session, request, base, fn device ->
          AccountPages.send_page(conn, 200, :device, Map.merge(base, %{action: @device_view, device: device}))
        end)

      @device_delete ->
        with_device(conn, session, request, base, fn device ->
          page =
            Map.merge(base_destructive, %{
              action: @device_delete,
              device: device,
              fresh: fresh?(session.auth_time),
              no_auth_time: is_nil(session.auth_time),
              reauth_href: reauth_href(@device_delete, device.device_id)
            })

          AccountPages.send_page(conn, 200, :delete, page)
        end)

      @reset ->
        reset_page(conn, session, base_destructive)

      _default ->
        with_devices(conn, session, fn devices -> device_list_page(conn, base, devices, "default", :default) end)
    end
  end

  defp device_list_page(conn, base, devices, action, page \\ :devices) do
    {shown, hidden} = Enum.split(devices, @max_devices_rendered)
    shown = with_app_names(shown)

    # The facade reads at most @device_read_limit rows: at that size the "not shown" count is a lower bound
    # and the page says "At least N more devices" (review cycle 1 i5: an honest counter).
    page_assigns = %{action: action, devices: shown, hidden: length(hidden), hidden_exact: length(devices) < @device_read_limit}
    AccountPages.send_page(conn, 200, page, Map.merge(base, page_assigns))
  end

  # The device (own devices only, by membership in the user's device list: foreign, unknown, invalid and
  # missing ids all get the SAME answer, the device list with the notice `device_not_found`, A5/A13).
  defp with_device(conn, session, request, base, found) do
    with_devices(conn, session, fn devices ->
      case request.device_id && Enum.find(devices, &(&1.device_id == request.device_id)) do
        %{} = device ->
          [device] = with_app_names([device])
          found.(device)

        _ ->
          device_list_page(conn, %{base | notice: "device_not_found"}, devices, @devices_list)
      end
    end)
  end

  defp with_devices(conn, session, render) do
    case Nebu.Matrix.account_devices(session.user_id) do
      {:ok, devices} ->
        render.(devices)

      {:error, :unavailable} ->
        Logger.error("OAuth account: the device list is unavailable")
        session_error(conn, :storage)
    end
  end

  defp reset_page(conn, session, base) do
    case Nebu.Matrix.cross_signing_reset_requests(session.user_id) do
      {:ok, requests} ->
        page =
          Map.merge(base, %{
            action: @reset,
            requests: with_request_devices(session.user_id, requests),
            fresh: fresh?(session.auth_time),
            no_auth_time: is_nil(session.auth_time),
            reauth_href: reauth_href(@reset, nil)
          })

        AccountPages.send_page(conn, 200, :reset, page)

      {:error, :unavailable} ->
        Logger.error("OAuth account: the reset requests are unavailable")
        session_error(conn, :storage)
    end
  end

  # The requesting device's app (the app's OWN claim) and last activity make a request recognizable
  # (UX review A1); best effort: without them the page still lists the request.
  defp with_request_devices(_user_id, []), do: []

  defp with_request_devices(user_id, requests) do
    devices =
      case Nebu.Matrix.account_devices(user_id) do
        {:ok, list} -> list |> Enum.filter(&(&1.device_id in Enum.map(requests, fn r -> r.device_id end))) |> with_app_names()
        _ -> []
      end

    by_id = Map.new(devices, &{&1.device_id, &1})

    Enum.map(requests, fn r ->
      device = Map.get(by_id, r.device_id, %{})
      Map.merge(r, %{app_name: device[:app_name], device_last_seen_ts: device[:last_seen_ts]})
    end)
  end

  # The OAuth app of a device is shown as the registration's `client_name` (the app's OWN claim,
  # escaped by the renderer; follow-up story-3 (c) is made visible, not solved). ONE query for all
  # clients; a name that cannot be read is simply not shown (the list does not depend on it).
  defp with_app_names(devices) do
    names = client_names(devices |> Enum.map(& &1.client_id) |> Enum.reject(&is_nil/1))
    Enum.map(devices, &Map.put(&1, :app_name, Map.get(names, &1.client_id)))
  end

  defp client_names([]), do: %{}

  defp client_names(ids) do
    case ClientStore.client_names(ids) do
      {:ok, names} ->
        names

      {:error, reason} ->
        Logger.warning("OAuth account: client names unavailable reason=#{log_reason(reason)}")
        %{}
    end
  rescue
    e ->
      Logger.warning("OAuth account: client names unavailable reason=#{inspect(e.__struct__)}")
      %{}
  catch
    :exit, _ ->
      Logger.warning("OAuth account: client names unavailable reason=exit")
      %{}
  end

  defp reauth_href(action, nil), do: "/account/reauth?" <> URI.encode_query([{"action", action}])
  defp reauth_href(action, device_id), do: "/account/reauth?" <> URI.encode_query([{"action", action}, {"device_id", device_id}])

  defp fresh?(auth_time) when is_integer(auth_time), do: System.system_time(:second) - auth_time < @fresh_seconds
  defp fresh?(_auth_time), do: false

  # ════════════════════════════════════════════════════════════════════════════
  # session (A8)
  # ════════════════════════════════════════════════════════════════════════════

  # `{:ok, session}` | `:none` | `{:error, :storage | :deactivated | :no_account}`.
  defp current_session(conn) do
    case session_cookie(conn) do
      nil ->
        :none

      cookie ->
        case AccountStore.touch_session(AccountStore.hash(cookie)) do
          {:ok, session} -> check_active(session, cookie)
          :none -> :none
          {:error, :storage} -> {:error, :storage}
        end
    end
  end

  # A deactivated user's next request deletes the session (A8).
  defp check_active(session, cookie) do
    case Nebu.Matrix.account_profile(session.user_id) do
      {:ok, profile} ->
        {:ok, Map.merge(session, %{cookie: cookie, display_name: profile.display_name, csrf_token: csrf_token(cookie)})}

      {:error, :deactivated} ->
        _ = AccountStore.delete_session(AccountStore.hash(cookie))
        {:error, :deactivated}

      {:error, :not_found} ->
        _ = AccountStore.delete_session(AccountStore.hash(cookie))
        {:error, :no_account}

      {:error, :unavailable} ->
        {:error, :storage}
    end
  end

  defp session_error(conn, :storage), do: AccountPages.send_error(conn, 503, "unavailable", retry_after: @unavailable_retry_after_s)
  defp session_error(conn, :deactivated), do: AccountPages.send_error(conn, 403, "deactivated")
  defp session_error(conn, :no_account), do: AccountPages.send_error(conn, 403, "no_account")

  # On an https request ONLY the `__Host-` cookie is read (an unprefixed cookie is ignored: cookie
  # tossing from a sibling subdomain); on plain http (dev / test only) `nebu_account`.
  defp session_cookie_name(conn), do: if(https?(conn), do: @cookie_https, else: @cookie_http)

  defp session_cookie(conn) do
    case conn.req_cookies[session_cookie_name(conn)] do
      value when is_binary(value) -> if Regex.match?(@cookie_regex, value), do: value
      _ -> nil
    end
  end

  defp session_hash(conn) do
    case session_cookie(conn) do
      nil -> nil
      cookie -> AccountStore.hash(cookie)
    end
  end

  defp put_session_cookie(conn, cookie) do
    if https?(conn) do
      put_resp_cookie(conn, @cookie_https, cookie, path: "/", secure: true, http_only: true, same_site: "Lax")
    else
      put_resp_cookie(conn, @cookie_http, cookie, path: "/account", http_only: true, same_site: "Lax")
    end
  end

  defp delete_session_cookie(conn) do
    if https?(conn) do
      delete_resp_cookie(conn, @cookie_https, path: "/", secure: true, http_only: true, same_site: "Lax")
    else
      delete_resp_cookie(conn, @cookie_http, path: "/account", http_only: true, same_site: "Lax")
    end
  end

  # The CSRF token of a session, derived from the session cookie (256 bits, only known to this
  # browser): the page can render it on every request although only its SHA-256 is stored. Never
  # logged, never in a URL.
  defp csrf_token(cookie),
    do: :crypto.mac(:hmac, :sha256, "nebu-account-csrf-v1", cookie) |> Base.url_encode64(padding: false)

  # Same rule as the IdP callback URL and `.well-known` (`Nebu.Web.RequestScheme`).
  defp https?(conn), do: Nebu.Web.RequestScheme.https?(conn)

  # ════════════════════════════════════════════════════════════════════════════
  # IdP login (A6)
  # ════════════════════════════════════════════════════════════════════════════

  # See `Nebu.OAuth.Authorize`: a PER-SOURCE refusal is told apart from the global cap and logged once
  # per node and minute, without any client address, source key or host.
  defp log_capacity(source_key) do
    if AccountStore.source_capped?(source_key) do
      if RateLimit.take({"oauth_cap_warning", :account}, 1, 1) == :ok do
        Logger.warning(
          "OAuth account: per-source live login request cap reached " <>
            "(one client address is at its limit; if all clients hit it, check NEBU_TRUSTED_PROXY_CIDRS)"
        )
      end
    else
      Logger.warning("OAuth account: global live login request cap reached")
    end
  end

  defp start_login(conn, _issuer, {action, device_id}, replaces) do
    state = "o2.acct." <> AccountStore.random_token()
    state_hash = AccountStore.hash(state)
    binding = AccountStore.random_token()
    source_key = SourceKey.for_conn(conn)

    with {:idp, {:ok, idp}} <- {:idp, Nebu.Matrix.idp_authorize_location(conn, %{state: state, prompt: nil})},
         {:encrypt, {:ok, verifier_enc}} <- {:encrypt, encrypt(idp.verifier)},
         {:insert, :ok} <-
           {:insert,
            AccountStore.insert_login_request(%{
              state_hash: state_hash,
              idp_verifier_enc: verifier_enc,
              idp_nonce: idp.nonce,
              binding_hash: AccountStore.hash(binding),
              return_action: action,
              return_device_id: device_id,
              replaces_session_hash: replaces |> Enum.reject(&is_nil/1) |> List.first(),
              # per-source cap of live login requests (AH11)
              source_key: source_key
            })} do
      conn
      |> put_resp_cookie(binding_cookie_name(conn, state_hash), binding,
        path: binding_cookie_path(conn),
        max_age: @binding_max_age,
        http_only: true,
        same_site: "Lax",
        secure: https?(conn)
      )
      |> redirect(idp.location, 302)
    else
      {:idp, {:error, reason}} ->
        Logger.warning("OAuth account: IdP unavailable reason=#{log_reason(reason)}")
        unavailable(conn)

      {:encrypt, :error} ->
        Logger.error("OAuth account: cannot encrypt the IdP verifier (no internal secret?)")
        unavailable(conn)

      {:insert, {:error, :capacity}} ->
        log_capacity(source_key)
        unavailable(conn)

      {:insert, {:error, reason}} ->
        Logger.error("OAuth account: could not persist the login request: #{log_reason(reason)}")
        unavailable(conn)
    end
  end

  defp unavailable(conn), do: AccountPages.send_error(conn, 503, "unavailable", retry_after: @unavailable_retry_after_s)

  @doc """
  The account branch of the SHARED IdP callback (`Nebu.OAuth.handle_idp_callback/1` hands every
  `o2.acct.` state here; `conn.query_params` is fetched). Order: per-IP bucket (a rate-limited
  callback keeps the cookie and consumes nothing) => live check (nothing consumed) => state format =>
  atomic consume => browser binding => IdP `error` => IdP code exchange => Matrix user (no
  provisioning) => `auth_time` freshness => new session => `303` to the server-built return target.
  """
  @spec handle_idp_callback(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_idp_callback(conn) do
    conn = fetch_cookies(conn)
    params = conn.query_params

    case RateLimit.take({"oauth_account", ClientIP.bucket(conn)}, @per_ip_per_hour / 60, @per_ip_per_hour) do
      {:deny, retry_after_s} ->
        AccountPages.send_error(conn, 429, "rate_limited", retry_after: retry_after_s)

      :ok ->
        state = params["state"]

        # review cycle 1 (m6): the binding cookie is cleared only once the live check passed, so a
        # callback while OAuth is not live consumes AND clears nothing (the request row survives with it)
        case Config.live_state() do
          {:live, _issuer} -> callback(clear_binding_cookie(conn, state), params, state)
          :unknown -> unavailable(conn)
          :off -> AccountPages.send_error(conn, 404, "unavailable")
        end
    end
  end

  defp callback(conn, params, state) do
    with true <- is_binary(state) and Regex.match?(@state_regex, state),
         {:ok, row} <- AccountStore.consume_login_request(state),
         :ok <- check_binding(conn, state, row.binding_hash) do
      complete(conn, params, row)
    else
      {:error, :storage} ->
        Logger.error("OAuth account callback: login request store unavailable")
        unavailable(conn)

      _invalid ->
        Logger.info("OAuth account callback: invalid, expired or replayed sign-in state")
        AccountPages.send_error(conn, 400, "invalid_state")
    end
  end

  # The per-flow cookie must be present and match (constant time on the hashes).
  defp check_binding(conn, state, stored_hash) do
    case conn.req_cookies[binding_cookie_name(conn, AccountStore.hash(state))] do
      value when is_binary(value) and value != "" ->
        if Plug.Crypto.secure_compare(AccountStore.hash(value), stored_hash), do: :ok, else: :mismatch

      _ ->
        :missing
    end
  end

  defp complete(conn, params, row) do
    idp_error = params["error"]
    code = params["code"]

    cond do
      # the IdP's error / error_description are never shown
      is_binary(idp_error) and idp_error != "" ->
        Logger.info("OAuth account callback: the IdP returned an authorization error")
        AccountPages.send_error(conn, 403, "access_denied")

      not is_binary(code) or code == "" ->
        AccountPages.send_error(conn, 403, "access_denied")

      true ->
        sign_in(conn, code, row)
    end
  end

  defp sign_in(conn, code, row) do
    with {:verifier, {:ok, verifier}} <- {:verifier, decrypt(row.idp_verifier_enc)},
         {:idp, {:ok, %{claims: claims}}} <- {:idp, Nebu.Matrix.idp_complete_login(conn, code, verifier, row.idp_nonce)},
         {:identity, {:ok, %{user_id: user_id, auth_time: idp_auth_time}}} <- {:identity, Nebu.Matrix.account_identity(claims)},
         {:fresh, {:ok, auth_time}} <- {:fresh, login_freshness(idp_auth_time, row.created_at)},
         cookie = AccountStore.random_token(),
         :ok <-
           AccountStore.create_session(%{
             session_hash: AccountStore.hash(cookie),
             user_id: user_id,
             auth_time: auth_time,
             csrf_hash: AccountStore.hash(csrf_token(cookie)),
             replaces: [row.replaces_session_hash, session_hash(conn)]
           }) do
      Logger.info("OAuth account: signed in user_id=#{user_id}")

      conn
      |> put_session_cookie(cookie)
      |> redirect(return_location(row), 303)
    else
      {:verifier, _} ->
        Logger.error("OAuth account callback: the stored IdP verifier cannot be decrypted")
        AccountPages.send_error(conn, 500, "server_error")

      {:idp, {:error, :idp_unavailable}} ->
        unavailable(conn)

      {:idp, _} ->
        Logger.info("OAuth account callback: the IdP login could not be verified")
        AccountPages.send_error(conn, 403, "access_denied")

      {:identity, {:error, :unknown_user}} ->
        Logger.info("OAuth account callback: no Matrix account for the signed-in identity")
        AccountPages.send_error(conn, 403, "no_account")

      {:identity, {:error, :deactivated}} ->
        AccountPages.send_error(conn, 403, "deactivated")

      {:identity, _} ->
        unavailable(conn)

      {:fresh, :stale} ->
        Logger.info("OAuth account callback: the IdP did not re-authenticate the user")
        AccountPages.send_error(conn, 403, "reauth_failed")

      {:error, reason} ->
        Logger.error("OAuth account callback: could not create the session: #{log_reason(reason)}")
        unavailable(conn)
    end
  end

  # A7 / FR14: the id_token's `auth_time` claim ONLY (`iat` proves issuance, not authentication), judged by
  # `Nebu.OAuth.Freshness`: present and not older than the login request minus 60 s => the session's
  # `auth_time` (a future value is clamped to now: the session must never stay "fresh" longer than the
  # re-authentication window); STALE => the caller answers `reauth_failed`; ABSENT => the session carries NO
  # `auth_time` (NULL = never fresh, fail closed: gate y). The operator gets ONE WARNING per hour per node,
  # not one per login.
  defp login_freshness(auth_time, requested_at) do
    case Freshness.evaluate(auth_time, requested_at) do
      {:fresh, t} ->
        {:ok, t}

      {:stale, _t} ->
        :stale

      :absent ->
        if RateLimit.take({"oauth_config_warning", :account_no_auth_time}, 1 / 60, 1) == :ok do
          Logger.warning(
            "OAuth account: the IdP returned no auth_time; sessions without it can neither sign out devices nor approve key resets (fail closed)"
          )
        end

        {:ok, nil}
    end
  end

  # The redirect comes ONLY from the consumed row (never from the callback query): relative, encoded.
  defp return_location(%{return_action: action, return_device_id: device_id}) when action in @actions do
    pairs = [{"action", action}] ++ if(device_id, do: [{"device_id", device_id}], else: [])
    "/account?" <> URI.encode_query(pairs)
  end

  defp return_location(_row), do: "/account"

  # story oauth-hardening-hygiene (HY9): `__Host-nebu_acct_<16 hex>` (`Path=/; Secure`) on an https request, the
  # pre-existing `nebu_acct_<16 hex>` (`Path=<callback path>`) on plain http; the callback reads only the name of its
  # own scheme (no legacy fallback on https, a scheme mismatch is `400 invalid_state`). Same rule as the authorize flow.
  defp binding_cookie_name(conn, state_hash) do
    prefix = if https?(conn), do: @host_binding_prefix, else: @binding_prefix
    prefix <> binary_part(state_hash, 0, 16)
  end

  defp binding_cookie_path(conn), do: if(https?(conn), do: "/", else: @callback_path)

  # Cleared (Max-Age=0) on every callback outcome except the rate-limited one.
  defp clear_binding_cookie(conn, state) when is_binary(state) do
    delete_resp_cookie(conn, binding_cookie_name(conn, AccountStore.hash(state)),
      path: binding_cookie_path(conn),
      http_only: true,
      same_site: "Lax",
      secure: https?(conn)
    )
  end

  defp clear_binding_cookie(conn, _state), do: conn

  # ════════════════════════════════════════════════════════════════════════════
  # POST /account/* (A9, A10, A11, A13, A16)
  # ════════════════════════════════════════════════════════════════════════════

  defp post(conn, issuer, path) do
    case FormPost.parse(conn) do
      {:error, conn, _status, _description} ->
        AccountPages.send_error(conn, 400, "invalid_request")

      {:ok, conn, params} ->
        case current_session(conn) do
          {:ok, session} -> checked_post(conn, issuer, path, params, session)
          # an expired session: sign in first (a POST cannot be replayed through the IdP)
          :none -> redirect(conn, "/account", 303)
          {:error, reason} -> session_error(conn, reason)
        end
    end
  end

  defp checked_post(conn, issuer, path, params, session) do
    # story oauth-client-revocation SO2: approving a cross-signing reset needs the STRICT fetch-metadata level
    # (all four headers present); decline, device delete and sign-out keep the lenient rules.
    #
    # story safari-fetch-metadata-compat: Safari never sends `Sec-Fetch-User`; the approve form carries the click proof
    # (`params:` opts into the proof rules of `BrowserPost`). A WebKit request with correct headers but without the proof
    # (script blocked, stale page) is a NOTICE on the reset page, not an error; nothing is approved.
    opts = [navigation: path != ["logout"], strict: path == ["cross_signing_reset", "approve"], params: params]

    case {csrf_ok?(params, session), BrowserPost.check(conn, issuer, opts)} do
      {true, :ok} ->
        dispatch(conn, path, params, session)

      {true, :unproven} ->
        Logger.warning("OAuth account: request not carried out, the click proof of a user-clicked form submit is missing")
        notice_redirect(conn, [{"action", @reset}], "activation_unproven")

      _ ->
        Logger.warning("OAuth account: CSRF check failed")
        AccountPages.send_error(conn, 403, "forbidden")
    end
  end

  # The hidden token is authoritative; `Nebu.OAuth.BrowserPost` (Origin, fetch metadata) is additional and
  # independent of it.
  defp csrf_ok?(params, session),
    do: is_binary(params["csrf_token"]) and Plug.Crypto.secure_compare(AccountStore.hash(params["csrf_token"]), session.csrf_hash)

  defp dispatch(conn, ["logout"], _params, session), do: logout(conn, session)
  defp dispatch(conn, ["devices", "delete"], params, session), do: delete_device(conn, params, session)
  defp dispatch(conn, ["cross_signing_reset", verb], params, session), do: decide_reset(conn, verb, params, session)

  defp logout(conn, session) do
    case AccountStore.delete_session(AccountStore.hash(session.cookie)) do
      :ok ->
        Logger.info("OAuth account: signed out user_id=#{session.user_id}")

        conn
        |> delete_session_cookie()
        |> AccountPages.send_page(200, :signed_out, %{action: "signed_out", notice: "signed_out"})

      {:error, reason} ->
        Logger.error("OAuth account: could not end the session: #{log_reason(reason)}")
        unavailable(conn)
    end
  end

  defp delete_device(conn, params, session) do
    device_id = params["device_id"]

    cond do
      is_nil(session.auth_time) ->
        notice_redirect(conn, device_target(device_id), "freshness_unavailable")

      not fresh?(session.auth_time) ->
        notice_redirect(conn, device_target(device_id), "stale")

      not valid_device_id?(device_id) ->
        notice_redirect(conn, [{"action", @devices_list}], "device_not_found")

      true ->
        case Nebu.Matrix.account_devices(session.user_id) do
          {:ok, devices} ->
            if Enum.any?(devices, &(&1.device_id == device_id)),
              do: end_device(conn, session, device_id),
              else: notice_redirect(conn, [{"action", @devices_list}], "device_not_found")

          {:error, :unavailable} ->
            unavailable(conn)
        end
    end
  end

  # The same locked teardown as revoke / logout (story 5 C12): every `matrix_sessions` row of the device
  # of ANY `auth_api`, the device tables with keys, one transaction.
  defp end_device(conn, session, device_id) do
    case Nebu.Matrix.end_device_session(session.user_id, device_id) do
      :ok ->
        Logger.info("OAuth account: device signed out user_id=#{session.user_id} device_id=#{device_id}")
        notice_redirect(conn, [{"action", @devices_list}], "device_deleted")

      {:error, :unavailable} ->
        Logger.error("OAuth account: the device teardown failed")
        AccountPages.send_error(conn, 500, "server_error")
    end
  end

  defp device_target(device_id) do
    if valid_device_id?(device_id),
      do: [{"action", @device_delete}, {"device_id", device_id}],
      else: [{"action", @device_delete}]
  end

  defp decide_reset(conn, verb, params, session) when verb in ["approve", "decline"] do
    session_id = params["session_id"]

    cond do
      is_nil(session.auth_time) ->
        notice_redirect(conn, [{"action", @reset}], "freshness_unavailable")

      not fresh?(session.auth_time) ->
        notice_redirect(conn, [{"action", @reset}], "stale")

      not (is_binary(session_id) and byte_size(session_id) <= 255) ->
        notice_redirect(conn, [{"action", @reset}], "reset_not_found")

      true ->
        device_id = requesting_device(session.user_id, session_id)

        result =
          if verb == "approve",
            do: Nebu.Matrix.approve_cross_signing_reset(session.user_id, session_id),
            else: Nebu.Matrix.decline_cross_signing_reset(session.user_id, session_id)

        case result do
          :ok ->
            Logger.info("OAuth account: cross-signing reset #{verb}d user_id=#{session.user_id} device_id=#{device_id}")
            notice_redirect(conn, [{"action", @reset}], if(verb == "approve", do: "reset_approved", else: "reset_declined"))

          {:error, :not_found} ->
            notice_redirect(conn, [{"action", @reset}], "reset_not_found")

          {:error, :unavailable} ->
            Logger.error("OAuth account: the reset decision could not be stored")
            AccountPages.send_error(conn, 500, "server_error")
        end
    end
  end

  # Best effort, for the INFO line only (the UIA session id itself is never logged).
  defp requesting_device(user_id, session_id) do
    with {:ok, requests} <- Nebu.Matrix.cross_signing_reset_requests(user_id),
         %{device_id: device_id} when is_binary(device_id) <- Enum.find(requests, &(&1.session_id == session_id)) do
      device_id
    else
      _ -> "unknown"
    end
  end

  # PRG (A11): a POST never renders its result, it answers 303 to a GET with a fixed notice code.
  defp notice_redirect(conn, query_pairs, notice) do
    redirect(conn, "/account?" <> URI.encode_query(query_pairs ++ [{"notice", notice}]), 303)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # helpers
  # ════════════════════════════════════════════════════════════════════════════

  defp redirect(conn, location, status) do
    conn
    |> AccountPages.put_headers()
    |> put_resp_header("location", location)
    |> send_resp(status, "")
  end

  # SecretBox raises without an internal secret: never a 500.
  defp encrypt(plaintext) do
    {:ok, Nebu.Web.SecretBox.encrypt(plaintext)}
  rescue
    _ -> :error
  end

  defp decrypt(blob) do
    Nebu.Web.SecretBox.decrypt(blob)
  rescue
    _ -> {:error, :decrypt_failed}
  end

  # Never `inspect/1` a store or IdP error (may carry row data or IdP-supplied text).
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason({tag, _detail}) when is_atom(tag), do: inspect(tag)
  defp log_reason(other) when is_atom(other), do: inspect(other)
  defp log_reason(_other), do: "unexpected error"
end
