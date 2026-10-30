defmodule Nebu.Admin.ConfigController do
  @moduledoc """
  HTTP controller for Admin Configuration page (admin-http-refactor story).

  Replaces Nebu.Admin.ConfigLive. GET /admin/config renders the config overview.
  POST /admin/config/refresh-mode updates the OIDC refresh mode (offline|online)
  for BOTH the Matrix and admin clients — mirroring the bootstrap-wizard contract
  (story oidc-refresh-mode-config, AC5/AC6). Each key is validated independently;
  only valid (offline|online) values are persisted.

  POST /admin/config/oauth-switch saves the OAuth 2.0 authorization server switch (`oauth_enabled`, `oauth_issuer_url`;
  story admin-oauth-switch): the same protection as the SSO trust lists, an activation acknowledgement and one audit row.

  Story admin-config-privileged-forms-sweep (ADR-033 SO10): every POST of this page is behind `Nebu.Admin.OAuthAdminHelpers.gate/3`:
  the SSO trust lists and the OAuth switch with a fresh sign-in (`:marker`), the OIDC scopes and the refresh mode with strict fetch metadata
  only (`:click`: the fresh sign-in would use the very scopes the form changes). All forms read the BODY parameters (never a query string).

  Story admin-config-audit-atomic (follow-up `dh`): the SSO trust lists, the scopes and the refresh mode save their value and audit row in ONE transaction through
  `Nebu.Admin.OAuthAdminHelpers.save_config_audited/3` (a widening is refused when the row cannot be written, a narrowing / clearing and the refresh mode are the
  way back and are applied without it, ADR-033 SO10 addendum).

  ADR-018: DB helpers inline, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn
  require Logger

  plug Nebu.Admin.Auth, :require_admin

  alias Nebu.Admin.OAuthAdminHelpers, as: H

  # server_config keys this page may write, with their valid value set.
  @refresh_mode_keys ["matrix_oidc_refresh_mode", "admin_oidc_refresh_mode"]
  @valid_modes ["offline", "online"]
  @scope_keys ["matrix_oidc_extra_scopes", "admin_oidc_extra_scopes"]

  # the page the fresh re-authentication marker of the two SSO trust forms is bound to (and where the admin returns)
  @config_path "/admin/config"

  # Story fix-and-configure-sso-redirect-schemes (AC5/AC9): RFC 3986 scheme-token
  # syntax. The denylist itself is NOT duplicated here — it is read via
  # Nebu.Matrix.SsoLogin.scheme_denylist/0, the single source of truth also
  # enforced at request-time by redirect_url_allowed?/1 (ADR-018/ADR-021).
  #
  # Anchored with \z, NOT $ — established rule since the configurable-oidc-scopes
  # security review (see Nebu.Web.OidcScopes.@scope_regex): PCRE $ matches
  # immediately before a trailing "\n", so a $-anchored whitelist regex lets a
  # string like "element\n" through even though it contains a control character.
  # \z only matches the true end of the string. Every input-whitelist regex in
  # this codebase must use \z.
  @scheme_regex ~r/^[a-zA-Z][a-zA-Z0-9+.-]*\z/

  def index(conn, _params) do
    render_config(conn)
  end

  # Story admin-config-privileged-forms-sweep (cw): strict fetch metadata (incl. the Safari click proof), NO fresh sign-in: the sign-in
  # would use the very scopes / refresh mode these forms change, a wrong value would lock the admin out of the sign-in needed to correct it.
  def save_refresh_mode(conn, _params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :click, @config_path) do
      do_save_refresh_mode(conn, conn.body_params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_save_refresh_mode(conn, params) do
    # Collect only the keys present in the form whose value is valid (offline|online).
    # A garbage value for a key is silently dropped — it is never persisted.
    changes =
      @refresh_mode_keys
      |> Enum.filter(fn key -> params[key] in @valid_modes end)
      |> Map.new(fn key -> {key, params[key]} end)

    cond do
      changes == %{} ->
        # Nothing valid to save — re-render (200) without touching the DB.
        conn
        |> put_status(200)
        |> render_config()

      true ->
        # refresh mode: "offline" adds offline_access (a refresh token that outlives the user's IdP session, SEC review L-2), "online" is the way out of a
        # sign-in lock-out: a change is applied without its audit row only when every changed key goes to "online" or stays as stored (story
        # admin-config-audit-atomic, D2)
        stored = Map.new(load_config())
        way_back? = fn stored_values -> Enum.all?(changes, fn {key, value} -> value == "online" or value == stored_values[key] end) end

        result =
          H.save_config_audited(conn, changes,
            action: "oidc_refresh_mode_changed",
            target_id: "oidc_refresh_mode",
            metadata: changes,
            label: "OIDC refresh mode",
            form: :refresh_mode,
            unaudited_ok: way_back?.(stored),
            narrowing: way_back?
          )

        case result do
          {:ok, :audited} ->
            conn
            |> put_flash(:info, "Configuration saved")
            |> redirect(to: "/admin/config")

          {:ok, :unaudited} ->
            conn
            |> put_flash(:error, H.unaudited_flash("Configuration"))
            |> redirect(to: "/admin/config")

          {:error, :audit} ->
            conn
            |> put_flash(:error, H.audit_refused_flash("Configuration"))
            |> redirect(to: "/admin/config")

          {:error, :db} ->
            conn
            |> put_flash(:error, "Failed to save configuration")
            |> redirect(to: "/admin/config")
        end
    end
  end

  def save_scopes(conn, _params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :click, @config_path) do
      do_save_scopes(conn, conn.body_params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_save_scopes(conn, params) do
    # Story centralize-scope-resolution (AC5): validate each submitted scope key via
    # the ONE validator (Nebu.Web.OidcScopes.validate_scope_string/1) instead of a
    # local regex copy.
    errors =
      @scope_keys
      |> Enum.flat_map(fn key ->
        case scope_text(params[key]) do
          {:ok, value} ->
            case Nebu.Web.OidcScopes.validate_scope_string(value) do
              :ok -> []
              {:error, msg} -> [msg]
            end

          :error ->
            ["Scope values must be text."]
        end
      end)

    if errors == [] do
      changes =
        @scope_keys
        |> Map.new(fn key ->
          {:ok, raw} = scope_text(params[key])
          {key, String.trim(raw)}
        end)

      # scopes widen the claim set: the audit row is mandatory unless every changed key narrows (a clear included: the way out of a scope that
      # breaks the IdP sign-in), story admin-config-audit-atomic D2
      narrowing? = fn stored_values -> Enum.all?(changes, fn {key, value} -> H.subset?(value, stored_values[key], :space) end) end
      unaudited_ok = narrowing?.(Map.new(load_config()))

      result =
        H.save_config_audited(conn, changes,
          action: "oidc_scopes_changed",
          target_id: "oidc_extra_scopes",
          metadata: changes,
          label: "OIDC scopes",
          form: :scopes,
          unaudited_ok: unaudited_ok,
          narrowing: narrowing?
        )

      case result do
        {:ok, :audited} ->
          conn
          |> put_flash(:info, "Scopes saved")
          |> redirect(to: "/admin/config")

        {:ok, :unaudited} ->
          conn
          |> put_flash(:error, H.unaudited_flash("Scopes"))
          |> redirect(to: "/admin/config")

        {:error, :audit} ->
          conn
          |> put_flash(:error, H.audit_refused_flash("Scopes"))
          |> redirect(to: "/admin/config")

        {:error, :db} ->
          conn
          |> put_flash(:error, "Failed to save scopes")
          |> redirect(to: "/admin/config")
      end
    else
      conn
      |> put_status(200)
      |> put_flash(:error, hd(errors))
      |> render_config()
    end
  end

  # a missing field is the empty string (it clears the scopes, as before); a list / map value (a parameter pollution shape) is an error
  defp scope_text(nil), do: {:ok, ""}
  defp scope_text(value) when is_binary(value), do: {:ok, value}
  defp scope_text(_other), do: :error

  # Story fix-and-configure-sso-redirect-schemes (AC5/AC9): validates + persists the
  # `sso_extra_redirect_schemes` server_config key. Mirrors save_scopes/2 exactly:
  # server-side validation BEFORE any DB write; on failure, HTTP 200 re-render with
  # a flash error (no redirect, no persistence); on success, upsert + flash + redirect.
  #
  # Story sso-origins-admin-hardening (X-1, AC1): the same gate as the OAuth client approval (strict fetch metadata, a
  # fresh admin re-authentication bound to /admin/config) runs BEFORE the validation; the marker is consumed after a
  # SUCCESSFUL write only.
  def save_sso_schemes(conn, _params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, @config_path) do
      do_save_sso_schemes(conn, conn.body_params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_save_sso_schemes(conn, params) do
    value = params["sso_extra_redirect_schemes"] || ""

    case validate_sso_schemes(value) do
      :ok ->
        # Persist the NORMALIZED form (each token individually trimmed, rejoined
        # with ", "), not just String.trim/1 on the raw outer string — otherwise
        # interior whitespace/newlines between tokens (e.g. "element\n, app ")
        # survive into server_config verbatim even though validate_sso_schemes/1
        # validated the trimmed tokens. extra_redirect_schemes/0 re-trims on read
        # so this was never a security bypass, but the stored/displayed value
        # must match what the operator actually validated (AC4; code-review finding).
        normalized =
          if value == "" do
            ""
          else
            value
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.join(", ")
          end

        changes = %{"sso_extra_redirect_schemes" => normalized}

        count = if normalized == "", do: 0, else: normalized |> String.split(", ") |> length()
        narrowing? = fn stored_values -> H.subset?(normalized, readable_schemes(stored_values["sso_extra_redirect_schemes"]), :comma, downcase: true) end

        # the scheme list is a redirect sink for the loginToken: a widening needs its audit row (Y-5), a subset (narrowing, clearing) is the way back
        result =
          H.save_config_audited(conn, changes,
            action: "sso_redirect_schemes_changed",
            target_id: "sso_extra_redirect_schemes",
            metadata: %{"schemes" => normalized, "count" => count},
            label: "SSO redirect schemes",
            form: :sso_schemes,
            unaudited_ok: narrowing?.(Map.new(load_config())),
            narrowing: narrowing?
          )

        trust_list_result(conn, result, "SSO schemes")

      {:error, msg} ->
        conn
        |> put_status(200)
        |> put_flash(:error, msg)
        |> render_config()
    end
  end

  # Story legacy-sso-redirect-confirmation (G3-3, D14, AC14): validates + persists the operator list of https
  # origins whose legacy SSO logins skip the confirmation page (`sso_redirect_allowed_origins`). Mirrors
  # save_sso_schemes/2: validation (through the Matrix facade, the single implementation) BEFORE any write; on
  # failure HTTP 200 re-render with a flash error and nothing persisted; on success the NORMALIZED string is
  # persisted (`Nebu.Admin.DB.save_config_audited/2` writes the value and its audit row in one transaction and refreshes the OidcConfig cache cluster-wide after the commit).
  #
  # Story sso-origins-admin-hardening (X-1, AC1): gated like save_sso_schemes/2 (strict fetch metadata, then the fresh
  # re-authentication marker bound to /admin/config), before the validation; consumed after a successful write only.
  def save_sso_origins(conn, _params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, @config_path) do
      do_save_sso_origins(conn, conn.body_params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_save_sso_origins(conn, params) do
    submitted = params["sso_redirect_allowed_origins"] || ""

    case Nebu.Matrix.normalize_sso_redirect_origins(submitted) do
      {:ok, normalized} ->
        count = if normalized == "", do: 0, else: normalized |> String.split(", ") |> length()
        narrowing? = fn stored_values -> H.subset?(normalized, readable_origins(stored_values["sso_redirect_allowed_origins"]), :comma, downcase: true) end

        result =
          H.save_config_audited(conn, %{"sso_redirect_allowed_origins" => normalized},
            action: "sso_redirect_origins_changed",
            target_id: "sso_redirect_allowed_origins",
            metadata: %{"origins" => normalized, "count" => count},
            label: "SSO redirect origins",
            form: :sso_origins,
            unaudited_ok: narrowing?.(Map.new(load_config())),
            narrowing: narrowing?
          )

        trust_list_result(conn, result, "SSO origins")

      {:error, msg} ->
        # UX N10: keep the submitted text in the field and show the error under it (aria-invalid / role=alert)
        conn
        |> put_status(200)
        |> put_flash(:error, msg)
        |> assign(:sso_origins_submitted, if(is_binary(submitted), do: submitted, else: ""))
        |> assign(:sso_origins_error, msg)
        |> render_config()
    end
  end

  # The stored lists as the runtime reads them (SEC review L-1): a stored value that the validator would refuse as a whole (a dead token written by hand or
  # by an older writer) counts as the empty set, so a "narrowing" can never activate a token the runtime never trusted (fail closed).
  defp readable_origins(stored) when is_binary(stored) do
    case Nebu.Matrix.normalize_sso_redirect_origins(stored) do
      {:ok, normalized} -> normalized
      _ -> ""
    end
  end

  defp readable_origins(_other), do: ""

  defp readable_schemes(stored) when is_binary(stored), do: if(validate_sso_schemes(stored) == :ok, do: stored, else: "")
  defp readable_schemes(_other), do: ""

  # the answer of the two SSO trust list saves (marker forms): the marker is consumed after a write (also an unaudited one), kept after a refusal
  defp trust_list_result(conn, result, what) do
    case result do
      {:ok, :audited} ->
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(:info, "#{what} saved")
        |> redirect(to: @config_path)

      {:ok, :unaudited} ->
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(:error, H.unaudited_flash(what))
        |> redirect(to: @config_path)

      {:error, :audit} ->
        conn
        |> put_flash(:error, H.audit_refused_flash(what))
        |> redirect(to: @config_path)

      {:error, :db} ->
        conn
        |> put_flash(:error, "Failed to save #{what}")
        |> redirect(to: @config_path)
    end
  end

  # Story admin-oauth-switch (AS1 - AS12): the OAuth 2.0 authorization server switch (`oauth_enabled`, `oauth_issuer_url`).
  # The same gate as the two SSO trust forms (strict fetch metadata incl. the Safari click proof, then a fresh admin
  # re-authentication marker bound to /admin/config; both BEFORE anything is validated or written), then validation
  # (`Nebu.Admin.OAuthSwitch.validate/2`: the runtime's issuer function, the activation acknowledgement), then ONE transaction
  # (`Nebu.OAuth.save_switch/2`: both upserts and the audit row together). The marker is consumed after a SUCCESSFUL write only.
  # The audit asymmetry: a change that leaves the switch ON needs its audit row (else nothing is saved), a change to OFF is applied
  # even when the audit row cannot be written (the kill switch is never blocked), with a flash that says so.
  def save_oauth_switch(conn, params) do
    with {:ok, conn, kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, @config_path) do
      do_save_oauth_switch(conn, params, kind)
    else
      {:halt, conn} -> conn
    end
  end

  # `params` are the BODY parameters (like the click proof of the gate): a query string never carries the form (SEC L-1)
  defp do_save_oauth_switch(conn, _merged_params, reauth_kind) do
    params = conn.body_params

    stored = Nebu.Admin.OAuthSwitch.stored(load_config())

    case Nebu.Admin.OAuthSwitch.validate(params, stored) do
      {:error, errors} ->
        conn
        |> put_status(200)
        |> assign(:oauth_form, submitted_oauth_form(params))
        |> assign(:oauth_errors, errors)
        |> render_config()

      {:ok, %{changed?: false}} ->
        conn
        |> put_flash(:info, "No change: the OAuth settings already have these values.")
        |> redirect(to: "/admin/config#oauth-switch")

      {:ok, change} ->
        save_oauth_change(conn, change, reauth_kind)
    end
  end

  defp save_oauth_change(conn, change, reauth_kind) do
    actor = Nebu.Admin.OAuthAdminHelpers.actor_id(conn)
    changes = %{"oauth_enabled" => to_string(change.enabled), "oauth_issuer_url" => change.issuer}

    audit = fn ->
      if is_binary(actor) do
        Nebu.Admin.OAuthAdminHelpers.write_config_audit(actor, "oauth_switch_changed", "oauth_enabled", %{
          "enabled_before" => change.enabled_before,
          "enabled_after" => change.enabled,
          "issuer_before" => change.issuer_before,
          "issuer_after" => change.issuer,
          "reauth" => reauth_kind
        })
      else
        {:error, :no_actor}
      end
    end

    # the kill switch is never blocked by the audit: ONLY a result OFF whose issuer stays the same or is cleared is applied without its audit
    # row; setting / changing an issuer widens the legacy-SSO trust (its origin is trusted with OAuth off too) and needs its row (SEC M-1)
    unaudited_ok = not change.enabled and (change.issuer == "" or change.issuer == change.issuer_before_normalized)

    case Nebu.OAuth.save_switch(changes, audit: audit, unaudited_ok: unaudited_ok) do
      {:ok, %{audited: true}} ->
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(:info, "OAuth settings saved. " <> oauth_propagation_sentence())
        |> redirect(to: "/admin/config#oauth-switch")

      {:ok, %{audited: false}} ->
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(
          :error,
          "OAuth settings saved (switched off), but the audit entry could not be written. Check the database and the server log. " <> oauth_propagation_sentence()
        )
        |> redirect(to: "/admin/config#oauth-switch")

      {:error, {:audit, _reason}} ->
        conn
        |> put_flash(:error, "OAuth settings not saved: the audit entry could not be written, so the change was not applied. Try again; if it persists check the database and the server log.")
        |> redirect(to: "/admin/config#oauth-switch")

      {:error, reason} ->
        # value-free: the error TYPE only, never a row, the issuer or the actor
        Logger.error("admin: OAuth switch save failed: #{Nebu.Admin.OAuthAdminHelpers.error_type(reason)}")

        conn
        |> put_flash(:error, "Failed to save OAuth settings.")
        |> redirect(to: "/admin/config#oauth-switch")
    end
  end

  defp oauth_propagation_sentence do
    case Nebu.OAuth.config_cache_ms() do
      0 -> "The change takes effect on all nodes immediately."
      ms -> "The change takes effect on this node now and on all other nodes " <> Nebu.Admin.OAuthSwitch.propagation_text(ms) <> "."
    end
  end

  # the submitted values again after a rejected save (the admin corrects them instead of retyping)
  defp submitted_oauth_form(params) do
    %{
      enabled: params["oauth_enabled"] == "true",
      issuer: if(is_binary(params["oauth_issuer_url"]), do: params["oauth_issuer_url"], else: ""),
      ack: params["oauth_activation_ack"] == "true",
      suggested?: false
    }
  end

  defp default_oauth_form(cfg, env) do
    stored = Nebu.Admin.OAuthSwitch.stored(cfg)
    suggestion = if stored.issuer == "", do: Nebu.Admin.OAuthSwitch.suggested_issuer(env), else: nil

    %{enabled: stored.enabled, issuer: suggestion || stored.issuer, ack: false, suggested?: suggestion != nil}
  end

  # AC5: each comma-separated token must (a) be non-empty/non-whitespace, (b) match
  # RFC 3986 scheme syntax, (c) not case-insensitively collide with the hardcoded
  # denylist. An empty overall string is valid input (operator clearing custom
  # schemes → falls back to defaults).
  defp validate_sso_schemes(str) do
    # NOTE: split WITHOUT trim: true so a blank/whitespace-only token between two
    # commas (e.g. "a,, b" or "a,   , b") is preserved and caught below — an empty
    # overall string ("" — no commas at all) is still valid input (clears schemes).
    tokens = if str == "", do: [], else: String.split(str, ",")

    cond do
      Enum.any?(tokens, &(String.trim(&1) == "")) ->
        {:error, "Found an empty scheme. All schemes must be non-empty and valid."}

      true ->
        tokens
        |> Enum.map(&trim_space_only/1)
        |> Enum.find_value(:ok, &invalid_scheme_error/1)
    end
  end

  # Trims ONLY literal leading/trailing ASCII space and tab (cosmetic separator
  # whitespace around commas, e.g. "a, b" -> ["a", " b"] -> ["a", "b"]) — NOT
  # String.trim/1, which strips ALL Unicode whitespace including "\n"/"\r".
  # @scheme_regex is \z-anchored specifically to reject a token with an embedded
  # or trailing newline (see codebase-wide rule from the configurable-oidc-scopes
  # security review, mirrored in Nebu.Web.OidcScopes.@scope_regex); if this
  # function used String.trim/1, a token like "element\n" would have its "\n"
  # silently stripped BEFORE the regex ever sees it, defeating the \z anchor
  # entirely. Space/tab are safe to strip because @scheme_regex's character
  # class already excludes them from valid scheme syntax either way.
  defp trim_space_only(token), do: String.trim(token, " ") |> String.trim("\t")

  defp invalid_scheme_error(token) do
    cond do
      not String.match?(token, @scheme_regex) ->
        {:error,
         "Scheme '#{token}' is not a valid RFC 3986 scheme. Must start with a letter and contain only alphanumeric, plus, dash, or dot characters."}

      String.downcase(token) in Nebu.Matrix.SsoLogin.scheme_denylist() ->
        {:error, "Scheme '#{token}' is blocked. Cannot allow javascript, data, file, vbscript, or blob."}

      true ->
        nil
    end
  end

  defp render_config(conn) do
    cfg = load_config()
    env = Nebu.Admin.OAuthSwitch.current_env()

    conn
    |> assign(:config, cfg)
    |> assign(:oauth_status, Nebu.Admin.OAuthSwitch.status(cfg, env))
    |> assign(:oauth_cache_ms, env.cache_ms)
    |> then(fn conn ->
      conn
      |> assign(:oauth_form, conn.assigns[:oauth_form] || default_oauth_form(cfg, env))
      |> assign(:oauth_errors, conn.assigns[:oauth_errors] || %{})
    end)
    |> Nebu.Admin.OAuthAdminHelpers.assign_reauth(@config_path)
    |> assign(:page_title, "Configuration")
    # admin-sidebar-nesting coordination contract (UX gate V1): the parent
    # "config" key belongs to a pure disclosure <button> that never emits
    # aria-current="page" — the page must highlight the "General" CHILD so the
    # current page stays programmatically determinable (WCAG 1.3.1). The
    # parent gets its secondary accent from the child match in
    # Nebu.Admin.Layouts.nav_item/1.
    |> assign(:active_nav, "config-general")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  # Test seam `:admin_server_config_reader` (0-arity, `{:ok, map}`): compile-guarded, it exists only in test builds (follow-up `dd`).
  if Mix.env() == :test do
    defp load_config do
      case Application.get_env(:nebu_http, :admin_server_config_reader) do
        reader when is_function(reader, 0) ->
          case reader.() do
            {:ok, cfg} -> Enum.sort(cfg)
            _ -> []
          end

        _ ->
          load_config_from_db()
      end
    end
  else
    defp load_config, do: load_config_from_db()
  end

  defp load_config_from_db do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Enum.sort(cfg)
      _ -> []
    end
  end
end
