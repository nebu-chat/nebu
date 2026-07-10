defmodule Nebu.Web.OidcScopes do
  @moduledoc """
  Single source of OIDC scope resolution + validation (story
  `centralize-scope-resolution`, epic `oidc-simplification`).

  Replaces the scattered per-domain logic previously living in
  `Nebu.Matrix.SsoLogin` (`scope_list/0`, `matrix_extra_scopes/0`,
  `matrix_refresh_mode/0`) and `Nebu.Admin.Auth` (`admin_oidc_scope/0`,
  `union_scopes/2`, `admin_extra_scopes/0`, `admin_refresh_mode/0`) — including the
  Admin→Matrix facade fold (`Nebu.Matrix.matrix_oidc_extra_scopes/0`, now removed)
  that used to leak Matrix's `offline_access` into the Admin scope request.

  ## Public API

    * `resolve_scope/1` — `:matrix | :admin -> String.t()`. Returns the full,
      deduplicated, space-separated scope string: `"openid"` + operator-configured
      extra scopes + `"offline_access"` iff that client's OWN refresh mode is
      `"offline"`.
    * `resolve_scope_with_extra/2` — same composition, but the extra-scopes
      value is supplied by the caller instead of read from the reader seam /
      `server_config`. Used by bootstrap-mode admin login, whose extras live in
      the in-progress `bootstrap_draft` (see `bugfix-bootstrap-scope-ignored`).
    * `validate_scope_string/1` — the ONE scope-token validator
      (`~r/^[a-zA-Z0-9_:.\\-]+\\z/` per token, split on `" "`), replacing the two
      previously-duplicated copies in `bootstrap_controller.ex` and `admin/auth.ex`.

  ## OIDC Scopes Law (bugfix-remove-default-scopes)

  The base scope is ALWAYS `"openid"`. Extra scopes come EXCLUSIVELY from
  `server_config` (`matrix_oidc_extra_scopes` / `admin_oidc_extra_scopes`). When a
  key is absent or empty, the result is `"openid"` alone (plus `"offline_access"`
  when that client's refresh mode is `"offline"`) — NEVER a hardcoded
  `"profile"`/`"email"`/`"groups"` default.

  ## AC3 — no cross-client scope leakage

  Each client (`:matrix` | `:admin`) resolves its OWN extra scopes and its OWN
  refresh mode ONLY. There is no union/fold across clients — a value configured
  under `matrix_oidc_extra_scopes` (e.g. an operator manually adding
  `offline_access` there) never appears in the Admin scope request, and vice
  versa. `offline_access` is requested by a client exclusively via that client's
  own `*_refresh_mode` = `"offline"`.

  ## AC2 — cache (extends `Nebu.Web.OidcConfig`, no ad-hoc SQL)

  Values are read through the SAME ETS/`:pg` cache mechanism `Nebu.Web.OidcConfig`
  already uses for issuer/audience/jwks_uri (see `Nebu.Web.OidcConfig.get/0` and
  its 4 additional scope/refresh-mode keys). `OidcScopes` itself never issues its
  own `server_config` SQL query — the DB read (and the cache population/`:pg`
  broadcast on write) lives entirely in `Nebu.Web.OidcConfig`.

  ## Test seams (unchanged names/shapes — "one set of seams instead of four")

  The pre-existing per-domain reader seams migrate here as-is so the existing
  regression suites (`sso_login_scope_test.exs`, `admin_scope_mode_test.exs`, etc.)
  keep passing unmodified once `SsoLogin`/`Admin.Auth` delegate to this module:

    * `:matrix_oidc_extra_scopes_reader` — 0-arity fun, Matrix extra scopes.
    * `:matrix_oidc_refresh_mode_reader` — 0-arity fun, Matrix refresh mode.
    * `:admin_oidc_extra_scopes_reader` — 0-arity fun, Admin extra scopes.
    * `:admin_oidc_refresh_mode_reader` — 0-arity fun, Admin refresh mode.

  When unset, the default reader reads through `Nebu.Web.OidcConfig.get_scopes/0`
  (the extended ETS cache).
  """

  @scope_regex ~r/^[a-zA-Z0-9_:.\-]+\z/

  @doc """
  Resolves the full OIDC scope string for `:matrix` or `:admin`: `"openid"` plus
  that client's own configured extra scopes, plus `"offline_access"` iff that
  client's own refresh mode is `"offline"`. Deduplicated, space-separated.

  Per AC3, each client's extras/refresh-mode are read INDEPENDENTLY — there is no
  cross-client union, so `offline_access` (or any other scope) configured for one
  client never leaks into the other's request.
  """
  @spec resolve_scope(:matrix | :admin) :: String.t()
  def resolve_scope(client) when client in [:matrix, :admin] do
    compose_scope(extra_scopes(client), refresh_mode(client))
  end

  @doc """
  Same scope composition as `resolve_scope/1` (`"openid"` + extras +
  `"offline_access"` iff `client`'s refresh mode is `"offline"`), but the
  caller supplies the extra-scopes value directly instead of it being read
  from the `:{client}_oidc_extra_scopes_reader` seam / `server_config`.

  This exists for `bugfix-bootstrap-scope-ignored`: bootstrap-mode admin login
  (`Nebu.Admin.Auth.oidc_config("bootstrap")`) must resolve its extra scopes
  from the in-progress `bootstrap_draft` — `server_config`'s
  `admin_oidc_extra_scopes` key does not exist yet mid-bootstrap (it is only
  written at final bootstrap completion), so the normal seam/`server_config`
  path is unusable there. `client`'s refresh mode is still resolved via its
  normal reader (that side of scope resolution is unaffected by this bug).

  An absent/empty/blank `extra` resolves to `"openid"` alone (plus
  `"offline_access"` per the refresh-mode rule above) — the OIDC Scopes Law
  default applies exactly as it does in `resolve_scope/1`.

  SEC (Kassandra, bugfix-bootstrap-scope-ignored review): unlike `resolve_scope/1`,
  `extra` here is caller-supplied rather than read through a fixed seam/`server_config`
  boundary, so this function validates it itself (`validate_scope_string/1`, fail-closed
  to `""` on an invalid string) rather than trusting every call site to have validated
  it beforehand. Today's only caller already validates at write time
  (`bootstrap_controller.ex`'s `save_step3/2`) — this is defense-in-depth for future
  callers, not a fix for a currently-reachable bug.
  """
  @spec resolve_scope_with_extra(:matrix | :admin, String.t() | nil) :: String.t()
  def resolve_scope_with_extra(client, extra) when client in [:matrix, :admin] do
    safe_extra =
      case validate_scope_string(normalize_extra(extra)) do
        :ok -> extra
        {:error, _reason} -> ""
      end

    compose_scope(safe_extra, refresh_mode(client))
  end

  defp compose_scope(extra, mode) do
    base = ["openid"] ++ String.split(normalize_extra(extra), " ", trim: true)
    base = if mode == "offline", do: base ++ ["offline_access"], else: base

    base
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  @doc """
  Validates a space-separated scope string: every token (after splitting on `" "`,
  discarding empty tokens) must match `~r/^[a-zA-Z0-9_:.\\-]+\\z/`. `\\z` (not `$`)
  so a trailing `"\\n"` is rejected. The empty string is valid (an operator may
  configure no extra scopes at all — `"openid"`-only is a legitimate outcome).

  Returns `:ok` or `{:error, String.t()}` with a human-readable message naming the
  first offending token.
  """
  @spec validate_scope_string(String.t()) :: :ok | {:error, String.t()}
  def validate_scope_string(scope_string) when is_binary(scope_string) do
    scopes = String.split(scope_string, " ", trim: true)

    invalid = Enum.find(scopes, fn s -> not String.match?(s, @scope_regex) end)

    case invalid do
      nil ->
        :ok

      bad ->
        {:error,
         "Scope '#{bad}' contains invalid characters. Only alphanumeric, underscore, colon, period, and dash are allowed."}
    end
  end

  # ── extra scopes (per-client, seam-first, then the shared ETS cache) ─────────

  defp extra_scopes(:matrix) do
    reader =
      Application.get_env(
        :nebu_http,
        :matrix_oidc_extra_scopes_reader,
        &default_matrix_extra_scopes/0
      )

    normalize_extra(reader.())
  end

  defp extra_scopes(:admin) do
    reader =
      Application.get_env(
        :nebu_http,
        :admin_oidc_extra_scopes_reader,
        &default_admin_extra_scopes/0
      )

    normalize_extra(reader.())
  end

  defp normalize_extra(s) when is_binary(s) and s != "", do: s
  defp normalize_extra(_), do: ""

  defp default_matrix_extra_scopes, do: Nebu.Web.OidcConfig.get_scopes().matrix_oidc_extra_scopes
  defp default_admin_extra_scopes, do: Nebu.Web.OidcConfig.get_scopes().admin_oidc_extra_scopes

  # ── refresh mode (per-client, seam-first, then the shared ETS cache) ────────
  #
  # Any value other than the expected enum member collapses to that client's
  # historical default — a stray server_config value can never inject an
  # arbitrary scope. Matrix defaults to "offline" (parity with the pre-existing
  # SsoLogin behaviour); Admin defaults to "online" (parity with the pre-existing
  # Admin.Auth behaviour).

  defp refresh_mode(:matrix) do
    reader =
      Application.get_env(
        :nebu_http,
        :matrix_oidc_refresh_mode_reader,
        &default_matrix_refresh_mode/0
      )

    case reader.() do
      "online" -> "online"
      _ -> "offline"
    end
  end

  defp refresh_mode(:admin) do
    reader =
      Application.get_env(
        :nebu_http,
        :admin_oidc_refresh_mode_reader,
        &default_admin_refresh_mode/0
      )

    case reader.() do
      "offline" -> "offline"
      _ -> "online"
    end
  end

  defp default_matrix_refresh_mode, do: Nebu.Web.OidcConfig.get_scopes().matrix_oidc_refresh_mode
  defp default_admin_refresh_mode, do: Nebu.Web.OidcConfig.get_scopes().admin_oidc_refresh_mode
end
