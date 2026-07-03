defmodule Nebu.Admin.ConfigController do
  @moduledoc """
  HTTP controller for Admin Configuration page (admin-http-refactor story).

  Replaces Nebu.Admin.ConfigLive. GET /admin/config renders the config overview.
  POST /admin/config/refresh-mode updates the OIDC refresh mode (offline|online)
  for BOTH the Matrix and admin clients — mirroring the bootstrap-wizard contract
  (story oidc-refresh-mode-config, AC5/AC6). Each key is validated independently;
  only valid (offline|online) values are persisted.

  ADR-018: DB helpers inline, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  # server_config keys this page may write, with their valid value set.
  @refresh_mode_keys ["matrix_oidc_refresh_mode", "admin_oidc_refresh_mode"]
  @valid_modes ["offline", "online"]
  @scope_keys ["matrix_oidc_extra_scopes", "admin_oidc_extra_scopes"]

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

  def save_refresh_mode(conn, params) do
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
        case persist(changes) do
          :ok ->
            conn
            |> put_flash(:info, "Configuration saved")
            |> redirect(to: "/admin/config")

          _ ->
            conn
            |> put_flash(:error, "Failed to save configuration")
            |> redirect(to: "/admin/config")
        end
    end
  end

  def save_scopes(conn, params) do
    # Story centralize-scope-resolution (AC5): validate each submitted scope key via
    # the ONE validator (Nebu.Web.OidcScopes.validate_scope_string/1) instead of a
    # local regex copy.
    errors =
      @scope_keys
      |> Enum.flat_map(fn key ->
        value = params[key] || ""

        case Nebu.Web.OidcScopes.validate_scope_string(value) do
          :ok -> []
          {:error, msg} -> [msg]
        end
      end)

    if errors == [] do
      changes =
        @scope_keys
        |> Map.new(fn key ->
          raw = String.trim(params[key] || "")
          {key, raw}
        end)

      case persist_scopes(changes) do
        :ok ->
          conn
          |> put_flash(:info, "Scopes saved")
          |> redirect(to: "/admin/config")

        _ ->
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

  # Story fix-and-configure-sso-redirect-schemes (AC5/AC9): validates + persists the
  # `sso_extra_redirect_schemes` server_config key. Mirrors save_scopes/2 exactly:
  # server-side validation BEFORE any DB write; on failure, HTTP 200 re-render with
  # a flash error (no redirect, no persistence); on success, upsert + flash + redirect.
  def save_sso_schemes(conn, params) do
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

        case persist_sso_schemes(changes) do
          :ok ->
            conn
            |> put_flash(:info, "SSO schemes saved")
            |> redirect(to: "/admin/config")

          _ ->
            conn
            |> put_flash(:error, "Failed to save SSO schemes")
            |> redirect(to: "/admin/config")
        end

      {:error, msg} ->
        conn
        |> put_status(200)
        |> put_flash(:error, msg)
        |> render_config()
    end
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

  defp persist_sso_schemes(changes) do
    case Application.get_env(:nebu_http, :admin_config_sso_schemes_writer) do
      writer when is_function(writer, 1) ->
        writer.(changes)

      _ ->
        if Process.whereis(Nebu.Repo) do
          Nebu.Admin.DB.upsert_server_config(changes)
        else
          {:error, :no_repo}
        end
    end
  end

  # Persist via the injectable writer seam (tests) or the DB (runtime).
  defp persist(changes) do
    case Application.get_env(:nebu_http, :admin_config_refresh_mode_writer) do
      writer when is_function(writer, 1) ->
        writer.(changes)

      _ ->
        if Process.whereis(Nebu.Repo) do
          Nebu.Admin.DB.upsert_server_config(changes)
        else
          {:error, :no_repo}
        end
    end
  end

  defp persist_scopes(changes) do
    case Application.get_env(:nebu_http, :admin_config_scopes_writer) do
      writer when is_function(writer, 1) ->
        writer.(changes)

      _ ->
        if Process.whereis(Nebu.Repo) do
          Nebu.Admin.DB.upsert_server_config(changes)
        else
          {:error, :no_repo}
        end
    end
  end

  defp render_config(conn) do
    conn
    |> assign(:config, load_config())
    |> assign(:page_title, "Configuration")
    |> assign(:active_nav, "config")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  defp load_config do
    case Application.get_env(:nebu_http, :admin_server_config_reader) do
      reader when is_function(reader, 0) ->
        case reader.() do
          {:ok, cfg} -> Enum.sort(cfg)
          _ -> []
        end

      _ ->
        case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
          {:ok, cfg} -> Enum.sort(cfg)
          _ -> []
        end
    end
  end

end
