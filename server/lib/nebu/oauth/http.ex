defmodule Nebu.OAuth.Http do
  @moduledoc """
  UNAUTHENTICATED HTTP endpoints of Nebu's OAuth 2.0 authorization-server surface (epic
  oauth-broker, ADR-033), forwarded from `Nebu.Web.Router` with an `action:` tag:

    * `GET  /_matrix/client/v1/auth_metadata` (`:auth_metadata`) — RFC 8414 metadata document
    * `GET  /_matrix/client/unstable/org.matrix.msc2965/auth_metadata` — the same document (alias,
      via `Nebu.Web.Plugs.OAuthDiscovery`, security review F-2)
    * `GET  /_matrix/client/{v1,unstable/org.matrix.msc2965}/auth_issuer` (`:auth_issuer`) —
      `{"issuer": "<Nebu issuer>"}` (same issuer as the metadata; F-2)
    * `POST /oauth2/register` (`:register`) — Dynamic Client Registration, RFC 7591
    * `GET  /oauth2/authorize` (`:authorize`) — the authorization endpoint (story
      oauth-authorize-idp-delegation-code): `Nebu.OAuth.Authorize`. Its responses are HTML pages
      and 302 redirects (browser navigation, NO CORS headers), see that module.
    * `POST /oauth2/token` (`:token`) — the token endpoint (story oauth-token-endpoint):
      `Nebu.OAuth.Token` (authorization_code + refresh_token, RFC 6749 5.2 errors, every 5xx
      `{}` + `Retry-After`). Non-POST => 405 `Allow: POST, OPTIONS`.
    * `GET  /oauth2/jwks` (`:jwks`) — Nebu's id_token signing keys (ES256, public members only,
      generated lazily, `Nebu.OAuth.SigningKeyStore`). Non-GET => 405 `Allow: GET, OPTIONS`.
    * `GET  /.well-known/openid-configuration` (`:openid_configuration`) — the SAME document as
      `auth_metadata` (matrix-js-sdk's `OidcTokenRefresher` fetches it under the issuer, T31); never
      the IdP document.
    * `GET|POST /oauth2/consent` (`:consent`) — the consent page (story oauth-authorize-freshness):
      `Nebu.OAuth.Consent`. HTML pages and `303` redirects, NO CORS, live exactly while `auth_metadata`
      answers 200.
    * `GET /account` (+ `/account/reauth`, the POST sub-paths; `:account`) — the account-management page
      (story oauth-account-management): `Nebu.OAuth.Account`. HTML pages and redirects, NO CORS, live
      exactly while `auth_metadata` answers 200.
    * `POST /oauth2/revoke` (`:revoke`) — RFC 7009 token revocation (story
      oauth-token-revocation-logout): `Nebu.OAuth.Revoke`; ends the whole OAuth session of the device
      for either token. NO kill switch: live while OAuth is disabled or the issuer is invalid, only an
      unreadable config answers `503 {}` (R13). Non-POST (also HEAD) => 405 `Allow: POST, OPTIONS`.

  ## Kill switch of the story-3 endpoints (T22)

  `/oauth2/token`, `/oauth2/jwks` and `/.well-known/openid-configuration` read the THREE-state
  config: disabled or an invalid issuer => `404 M_UNRECOGNIZED` (no DB access beyond the config
  read, no rate-limit token); `:unknown` (server_config unreadable) => `503 {}` + `Retry-After: 5`
  (a transient DB error is a transient answer, never a 4xx that logs a Matrix client out).

  No Bearer authentication: all are public discovery/registration/authorization endpoints. They are only live when OAuth
  is enabled (`Nebu.OAuth.Config`); otherwise they answer `404 {"errcode":"M_UNRECOGNIZED",...}`
  (Matrix error shape — the Matrix Dart SDK only distinguishes this case; never 503, never an IdP
  passthrough). The legacy IdP passthrough of the unstable/`auth_issuer` paths while OAuth is
  DISABLED lives in `Nebu.Web.Plugs.OAuthDiscovery`, not here.

  ## Rate limits (`POST /oauth2/register`)

  Three bucket families in the node-local ETS table of `Nebu.Web.Plugs.RateLimit` (same posture as
  the login/refresh limits): in a cluster of N nodes the effective limits are up to N times higher,
  and the "IP" is `Nebu.Web.ClientIP.get/1` (story oauth-trusted-proxy-client-ip): the direct peer
  unless that peer is listed in `NEBU_TRUSTED_PROXY_CIDRS`, then the rightmost untrusted element of
  the forwarding header. Without that configuration it still is the direct peer, so behind a reverse
  proxy all clients share one per-IP bucket (see ADR-033 "Trusted-proxy client IP" and
  docs/architecture/07-deployment.md).

    * INVALID (own buckets, security review F-1 remainder): 600/h per IP, 5000/h globally. Charged
      by a request that is JUNK — unparsable/oversize/invalid body, or OAuth disabled — and only
      then; when exhausted the junk request is answered `429` instead of its 4xx. Junk therefore
      never spends the budget of a dedup hit, which every login depends on.
    * LOOSE (every VALID request): 600/h per IP, and NO global bucket. This is the only limit a
      DEDUP HIT pays (one indexed SELECT) — a known `client_id` re-registers at every login (spec),
      and must not compete with the strict budget of new registrations.
    * STRICT (only a request that would INSERT a new row, i.e. valid metadata unknown by hash):
      50/h per IP, 500/h globally, charged after validation and the hash lookup.

  This is abuse control only — correctness (dedup, approval) never depends on it; it is atomic in
  PostgreSQL.

  ## Error shapes

  Matrix shape (`errcode`/`error`) ONLY for the disabled 404. Everything DCR-related uses the
  RFC 7591 3.2.2 / RFC 6749 shape `{"error": code, "error_description": text}` — including the
  429 (`{"error":"too_many_requests"}` + `Retry-After`).

  ## `POST /oauth2/register` order

    0. (router, before this module) `Nebu.Web.Plugs.JsonBody` parses the body with a 128 KiB cap
       (not the 1 MB default) — the limiters below can only run once the body was parsed, so the
       cap bounds what an unthrottled client can make a node parse. Oversize is flagged and
       answered in step 3.
    1. OAuth enabled? else the request is junk: INVALID bucket, then `404 M_UNRECOGNIZED`
       (or `429` when that bucket is exhausted)
    2. body: oversize => `413 invalid_request`; malformed / empty / non-object / deeper than
       8 levels => `400 invalid_request`; `Nebu.OAuth.Registration.validate/1` =>
       `400 invalid_redirect_uri | invalid_client_metadata`. Each of these is junk: it is charged
       to the INVALID bucket (600/h per IP, 5000/h global) and answered `429` once exhausted
    3. a VALID request pays the LOOSE bucket (600/h per IP, no global) => `429`
    4. lookup by metadata hash: a DEDUP HIT is answered `201` now (only the loose limit was paid)
    5. a NEW registration pays the STRICT rate limit (50/h per IP, 500/h global) => `429`
    6. `Nebu.OAuth.ClientStore.register/1` (atomic insert; pending caps: global, per (registrable
       domain of the `client_uri` host, client source) and per source over all domains, story
       oauth-dcr-abuse-hardening; the source is `Nebu.OAuth.SourceKey.for_conn/1`) => `201` with the REGISTERED metadata + `client_id` (`Cache-Control: no-store`). Every
       new registration is `pending` (no auto-approval). Cap reached => `503
       temporarily_unavailable` + `Retry-After`; metadata the database refuses as data => `400
       invalid_client_metadata`; storage unavailable => `503 temporarily_unavailable`.

  ## CORS

  `Nebu.Web.Router` runs `CORSPlug` first (answers every `OPTIONS` preflight itself: no endpoint
  logic, no rate-limit token). Every response produced here additionally carries
  `Access-Control-Allow-Origin: *` explicitly, so browser clients (Element Web, FluffyChat) can
  also read the 404/400/429 bodies.

  ## Logging

  INFO logs carry only `client_id` and `metadata_hash`, never the client metadata. The DEBUG
  payload line of `RequestLogger` runs through `PayloadRedactor` (client secrets etc. redacted).
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  alias Nebu.OAuth.{Account, Authorize, ClientStore, Config, Consent, FormPost, Metadata, Registration, Revoke, SigningKeyStore, SourceKey, Token}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  # POST /oauth2/register limits. STRICT (new rows only): 50/hour per IP, 500/hour globally. LOOSE
  # (every valid request, so the only budget of a dedup hit): 600/hour per IP, NO global bucket.
  # INVALID (junk and disabled-path requests, own buckets): 600/hour per IP, 5000/hour globally.
  @per_ip_per_hour 50
  @global_per_hour 500
  @loose_per_ip_per_hour 600
  @invalid_per_ip_per_hour 600
  @invalid_global_per_hour 5000

  # 503 for NEW metadata while the pending cap is reached: the cap is relieved by admin decisions
  # and the hourly TTL purge, so an hour is an honest "try again later".
  @capacity_retry_after_s 3600

  @metadata_cache_control "public, max-age=259200"
  @jwks_cache_control "public, max-age=600"

  # GET /oauth2/jwks: 600/h per IP ({"oauth_jwks", ip}).
  @jwks_rate_per_min 10
  @jwks_burst 600
  @unknown_retry_after_s 5

  # GET /.well-known/openid-configuration (live branch): 600/min per source, burst 600 (HY3).
  @openid_rate_per_min 600
  @openid_burst 600

  # A registration is a flat object whose deepest legitimate value is an array of strings (depth
  # 2). Anything nested deeper than this is refused before validation (Jason has no depth limit).
  @max_depth 8

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :action)

  @impl Plug
  # The authorization endpoint is browser navigation (no CORS at all, AC13): every method,
  # including a non-preflight OPTIONS, is answered by `authorize/1` (405 for non-GET).
  def call(%Plug.Conn{path_info: []} = conn, :authorize), do: authorize(conn)

  # The account-management page (story oauth-account-management, A2-A4) is browser navigation too: every
  # method, a non-preflight OPTIONS included (the router skips CORSPlug for `/account*`), and every sub-path
  # is answered by `Nebu.OAuth.Account` (its own 404 / 405 pages, live check first).
  def call(conn, :account), do: Account.handle(conn)

  # The consent page (story oauth-authorize-freshness, FR7) is browser navigation as well: every method (a
  # non-preflight OPTIONS included; the router skips CORSPlug for `/oauth2/consent*`) and every sub-path is
  # answered by `Nebu.OAuth.Consent` (its own 404 / 405 pages, live check first).
  def call(conn, :consent), do: Consent.handle(conn)

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _action) do
    # Normally answered by CORSPlug before the router dispatches; kept as a no-logic fallback.
    conn
    |> put_cors()
    |> send_resp(204, "")
  end

  def call(%Plug.Conn{path_info: [_ | _]} = conn, action) when action in [:token, :jwks, :openid_configuration, :revoke],
    do: unrecognized_no_error(conn)

  def call(%Plug.Conn{path_info: [_ | _]} = conn, _action), do: unrecognized(conn)

  def call(conn, :auth_metadata), do: auth_metadata(conn)
  def call(conn, :auth_issuer), do: auth_issuer(conn)
  def call(conn, :register), do: register(conn)
  def call(conn, :token), do: token(conn)
  def call(conn, :revoke), do: revoke(conn)
  def call(conn, :jwks), do: jwks(conn)
  def call(conn, :openid_configuration), do: openid_configuration(conn)

  # ── story oauth-token-endpoint: kill switch (T22) ────────────────────────────

  # `{:live, issuer}` | `:unknown` | `:off` (disabled or invalid issuer, fail closed): the shared predicate
  # of `Nebu.OAuth.Config.live_state/0` (also behind `Nebu.OAuth.oauth_aware?/0`, story 5 C1).
  defp live_state, do: Config.live_state()

  # ── POST /oauth2/token ──────────────────────────────────────────────────────

  defp token(conn) do
    case live_state() do
      {:live, issuer} ->
        if conn.method == "POST", do: Token.handle_token(conn, issuer), else: Token.method_not_allowed(conn)

      :unknown ->
        Token.unavailable(conn, @unknown_retry_after_s)

      :off ->
        unrecognized_no_error(conn)
    end
  end

  # ── POST /oauth2/revoke (story oauth-token-revocation-logout, R13) ──────────

  # NO kill switch (R13): revoke can only DELETE sessions and stays live while OAuth is disabled or
  # the issuer is invalid (otherwise server sessions would survive a logout made while the operator has
  # OAuth switched off). Only an unreadable config (`:unknown`) answers 503 `{}` + `Retry-After`,
  # before any parse / rate-limit token.
  defp revoke(conn) do
    case Config.get().state do
      :unknown -> FormPost.server_error(conn, 503, @unknown_retry_after_s)
      _live -> if conn.method == "POST", do: Revoke.handle_revoke(conn), else: Revoke.method_not_allowed(conn)
    end
  end

  # ── GET /oauth2/jwks (AC13) ─────────────────────────────────────────────────

  defp jwks(conn) do
    case live_state() do
      {:live, _issuer} -> if conn.method == "GET", do: serve_jwks(conn), else: get_only(conn)
      :unknown -> empty_5xx(conn, @unknown_retry_after_s)
      :off -> unrecognized_no_error(conn)
    end
  end

  defp serve_jwks(conn) do
    with :ok <- RateLimit.take({"oauth_jwks", ClientIP.bucket(conn)}, @jwks_rate_per_min, @jwks_burst),
         {:ok, _key} <- SigningKeyStore.ensure_active_key(),
         {:ok, keys} <- SigningKeyStore.published_keys() do
      conn
      |> put_cors()
      |> put_resp_header("cache-control", @jwks_cache_control)
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"keys" => keys}))
    else
      {:deny, retry_after_s} ->
        conn
        |> put_cors()
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> oauth_error(429, "too_many_requests", nil)

      {:error, reason} ->
        Logger.warning("OAuth JWKS: signing keys unavailable (#{inspect(reason)})")
        empty_5xx(conn, @unknown_retry_after_s)
    end
  end

  # ── GET /.well-known/openid-configuration (AC21 / T31) ──────────────────────

  defp openid_configuration(conn) do
    case live_state() do
      {:live, issuer} ->
        if conn.method == "GET" do
          # story oauth-hardening-hygiene (HY3): own per-source bucket on the LIVE branch only (the disabled
          # branch and non-GET methods take no token); generous, matrix-js-sdk fetches it before every refresh.
          case RateLimit.take({"oauth_openid_configuration", ClientIP.bucket(conn)}, @openid_rate_per_min, @openid_burst) do
            :ok ->
              {:ok, document} = Metadata.build(issuer)

              conn
              |> put_cors()
              |> put_resp_header("cache-control", @metadata_cache_control)
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(document))

            {:deny, retry_after_s} ->
              conn
              |> put_cors()
              |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
              |> oauth_error(429, "too_many_requests", nil)
          end
        else
          get_only(conn)
        end

      :unknown ->
        empty_5xx(conn, @unknown_retry_after_s)

      :off ->
        unrecognized_no_error(conn)
    end
  end

  defp get_only(conn) do
    conn
    |> put_cors()
    |> put_resp_header("allow", "GET, OPTIONS")
    |> oauth_error(405, "invalid_request", "Method not allowed.")
  end

  # T20: a 5xx of the story-3 endpoints is `{}` + Retry-After (no `error` member).
  defp empty_5xx(conn, retry_after_s) do
    conn
    |> put_cors()
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(503, "{}")
  end

  # ── GET /oauth2/authorize (story oauth-authorize-idp-delegation-code) ────────

  # Disabled / unreadable config / invalid issuer => 404 M_UNRECOGNIZED BEFORE anything else: no
  # rate-limit token, no DB access (AC1). Everything else is `Nebu.OAuth.Authorize`.
  defp authorize(conn) do
    case Authorize.live_issuer() do
      {:ok, issuer} -> Authorize.handle_authorize(conn, issuer)
      :error -> unrecognized(conn)
    end
  end

  # ── GET /_matrix/client/v1/auth_metadata ────────────────────────────────────

  defp auth_metadata(%Plug.Conn{method: "GET"} = conn) do
    # The SAME predicate as `Nebu.OAuth.oauth_aware?/0` (story 5 C1): the OAuth-aware flags and the SSO
    # `action` are present IFF this answers 200, by construction.
    with {:live, issuer} <- Config.live_state(),
         {:ok, document} <- Metadata.build(issuer) do
      conn
      |> put_cors()
      |> put_resp_header("cache-control", @metadata_cache_control)
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(document))
    else
      # disabled, or an issuer that is not a valid https URL (fail closed, never echoed)
      _ -> unrecognized(conn)
    end
  end

  defp auth_metadata(conn), do: discovery_wrong_method(conn)

  # GET .../auth_issuer (v1 + unstable MSC2965): `{"issuer": "<Nebu issuer>"}`, the SAME issuer the
  # metadata document names (security review F-2: once OAuth is enabled discovery must not advertise
  # a second issuer). Disabled or misconfigured issuer => 404 M_UNRECOGNIZED (fail closed).
  defp auth_issuer(%Plug.Conn{method: "GET"} = conn) do
    # story oauth-versions-switch V2: the shared predicate (`Config.live_state/0`), no second copy
    with {:live, issuer} <- Config.live_state() do
      conn
      |> put_cors()
      |> put_resp_header("cache-control", @metadata_cache_control)
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"issuer" => issuer}))
    else
      _ -> unrecognized(conn)
    end
  end

  defp auth_issuer(conn), do: discovery_wrong_method(conn)

  # Non-GET on a discovery path (story oauth-room-summary-unrecognized, RU14): while OAuth is live the endpoint
  # exists, so the wrong method is `405 M_UNRECOGNIZED` + `Allow: GET, OPTIONS` (spec: M_UNRECOGNIZED / 405);
  # disabled, unreadable or an invalid issuer keeps the fail-closed `404 M_UNRECOGNIZED` of `unrecognized/1`.
  defp discovery_wrong_method(conn) do
    case Config.live_state() do
      {:live, _issuer} ->
        conn
        |> put_cors()
        |> put_resp_header("cache-control", "no-store")
        |> Nebu.Web.Unrecognized.method_not_allowed(["GET"])

      _ ->
        unrecognized(conn)
    end
  end

  # ── POST /oauth2/register ───────────────────────────────────────────────────

  defp register(%Plug.Conn{method: "POST"} = conn) do
    with :ok <- ensure_enabled(),
         {:ok, body} <- request_body(conn),
         {:ok, registration} <- Registration.validate(body),
         :ok <- loose_rate_limit(conn),
         {:ok, client} <- register_or_dedup(conn, registration) do
      Logger.info(
        "OAuth DCR: registration accepted client_id=#{client.client_id} " <>
          "metadata_hash=#{registration.hash} status=#{client.status} new=#{client.created?}"
      )

      conn
      |> put_cors()
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(Map.put(client.metadata, "client_id", client.client_id)))
    else
      {:too_many_requests, retry_after_s} ->
        conn
        |> put_cors()
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> oauth_error(429, "too_many_requests", nil)

      :disabled ->
        # junk from the server's point of view: own bucket, 429 once exhausted
        with_invalid_budget(conn, fn -> unrecognized(conn) end)

      {:error, :too_large} ->
        with_invalid_budget(conn, fn ->
          oauth_error(put_cors(conn), 413, "invalid_request", "The request body is too large.")
        end)

      {:error, code, description} ->
        with_invalid_budget(conn, fn -> oauth_error(put_cors(conn), 400, code, description) end)

      {:error, :storage} ->
        oauth_error(put_cors(conn), 503, "temporarily_unavailable", "Registration is temporarily unavailable.")

      {:error, :capacity} ->
        conn
        |> put_cors()
        |> put_resp_header("retry-after", Integer.to_string(@capacity_retry_after_s))
        |> oauth_error(
          503,
          "temporarily_unavailable",
          "Too many client registrations are awaiting approval. Try again later."
        )
    end
  end

  defp register(conn) do
    case ensure_enabled() do
      :disabled ->
        unrecognized(conn)

      :ok ->
        conn
        |> put_cors()
        |> put_resp_header("allow", "POST, OPTIONS")
        |> oauth_error(405, "invalid_request", "Method not allowed.")
    end
  end

  # Every VALID request pays the per-IP loose bucket; it is the ONLY budget of a dedup hit (no
  # global bucket: a dedup hit is one indexed SELECT).
  defp loose_rate_limit(conn) do
    case RateLimit.take({"oauth_register_loose", ClientIP.bucket(conn)}, @loose_per_ip_per_hour / 60, @loose_per_ip_per_hour) do
      :ok -> :ok
      {:deny, retry_after_s} -> {:too_many_requests, retry_after_s}
    end
  end

  # A JUNK request (disabled path, unparsable/oversize/invalid body) is charged to its OWN
  # buckets, never to the loose/strict ones. Exhausted => 429 instead of the 4xx.
  defp with_invalid_budget(conn, respond) do
    ip = ClientIP.bucket(conn)

    with :ok <- RateLimit.take({"oauth_register_invalid", ip}, @invalid_per_ip_per_hour / 60, @invalid_per_ip_per_hour),
         :ok <-
           RateLimit.take(
             {"oauth_register_invalid", :global},
             @invalid_global_per_hour / 60,
             @invalid_global_per_hour
           ) do
      respond.()
    else
      {:deny, retry_after_s} ->
        conn
        |> put_cors()
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> oauth_error(429, "too_many_requests", nil)
    end
  end

  # Only a request that would INSERT a new row pays the strict buckets.
  defp strict_rate_limit(conn) do
    ip = ClientIP.bucket(conn)

    with :ok <- RateLimit.take({"oauth_register", ip}, @per_ip_per_hour / 60, @per_ip_per_hour),
         :ok <- RateLimit.take({"oauth_register", :global}, @global_per_hour / 60, @global_per_hour) do
      :ok
    else
      {:deny, retry_after_s} -> {:too_many_requests, retry_after_s}
    end
  end

  # Known metadata (a dedup hit) is answered without touching the strict budget; unknown metadata
  # is charged first, then inserted (the INSERT itself still dedups atomically if a concurrent
  # request won the race, and enforces the pending caps).
  defp register_or_dedup(conn, registration) do
    case ClientStore.find_by_hash(registration.hash) do
      {:ok, %{} = known} ->
        {:ok, Map.put(known, :created?, false)}

      {:ok, nil} ->
        with :ok <- strict_rate_limit(conn), do: store(conn, registration)

      {:error, reason} ->
        Logger.error("OAuth DCR: could not look up registration: #{log_reason(reason)}")
        {:error, :storage}
    end
  end

  defp ensure_enabled, do: if(Config.enabled?(), do: :ok, else: :disabled)

  # Nebu.Web.Plugs.JsonBody (router level) already parsed the body. Malformed JSON, an empty body,
  # a non-object (array/scalar, which Plug wraps as %{"_json" => _}) and a non-JSON content type
  # are all `invalid_request`.
  defp request_body(%Plug.Conn{assigns: %{body_too_large: true}}), do: {:error, :too_large}

  defp request_body(%Plug.Conn{assigns: %{json_parse_error: true}}),
    do: {:error, "invalid_request", "The request body is not valid JSON."}

  defp request_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}),
    do: {:error, "invalid_request", "The request body must be a JSON object (Content-Type: application/json)."}

  defp request_body(%Plug.Conn{body_params: %{"_json" => _}}),
    do: {:error, "invalid_request", "The request body must be a JSON object."}

  defp request_body(%Plug.Conn{body_params: body}) when is_map(body) and map_size(body) > 0 do
    if too_deep?(body, @max_depth),
      do: {:error, "invalid_request", "The request body is nested too deeply."},
      else: {:ok, body}
  end

  defp request_body(_conn),
    do: {:error, "invalid_request", "The request body must be a non-empty JSON object."}

  # True when `term` nests maps/lists deeper than `levels` (stops descending at the limit, so a
  # hostile body costs at most `levels` frames).
  defp too_deep?(_term, levels) when levels < 0, do: true
  defp too_deep?(%{} = map, levels), do: Enum.any?(map, fn {_k, v} -> too_deep?(v, levels - 1) end)
  defp too_deep?(list, levels) when is_list(list), do: Enum.any?(list, &too_deep?(&1, levels - 1))
  defp too_deep?(_scalar, _levels), do: false

  defp store(conn, registration) do
    attrs =
      Map.merge(registration, %{
        ip: ClientIP.get(conn),
        source_key: SourceKey.for_conn(conn),
        user_agent: conn |> get_req_header("user-agent") |> List.first()
      })

    case ClientStore.register(attrs) do
      {:ok, client} ->
        {:ok, client}

      {:error, :capacity} ->
        # Not logged above INFO and never with client data: a flood would otherwise flood the log.
        Logger.info("OAuth DCR: registration refused, pending cap reached (global or per source)")
        {:error, :capacity}

      {:error, :invalid_metadata} ->
        # PostgreSQL refused the metadata as data (e.g. a character jsonb cannot store): a client
        # error, not an outage. Nothing client-supplied is logged.
        Logger.info("OAuth DCR: registration refused, metadata not storable")
        {:error, "invalid_client_metadata", "The client metadata contains values that cannot be stored."}

      {:error, reason} ->
        Logger.error("OAuth DCR: could not persist registration: #{log_reason(reason)}")
        {:error, :storage}
    end
  end

  # Never `inspect/1` a store error: a failed constraint carries "Failing row contains (...)" with
  # the registrant's IP, user agent and metadata (security review I-8). Only the SQLSTATE / the
  # exception type is logged.
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason(other) when is_atom(other), do: inspect(other)
  defp log_reason(_other), do: "unexpected error"

  # ── responses ───────────────────────────────────────────────────────────────

  # 404 {"errcode":"M_UNRECOGNIZED","error":...} — OAuth not supported/enabled (Matrix shape).
  defp unrecognized(conn) do
    conn
    |> put_cors()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{
        "errcode" => "M_UNRECOGNIZED",
        "error" => "OAuth 2.0 is not supported by this server."
      })
    )
  end

  # Kill-switch 404 of the story-3 endpoints (/oauth2/token, /oauth2/jwks,
  # /.well-known/openid-configuration; review cycle 1, MINOR 1): `errcode: M_UNRECOGNIZED` but NO
  # `error` member. oidc-client-ts turns ANY JSON with `error` into an ErrorResponse, which
  # matrix-js-sdk treats as a logout, so an operator flipping the kill switch must not log
  # refreshing clients out (no `error` => a plain Error => a retryable failure, oracle C2).
  defp unrecognized_no_error(conn) do
    conn
    |> put_cors()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"errcode" => "M_UNRECOGNIZED"}))
  end

  # RFC 7591 3.2.2 error response. `description == nil` (429) => body is only {"error": code}.
  defp oauth_error(conn, status, code, description) do
    body =
      if description,
        do: %{"error" => code, "error_description" => description},
        else: %{"error" => code}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp put_cors(conn), do: put_resp_header(conn, "access-control-allow-origin", "*")

end
