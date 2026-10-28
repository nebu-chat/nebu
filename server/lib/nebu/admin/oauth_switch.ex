defmodule Nebu.Admin.OAuthSwitch do
  @moduledoc """
  The pure parts of the OAuth switch section of `/admin/config` (story `admin-oauth-switch`, ADR-033 "Admin UI switch",
  AS1 - AS12): turning the submitted form into a change or per-field errors (`validate/2`) and deriving the non-blocking
  precondition list the server can see itself (`status/2`). No database access in either function; `current_env/0` reads the
  running node for `status/2`. The write itself is `Nebu.OAuth.save_switch/2` (ADR-020: this module reaches the OAuth domain
  only through `Nebu.OAuth`).

  ## Validation (AS3)

  `oauth_enabled` must be exactly `"true"` or `"false"`; anything else (also a list or a map, a parameter-pollution shape) is an
  error on that field, never a silent "off". A non-empty issuer is validated by `Nebu.OAuth.normalize_issuer/1`, the ONE function
  the runtime uses (https only, a host, no userinfo, query or fragment, an empty path), plus two form-only rules that are stricter and
  never looser: no whitespace or control character inside, an ASCII host (punycode for IDN) or a bracketed IPv6 literal, an optional numeric port 1..65535, and at most #{255} bytes. Switching on needs a valid issuer; switching
  off allows an empty one (it is stored as the empty string, which the runtime reads as "no issuer"). Switching on, or setting / changing a non-empty
  issuer (also while off: its origin is trusted by the legacy SSO login), needs the activation acknowledgement (`oauth_activation_ack` = `"true"`).

  ## Status (AS9)

  Each item is `%{id, level, text}` with `level` `:ok | :attention | :note`; the page prints the level as a word, never colour
  only. Nothing here claims that a precondition the server cannot see (the load balancer, the client-IP positive test, the IdP's
  `auth_time`, the clients) is fulfilled.
  """

  @max_issuer_bytes 255

  @type stored :: %{enabled: boolean(), issuer: String.t()}
  @type change :: %{
          enabled: boolean(),
          issuer: String.t(),
          enabled_before: boolean(),
          issuer_before: String.t(),
          issuer_before_normalized: String.t(),
          changed?: boolean(),
          enabling?: boolean()
        }
  @type status_item :: %{id: atom(), level: :ok | :attention | :note, text: String.t()}

  # ─── the stored state ──────────────────────────────────────────────────────

  @doc "The stored switch from the `[{key, value}]` list (or map) of the page: `enabled` only for the exact text `\"true\"`, the trimmed issuer (`\"\"` when absent)."
  @spec stored(list() | map()) :: stored()
  def stored(config) do
    %{
      enabled: value(config, "oauth_enabled") == "true",
      issuer:
        case value(config, "oauth_issuer_url") do
          v when is_binary(v) -> String.trim(v)
          _ -> ""
        end
    }
  end

  defp value(config, key) when is_list(config) do
    case List.keyfind(config, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp value(config, key) when is_map(config), do: Map.get(config, key)
  defp value(_config, _key), do: nil

  # ─── validate ──────────────────────────────────────────────────────────────

  @doc """
  `{:ok, change}` or `{:error, errors}` (`errors`: `%{optional(:enabled | :issuer | :ack) => message}`; every problem is reported at
  once). `change.changed?` is false when the normalized values equal the stored ones (nothing to write, nothing to audit).
  """
  @spec validate(map(), stored()) :: {:ok, change()} | {:error, %{optional(:enabled | :issuer | :ack) => String.t()}}
  def validate(params, %{enabled: enabled_before, issuer: issuer_before} = stored) when is_map(params) do
    enabled = parse_enabled(params["oauth_enabled"])
    issuer = parse_issuer(params["oauth_issuer_url"])

    errors =
      %{}
      |> put_enabled_error(enabled)
      |> put_issuer_error(enabled, issuer)
      |> put_ack_error(enabled, issuer, params["oauth_activation_ack"], stored)

    case {errors, enabled, issuer} do
      {errors, _, _} when map_size(errors) > 0 ->
        {:error, errors}

      {_, {:ok, enabled}, {:ok, issuer}} ->
        before_issuer = normalized_or_raw(issuer_before)

        {:ok,
         %{
           enabled: enabled,
           issuer: issuer,
           enabled_before: enabled_before,
           issuer_before: issuer_before,
           issuer_before_normalized: before_issuer,
           changed?: enabled != enabled_before or issuer != before_issuer,
           enabling?: enabled and not enabled_before
         }}
    end
  end

  defp parse_enabled("true"), do: {:ok, true}
  defp parse_enabled("false"), do: {:ok, false}
  defp parse_enabled(_other), do: :error

  # `{:ok, normalized | ""}`, `{:error, :too_long | :invalid}` or `{:error, :not_text}`
  defp parse_issuer(nil), do: {:ok, ""}

  defp parse_issuer(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" -> {:ok, ""}
      byte_size(trimmed) > @max_issuer_bytes -> {:error, :too_long}
      not String.valid?(trimmed) or String.match?(trimmed, ~r/[\s\x00-\x1f\x7f]/u) -> {:error, :invalid}
      true -> normalize(trimmed)
    end
  end

  defp parse_issuer(_other), do: {:error, :not_text}

  # the runtime function first, then the form-only shape rule: an ASCII host (letters, digits, dots, dashes; an IDN must be given as
  # punycode) or a bracketed IPv6 literal, and an optional numeric port 1..65535 (URI.parse reads `https://host:` and
  # `https://host:abc` as the default port, a backslash or a percent escape as part of a host or user name)
  @origin_shape ~r/\Ahttps:\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::([0-9]{1,5}))?\z/

  defp normalize(trimmed) do
    with {:ok, normalized} <- Nebu.OAuth.normalize_issuer(trimmed),
         [_, _host | port] <- Regex.run(@origin_shape, normalized),
         true <- port_in_range?(port) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid}
    end
  end

  defp port_in_range?([]), do: true
  defp port_in_range?([port]), do: String.to_integer(port) in 1..65_535

  defp normalized_or_raw(issuer) do
    case Nebu.OAuth.normalize_issuer(issuer) do
      {:ok, normalized} -> normalized
      :error -> issuer
    end
  end

  defp put_enabled_error(errors, {:ok, _}), do: errors
  defp put_enabled_error(errors, :error), do: Map.put(errors, :enabled, "The switch value is not valid. Use the checkbox.")

  defp put_issuer_error(errors, enabled, issuer) do
    switching_on? = enabled == {:ok, true}

    case issuer do
      {:ok, ""} when switching_on? ->
        Map.put(errors, :issuer, "OAuth cannot be switched on without a valid https issuer URL. Enter the public https address of this server.")

      {:ok, _issuer} ->
        errors

      {:error, reason} ->
        detail = issuer_detail(reason)

        message =
          if switching_on?,
            do: "OAuth cannot be switched on without a valid https issuer URL. " <> detail,
            else: detail

        Map.put(errors, :issuer, message)
    end
  end

  defp issuer_detail(:too_long), do: "The issuer URL is too long (at most #{@max_issuer_bytes} characters)."
  defp issuer_detail(:not_text), do: "The issuer URL is not valid."

  defp issuer_detail(:invalid),
    do: "The issuer URL is not valid. Use the public https origin of this server, for example https://chat.example.com (no path, query, fragment, user name or spaces)."

  # The acknowledgement is needed (a) when the resulting state is ON and differs from the stored one (the switch turns on, or the
  # issuer changes while on) and (b) whenever a NON-EMPTY issuer is set or changed, also while the switch stays OFF: the issuer origin is
  # a trusted `redirectUrl` of the legacy SSO login (no confirmation page) independent of `oauth_enabled` (SEC gate admin-oauth-switch,
  # M-1). Clearing the issuer and switching off with the issuer unchanged need none (D6: an unchanged state needs none).
  defp put_ack_error(errors, enabled, issuer, ack, %{enabled: enabled_before, issuer: issuer_before}) do
    issuer_differs? =
      case issuer do
        {:ok, ""} -> false
        {:ok, normalized} -> normalized != normalized_or_raw(issuer_before)
        {:error, _} -> true
      end

    turning_on? = enabled == {:ok, true} and not enabled_before

    if (turning_on? or issuer_differs?) and ack != "true",
      do: Map.put(errors, :ack, "Tick the box to confirm that you have read the activation checklist before OAuth is switched on or an issuer is set or changed: the issuer origin is also trusted by the legacy SSO login, with OAuth off too."),
      else: errors
  end

  # ─── status ────────────────────────────────────────────────────────────────

  @doc """
  The status list for `config` (the `[{key, value}]` list of the page) and `env` (see `current_env/0`): `:switch`, `:node`, `:proxy`,
  `:issuer_host` (only with a valid stored issuer), `:refresh_mode`, `:secure` (only when the admin session is not secure) and
  `:reauth_optout` (only when the opt-out is set).
  """
  @spec status(list() | map(), map()) :: [status_item()]
  def status(config, env) do
    stored = stored(config)

    [
      switch_item(stored),
      node_item(stored, env),
      proxy_item(env),
      issuer_host_item(stored, env),
      refresh_mode_item(config),
      secure_item(env),
      reauth_optout_item(env)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp item(id, level, text), do: %{id: id, level: level, text: text}

  defp switch_item(%{enabled: true, issuer: issuer}),
    do: item(:switch, :note, "Stored setting: OAuth is on" <> issuer_suffix(issuer) <> ".")

  defp switch_item(%{enabled: false, issuer: issuer}),
    do: item(:switch, :note, "Stored setting: OAuth is off" <> issuer_suffix(issuer) <> ".")

  defp issuer_suffix(""), do: ", no issuer is stored"
  defp issuer_suffix(issuer), do: ", issuer " <> issuer

  # "Does this node offer OAuth right now" against "should it, by the stored setting"
  defp node_item(%{enabled: enabled, issuer: issuer}, env) do
    stored_valid? = Nebu.OAuth.normalize_issuer(issuer) != :error
    expected? = enabled and stored_valid?
    answers? = env.node_answers == true

    cond do
      enabled and not stored_valid? ->
        item(:node, :attention, "OAuth is switched on but the stored issuer is missing or not a valid https URL: this node does NOT offer OAuth (fail closed). Save a valid issuer.")

      answers? == expected? ->
        item(:node, :ok, "This node answers GET /_matrix/client/v1/auth_metadata with #{http_status(answers?)} (OAuth is #{if answers?, do: "offered", else: "not offered"}).")

      true ->
        item(
          :node,
          :note,
          "This node still answers GET /_matrix/client/v1/auth_metadata with #{http_status(answers?)}, the stored setting says otherwise. A change takes effect on all nodes #{propagation(env)}."
        )
    end
  end

  defp http_status(true), do: "200"
  defp http_status(false), do: "404"

  defp propagation(%{cache_ms: ms}), do: propagation_text(ms) <> " (NEBU_OAUTH_CONFIG_CACHE_MS)"

  @doc "\"immediately\" / \"within N seconds\": how long another node can still serve the old state (the ONE wording of the page, the flash and the status list)."
  @spec propagation_text(term()) :: String.t()
  def propagation_text(0), do: "immediately"
  def propagation_text(ms) when is_integer(ms) and ms > 0, do: "within #{max(1, div(ms + 999, 1000))} seconds"
  def propagation_text(_other), do: "within a few seconds"

  defp proxy_item(%{trusted_proxy_cidrs: []}) do
    item(
      :proxy,
      :attention,
      "NEBU_TRUSTED_PROXY_CIDRS is empty: behind a reverse proxy or load balancer every per-IP limit and per-source cap is global, so one anonymous client can lock all users out. Empty is right only when clients connect to Nebu directly (see the activation checklist, group A)."
    )
  end

  defp proxy_item(%{trusted_proxy_cidrs: list}) when is_list(list) do
    item(
      :proxy,
      :note,
      "NEBU_TRUSTED_PROXY_CIDRS lists #{length(list)} proxy address range(s). The server cannot verify that your load balancer forwards the real client address: the positive client-IP test stays your job (checklist group A)."
    )
  end

  defp proxy_item(_env), do: nil

  defp issuer_host_item(%{issuer: issuer}, %{server_name: server_name}) when is_binary(server_name) do
    with {:ok, normalized} <- Nebu.OAuth.normalize_issuer(issuer),
         %URI{host: host} = uri when is_binary(host) <- URI.parse(normalized) do
      authority = if uri.port in [nil, 443], do: host, else: "#{host}:#{uri.port}"

      if String.downcase(authority) == String.downcase(server_name) do
        item(:issuer_host, :ok, "The issuer host (#{authority}) matches NEBU_SERVER_NAME.")
      else
        item(
          :issuer_host,
          :attention,
          "The issuer host (#{authority}) differs from NEBU_SERVER_NAME (#{server_name}). That is right only when your server name is delegated with /.well-known to the host the clients reach; the issuer must be the public address of this server."
        )
      end
    else
      _ -> nil
    end
  end

  defp issuer_host_item(_stored, _env), do: nil

  # sessions of an IdP client without a refresh token fail at their first refresh while the IdP is revalidated per refresh
  defp refresh_mode_item(config) do
    mode = value(config, "matrix_oidc_refresh_mode") |> then(&if(&1 in ["offline", "online"], do: &1, else: "offline"))
    revalidation = if value(config, "oauth_idp_revalidation") |> to_text() == "off", do: :off, else: :per_refresh

    if mode == "offline" or revalidation == :off do
      item(:refresh_mode, :note, "matrix_oidc_refresh_mode is #{mode}" <> if(revalidation == :off, do: " and oauth_idp_revalidation is off.", else: ", which per-refresh IdP revalidation needs."))
    else
      item(
        :refresh_mode,
        :attention,
        "matrix_oidc_refresh_mode is online while oauth_idp_revalidation is per_refresh (the default): OAuth logins are refused because the IdP issues no refresh token. Set the refresh mode to offline (form above)."
      )
    end
  end

  defp to_text(v) when is_binary(v), do: String.trim(v)
  defp to_text(_), do: ""

  defp secure_item(%{admin_session_secure: false}) do
    item(:secure, :attention, "The admin session is not marked secure (NEBU_ADMIN_SESSION_SECURE=false): the issuer must be https and the OAuth binding cookies are Secure; use this setting on a local test stack only.")
  end

  defp secure_item(_env), do: nil

  defp reauth_optout_item(%{reauth_allow_missing: true}) do
    item(:reauth_optout, :note, "NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME is on: a fresh sign-in is accepted without an auth_time claim. Use this on a local test stack only.")
  end

  defp reauth_optout_item(_env), do: nil

  # ─── the running node ──────────────────────────────────────────────────────

  @doc "What `status/2` needs from the running node (reads the application environment and the live predicate; never raises)."
  @spec current_env() :: map()
  def current_env do
    %{
      trusted_proxy_cidrs: trusted(),
      server_name: to_string(Application.get_env(:nebu_http, :server_name, "localhost")),
      admin_session_secure: Application.get_env(:nebu_http, :admin_session_secure, true) != false,
      reauth_allow_missing: Application.get_env(:nebu_http, :admin_reauth_allow_missing_auth_time, false) == true,
      node_answers: Nebu.OAuth.oauth_aware?(),
      cache_ms: Nebu.OAuth.config_cache_ms()
    }
  end

  defp trusted do
    case Nebu.Web.ClientIP.trusted() do
      list when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  The issuer the field is pre-filled with while nothing is stored: `https://<NEBU_SERVER_NAME>` when the admin session is secure and the
  name is not a local one (`localhost`, an IP literal), else `nil`. Only a suggestion: the page says it is not saved yet.
  """
  @spec suggested_issuer(map()) :: String.t() | nil
  def suggested_issuer(%{server_name: name, admin_session_secure: true}) when is_binary(name) do
    host = name |> String.split(":") |> hd() |> String.downcase()

    cond do
      host == "" or host == "localhost" -> nil
      String.match?(host, ~r/\A[0-9.]+\z/) -> nil
      true -> normalize_suggestion("https://" <> name)
    end
  end

  def suggested_issuer(_env), do: nil

  defp normalize_suggestion(candidate) do
    case Nebu.OAuth.normalize_issuer(candidate) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end
end
