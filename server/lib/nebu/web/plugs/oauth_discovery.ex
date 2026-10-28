defmodule Nebu.Web.Plugs.OAuthDiscovery do
  @moduledoc """
  Discovery paths that exist in TWO flavours — Nebu's own OAuth 2.0 broker (epic oauth-broker,
  ADR-033) and the legacy MSC2965 IdP passthrough — and must never advertise both at once
  (security review F-2, spec section 14 decision #7: "auth_issuer is switched to the Nebu issuer").

  Forwarded paths (see `Nebu.Web.Router`):

    * `GET /_matrix/client/v1/auth_issuer`
    * `GET /_matrix/client/unstable/org.matrix.msc2965/auth_issuer`
    * `GET /_matrix/client/unstable/org.matrix.msc2965/auth_metadata`

  Behaviour per request (decided by `Nebu.OAuth.config/0`, read per request through the per-node config cache, at most `NEBU_OAUTH_CONFIG_CACHE_MS` stale, HY1,
  like every OAuth switch; the config is THREE-state, security review N-4):

    * OAuth ENABLED  => served by `Nebu.OAuth.Http`: `auth_issuer` answers `{"issuer": "<Nebu
      issuer>"}`, the unstable `auth_metadata` answers the same RFC 8414 document as the stable path
      — no IdP field and no second issuer leaks. A misconfigured issuer is `404 M_UNRECOGNIZED`.
    * OAuth DISABLED (positively read) => the legacy IdP passthrough of `Nebu.Matrix.HttpPublic`
      (unchanged, the pre-broker behaviour Element/FluffyChat rely on). This is the DECIDED
      behaviour (spec section 14 decision #7, amended): Nebu's issuer is advertised only while OAuth
      is enabled, and these paths do NOT turn into a 404 while it is disabled. It is not a bypass of
      the approval gate: with OAuth off there is no Nebu authorization server and no registration.
      (The STABLE `v1/auth_metadata` is Nebu's own document and is a 404 while disabled.)
    * config UNKNOWN (`server_config` unreadable, e.g. a DB timeout) => `503` with the Matrix error
      shape `{"errcode":"M_UNKNOWN",...}`, `Cache-Control: no-store`, no `issuer` in the body and NO
      passthrough. A transient read error must never advertise the IdP issuer while OAuth is
      enabled, so the plug's invariant "never both issuers at once" holds in fault mode too; 503
      (not 404) because the state is transient and clients/caches must retry rather than conclude
      "OAuth unsupported".

  Residual risk (recorded in ADR-033): while OAuth is enabled, a client that ignores the Nebu
  discovery paths and talks to the IdP directly (legacy coexistence, e.g. through the IdP's own
  `.well-known` or the `m.login.sso` flow) is not subject to DCR admin approval until the legacy
  login path is shut down.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: %{oauth: Keyword.fetch!(opts, :oauth_action), legacy: Keyword.fetch!(opts, :legacy_action)}

  @impl Plug
  def call(conn, %{oauth: oauth_action, legacy: legacy_action}) do
    case Nebu.OAuth.config().state do
      :enabled -> Nebu.OAuth.Http.call(conn, Nebu.OAuth.Http.init(action: oauth_action))
      :disabled -> Nebu.Matrix.HttpPublic.call(conn, Nebu.Matrix.HttpPublic.init(action: legacy_action))
      :unknown -> unavailable(conn)
    end
  end

  # 503 M_UNKNOWN: config unreadable, fail closed WITHOUT the legacy fallback (N-4).
  defp unavailable(conn) do
    conn
    |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      503,
      Jason.encode!(%{
        "errcode" => "M_UNKNOWN",
        "error" => "OAuth configuration is temporarily unavailable."
      })
    )
  end
end
