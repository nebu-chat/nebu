defmodule Nebu.OAuth.AuthorizeRequest do
  @moduledoc """
  Pure validation of `GET /oauth2/authorize` requests (epic oauth-broker, story
  oauth-authorize-idp-delegation-code: AC3, AC4, AC5, decisions D10, D11, D13, D14, D23). No I/O;
  the orchestration (client lookup, IdP delegation, responses) lives in `Nebu.OAuth.Authorize`.

    * `parse_query/1` — RAW query parse (D13): order and duplicates are kept (RFC 6749 3.1:
      parameters MUST NOT repeat; `conn.query_params` would be last-wins and turn `x[]=` into a
      list).
    * `match_redirect_uri/2` — exact byte-for-byte match against the registered URIs, plus the
      RFC 8252 7.3 loopback port exception (AC3).
    * `validate/2` — the AC4 checks once `client_id` and `redirect_uri` are trusted, in the AC4
      order: `response_type`, PKCE, `response_mode`, `state`, `nonce`, duplicates, `scope`,
      `prompt`; the first failure wins.
    * `redirect_location/3` — the client redirect (AC5, `query` or `fragment`).
  """

  alias Nebu.OAuth.Scope

  @max_text_bytes 2048
  @modes ["query", "fragment"]

  # RFC 8252 7.3 loopback redirect URIs (case as stored; `localhost`, `127.0.0.1`, `[::1]` are NOT
  # interchangeable).
  @loopback ~r/\Ahttp:\/\/(localhost|127\.0\.0\.1|\[::1\])([\/?]|\z)/
  @port ~r/\A[1-9][0-9]{0,4}\z/
  @challenge ~r/\A[A-Za-z0-9_-]{43}\z/

  @type pairs :: [{String.t(), String.t()}]
  @type error_context :: %{state: String.t() | nil, response_mode: String.t()}

  # ── D13 raw parsing ─────────────────────────────────────────────────────────

  @doc """
  Parses a raw query string into ordered `{name, value}` pairs (`+` = space). Duplicates and
  array-shaped names (`x[]`) are kept literally. A malformed percent-encoding is
  `{:error, :malformed}` (never a raise).
  """
  @spec parse_query(String.t()) :: {:ok, pairs()} | {:error, :malformed}
  def parse_query(qs) when is_binary(qs) do
    # URI.decode_www_form/1 does not reject every malformed escape (e.g. `%zz`), so a `%` that is
    # not followed by two hex digits is refused up front.
    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, qs), do: raise(ArgumentError, "malformed percent-encoding")

    pairs =
      qs
      |> String.split("&", trim: true)
      |> Enum.map(fn segment ->
        case String.split(segment, "=", parts: 2) do
          [name, value] -> {URI.decode_www_form(name), URI.decode_www_form(value)}
          [name] -> {URI.decode_www_form(name), ""}
        end
      end)

    {:ok, pairs}
  rescue
    ArgumentError -> {:error, :malformed}
  end

  def parse_query(_qs), do: {:error, :malformed}

  # ── AC3 redirect matching ───────────────────────────────────────────────────

  @doc """
  `{:ok, requested}` when `requested` equals one registered URI byte for byte (no normalization:
  case, trailing slash, default port, percent-encoding all count), or when a registered loopback
  URI `http://<host><rest>` (host `localhost`, `127.0.0.1` or `[::1]`, no port) matches a
  requested `http://<host>:<port><rest>` with a decimal port 1..65535. The REQUESTED URI (with its
  port) is returned: it is what is stored and redirected to. Otherwise `:error`.
  """
  @spec match_redirect_uri(term(), [String.t()]) :: {:ok, String.t()} | :error
  def match_redirect_uri(requested, registered) when is_binary(requested) and requested != "" and is_list(registered) do
    cond do
      requested in registered -> {:ok, requested}
      Enum.any?(registered, &loopback_match?(requested, &1)) -> {:ok, requested}
      true -> :error
    end
  end

  def match_redirect_uri(_requested, _registered), do: :error

  defp loopback_match?(requested, registered) when is_binary(registered) do
    case Regex.run(@loopback, registered) do
      [_, host | _] ->
        base = "http://" <> host
        rest = binary_part(registered, byte_size(base), byte_size(registered) - byte_size(base))
        prefix = base <> ":"

        with true <- String.starts_with?(requested, prefix),
             true <- String.ends_with?(requested, rest),
             middle_size when middle_size > 0 <- byte_size(requested) - byte_size(prefix) - byte_size(rest),
             port = binary_part(requested, byte_size(prefix), middle_size),
             true <- Regex.match?(@port, port) do
          String.to_integer(port) in 1..65_535
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp loopback_match?(_requested, _registered), do: false

  # ── D10 response mode ───────────────────────────────────────────────────────

  @doc "D10 default response mode: `\"fragment\"` for an https redirect URI, `\"query\"` otherwise (loopback, private-use scheme)."
  @spec default_response_mode(String.t()) :: String.t()
  def default_response_mode(redirect_uri) when is_binary(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: scheme} when is_binary(scheme) ->
        if String.downcase(scheme) == "https", do: "fragment", else: "query"

      _ ->
        "query"
    end
  end

  # ── AC4 validation ──────────────────────────────────────────────────────────

  @doc """
  Runs the AC4 checks on the request `pairs` for the already trusted `redirect_uri` (in the AC4
  order; first failure wins).

  `{:ok, %{response_mode:, code_challenge:, state:, nonce:, scope:, scope_prefix:, device_id:,
  openid_requested:, prompt: "create" | nil}}` or `{:error, error_code, error_context(pairs, uri)}`.
  """
  @spec validate(pairs(), String.t()) :: {:ok, map()} | {:error, String.t(), error_context()}
  def validate(pairs, redirect_uri) do
    ctx = error_context(pairs, redirect_uri)

    with :ok <- check_response_type(pairs),
         {:ok, challenge} <- check_pkce(pairs),
         :ok <- check_response_mode(pairs),
         {:ok, state} <- check_text(pairs, "state"),
         {:ok, nonce} <- check_text(pairs, "nonce"),
         :ok <- check_duplicates(pairs),
         {:ok, scope} <- check_scope(pairs),
         {:ok, prompt} <- check_prompt(pairs) do
      {:ok,
       %{
         response_mode: ctx.response_mode,
         code_challenge: challenge,
         state: state,
         nonce: nonce,
         scope: scope.scope,
         scope_prefix: scope.prefix,
         device_id: scope.device_id,
         openid_requested: scope.openid,
         prompt: prompt
       }}
    else
      {:error, code} -> {:error, code, ctx}
    end
  end

  @doc """
  The context of an error redirect for `pairs`: the client's `state` when it was sent exactly once
  and is valid (D14; else `nil`, never echoed), and the response mode — the explicit valid
  `response_mode` when sent exactly once, else the D10 default of `redirect_uri`.
  """
  @spec error_context(pairs(), String.t()) :: error_context()
  def error_context(pairs, redirect_uri) do
    state =
      case values(pairs, "state") do
        [s] when s != "" -> if valid_text?(s), do: s
        _ -> nil
      end

    mode =
      case values(pairs, "response_mode") do
        [m] when m in @modes -> m
        _ -> default_response_mode(redirect_uri)
      end

    %{state: state, response_mode: mode}
  end

  defp check_response_type(pairs) do
    case first(pairs, "response_type") do
      nil -> {:error, "invalid_request"}
      "code" -> :ok
      _ -> {:error, "unsupported_response_type"}
    end
  end

  # RFC 7636 / RFC 9700 2.1.1 / Matrix: S256 only. The challenge is base64url(SHA-256) = exactly 43
  # characters; a 64+ character "challenge" (js-sdk's plain fallback labelled S256) is refused.
  defp check_pkce(pairs) do
    challenge = first(pairs, "code_challenge")

    cond do
      not (is_binary(challenge) and Regex.match?(@challenge, challenge)) -> {:error, "invalid_request"}
      first(pairs, "code_challenge_method") != "S256" -> {:error, "invalid_request"}
      true -> {:ok, challenge}
    end
  end

  defp check_response_mode(pairs) do
    case first(pairs, "response_mode") do
      nil -> :ok
      mode when mode in @modes -> :ok
      _ -> {:error, "invalid_request"}
    end
  end

  # D14 (state) / D23 (client nonce): optional; at most 2048 bytes, valid UTF-8, no control
  # characters (PostgreSQL text cannot store NUL). An empty value counts as absent.
  defp check_text(pairs, name) do
    case first(pairs, name) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value -> if valid_text?(value), do: {:ok, value}, else: {:error, "invalid_request"}
    end
  end

  # RFC 6749 3.1: no parameter may appear more than once (client_id / redirect_uri are checked by
  # the caller before the redirect URI is trusted).
  defp check_duplicates(pairs) do
    names = Enum.map(pairs, &elem(&1, 0))
    if length(names) == length(Enum.uniq(names)), do: :ok, else: {:error, "invalid_request"}
  end

  defp check_scope(pairs) do
    case Scope.parse(first(pairs, "scope")) do
      {:ok, scope} -> {:ok, scope}
      {:error, :invalid_scope} -> {:error, "invalid_scope"}
    end
  end

  # D11: `none` alone => login_required (Nebu always needs an interactive IdP login); `none`
  # combined with another value => invalid_request (OIDC Core 3.1.2.1); `create` is carried (the
  # IdP leg forwards it only when the IdP supports it); everything else is ignored.
  defp check_prompt(pairs) do
    values = (first(pairs, "prompt") || "") |> String.split(" ", trim: true)

    cond do
      values == ["none"] -> {:error, "login_required"}
      "none" in values -> {:error, "invalid_request"}
      "create" in values -> {:ok, "create"}
      true -> {:ok, nil}
    end
  end

  defp valid_text?(value) do
    byte_size(value) <= @max_text_bytes and String.valid?(value) and not Regex.match?(~r/\p{Cc}/u, value)
  end

  defp values(pairs, name), do: for({^name, v} <- pairs, do: v)

  defp first(pairs, name) do
    case List.keyfind(pairs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # ── AC5 redirect building ───────────────────────────────────────────────────

  @doc """
  The client redirect: `params` (in the given order) www-form-encoded and appended to the query
  (`?`, or `&` when the URI already has a query) or as the fragment (`#`; registered URIs never
  contain one).
  """
  @spec redirect_location(String.t(), String.t(), [{String.t(), String.t()}]) :: String.t()
  def redirect_location(redirect_uri, mode, params) do
    encoded = Enum.map_join(params, "&", fn {k, v} -> URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v) end)

    case mode do
      "fragment" -> redirect_uri <> "#" <> encoded
      _ -> redirect_uri <> if(String.contains?(redirect_uri, "?"), do: "&", else: "?") <> encoded
    end
  end
end
