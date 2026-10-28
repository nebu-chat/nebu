defmodule Nebu.Matrix.SsoRedirect do
  @moduledoc """
  What a legacy SSO `redirectUrl` is, and whether its origin is trusted (story `legacy-sso-redirect-confirmation`,
  epic SEC gate 3 finding G3-3, decisions D1, D2, D4, D5). Matrix-private, plain functions, no state.

  ## `classify/1` (D1, D2)

  The ONE function that decides what a `redirectUrl` is, evaluated on the RAW string (the same string that is
  stored in the SSO state and later used for the `Location`, so there is no differential between the checked and
  the used value). `URI.parse/1` is never used for the decision: it parses `https://evil.example\\@listed.example/`
  with the host `listed.example` while a browser goes to `evil.example`.

    * `{:reject, reason}` - the unchanged `400` of the redirect leg (the reason atom is for tests and diagnostics,
      never rendered, never logged with the value);
    * `:direct` - loopback `http://localhost|127.0.0.1[:port]`, a default deep-link scheme or an operator extra
      scheme: never confirmed, behaviour unchanged;
    * `{:confirmable, %{origin:, host:, port:, path:}}` - a syntactically valid `https` URL. `origin` is the
      normalized `https://host[:port]` (lower case, default port dropped), `port` is `nil` for 443, `path` is the
      raw path (stops at `?` and `#`). Whether the origin is LISTED is decided at the callback by `listed?/1`.

  ## `listed?/1` (D4)

  First hit wins, fail closed: (1) `https://<server_name>` by exact ORIGIN (never the request `Host`), (2) the
  operator list `server_config.sso_redirect_allowed_origins` by exact origin, through the `Nebu.Web.OidcConfig`
  cache, (3) only when 1 and 2 did not match, `Nebu.OAuth.trusted_redirect_url?/2` (the issuer origin; an approved
  client's REGISTERED redirect URI, matched on the raw URL at a path boundary; one bounded DB read). Any error or
  exception of the third source is `false`.

  ## `normalize_origin_list/1` (D5)

  The single validator of the operator list (the Admin form reaches it only through
  `Nebu.Matrix.normalize_sso_redirect_origins/1`, the callback applies it per token to the stored string).
  """

  # Schemes that are NEVER allowed as a redirectUrl even if an operator misconfigures an allowlist - they can
  # exfiltrate the loginToken via script/file/opaque-data URIs.
  @scheme_denylist ~w(javascript data file vbscript blob)

  # Default Matrix-client deep-link schemes always accepted (Element / SchildiChat / FluffyChat).
  @default_deep_link_schemes ~w(element schildichat im.fluffychat.auth)

  @max_url_bytes 2048
  @max_host_bytes 253
  @max_origins 50
  @max_list_chars 4096
  @token_display_chars 80

  @scheme_re ~r/\A([A-Za-z][A-Za-z0-9+.\-]*):(.*)\z/s
  @host_re ~r/\A[a-z0-9\-]+(\.[a-z0-9\-]+)*\z/i
  @numeric_label_re ~r/\A([0-9]+|0[xX][0-9a-fA-F]*)\z/
  @ipv4_label_re ~r/\A(0|[1-9][0-9]{0,2})\z/
  @port_re ~r/\A[0-9]+\z/
  @control_re ~r/[\x00-\x20\x7F]/
  @non_ascii_re ~r/[^\x00-\x7F]/

  @doc """
  The hardcoded scheme denylist (`javascript`, `data`, `file`, `vbscript`, `blob`), exposed through
  `Nebu.Matrix.SsoLogin.scheme_denylist/0` so the Admin form can refuse an operator scheme from it at save time.
  """
  @spec scheme_denylist() :: [String.t()]
  def scheme_denylist, do: @scheme_denylist

  @type target :: %{origin: String.t(), host: String.t(), port: pos_integer() | nil, path: String.t()}

  # ── classify/1 ───────────────────────────────────────────────────────────────

  @doc "Classifies a raw `redirectUrl` (see the moduledoc). Never raises."
  @spec classify(term()) :: {:reject, atom()} | :direct | {:confirmable, target()}
  def classify(raw) when is_binary(raw) do
    cond do
      raw == "" -> {:reject, :empty}
      byte_size(raw) > @max_url_bytes -> {:reject, :too_long}
      Regex.match?(@control_re, raw) -> {:reject, :control_byte}
      String.contains?(raw, "\\") -> {:reject, :backslash}
      true -> classify_scheme(raw)
    end
  end

  def classify(_other), do: {:reject, :not_a_string}

  defp classify_scheme(raw) do
    case Regex.run(@scheme_re, raw) do
      [_, scheme, rest] -> classify_scheme(String.downcase(scheme), rest)
      _ -> {:reject, :no_scheme}
    end
  end

  defp classify_scheme(scheme, _rest) when scheme in @scheme_denylist, do: {:reject, :denylisted_scheme}
  defp classify_scheme("https", rest), do: classify_https(rest)
  defp classify_scheme("http", rest), do: classify_loopback(rest)

  defp classify_scheme(scheme, _rest) do
    if scheme in @default_deep_link_schemes or scheme in extra_redirect_schemes(),
      do: :direct,
      else: {:reject, :scheme_not_permitted}
  end

  defp classify_https(rest) do
    with {:ok, authority, after_authority} <- split_authority(rest),
         :ok <- ascii_only(rest),
         {:ok, host, port} <- parse_authority(authority) do
      {:confirmable, %{origin: origin(host, port), host: host, port: port, path: path_of(after_authority)}}
    end
  end

  defp classify_loopback(rest) do
    with {:ok, authority, _after} <- split_authority(rest),
         :ok <- ascii_only(rest),
         {:ok, host, _port} <- parse_loopback_authority(authority) do
      if host in ["localhost", "127.0.0.1"], do: :direct, else: {:reject, :not_loopback}
    end
  end

  # `//` must follow the scheme exactly (`https:evil.example`, `https:/evil.example`, `https:\\evil.example` are
  # read as `https://evil.example/` by a browser); the authority ends at the first `/`, `?` or `#`.
  defp split_authority("//" <> rest) do
    [authority | _] = String.split(rest, ["/", "?", "#"], parts: 2)
    after_authority = binary_part(rest, byte_size(authority), byte_size(rest) - byte_size(authority))
    if authority == "", do: {:reject, :empty_host}, else: {:ok, authority, after_authority}
  end

  defp split_authority(_other), do: {:reject, :no_authority}

  defp ascii_only(rest), do: if(Regex.match?(@non_ascii_re, rest), do: {:reject, :non_ascii}, else: :ok)

  defp path_of(after_authority), do: after_authority |> String.split(["?", "#"], parts: 2) |> hd()

  defp parse_loopback_authority(authority) do
    with :ok <- no_userinfo_or_percent(authority),
         {:ok, host_part, port} <- split_host_port(authority) do
      {:ok, String.downcase(host_part), port}
    end
  end

  defp parse_authority(authority) do
    with :ok <- no_userinfo_or_percent(authority),
         {:ok, host_part, port} <- split_host_port(authority),
         {:ok, host} <- validate_https_host(host_part) do
      {:ok, host, port}
    end
  end

  defp no_userinfo_or_percent(authority) do
    cond do
      String.contains?(authority, "@") -> {:reject, :userinfo}
      String.contains?(authority, "%") -> {:reject, :percent_in_authority}
      true -> :ok
    end
  end

  # `host[:port]`; an IPv6 literal (`[`) is not supported, an empty or invalid port is refused. 443 -> nil.
  defp split_host_port(authority) do
    if String.starts_with?(authority, "[") do
      {:reject, :ipv6_literal}
    else
      case String.split(authority, ":", parts: 2) do
        [host] -> {:ok, host, nil}
        [host, port] -> with {:ok, port} <- parse_port(port), do: {:ok, host, port}
      end
    end
  end

  defp parse_port(port) do
    with true <- Regex.match?(@port_re, port),
         {n, ""} when n in 1..65_535 <- Integer.parse(port) do
      {:ok, if(n == 443, do: nil, else: n)}
    else
      _ -> {:reject, :invalid_port}
    end
  end

  # `[a-z0-9-]+(\.[a-z0-9-]+)*` (the `\z`-anchored regex rejects `_`, a trailing dot, empty labels), then the WHATWG
  # numeric-host rule: when the LAST label looks numeric (all digits or `0x` hex) the host must be CANONICAL
  # dotted-decimal IPv4.
  defp validate_https_host(host) do
    cond do
      byte_size(host) > @max_host_bytes -> {:reject, :host_too_long}
      not Regex.match?(@host_re, host) -> {:reject, :invalid_host}
      true -> host |> String.downcase() |> check_numeric_host()
    end
  end

  defp check_numeric_host(host) do
    labels = String.split(host, ".")

    cond do
      not Regex.match?(@numeric_label_re, List.last(labels)) -> {:ok, host}
      canonical_ipv4?(labels) -> {:ok, host}
      true -> {:reject, :numeric_host}
    end
  end

  defp canonical_ipv4?(labels) do
    length(labels) == 4 and
      Enum.all?(labels, fn label ->
        Regex.match?(@ipv4_label_re, label) and String.to_integer(label) <= 255
      end)
  end

  @doc """
  True for a host that satisfies the D2 https host rule (ASCII `[a-z0-9-]` labels, no trailing dot, no empty label,
  at most 253 bytes, a numeric last label only as canonical dotted-decimal IPv4). The ONE host validator: the
  confirmation page uses it before it builds the CSP `form-action` source from a stored host. Never raises.
  """
  @spec valid_https_host?(term()) :: boolean()
  def valid_https_host?(host) when is_binary(host), do: match?({:ok, _}, validate_https_host(host))
  def valid_https_host?(_other), do: false

  defp origin(host, nil), do: "https://" <> host
  defp origin(host, port), do: "https://" <> host <> ":" <> Integer.to_string(port)

  @doc "`host[:port]` of a target (or stored confirm entry), for the INFO lines; the host charset is `[a-z0-9.-]`."
  @spec host_label(map()) :: String.t()
  def host_label(%{host: host} = target) when is_binary(host) do
    host = host |> String.replace(~r/[^a-z0-9.\-]/, "?") |> String.slice(0, @max_host_bytes)

    case Map.get(target, :port) do
      port when is_integer(port) and port in 1..65_535 and port != 443 -> host <> ":" <> Integer.to_string(port)
      _ -> host
    end
  end

  def host_label(_other), do: "unknown"

  # AC6/AC7 (story fix-and-configure-sso-redirect-schemes): the operator's extra schemes
  # (`server_config.sso_extra_redirect_schemes`) are read through the cluster-aware `Nebu.Web.OidcConfig` cache.
  # The `:sso_redirect_schemes_reader` 0-arity seam lets unit tests inject a scheme list directly; it is
  # compile-guarded (test builds only, security review SEC #9).
  if Mix.env() == :test do
    defp extra_redirect_schemes do
      case Application.get_env(:nebu_http, :sso_redirect_schemes_reader) do
        fun when is_function(fun, 0) -> fun.() |> List.wrap() |> Enum.map(&String.downcase/1)
        _ -> configured_extra_schemes()
      end
    end
  else
    defp extra_redirect_schemes, do: configured_extra_schemes()
  end

  defp configured_extra_schemes do
    case Nebu.Web.OidcConfig.get_sso_extra_redirect_schemes() do
      str when is_binary(str) and str != "" ->
        str
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # ── listed?/1 (D4) ───────────────────────────────────────────────────────────

  @doc """
  True when the target (its normalized origin `https://host[:port]`, see `classify/1`, and the RAW redirect URL)
  is trusted without a confirmation (D4, in this order, first hit wins): `https://<server_name>` (by origin), the
  operator list (by origin), then the OAuth domain (`Nebu.OAuth.trusted_redirect_url?/2`: the issuer origin, an
  approved client's REGISTERED redirect URI). Fails closed: any problem is `false`.
  """
  @spec listed?(String.t(), String.t()) :: boolean()
  def listed?(origin, raw_redirect_url) when is_binary(origin) and is_binary(raw_redirect_url) do
    origin in server_name_origins() or origin in operator_origins() or oauth_trusted?(origin, raw_redirect_url)
  end

  def listed?(_origin, _raw_redirect_url), do: false

  @doc """
  `[https://<server_name>]` (the Matrix server_name may carry a port, `host[:port]`), or `[]` for an unparsable value.
  Trusted automatically by `listed?/2` and accepted as the `Origin` of the confirmation POST. The request `Host`
  header is NEVER used.
  """
  @spec server_name_origins() :: [String.t()]
  def server_name_origins do
    case Application.get_env(:nebu_http, :server_name) do
      name when is_binary(name) and name != "" ->
        case parse_authority(name) do
          {:ok, host, port} -> [origin(host, port)]
          _ -> []
        end

      _ ->
        []
    end
  end

  # The operator list, parsed with the SAME per-token normalizer as the Admin form; a token that does not
  # normalize (hand-edited DB) is ignored and never widens the list.
  defp operator_origins do
    operator_origins_raw()
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",")
      _ -> []
    end)
    |> Enum.flat_map(fn token ->
      case normalize_origin(trim_space_only(token)) do
        {:ok, origin} -> [origin]
        {:error, _} -> []
      end
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Test seams (compile-guarded: they exist only in test builds, a stray `Application.put_env` in a release can
  # never widen the list or the trusted origins).
  if Mix.env() == :test do
    defp operator_origins_raw do
      case Application.get_env(:nebu_http, :sso_redirect_origins_reader) do
        fun when is_function(fun, 0) -> fun.()
        _ -> Nebu.Web.OidcConfig.get_sso_redirect_allowed_origins()
      end
    end

    defp oauth_check(origin, raw_url) do
      case Application.get_env(:nebu_http, :sso_trusted_origin_check) do
        fun when is_function(fun, 2) -> fun.(origin, raw_url)
        _ -> Nebu.OAuth.trusted_redirect_url?(origin, raw_url)
      end
    end
  else
    defp operator_origins_raw, do: Nebu.Web.OidcConfig.get_sso_redirect_allowed_origins()
    defp oauth_check(origin, raw_url), do: Nebu.OAuth.trusted_redirect_url?(origin, raw_url)
  end

  defp oauth_trusted?(origin, raw_url) do
    oauth_check(origin, raw_url) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # ── normalize_origin_list/1 (D5) ─────────────────────────────────────────────

  @doc """
  Validates and normalizes the operator list (comma separated https origins): `{:ok, "https://a.example,
  https://b.example:8443"}` (lower case, `:443` and a single trailing `/` dropped, duplicates removed keeping the
  first occurrence, comma + space separated; `""` is valid and means "no listed origins") or `{:error, message}`.
  Nothing is partially accepted. At most #{@max_origins} origins and #{@max_list_chars} characters. The message
  names the offending token truncated to #{@token_display_chars} characters; it is rendered HTML-escaped by the
  Admin UI and never logged.
  """
  @spec normalize_origin_list(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_origin_list(raw) when is_binary(raw) do
    cond do
      raw == "" ->
        {:ok, ""}

      String.length(raw) > @max_list_chars ->
        {:error, "The list is too long: at most #{@max_list_chars} characters are allowed."}

      true ->
        tokens = String.split(raw, ",")

        if length(tokens) > @max_origins do
          {:error, "Too many origins: at most #{@max_origins} are allowed."}
        else
          normalize_tokens(tokens, [])
        end
    end
  end

  def normalize_origin_list(_other), do: {:error, "The origin list is not valid text."}

  defp normalize_tokens([], acc), do: {:ok, acc |> Enum.reverse() |> Enum.uniq() |> Enum.join(", ")}

  defp normalize_tokens([token | rest], acc) do
    trimmed = trim_space_only(token)

    case normalize_origin(trimmed) do
      {:ok, origin} -> normalize_tokens(rest, [origin | acc])
      {:error, reason} -> {:error, error_message(trimmed, reason)}
    end
  end

  # Trims ONLY literal ASCII space and tab (not String.trim/1, which would strip a trailing "\n" before the
  # `\z`-anchored checks ever see it).
  defp trim_space_only(token), do: token |> String.trim(" ") |> String.trim("\t")

  # One token -> `{:ok, "https://host[:port]"}` | `{:error, reason_atom}`.
  defp normalize_origin(token) do
    cond do
      token == "" ->
        {:error, :empty}

      Regex.match?(@non_ascii_re, token) ->
        {:error, :non_ascii}

      Regex.match?(@control_re, token) ->
        {:error, :control_byte}

      String.contains?(token, ["\\", "*"]) ->
        {:error, :forbidden_character}

      true ->
        case Regex.run(~r/\Ahttps:\/\/(.*)\z/is, token) do
          [_, rest] -> normalize_authority(rest)
          _ -> {:error, :scheme}
        end
    end
  end

  defp normalize_authority(rest) do
    authority = if String.ends_with?(rest, "/"), do: binary_part(rest, 0, byte_size(rest) - 1), else: rest

    cond do
      authority == "" -> {:error, :empty_host}
      String.contains?(authority, ["/", "?", "#"]) -> {:error, :path_query_or_fragment}
      true -> origin_of_authority(authority)
    end
  end

  defp origin_of_authority(authority) do
    case parse_authority(authority) do
      {:ok, host, port} -> {:ok, origin(host, port)}
      {:reject, reason} -> {:error, reason}
    end
  end

  defp error_message(token, reason) do
    shown = if String.length(token) > @token_display_chars, do: String.slice(token, 0, @token_display_chars) <> "...", else: token
    "Origin '#{shown}' is not valid: #{reason_text(reason)}"
  end

  defp reason_text(:empty), do: "an empty entry is not allowed."
  defp reason_text(:non_ascii), do: "write non-ASCII host names in their ASCII (xn--) form."
  defp reason_text(:scheme), do: "only https origins are allowed."
  defp reason_text(:userinfo), do: "a user name or password is not allowed."
  defp reason_text(:percent_in_authority), do: "percent-encoding is not allowed in the host."
  defp reason_text(:path_query_or_fragment), do: "give the origin only (scheme, host and optional port), no path, query or fragment."
  defp reason_text(:forbidden_character), do: "wildcards and backslashes are not allowed."
  defp reason_text(:invalid_port), do: "the port must be a number from 1 to 65535."
  defp reason_text(:ipv6_literal), do: "IPv6 addresses are not supported."
  defp reason_text(:numeric_host), do: "numeric hosts must be a plain dotted-decimal IPv4 address."
  defp reason_text(:control_byte), do: "spaces and control characters are not allowed."
  defp reason_text(_other), do: "expected https://host or https://host:port."
end
