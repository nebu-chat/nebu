defmodule Nebu.Matrix.SsoLogin do
  @moduledoc """
  Matrix client SSO login leg (`bugfix-fix-matrix-sso-redirect-missing`).

  Ports the removed Go `gateway/internal/matrix/sso.go` (`GetSSORedirect` +
  `GetSSOCallback`) to Elixir. Handles the two browser-facing endpoints that the
  advertised `m.login.sso` flow needs:

    * `GET /_matrix/client/v3/login/sso/redirect[?redirectUrl=]` and
      `.../sso/redirect/{idpId}` — validate `redirectUrl` against a scheme
      allowlist (open-redirect protection), generate CSRF `state` + OIDC `nonce` +
      PKCE verifier, persist them in `Nebu.Matrix.SsoStore` (cluster-aware,
      TTL 10 min), then 302 to the IdP `authorization_endpoint`.

    * `GET /_matrix/client/v3/login/sso/redirect/oidc?code=&state=` (callback) —
      constant-time fail-closed `state` check, exchange the code (PKCE), verify the
      `id_token` via the SINGLE shared `Nebu.Web.Plugs.OidcPlug.verify_token/2`
      path, constant-time-check the `nonce`, mint a **short-lived (30s) single-use
      opaque loginToken** mapped to the verified `id_token` in `SsoStore`, and 302
      back to the original `redirectUrl` with `?loginToken=<opaque>`. Since story
      `legacy-sso-redirect-confirmation` (epic SEC gate 3, G3-3) that only holds for a `:direct`
      target (loopback, deep-link scheme) or an https origin that is LISTED
      (`Nebu.Matrix.SsoRedirect.listed?/1`); an UNLISTED https target gets no loginToken but a
      confirmation page (`Nebu.Matrix.SsoConfirm`, `303` to `GET .../sso/confirm`), and only
      Continue mints the token. `redirectUrl` is classified by `Nebu.Matrix.SsoRedirect.classify/1`
      (stricter parsing, still the unchanged `400`), and pre-existing `loginToken` parameters of the
      `redirectUrl` are removed before the new one is appended.

  The client then calls `POST /_matrix/client/v3/login` with
  `{"type":"m.login.token","token":"<opaque>"}`. `Nebu.Matrix.HttpPublic.do_login`
  resolves the opaque token back to the `id_token` (via `SsoStore.pop_login_token`)
  and verifies it through the same `OidcPlug.verify_token` path — there is exactly
  ONE token-verification code path in the codebase.

  ## OIDC credentials (ADR-022 — bootstrap-only, single client)

  The SINGLE OIDC client's id/secret come SOLELY from the Bootstrap DB
  (`server_config`); the secret is stored AES-256-GCM encrypted at rest and decrypted
  on use. There is no `NEBU_OIDC_*` env config path.

  OIDC Scopes Law (bugfix-remove-default-scopes): the base scope is always `openid`;
  extra scopes come exclusively from `server_config.matrix_oidc_extra_scopes`.
  When that key is absent or empty, the scope is `openid` only (no profile/email
  defaults). `offline_access` is added when `matrix_oidc_refresh_mode` is "offline".
  Scope resolution itself is centralized in `Nebu.Web.OidcScopes.resolve_scope/1`
  (story `centralize-scope-resolution`) — this module only calls it.

  ## OAuth broker leg (epic oauth-broker, story oauth-authorize-idp-delegation-code)

  The callback is SHARED with Nebu's OAuth authorization server (ADR-033 D1): a `state` with
  the `o2.` tag is handed to `Nebu.OAuth.handle_idp_callback/1` before anything of the legacy
  branch runs (the OAuth flow state lives in the database, never in `SsoStore`). The IdP request
  builder (`idp_authorize_url/4`) and the IdP login completion (`complete_idp_login/4`) are
  shared by the legacy login, the UIA fallback and the OAuth leg; the OAuth domain reaches them
  only through `Nebu.Matrix.idp_authorize_location/2`, `idp_complete_login/4` and
  `provision_login_user/1` (ADR-020).
  """
  import Plug.Conn
  import Nebu.Matrix.Http, only: [error: 4]

  require Logger

  alias Nebu.Matrix.{SsoConfirm, SsoRedirect, SsoStore}

  # State (user-typing-at-IdP) window and opaque-loginToken replay window.
  @state_ttl_seconds 600
  @login_token_ttl_seconds 30

  # ── GET /sso/redirect[/:idp] ────────────────────────────────────────────────

  @doc """
  Handles `GET .../sso/redirect` and `.../sso/redirect/{idpId}`. Either initiates a
  fresh SSO flow (302 to the IdP) or, when called with `code`+`state` (the IdP
  bounced back to a `/{idpId}` path), delegates to `callback/1`.
  """
  def redirect(conn) do
    redirect_url = conn.query_params["redirectUrl"]

    cond do
      not is_binary(redirect_url) or redirect_url == "" ->
        error(conn, 400, "M_MISSING_PARAM", "redirectUrl is required")

      match?({:reject, _}, SsoRedirect.classify(redirect_url)) ->
        # Do NOT echo the full url back (avoid reflected-XSS / info leak) — only
        # the parsed+escaped scheme is ever rendered, and only on the HTML path.
        Logger.warning("matrix SSO: redirectUrl rejected by allowlist")
        reject_redirect(conn, redirect_url)

      true ->
        # story oauth-legacy-coexistence (C4/C5): `action` is read only AFTER the redirectUrl checks (the
        # error order is unchanged) and only honoured while OAuth is offered.
        do_redirect(conn, redirect_url, nil, sso_action(conn))
    end
  end

  # C4: the stable `action`, else the unstable `org.matrix.msc3824.action` (matrix-js-sdk sends both
  # with the same value). Only the exact values "login" / "register" count; anything else (absent,
  # empty, other case, a map/list from `action[]=`, over-long) is IGNORED, never a 4xx. Precedence: a
  # VALID stable value wins; an invalid stable value falls through to the unstable one; both invalid =>
  # nil. A repeated key resolves through `conn.query_params` (Plug: the last value wins). The raw value
  # is never logged and never forwarded; only the mapped `prompt` reaches the IdP (C6).
  #
  # `action` is honoured for the one advertised identity provider only (`GET /login` lists `id: "oidc"`):
  # no `{idpId}` segment or `oidc`. An arbitrary `{idpId}` behaves exactly as today (the segment is
  # ignored by the legacy redirect, which serves the one IdP), i.e. WITHOUT `action` support.
  defp sso_action(conn) do
    if sso_idp(conn) in [nil, "oidc"] do
      [conn.query_params["action"], conn.query_params["org.matrix.msc3824.action"]]
      |> Enum.find(&(&1 in ["login", "register"]))
    end
  end

  # The `{idpId}` path segment of `/sso/redirect/{idpId}` (nil for `/sso/redirect`). The router forwards with
  # the prefix stripped, so `path_info` is exactly `["sso", "redirect"]` or `["sso", "redirect", idpId]`
  # (matched directly: an idpId that is literally named "redirect" is an idpId, not the route).
  defp sso_idp(conn) do
    case conn.path_info do
      ["sso", "redirect", idp] -> idp
      _ -> nil
    end
  end

  # C5: `prompt=create` replaces `prompt=login` ONLY for `action=register`, while OAuth is offered, and
  # when the IdP's discovery document lists `create` (the story-2 D11 rule); otherwise `login`. The
  # OAuth-offered predicate is asked ONLY when an action is present, so a plain redirect costs nothing new
  # and the URL while OAuth is not offered stays byte-identical to the pre-broker one.
  defp legacy_prompt("register", doc) do
    values = doc["prompt_values_supported"]
    if is_list(values) and "create" in values and oauth_aware?(), do: "create", else: "login"
  end

  defp legacy_prompt(_action, _doc), do: "login"

  defp oauth_aware? do
    Nebu.OAuth.oauth_aware?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # story sso-redirect-error-page/html-error-page-for-rejected-sso-redirect-scheme:
  # a rejected redirectUrl scheme is ALWAYS a 400. What changes is only the
  # response *representation* — a real browser navigating to this endpoint (the
  # Matrix SSO flow always opens a browser here) gets a human-readable HTML page
  # instead of a raw JSON blob, when its Accept header clearly prefers HTML.
  # Every other/ambiguous/missing Accept header keeps the EXACT pre-existing
  # JSON body byte-for-byte (AC2 — the guaranteed default fallback; Oracle N2).
  # This branch is a rejection-only concern (AC6/N1) — it never touches
  # redirect_url_allowed?/1 or the allow path.
  defp reject_redirect(conn, redirect_url) do
    if prefers_html?(conn) do
      uri = URI.parse(redirect_url)
      scheme = uri.scheme && String.downcase(uri.scheme)

      conn
      |> put_resp_header("content-security-policy", "default-src 'none'")
      |> put_resp_content_type("text/html")
      |> send_resp(400, render_html_error(scheme))
    else
      error(conn, 400, "M_INVALID_PARAM", "redirectUrl scheme is not permitted")
    end
  end

  # ── Content negotiation (AC1) ────────────────────────────────────────────────
  #
  # Conservative, JSON-biased heuristic: HTML is rendered ONLY when the Accept
  # header clearly, unambiguously prefers it. Every other case — missing Accept,
  # bare `*/*`, explicit `application/json`, or any tie/ambiguity — falls back to
  # JSON, which stays the guaranteed default representation (AC2, Oracle N2).
  #
  # Algorithm:
  #   1. Parse the Accept header into `{media_type, q}` pairs (default q = 1.0
  #      when the `q` parameter is absent, per RFC 7231 §5.3.2).
  #   2. Find the best (highest-q) HTML-ish entry — `text/html` or
  #      `application/xhtml+xml` (NOT the `*/*` or `text/*` wildcards; those are
  #      too ambiguous to count as an explicit HTML preference).
  #   3. Find the best (highest-q) `application/json` entry.
  #   4. Prefer HTML only if an HTML-ish entry exists AND (no json entry exists
  #      OR the html q-value is strictly greater than the json q-value). A tie
  #      is resolved in favour of JSON (conservative default).
  #
  # `action`/`idpId` query/path params are handled entirely upstream of this
  # function and are never affected by content negotiation (Oracle N3).
  defp prefers_html?(conn) do
    accept_entries =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&parse_accept_header/1)

    html_q = best_q(accept_entries, ["text/html", "application/xhtml+xml"])
    json_q = best_q(accept_entries, ["application/json"])

    case {html_q, json_q} do
      {nil, _} -> false
      {html_q, nil} -> html_q > 0.0
      {html_q, json_q} -> html_q > json_q
    end
  end

  # Highest q-value among entries whose media type is in `wanted`, or nil if none present.
  defp best_q(entries, wanted) do
    entries
    |> Enum.filter(fn {type, _q} -> type in wanted end)
    |> Enum.map(fn {_type, q} -> q end)
    |> case do
      [] -> nil
      qs -> Enum.max(qs)
    end
  end

  # Splits a (possibly comma-joined, since Plug may return one header value per
  # line already split, or one combined "a, b, c" string) Accept header value
  # into `{media_type, q}` pairs. Media type is lowercased; q defaults to 1.0.
  defp parse_accept_header(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_media_range/1)
  end

  defp parse_media_range(entry) do
    [type | params] = entry |> String.split(";") |> Enum.map(&String.trim/1)

    q =
      params
      |> Enum.find_value(fn param ->
        case param |> String.split("=", parts: 2) |> Enum.map(&String.trim/1) do
          ["q", value] ->
            # Require the ENTIRE value to be a valid float (reject trailing
            # garbage like "0.8abc") — this is the client's own header, so
            # there's no cross-boundary trust issue, but a strict parse avoids
            # silently accepting a malformed q-value as if it were valid.
            case Float.parse(value) do
              {q, ""} -> q
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    {String.downcase(type), q || 1.0}
  end

  # ── HTML error page rendering (AC3/AC4) ──────────────────────────────────────
  #
  # `scheme` is the ONLY user-controlled value ever rendered here — never the
  # full redirectUrl (host/path/query). It is explicitly HTML-entity-escaped via
  # `Plug.HTML.html_escape/1` BEFORE interpolation into the static template
  # below. Elixir's bare string interpolation (and EEx, if it were used) does
  # NOT auto-escape — that is a Phoenix.HTML/HEEx-only behaviour — so the
  # escaping must be, and is, explicit here.
  #
  # Defense in depth: `URI.parse/1`'s scheme grammar (RFC 3986) already rejects
  # HTML metacharacters at the parsing layer (any such input yields `scheme ==
  # nil`, never reaching this function via the HTTP path) — layer 1. This
  # explicit escape is layer 2, the failsafe verified independently by the
  # `render_html_error/1` unit test with a directly-injected hostile string.
  #
  # Public (not `defp`) so it can be unit-tested directly, independent of the
  # HTTP/Plug.Conn integration path.
  @doc false
  @spec render_html_error(String.t() | nil) :: String.t()
  def render_html_error(scheme) do
    escaped_scheme = Plug.HTML.html_escape(scheme || "")

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Login Not Supported</title>
    </head>
    <body>
      <h1>Login Method Not Supported</h1>
      <p>This app's login method (<code>#{escaped_scheme}</code>) is not yet permitted on this server.</p>
      <p>Please contact your server administrator and ask them to add this scheme under
      the Admin UI at <code>/admin/config</code>, in the "SSO redirect schemes" section.</p>
    </body>
    </html>
    """
  end

  defp do_redirect(conn, redirect_url, uia_session, action \\ nil) do
    with {:ok, cfg} <- oidc_config(),
         {:ok, doc} <- discovery_doc(cfg.issuer),
         {:ok, authorize} <- doc_url(doc, "authorization_endpoint") do
      verifier = pkce_verifier()
      challenge = pkce_challenge(verifier)
      state = random_token(16)
      nonce = random_token(32)

      case SsoStore.put_state(
             state,
             %{
               verifier: verifier,
               nonce: nonce,
               redirect_url: redirect_url,
               uia_session: uia_session
             },
             @state_ttl_seconds
           ) do
        :ok ->
          # M-1: the UIA step-up fallback (uia_session set) must force a GENUINELY fresh
          # IdP authentication, not silently reuse an existing IdP SSO-session cookie.
          # `prompt=login` is advisory; several IdPs honour an existing session. Adding
          # `max_age=0` forces the IdP to re-authenticate the user (or refuse) so the
          # returned auth_time is trustworthy. ONLY on the UIA-fallback path — the normal
          # login redirect keeps `prompt=login` alone so login UX is not degraded.
          max_age = if is_binary(uia_session) and uia_session != "", do: "0"

          location =
            idp_authorize_url(authorize, conn, cfg, %{
              state: state,
              nonce: nonce,
              code_challenge: challenge,
              prompt: legacy_prompt(action, doc),
              max_age: max_age
            })

          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("location", location)
          |> send_resp(302, "")

        {:error, :store_full} ->
          Logger.warning("matrix SSO: state store full, rejecting redirect")
          error(conn, 429, "M_LIMIT_EXCEEDED", "Too many pending SSO flows")

        {:error, :unavailable} ->
          Logger.warning("matrix SSO: state store unavailable, rejecting redirect")
          error(conn, 503, "M_UNAVAILABLE", "SSO is not available")
      end
    else
      {:error, reason} ->
        Logger.error("matrix SSO redirect failed: #{inspect(reason)}")
        error(conn, 503, "M_UNAVAILABLE", "SSO is not available")
    end
  end

  # The ONE builder of the IdP authorization request (legacy /sso/redirect, the UIA fallback and
  # the OAuth broker leg, story oauth-authorize-idp-delegation-code AC6): the single IdP client
  # (ADR-022), the SHARED registered callback, the scope of the OIDC Scopes Law
  # (`Nebu.Web.OidcScopes`, nothing hardcoded), PKCE S256. `max_age=0` only for the UIA fallback and the OAuth leg.
  defp idp_authorize_url(authorize_endpoint, conn, cfg, p) do
    params = %{
      "response_type" => "code",
      "client_id" => cfg.client_id,
      "redirect_uri" => callback_url(conn),
      "scope" => scope_list(),
      "state" => p.state,
      "nonce" => p.nonce,
      "code_challenge" => p.code_challenge,
      "code_challenge_method" => "S256",
      # prompt=login forces the IdP to re-auth (avoids replaying a cached,
      # already-denylisted id_token after logout) — Go parity.
      "prompt" => p.prompt
    }

    params = if p[:max_age], do: Map.put(params, "max_age", p.max_age), else: params
    authorize_endpoint <> "?" <> URI.encode_query(params)
  end

  @doc false
  # OAuth broker leg (epic oauth-broker, story oauth-authorize-idp-delegation-code AC6, D3, D11),
  # reached only through `Nebu.Matrix.idp_authorize_location/2`. Builds the IdP authorization
  # URL for the caller-generated, OAuth-tagged `state` with the SAME builder and helpers as the
  # legacy redirect, but stores NOTHING in the node-local SsoStore: the IdP PKCE verifier and nonce
  # are returned to the caller, which persists them in the database (cluster safe).
  #
  # `prompt` toward the IdP is the legacy `login`, replaced by `create` only when the caller asks
  # for it AND the IdP's discovery document lists `create` in `prompt_values_supported`;
  # `max_age=0` always (F-2). Discovery happens before anything is generated, so a failure persists nothing.
  def oauth_idp_authorize_location(conn, %{state: state} = params) when is_binary(state) do
    with {:ok, cfg} <- oidc_config(),
         {:ok, doc} <- discovery_doc(cfg.issuer),
         {:ok, authorize} <- doc_url(doc, "authorization_endpoint") do
      verifier = pkce_verifier()
      nonce = random_token(32)

      prompt =
        if params[:prompt] == "create" and "create" in List.wrap(doc["prompt_values_supported"]),
          do: "create",
          else: "login"

      location =
        idp_authorize_url(authorize, conn, cfg, %{
          state: state,
          nonce: nonce,
          code_challenge: pkce_challenge(verifier),
          prompt: prompt,
          # Kassandra F-2: `prompt` is advisory (and `create` replaces `login`), so the OAuth leg
          # ALWAYS asks the IdP for a genuinely fresh authentication; the client's own `max_age`
          # is never forwarded.
          max_age: "0"
        })

      {:ok, %{location: location, verifier: verifier, nonce: nonce}}
    end
  end

  # ── GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id> ────────

  @doc """
  The UIA `m.login.sso` auth FALLBACK (story s3-matrix-device-endpoints, CS v1.18
  §"Fallback"). The client opens this in a browser for an in-flight UIA `session`;
  it behaves exactly like `GET /sso/redirect` (302 → IdP authorize) EXCEPT the SSO
  state is tagged with the UIA session id, so the shared OIDC callback completes
  THAT UIA session (marks its `m.login.sso` stage complete + refreshes auth_time)
  instead of minting a normal loginToken. UNAUTHENTICATED (it IS the auth step).

  An unknown/expired UIA session → 400. The `redirect_url` is irrelevant to the
  re-submit (the client re-submits the original request itself), so a fixed internal
  marker is used; the callback renders a completion page rather than redirecting back.
  """
  def uia_fallback(conn) do
    session_id = conn.query_params["session"]

    cond do
      not is_binary(session_id) or session_id == "" ->
        error(conn, 400, "M_MISSING_PARAM", "session is required")

      match?(:error, Nebu.Matrix.Uia.load(session_id)) ->
        error(conn, 400, "M_UNKNOWN", "Unknown or expired UIA session")

      true ->
        # redirect_url is unused for a UIA completion (the callback renders a page),
        # but do_redirect requires one for the state entry; use an internal marker.
        do_redirect(conn, "https://uia.local/complete", session_id)
    end
  end

  # ── GET /sso/redirect/oidc (callback) ───────────────────────────────────────

  @doc """
  Handles the OIDC callback `.../sso/redirect/oidc`. Three cases (Go parity):

    * `?error=...&state=...` — IdP authorization error → consume state, 403.
    * `?code=...&state=...`  — code exchange → mint loginToken → 302 back to client.
    * neither — treat as an initiation for the "oidc" IdP (`redirect/1`).
  """
  def callback(conn) do
    code = conn.query_params["code"]
    state = conn.query_params["state"]
    idp_error = conn.query_params["error"]

    cond do
      # Epic oauth-broker (story oauth-authorize-idp-delegation-code, AC7, D1/D2): the SAME
      # IdP-registered callback serves the OAuth broker leg. An `o2.`-tagged state (also a
      # malformed one) is handed to the OAuth domain BEFORE anything of the legacy branch runs
      # (no SsoStore pop, no Matrix JSON errors, no fallback into redirect/1).
      Nebu.OAuth.oauth_idp_state?(state) ->
        Nebu.OAuth.handle_idp_callback(conn)

      is_binary(idp_error) and idp_error != "" ->
        # Consume the state to prevent replay, then fail.
        if is_binary(state), do: SsoStore.pop_state(state)
        Logger.warning("matrix SSO: IdP returned authorization error")
        error(conn, 403, "M_FORBIDDEN", "SSO provider rejected the authorization request")

      not is_binary(code) or code == "" or not is_binary(state) or state == "" ->
        # No code → treat as an initiation for the default IdP.
        redirect(conn)

      true ->
        do_callback(conn, code, state)
    end
  end

  defp do_callback(conn, code, state) do
    # pop_state is single-use + fail-closed: an unknown/expired/forged state yields
    # :error here (constant-time compare happens inside the store's key match — the
    # opaque state is a 128-bit random token, so a timing oracle on the ETS key is
    # not a practical CSRF bypass; the security property is "state must match a
    # value WE generated and have not yet consumed").
    case SsoStore.pop_state(state) do
      :error ->
        Logger.warning("matrix SSO: unknown or expired state")
        error(conn, 400, "M_UNKNOWN", "Invalid or expired SSO state")

      {:ok, entry} ->
        with {:ok, %{id_token: id_token, claims: claims, idp_refresh_token: oidc_refresh_token}} <-
               complete_idp_login(conn, code, entry.verifier, entry.nonce) do
          if is_binary(entry.uia_session) and entry.uia_session != "" do
            # S3: this was a UIA m.login.sso completion, not a normal login. Complete
            # the UIA session ONLY when the freshly-authenticated identity matches the
            # session's bound user (H-1), then render a terminal page; on mismatch
            # render a failure page WITHOUT marking the stage complete.
            complete_uia(conn, entry.uia_session, claims)
          else
            finish_legacy_login(conn, entry, id_token, claims, oidc_refresh_token)
          end
        else
          {:error, reason} ->
            Logger.warning("matrix SSO callback failed: #{inspect(reason)}")
            error(conn, 403, "M_FORBIDDEN", "SSO login failed")
        end
    end
  end

  # Story legacy-sso-redirect-confirmation (G3-3, D3): the decision AFTER the IdP login and BEFORE any loginToken
  # exists. `:direct` targets (loopback, deep-link / operator schemes) and https targets whose origin is LISTED keep
  # today's response (302, loginToken appended); an UNLISTED https target gets NO token: the verified login is parked
  # and the browser is sent to the confirmation page (`Nebu.Matrix.SsoConfirm`). A stored URL that no longer
  # classifies (a state created by an older node during a rolling deploy) is today's 403 (value-free WARNING).
  defp finish_legacy_login(conn, entry, id_token, claims, oidc_refresh_token) do
    case SsoRedirect.classify(entry.redirect_url) do
      :direct ->
        redirect_with_login_token(conn, entry.redirect_url, id_token, oidc_refresh_token)

      {:confirmable, target} ->
        if SsoRedirect.listed?(target.origin, entry.redirect_url) do
          redirect_with_login_token(conn, entry.redirect_url, id_token, oidc_refresh_token)
        else
          server = Application.get_env(:nebu_http, :server_name, "localhost")

          SsoConfirm.begin(conn, %{
            id_token: id_token,
            oidc_refresh_token: oidc_refresh_token,
            redirect_url: entry.redirect_url,
            user_id: Nebu.Matrix.UserId.from_claims(claims, server),
            target: target
          })
        end

      {:reject, _reason} ->
        Logger.warning("matrix SSO: the redirectUrl of the pending login is not permitted, login refused")
        error(conn, 403, "M_FORBIDDEN", "SSO login failed")
    end
  end

  defp redirect_with_login_token(conn, redirect_url, id_token, oidc_refresh_token) do
    case mint_login_token(id_token, oidc_refresh_token) do
      # review cycle 2 (INFO-3): a store that does not answer never stored the token, so do not redirect with it
      # (the pre-existing `:store_full` decision, redirecting anyway, is unchanged)
      {_opaque, {:error, :unavailable}} ->
        Logger.warning("matrix SSO: login token store unavailable, rejecting the callback")
        error(conn, 503, "M_UNAVAILABLE", "SSO is not available")

      {opaque, _stored} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("location", append_login_token(redirect_url, opaque))
        |> send_resp(302, "")
    end
  end

  @doc false
  # Mints the opaque, single-use, 30 s loginToken for a verified IdP login (the callback for a direct / listed
  # target, `Nebu.Matrix.SsoConfirm` after Continue). oidc-session-refresh: carries the OIDC refresh token through
  # the single-use loginToken so POST /login can mint a long-lived opaque Nebu session when the client asks for
  # refresh_token: true (nil -> JWT fallback). `{opaque, :ok | {:error, :store_full}}`.
  def mint_login_token(id_token, oidc_refresh_token) do
    opaque = random_token(32)

    {opaque,
     SsoStore.put_login_token(opaque, id_token, @login_token_ttl_seconds, oidc_refresh_token: oidc_refresh_token)}
  end

  @doc false
  # The ONE completion of an IdP login (legacy callback AND the OAuth broker leg, story
  # oauth-authorize-idp-delegation-code AC7.10): code exchange (PKCE verifier, the same
  # `callback_url/1` as the authorize request, the `:matrix_sso_token_override` seam), id_token
  # verification through the single shared `OidcPlug.verify_token/2` path, constant-time nonce
  # check. `{:ok, %{id_token:, claims:, idp_refresh_token:}}` or `{:error, reason}`.
  def complete_idp_login(conn, code, verifier, nonce) do
    with {:ok, cfg} <- oidc_config(),
         {:ok, id_token, idp_refresh_token} <- exchange(conn, code, verifier, cfg),
         {:ok, claims} <- Nebu.Web.Plugs.OidcPlug.verify_token(id_token),
         :ok <- check_nonce(claims, nonce) do
      {:ok, %{id_token: id_token, claims: claims, idp_refresh_token: idp_refresh_token}}
    end
  end

  @doc false
  # Story oauth-authorize-idp-delegation-code D18 (via `Nebu.Matrix.provision_login_user/1`): the
  # provisioning half of `Nebu.Matrix.HttpPublic.provision_and_respond/6` (legacy POST /login),
  # duplicated on purpose instead of refactoring the legacy login — keep the two in sync (a test
  # pins identical `users` rows). Device registration and session creation are NOT part of it
  # (story 3). `{:ok, %{user_id:, auth_time: unix_seconds | nil}}`, `{:error, :deactivated}` or
  # `{:error, reason}`.
  def provision_login_user(claims) when is_map(claims) do
    server = Application.get_env(:nebu_http, :server_name, "localhost")
    user_id = Nebu.Matrix.UserId.from_claims(claims, server)

    display_name = claims["preferred_username"] || claims["name"] || ""
    email = claims["email"] || ""

    case Nebu.Matrix.Session.TokenValidator.validate(user_id, "user", display_name, email) do
      {:ok, user} ->
        dn = if display_name == "", do: nil, else: display_name
        _ = Nebu.Matrix.Profile.DB.upsert_profile(user.user_id, dn, nil)

        is_new = Map.get(user, :is_new, false)
        Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning(user.user_id, is_new)

        {:ok, %{user_id: user.user_id, auth_time: login_auth_time(claims)}}

      {:error, _reason} = error ->
        error
    end
  end

  # Same rule as `HttpPublic.login_auth_time/1`: the id_token's auth_time, else iat.
  defp login_auth_time(claims) do
    case claims["auth_time"] do
      t when is_integer(t) ->
        t

      _ ->
        case claims["iat"] do
          t when is_integer(t) -> t
          _ -> nil
        end
    end
  end

  # S3 (H-1): terminal completion of a UIA m.login.sso stage, IDENTITY-BOUND. The fresh
  # OIDC login has been verified by the shared verify_token path above; derive the Matrix
  # user_id from the verified claims THE SAME WAY login does (UserId.from_claims/2 with
  # the configured server_name — identical derivation incl. sub normalisation) and only
  # complete the UIA session when that identity matches the session's bound user. On a
  # match, Uia.complete/2 marks the stage complete + refreshes auth_time → render the
  # terminal page (status 200; the page runs onAuthDone()); the client then re-submits
  # the original request with auth: {"session": id}.
  #
  # On a mismatch (a DIFFERENT IdP account completing a victim's pending fallback) the
  # UPDATE matches 0 rows → :error → the stage is NOT marked complete and auth_time is
  # NOT refreshed. We render an explicit failure page (403) and never call onAuthDone(),
  # so the step-up cannot be satisfied by an unrelated identity.
  defp complete_uia(conn, uia_session, claims) do
    server = Application.get_env(:nebu_http, :server_name, "localhost")
    authenticated_user = Nebu.Matrix.UserId.from_claims(claims, server)

    case Nebu.Matrix.Uia.complete(uia_session, authenticated_user) do
      {:ok, _user_id} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(200, """
        <!doctype html><html><head><meta charset="utf-8"><title>Authentication complete</title></head>
        <body><p>Authentication complete. You may return to your client.</p>
        <script>if (window.onAuthDone) { window.onAuthDone(); }
        if (window.opener && window.opener.postMessage) { window.opener.postMessage("authDone", "*"); }</script>
        </body></html>
        """)

      :error ->
        # Identity mismatch (or unknown/expired/consumed session). Do NOT mark the
        # stage complete, do NOT refresh auth_time, do NOT run onAuthDone(). Log a
        # warning with NO PII / token / session id.
        Logger.warning("matrix UIA SSO: completion identity did not match the pending request")

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(403, """
        <!doctype html><html><head><meta charset="utf-8"><title>Authentication did not match</title></head>
        <body><p>This authentication did not match the request that started it. The operation was not authorised.</p></body></html>
        """)
    end
  end

  # ── redirectUrl allowlist (open-redirect protection — Go isRedirectURLAllowed) ─

  @doc """
  Exposes the hardcoded scheme denylist (`javascript`, `data`, `file`, `vbscript`,
  `blob`) so `Nebu.Admin.ConfigController` can reject an operator's attempt to
  allowlist one of them at SAVE time (AC5/AC9), without duplicating the literal
  list (single source of truth — ADR-018/ADR-021).
  """
  @spec scheme_denylist() :: [String.t()]
  def scheme_denylist, do: SsoRedirect.scheme_denylist()

  @doc false
  # Boolean view of `Nebu.Matrix.SsoRedirect.classify/1` (the ONE classification, story
  # legacy-sso-redirect-confirmation D1): true unless the URL is rejected.
  def redirect_url_allowed?(raw), do: not match?({:reject, _}, SsoRedirect.classify(raw))

  # ── nonce (replay protection, constant-time) ────────────────────────────────

  defp check_nonce(_claims, stored) when not is_binary(stored) or stored == "",
    do: {:error, :missing_nonce}

  defp check_nonce(claims, stored) do
    case claims["nonce"] do
      n when is_binary(n) and n != "" ->
        if Plug.Crypto.secure_compare(n, stored), do: :ok, else: {:error, :nonce_mismatch}

      _ ->
        {:error, :missing_token_nonce}
    end
  end

  # ── append loginToken to the client redirectUrl (Go fragment-aware logic) ────

  @doc false
  # Story legacy-sso-redirect-confirmation D20 (oracle m3, spec "should be removed before adding the new one"): every
  # `loginToken` parameter of the base (the part before the first `#`) and of the FRAGMENT's own `?` query part
  # (Element Web's hash routing) is dropped first. Only a parameter whose name is exactly `loginToken` (after
  # percent-decoding the name) is removed; every other parameter, its order and its encoding stay byte-identical and
  # a URL without a `loginToken` parameter gives the pre-story output.
  def append_login_token(redirect_to, token) do
    case String.split(redirect_to, "#", parts: 2) do
      [base, fragment] ->
        base = strip_login_token(base)
        sep = if String.contains?(base, "?"), do: "&", else: "?"
        base <> sep <> "loginToken=" <> token <> "#" <> strip_login_token(fragment)

      [base] ->
        base = strip_login_token(base)
        sep = if String.contains?(base, "?"), do: "&", else: "?"
        base <> sep <> "loginToken=" <> token
    end
  end

  # `prefix?query` -> the same without `loginToken` parameters; the `?` is dropped when nothing is left.
  defp strip_login_token(part) do
    case String.split(part, "?", parts: 2) do
      [prefix, query] ->
        params = String.split(query, "&")
        kept = Enum.reject(params, &login_token_param?/1)

        cond do
          length(kept) == length(params) -> part
          kept == [] -> prefix
          true -> prefix <> "?" <> Enum.join(kept, "&")
        end

      [_no_query] ->
        part
    end
  end

  defp login_token_param?(param) do
    [name | _] = String.split(param, "=", parts: 2)
    percent_decode(name) == "loginToken"
  end

  defp percent_decode(name) do
    URI.decode(name)
  rescue
    ArgumentError -> name
  end

  # ── OIDC config (server_config only — ADR-022) ──────────────────────────────

  @doc false
  # matrix-refresh-revalidates-with-idp: exposes the Matrix-side OIDC config
  # resolution (issuer + the single client's id/secret, ADR-022) so
  # `Nebu.Matrix.HttpPublic.do_refresh_with/2` can resolve the SAME config this
  # module's own login/SSO flow uses when calling the shared
  # `Nebu.Web.OidcTokenExchange.refresh/2`. Honours the `:sso_bootstrap_reader`
  # test seam (unchanged).
  def oidc_config_for_refresh, do: oidc_config()

  defp oidc_config do
    # oidc-bootstrap-only-config (ADR-022): the issuer is resolved SOLELY from
    # server_config via the OidcConfig DB-backed cache. No env-var config path.
    issuer = Nebu.Web.OidcConfig.get().issuer

    {client_id, client_secret} = resolve_client_credentials()

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :issuer_not_configured}
      not is_binary(client_id) or client_id == "" -> {:error, :client_id_not_configured}
      true -> {:ok, %{issuer: issuer, client_id: client_id, client_secret: client_secret}}
    end
  end

  # oidc-bootstrap-only-config (ADR-022): a SINGLE OIDC client serves both Matrix
  # Bearer validation and admin operator login. Its id/secret come solely from
  # server_config (set by the bootstrap wizard); the secret is stored AES-256-GCM
  # encrypted at rest and decrypted here. There is no NEBU_OIDC_CLIENT_ID env path
  # and no separate admin client. client_id and secret are always read from the SAME
  # source so the pair can never mismatch. Fails closed (empty client) when unset.
  defp resolve_client_credentials do
    client_id = config_value("oidc_client_id")

    if is_binary(client_id) and client_id != "" do
      encrypted = config_value("oidc_client_secret") || ""
      {client_id, Nebu.Admin.BootstrapLive.decrypt_secret(encrypted)}
    else
      {nil, ""}
    end
  end

  @sql_config "SELECT value FROM server_config WHERE key = $1 LIMIT 1"

  # Test seam: :sso_bootstrap_reader is a 1-arity fun `fn(key) -> value | nil`.
  # When set, it replaces the live Repo query for server_config lookups — allows
  # tests to inject Bootstrap DB values (encrypted oidc_client_secret, oidc_client_id)
  # without a live PostgreSQL connection. Mirrors the :admin_bootstrap_store seam.
  defp config_value(key) do
    case Application.get_env(:nebu_http, :sso_bootstrap_reader) do
      fun when is_function(fun, 1) ->
        fun.(key)

      _ ->
        if running?(Nebu.Repo) do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_config, [key]) do
            {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
            _ -> nil
          end
        else
          nil
        end
    end
  end

  # ── scope list (openid [+extra_scopes] [+offline_access]) ───────────────────
  #
  # Story centralize-scope-resolution: scope resolution (validation, extra-scopes
  # read, refresh-mode read) is now centralized in Nebu.Web.OidcScopes — the SINGLE
  # source of OIDC scope resolution for both Matrix and Admin. This is a thin
  # delegate (AC4); SsoLogin no longer runs its own server_config SQL reads or
  # scope-validation regex. The pre-existing :matrix_oidc_extra_scopes_reader /
  # :matrix_oidc_refresh_mode_reader test seams are honoured by OidcScopes itself,
  # unchanged in name/shape, so existing tests keep passing.
  defp scope_list, do: Nebu.Web.OidcScopes.resolve_scope(:matrix)

  # ── token exchange (PKCE + Basic auth) — mirrors Nebu.Admin.Auth.exchange_code ─

  # Test seam: :matrix_sso_token_override accepts two forms:
  #
  #   - 0-arity `fn()` — legacy form. Returns {:ok, id_token[, oidc_refresh_token]}
  #     or {:error, _}, short-circuiting the HTTP+discovery leg. Existing tests use
  #     this form. Mirrors :admin_oidc_token_override.
  #
  #   - 1-arity `fn(cfg)` — credential-spy form (bugfix/oidc-login-keycloak). Receives
  #     the resolved OIDC config map (contains :client_id, :client_secret) so tests can
  #     assert on what credentials were actually resolved from the Bootstrap DB path.
  #     Returns the same shape as the 0-arity form.
  #
  # Every surrounding check — state, nonce, verify — still runs in both forms.
  # Normalised to a 3-tuple by normalize_exchange/1.
  defp exchange(conn, code, verifier, cfg) do
    result =
      case Application.get_env(:nebu_http, :matrix_sso_token_override) do
        fun when is_function(fun, 0) ->
          fun.()

        fun when is_function(fun, 1) ->
          fun.(cfg)

        _ ->
          with {:ok, token_endpoint} <- discover(cfg.issuer, "token_endpoint") do
            exchange_code(token_endpoint, code, verifier, cfg, callback_url(conn))
          end
      end

    normalize_exchange(result)
  end

  # Accept both the new 3-tuple and the legacy 2-tuple (AC7 / no-RT path).
  defp normalize_exchange({:ok, id_token, oidc_refresh_token}),
    do: {:ok, id_token, oidc_refresh_token}

  defp normalize_exchange({:ok, id_token}) when is_binary(id_token), do: {:ok, id_token, nil}
  defp normalize_exchange({:error, _} = err), do: err

  defp exchange_code(token_endpoint, code, verifier, cfg, redirect_uri)
       when is_binary(verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => verifier,
        "client_id" => cfg.client_id
      })

    basic = Base.encode64("#{cfg.client_id}:#{cfg.client_secret}")

    headers = [
      {~c"content-type", ~c"application/x-www-form-urlencoded"},
      {~c"accept", ~c"application/json"},
      {~c"authorization", String.to_charlist("Basic " <> basic)}
    ]

    request =
      {String.to_charlist(token_endpoint), headers, ~c"application/x-www-form-urlencoded", body}

    http_opts = [timeout: 5_000, connect_timeout: 5_000] ++ tls_opts_for(token_endpoint)

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, resp_body}} when status in 200..299 ->
        extract_id_token(resp_body)

      {:ok, {{_http, status, _reason}, _headers, _resp_body}} ->
        {:error, {:token_endpoint_status, status}}

      {:error, reason} ->
        {:error, {:token_endpoint_unreachable, reason}}
    end
  end

  defp exchange_code(_endpoint, _code, _verifier, _cfg, _redirect_uri),
    do: {:error, :missing_verifier}

  # oidc-session-refresh: also surface the OIDC `refresh_token` from the
  # token-endpoint response (present when `offline_access` is granted —
  # appended by scope_list/0 when mode is "offline"). The RT is returned as the
  # 3rd element so the login path can mint a long-lived opaque Nebu session;
  # absent → nil → JWT fallback (AC7).
  defp extract_id_token(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"id_token" => id_token} = body} when is_binary(id_token) and id_token != "" ->
        oidc_rt =
          case body["refresh_token"] do
            rt when is_binary(rt) and rt != "" -> rt
            _ -> nil
          end

        {:ok, id_token, oidc_rt}

      {:ok, _} ->
        {:error, :no_id_token}

      {:error, _} ->
        {:error, :malformed_token_response}
    end
  end

  # ── callback redirect_uri (registered with the IdP) ─────────────────────────
  #
  # Built from the request scheme+host so the dev (http://localhost:8008) and any
  # https origin both register the same fixed path. Honours X-Forwarded-Proto.
  defp callback_url(conn) do
    scheme = Nebu.Web.RequestScheme.scheme(conn)

    host =
      case get_req_header(conn, "host") do
        [h | _] -> h
        _ -> "#{conn.host}:#{conn.port}"
      end

    scheme <> "://" <> host <> "/_matrix/client/v3/login/sso/redirect/oidc"
  end

  # ── discovery (shared TLS-verifying OidcMetadata fetcher + override seam) ────

  defp discover(issuer, field) do
    with {:ok, doc} <- discovery_doc(issuer), do: doc_url(doc, field)
  end

  defp discovery_doc(issuer) do
    with {:ok, body} <- Nebu.Matrix.OidcMetadata.fetch(issuer),
         {:ok, %{} = doc} <- Jason.decode(body) do
      {:ok, doc}
    else
      {:ok, _not_an_object} -> {:error, {:discovery_failed, :not_an_object}}
      {:error, reason} -> {:error, {:discovery_failed, reason}}
    end
  end

  defp doc_url(doc, field) do
    case doc[field] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, {:discovery_missing, field}}
    end
  end

  defp tls_opts_for(url) do
    if String.starts_with?(url, "https://") do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    else
      []
    end
  end

  # ── PKCE / CSRF helpers (RFC 7636 — same as Nebu.Admin.Auth) ────────────────

  defp pkce_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp pkce_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp random_token(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  defp running?(name), do: Process.whereis(name) != nil
end
