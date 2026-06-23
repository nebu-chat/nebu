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
  # deriving an id from a claim) and the domain is a non-empty server name. We are
  # deliberately strict but not a full RFC server-name parser: a non-empty domain with
  # no whitespace is sufficient to reject the malformed ids this validation guards
  # against (story rm4 AC5 — admin add of an unknown/garbage id).
  @user_id_regex ~r/^@[a-z0-9._=\-\/+]+:[^\s:]+$/

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
