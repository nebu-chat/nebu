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

  # Matrix appendix "Identifier length limits": a user id (`@`, localpart, `:` and domain) is at most 255 BYTES.
  @max_user_id_bytes 255
  # A natural id is passed through only up to 254 bytes; the hashed form is EXACTLY 255 bytes (domain separation by length).
  @max_natural_id_bytes @max_user_id_bytes - 1
  # `-` + 16 lowercase hex characters (the first 8 bytes of a SHA-256) of a truncated localpart.
  @digest_hex_chars 16
  @digest_suffix_bytes 1 + @digest_hex_chars
  # the localpart room (`255 - 2 - byte_size(server_name)`) a server name must leave: a one-byte prefix, `-` and the 16 hex characters
  @min_localpart_room_bytes 1 + @digest_suffix_bytes

  @doc """
  Full Matrix user_id (`@localpart:server`) for the given verified claims, at most 255 bytes (story `event-size-limit`, D12).

  The localpart comes from an IdP claim and `sanitize/1` has no length bound, so a long claim would yield a user id above the
  Matrix limit, which then travels as `sender` / `state_key` of member events. An id of at most 254 bytes is returned exactly as
  before. Every id of 255 bytes or more is HASHED: the localpart becomes its first `236 - byte_size(server_name)` bytes, `"-"` and
  the first 16 lowercase hex characters of the SHA-256 of the FULL sanitised localpart, so the id is EXACTLY 255 bytes. The two
  forms are disjoint by LENGTH (a natural id is never 255 bytes long, a hashed one always is), so no claim a user can choose
  collides with the hashed id of another user's long claim. Deterministic (login, `OidcPlug`, SSO, account management and the Admin
  agree), two long claims that share a prefix get different ids, grammar-valid and ASCII.

  A server name that leaves fewer than 18 bytes of the localpart (`server_name_leaves_room?/1`) is a configuration error:
  `Nebu.Application` refuses to boot. (Called with such a name anyway, the id carries no prefix and is above 255 bytes: invalid.)
  """
  def from_claims(claims, server_name) when is_map(claims) do
    localpart = localpart(claims)
    id = "@" <> localpart <> ":" <> server_name

    if byte_size(id) <= @max_natural_id_bytes do
      id
    else
      "@" <> hashed_localpart(localpart, server_name) <> ":" <> server_name
    end
  end

  # The localpart of an id that is hashed. `localpart` is sanitised (ASCII, so a byte prefix never splits a character) and longer
  # than the prefix kept, because the natural id was at least 255 bytes.
  defp hashed_localpart(localpart, server_name) do
    digest = :crypto.hash(:sha256, localpart) |> Base.encode16(case: :lower) |> binary_part(0, @digest_hex_chars)
    keep = max(@max_user_id_bytes - 2 - byte_size(server_name) - @digest_suffix_bytes, 0)

    binary_part(localpart, 0, keep) <> "-" <> digest
  end

  @doc """
  True when a server name leaves at least 18 bytes of a 255-byte user id for the localpart (a one-byte prefix, `-` and the 16 hex
  characters of a hashed id): a server name of at most 235 bytes. `Nebu.Application` refuses to boot otherwise.
  """
  @spec server_name_leaves_room?(String.t()) :: boolean()
  def server_name_leaves_room?(server_name) when is_binary(server_name),
    do: @max_user_id_bytes - 2 - byte_size(server_name) >= @min_localpart_room_bytes

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

  The id is at most 255 bytes (Matrix appendix "Identifier length limits", story `event-size-limit`, D12).

  This is a shape check only — it does not verify the user exists. Callers that need
  default-deny on attacker-influenced input (e.g. the admin add-member path) MUST run
  this BEFORE any write so a malformed id never reaches the membership write path.
  """
  @spec valid?(term()) :: boolean()
  def valid?(user_id) when is_binary(user_id),
    do: byte_size(user_id) <= @max_user_id_bytes and valid_shape?(user_id)

  def valid?(_), do: false

  @doc """
  The grammar of `valid?/1` WITHOUT the 255-byte bound. Only for REMOVAL and teardown of a stored id: an account created before
  the ids were bounded (story `event-size-limit`, D12) can hold an id above 255 bytes, which an Admin must still be able to
  remove from a room. Creation and invitations use the strict `valid?/1`. Power-level `users` keys (story power-levels-enforcement):
  strict in a client-mode change, EXCEPT an entry unchanged from the stored content; the relaxed grammar (this one, plus an optional
  server-name port) for every key of the internal writer (the creator / upgrader / invitee ids the server chose).
  """
  @spec valid_shape?(term()) :: boolean()
  def valid_shape?(user_id) when is_binary(user_id), do: Regex.match?(@user_id_regex, user_id)
  def valid_shape?(_), do: false

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
