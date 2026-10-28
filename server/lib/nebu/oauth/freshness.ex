defmodule Nebu.OAuth.Freshness do
  @moduledoc """
  The ONE rule for "when did the user last sign in at the IdP" (epic oauth-broker, story
  oauth-authorize-freshness, ADR-033 FR2). Extracted from `Nebu.OAuth.Account` (story 6, A7) and shared
  by the authorize callback (the consent page's `login_fresh` verdict and the stored `auth_time`) and
  the account page's sign-in (fail closed, FR14).

  Pure: no I/O, never logs, never raises.

    * `auth_time/1` reads the `auth_time` claim ONLY: an integer as is, a float truncated; everything
      else (a string, `nil`, a missing claim, a list, a boolean, a non-map) counts as ABSENT (`nil`).
      `iat` / `exp` are never a substitute: an id_token proves ISSUANCE, not that the user just signed
      in (a silent IdP session mints a fresh id_token for an old login).
    * `evaluate/2` compares it with the time the login was requested (the authorization request's /
      login request's `created_at`): `{:fresh, min(t, now)}` when `t >= requested_at - 60` (the 60 s
      clock skew; a FUTURE value, i.e. an IdP clock that runs ahead, is clamped to now so the session
      never stays "fresh" longer than the re-authentication window), `{:stale, t}` when older,
      `:absent` for `nil`.
  """

  # clock skew between Nebu and the IdP, in seconds
  @skew_seconds 60

  @doc "The `auth_time` claim of `claims` as unix seconds, or `nil` when it is absent or not a number."
  @spec auth_time(term()) :: integer() | nil
  def auth_time(%{"auth_time" => t}) when is_integer(t), do: t
  def auth_time(%{"auth_time" => t}) when is_float(t), do: trunc(t)
  def auth_time(_claims), do: nil

  @doc """
  `{:fresh, clamped_auth_time}` | `{:stale, auth_time}` | `:absent`. `requested_at` is the unix time the
  login was requested.
  """
  @spec evaluate(integer() | nil, integer()) :: {:fresh, integer()} | {:stale, integer()} | :absent
  def evaluate(auth_time, requested_at) when is_integer(auth_time) and is_integer(requested_at) do
    if auth_time >= requested_at - @skew_seconds,
      do: {:fresh, min(auth_time, System.system_time(:second))},
      else: {:stale, auth_time}
  end

  def evaluate(_auth_time, _requested_at), do: :absent
end
