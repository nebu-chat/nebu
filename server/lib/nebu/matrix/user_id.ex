defmodule Nebu.Matrix.UserId do
  @moduledoc """
  Single source of truth for mapping OIDC token claims → a Matrix user_id.

  The localpart is taken from the operator-configured claim
  (`server_config.oidc_user_id_claim`, the Claim-Mapping admin page), falling back to the
  standard username claims and finally `sub` so a login never fails to produce an id.

  CRITICAL: every place that derives a Matrix identity from a token MUST use this — the
  public `POST /login` handler AND the `OidcPlug` that authenticates every protected
  request. If they diverge (e.g. one uses the configured claim and the other hardcodes
  `sub`), a client logs in as `@alex:localhost` but its sync/join/send are attributed to
  `@<opaque-sub>:localhost`, so it never sees its own room membership.
  """

  @doc "Full Matrix user_id (`@localpart:server`) for the given verified claims."
  def from_claims(claims, server_name) when is_map(claims) do
    "@" <> localpart(claims) <> ":" <> server_name
  end

  # Matrix user_id grammar (CS spec, room version 6+): `@localpart:domain` where the
  # localpart uses `a-z 0-9 . _ = - / +` (the same grammar `sanitize/1` enforces when
  # deriving an id from a claim) and the domain is a non-empty server name.
  #
  # Two security properties, both load-bearing (bugfix-mutual-rooms Kassandra
  # security review, finding F-1):
  #
  #   * Anchors are `\A`/`\z` (true string-start/end), not `^`/`$`. Elixir's `~r//`
  #     compiles WITHOUT PCRE_DOLLAR_ENDONLY, so `$` matches before a trailing `\n`
  #     — a `user_id` with a trailing newline byte would pass this check while not
  #     being byte-identical to the real id, letting a caller bypass an equality
  #     check (e.g. the mutual_rooms self-id guard) by appending `\n`.
  #   * The domain character class is `[A-Za-z0-9.\-]+` — ASCII letters/digits/dot/
  #     hyphen only — NOT `[^\s:]+`. The old negated class accepted 249 of 256
  #     possible bytes, including NUL, other control characters, and all high-bit
  #     (non-ASCII) bytes, because Erlang's `re` `\s` is ASCII-only. Those bytes
  #     could reach a Postgres query (DB error) and a `Logger.warning` call on a
  #     failure path (log injection: control bytes, or U+2028 LINE SEPARATOR,
  #     forging fake extra log lines). The new class still covers every real
  #     Matrix server name, including IDN/punycode domains (always pure-ASCII
  #     `xn--...`), and — like the old class — excludes `:`, so port-bearing or
  #     IPv6-literal server names remain unsupported (true of the original regex
  #     too, not a new restriction).
  @user_id_regex ~r/\A@[a-z0-9._=\-\/+]+:[A-Za-z0-9.\-]+\z/

  @doc """
  True if `user_id` is a syntactically valid Matrix user_id (`@localpart:domain`).

  This is a shape check only — it does not verify the user exists. Callers that need
  default-deny on attacker-influenced input (e.g. the admin add-member path) MUST run
  this BEFORE any write so a malformed id never reaches the membership write path.
  """
  @spec valid?(term()) :: boolean()
  def valid?(user_id) when is_binary(user_id), do: Regex.match?(@user_id_regex, user_id)
  def valid?(_), do: false

  @doc "The Matrix localpart for the given verified claims (sanitised, never empty)."
  def localpart(claims) when is_map(claims) do
    configured = configured_claim()

    raw =
      (configured && configured != "" && claims[configured]) ||
        claims["preferred_username"] ||
        claims["name"] ||
        claims["sub"]

    case sanitize(to_string(raw)) do
      "" -> sanitize(to_string(claims["sub"]))
      lp -> lp
    end
  end

  # Matrix localpart grammar (CS spec): a-z 0-9 . _ = - / +. Downcase and replace any
  # other character so an attacker-influenced claim value cannot break the user_id shape.
  defp sanitize(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._=\-\/+]/, "_")
  end

  # The configured claim is served from Nebu.Matrix.OidcClaimCache — a node-local,
  # lazily-populated, explicitly-invalidated in-memory cache (story
  # oidc-claim-boot-cache). This removes the former per-request live PostgreSQL
  # read from the identity hot path (POST /login + OidcPlug on every protected
  # request) AND the transient fail-open-to-weaker-claim window a live read could
  # open during a DB/Repo-unavailability window (Kassandra MEDIUM). The
  # nil-on-failure / nil-when-unconfigured contract is preserved: get/0 returns
  # nil and never raises when no claim is configured or the cache is unpopulated.
  defp configured_claim, do: Nebu.Matrix.OidcClaimCache.get()
end
