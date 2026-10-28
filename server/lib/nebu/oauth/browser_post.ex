defmodule Nebu.OAuth.BrowserPost do
  @moduledoc """
  The request-origin checks shared by every state-changing browser form of the OAuth surface
  (`POST /oauth2/consent`, the `POST /account/*` actions): ONE copy (story oauth-authorize-freshness, FR8,
  moved here from `Nebu.OAuth.Account`). They are DEFENCE IN DEPTH next to the per-flow CSRF token, which
  stays authoritative; each failure is answered by the caller with a `403` page and a value-free WARNING.

    * `Origin` — absent (older browsers / privacy settings), or exactly the issuer origin. A browser that
      strips referrer information sends `Origin: null` for a form POST (the pages use `Referrer-Policy:
      same-origin`, so this is only the fallback for privacy settings / extensions / sandboxes): accepted
      ONLY together with `Sec-Fetch-Site: same-origin`. Several `Origin` headers are refused.
    * `Sec-Fetch-Site` — absent or `same-origin` (`same-site` and `cross-site` are refused).
    * navigation (`navigation: true`, the default) — when the browser sends fetch metadata it must
      describe a user-activated top-level form navigation: `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest:
      document`, `Sec-Fetch-User: ?1`, each absent or exactly that value (a duplicate header is refused).

  ## Strict level (story oauth-client-revocation, SO2)

  The actions that grant authority (admin approve / revoke of an OAuth client, `/account` cross-signing reset
  approval) use the STRICT level: all four headers (`Sec-Fetch-Site: same-origin`, `-Mode: navigate`, `-Dest:
  document`, `-User: ?1`) must be present exactly once with exactly that value. An ABSENT header is refused
  there (Chrome 76+ and Firefox 90+ send all four for a user-activated form submit; Safari 16.4+ sends only the
  first three, see the next section; browsers without fetch metadata at all are locked out of those actions, an
  accepted trade). `check/3` with `strict: true` adds it to the
  Origin rules; `check_fetch_metadata/2` is the same header rule without the Origin comparison, for the admin
  controllers (`:strict` for every action behind `Nebu.Admin.OAuthAdminHelpers.gate/3`: approve, revoke, reject, bulk removal and the
  SSO trust saves; `:lenient` for the consent / account forms). The refusal lists the
  lower-case header NAMES that failed (never a value) for the value-free WARNING of the caller.

  ## Browsers that never send `Sec-Fetch-User` (story safari-fetch-metadata-compat)

  Safari / WebKit sends `Sec-Fetch-Site`, `-Mode` and `-Dest` but NEVER `Sec-Fetch-User`, so the plain strict rule locked every
  Safari user out of the strict actions. With the opt-in `check_fetch_metadata/3` (and `check/3` with `params:`) an ABSENT
  `Sec-Fetch-User` is replaced by a click proof: the form field `_click_proof=1`, filled by `Nebu.Web.ClickProofScript` on a TRUSTED
  click. It counts only when (a) `Sec-Fetch-Site` / `-Mode` / `-Dest` are strictly correct and (b) the single `User-Agent` header
  looks like WebKit (`AppleWebKit/` and none of `Chrome/`, `Chromium/`, `Firefox/`): Chromium and Gecko always send `?1` on a
  user activation, so for them an absent header stays the "no activation" signal and is refused, proof or not; page script cannot
  set the `User-Agent` of a navigation. A WebKit request with correct headers but without the proof is `:unproven`: the callers
  answer a friendly notice, nothing is changed (the script is blocked, the page is stale, a content blocker interferes). A present
  `Sec-Fetch-User` that is not exactly `?1` (also duplicated) is refused in every case. A script in the page that sets the field
  itself is the accepted SO7 residual (on WebKit it no longer even has to wait for a click).

  ## What this does NOT stop

  The navigation check stops `fetch()` / XHR (their mode is `cors` / `same-origin`, their destination
  `empty`), hidden iframes (`Dest: iframe`), cross-origin posts and, at the strict level, a scripted
  `form.submit()` WITHOUT a user activation (no `Sec-Fetch-User`; NOT on WebKit, where the script-set click proof replaces
  that header, ADR-033 SO9). It does NOT stop a SCRIPT running on the
  same origin that waits for ANY user click anywhere on the origin: the click gives the page transient
  activation, so a scripted `form.submit()` then sends `Sec-Fetch-User: ?1` and every strict header passes. Only a
  separate origin for Element Web removes that class (ADR-033, SO7, gate ag); the admin approve / revoke
  additionally bind their fresh-sign-in marker to one confirm page and consume it. The lenient level stops even less: a scripted `form.submit()` is a real top-level navigation.
  """

  import Plug.Conn

  @fetch_headers [
    {"sec-fetch-site", "same-origin"},
    {"sec-fetch-mode", "navigate"},
    {"sec-fetch-dest", "document"},
    {"sec-fetch-user", "?1"}
  ]

  @click_proof_param "_click_proof"

  @doc "The name of the hidden form field of the click proof (see the moduledoc)."
  @spec click_proof_param() :: String.t()
  def click_proof_param, do: @click_proof_param

  @doc """
  `:ok` when the request passes the Origin and fetch-metadata checks for `issuer` (the normalized issuer
  URL), else `:refused`. Option `navigation: false` skips the `Sec-Fetch-Mode` / `-Dest` / `-User` checks
  (used by the account page's sign-out, which is harmless). Option `strict: true` requires all four fetch
  metadata headers (see the moduledoc; it wins over `navigation: false`). Option `params:` (the request parameters) opts
  into the click-proof rules of the moduledoc at the strict level and makes `:unproven` a possible result; without it nothing
  changes.
  """
  @spec check(Plug.Conn.t(), String.t(), keyword()) :: :ok | :refused | :unproven
  def check(%Plug.Conn{} = conn, issuer, opts \\ []) when is_binary(issuer) do
    strict? = Keyword.get(opts, :strict, false) == true

    cond do
      not origin_ok?(conn, issuer) ->
        :refused

      strict? and Keyword.has_key?(opts, :params) ->
        case check_fetch_metadata(conn, :strict, Keyword.get(opts, :params)) do
          :ok -> :ok
          :unproven -> :unproven
          {:refused, _names} -> :refused
        end

      true ->
        headers = if strict? or Keyword.get(opts, :navigation, true), do: @fetch_headers, else: [hd(@fetch_headers)]
        if failed_headers(conn, headers, strict?) == [], do: :ok, else: :refused
    end
  end

  @doc """
  The fetch-metadata rules WITHOUT the Origin comparison, for the admin controllers (the admin has no
  issuer-bound origin). `:strict`: all four headers present, exactly once, exactly the expected value.
  `:lenient`: absent allowed, a present header must carry the expected value (once). `:ok` or `{:refused,
  [header_name]}` (lower-case names, never values).
  """
  @spec check_fetch_metadata(Plug.Conn.t(), :strict | :lenient) :: :ok | {:refused, [String.t()]}
  def check_fetch_metadata(%Plug.Conn{} = conn, level) when level in [:strict, :lenient] do
    case failed_headers(conn, @fetch_headers, level == :strict) do
      [] -> :ok
      names -> {:refused, names}
    end
  end

  @doc """
  The strict fetch-metadata rules WITH the click proof for browsers that never send `Sec-Fetch-User` (see the moduledoc):
  `:ok`, `:unproven` (WebKit, correct headers, no proof: answer a notice, change nothing) or `{:refused, [header_name]}`.
  `params` is the request parameter map (anything else, e.g. an unfetched struct, is "no proof"). At `:lenient` this is
  `check_fetch_metadata/2` (no proof logic).
  """
  @spec check_fetch_metadata(Plug.Conn.t(), :strict | :lenient, term()) :: :ok | :unproven | {:refused, [String.t()]}
  def check_fetch_metadata(%Plug.Conn{} = conn, :lenient, _params), do: check_fetch_metadata(conn, :lenient)

  def check_fetch_metadata(%Plug.Conn{} = conn, :strict, params) do
    case failed_headers(conn, Enum.take(@fetch_headers, 3), true) do
      [] -> user_header(conn, params)
      names -> {:refused, names}
    end
  end

  defp user_header(conn, params) do
    case get_req_header(conn, "sec-fetch-user") do
      ["?1"] -> :ok
      [] -> absent_user_header(conn, params)
      _other -> {:refused, ["sec-fetch-user"]}
    end
  end

  defp absent_user_header(conn, params) do
    cond do
      not webkit?(conn) -> {:refused, ["sec-fetch-user"]}
      proof?(params) -> :ok
      true -> :unproven
    end
  end

  defp proof?(%{@click_proof_param => "1"}), do: true
  defp proof?(_params), do: false

  # Safari on macOS / iOS / iPadOS and the iOS browsers (all WebKit). Chromium and Gecko send `Sec-Fetch-User: ?1` on a user
  # activation, so they are never treated as WebKit (no downgrade for them).
  defp webkit?(conn) do
    case get_req_header(conn, "user-agent") do
      [ua] -> String.contains?(ua, "AppleWebKit/") and not String.contains?(ua, ["Chrome/", "Chromium/", "Firefox/"])
      _none_or_several -> false
    end
  end

  defp failed_headers(conn, headers, strict?) do
    for {header, expected} <- headers, not header_ok?(conn, header, expected, strict?), do: header
  end

  defp header_ok?(conn, header, expected, strict?) do
    case get_req_header(conn, header) do
      [] -> not strict?
      [value] -> value == expected
      _several -> false
    end
  end

  defp origin_ok?(conn, issuer) do
    case get_req_header(conn, "origin") do
      [] -> true
      ["null"] -> get_req_header(conn, "sec-fetch-site") == ["same-origin"]
      [origin] -> String.downcase(origin) == issuer_origin(issuer)
      _several -> false
    end
  end

  defp issuer_origin(issuer) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(issuer)

    if port in [nil, URI.default_port(scheme)],
      do: String.downcase("#{scheme}://#{host}"),
      else: String.downcase("#{scheme}://#{host}:#{port}")
  end
end
