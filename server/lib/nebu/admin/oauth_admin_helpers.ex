defmodule Nebu.Admin.OAuthAdminHelpers do
  @moduledoc """
  The pieces the two OAuth admin controllers share (story oauth-client-revocation): `Nebu.Admin.OAuthRegistrationsController`
  (approve / reject / bulk removal) and `Nebu.Admin.OAuthClientsController` (approved / revoked lists, revoke).

    * `gate/3` — the order of checks of the state-changing actions: (`require_admin` and the Phoenix CSRF check
      already ran) -> STRICT fetch metadata (all four headers of a user-clicked form submit, every action:
      approve, revoke, reject, bulk removal; Safari / WebKit never sends `Sec-Fetch-User` and passes with the click proof
      `_click_proof=1` instead, see `Nebu.OAuth.BrowserPost`) -> for `:marker` the fresh re-authentication marker, bound
      to the confirm page of the action (approve and revoke only). A refusal is a `403` page (`data-error="fetch_metadata"`,
      a value-free WARNING that names the failed header NAMES only) or a redirect to the re-authentication start
      with the confirm page as return target; a WebKit request without the proof gets a `200` NOTICE page
      (`data-page="oauth-activation-unproven"`: press the button again; the marker is not consumed). Nothing is changed
      and nothing is audited in any of these cases.
    * `write_audit/4` — one compliance audit row through the `:compliance, :audit_writer` seam; never the client
      metadata.
    * `actor_id/1`, `error_type/1`.

  Since story admin-config-privileged-forms-sweep (ADR-033 SO10) the same gate protects the privileged forms under `/admin/config*`: the SSO trust
  lists, the OAuth switch, the claim mapping and the role mapping (`:marker`, each bound to its page) and the OIDC scopes / refresh mode (`:click`);
  `save_config_audited/3` saves their value and audit row in one transaction (story admin-config-audit-atomic).

  Story admin-forms-gate-sweep: `click_gate/2` is the controller plug of every other admin form post (level `:click`), `back_path/1` names the page its refusal links back to,
  `save_config_audited/3` / `subset?/4` serve the privileged config saves.

  ADR-020: the OAuth domain is reached only through `Nebu.OAuth` (the fetch-metadata rules are the single copy of
  `Nebu.OAuth.BrowserPost`, delegated by `Nebu.OAuth.check_fetch_metadata/2`).
  """
  import Plug.Conn

  require Logger

  alias Nebu.Admin.Auth

  @doc """
  Strict fetch metadata and, for `:marker`, the fresh re-authentication marker bound to `confirm_path`. `level`:
  `:marker` (approve, revoke) or `:click` (reject, bulk removal: no marker). `{:ok, conn, reauth_kind}` (`"auth_time"`
  | `"flow"` for `:marker`, `nil` for `:click`) or `{:halt, conn}` with the response already sent. `confirm_path` is
  where the admin returns after a fresh sign-in and the target of the back link of the refusal page.
  """
  @spec gate(Plug.Conn.t(), :marker | :click, String.t()) :: {:ok, Plug.Conn.t(), String.t() | nil} | {:halt, Plug.Conn.t()}
  def gate(conn, level, confirm_path) when level in [:marker, :click] do
    case Nebu.OAuth.check_fetch_metadata(conn, :strict, conn.body_params) do
      :ok ->
        if level == :marker, do: marker(conn, confirm_path), else: {:ok, conn, nil}

      :unproven ->
        # Safari / WebKit (no `Sec-Fetch-User`) without the click proof: a notice, nothing is changed, the marker stays
        Logger.warning("admin: request not carried out, the click proof of a user-clicked form submit is missing (browser without Sec-Fetch-User, script blocked or stale page)")

        {:halt, unproven(conn, confirm_path)}

      {:refused, names} ->
        Logger.warning("admin: request refused, the fetch metadata headers of the browser are not those of a user-clicked form submit: #{Enum.join(names, ",")}")

        {:halt, forbidden(conn, confirm_path)}
    end
  end

  defp marker(conn, confirm_path) do
    case Auth.reauth_fresh(conn, confirm_path) do
      {:ok, kind} ->
        {:ok, conn, kind}

      :stale ->
        {:halt,
         conn
         |> Phoenix.Controller.redirect(to: Auth.reauth_start_path(confirm_path))
         |> halt()}
    end
  end

  @doc """
  A controller plug for the admin forms that need the strict fetch metadata only (level `:click`, story admin-forms-gate-sweep D1): `plug :click_gate` in the
  controller, after `plug Nebu.Admin.Auth, :require_admin` (the Phoenix CSRF check ran in the router pipeline). The refusal / notice pages link back to
  `back_path/1` of the request.
  """
  @spec click_gate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def click_gate(conn, _opts) do
    case gate(conn, :click, back_path("/" <> Enum.join(conn.path_info, "/"))) do
      {:ok, conn, _kind} -> conn
      {:halt, conn} -> conn
    end
  end

  @plain_segment ~r/\A[A-Za-z0-9%._~!$&'()*+,;=:@-]{1,300}\z/

  @doc """
  The page a gated admin form lives on, from the request path of its post (the back link of the refusal page, the sidebar entry): a room / space / user
  page for the actions of one object, the list for the list-level toggles and the create forms, the settings pages. An id that is not a plain path segment
  falls back to the list; never anything outside `/admin/`.
  """
  @spec back_path(String.t()) :: String.t()
  def back_path(request_path) when is_binary(request_path) do
    case String.split(request_path, "/") do
      ["", "admin", "rooms"] -> "/admin/rooms/new"
      ["", "admin", "rooms", _id, "auto-join"] -> "/admin/rooms"
      ["", "admin", "rooms", id | _] -> object_page("/admin/rooms", id)
      ["", "admin", "spaces"] -> "/admin/spaces"
      ["", "admin", "spaces", _id, "auto-join"] -> "/admin/spaces"
      ["", "admin", "spaces", id | _] -> object_page("/admin/spaces", id)
      ["", "admin", "users", id | _] -> object_page("/admin/users", id)
      ["", "admin", "logs", "config" | _] -> "/admin/logs/config"
      ["", "admin", "media", "settings" | _] -> "/admin/media/settings"
      _ -> "/admin/dashboard"
    end
  end

  defp object_page(list, id) do
    down = String.downcase(id)

    if Regex.match?(@plain_segment, id) and not String.contains?(down, ["%2f", "%5c", "%2e", ".."]), do: list <> "/" <> id, else: list
  end

  # the sidebar entry of the page the admin came from (a child key, never the parent button)
  defp nav_for("/admin/config"), do: "config-general"
  defp nav_for("/admin/rooms" <> _), do: "rooms"
  defp nav_for("/admin/spaces" <> _), do: "spaces"
  defp nav_for("/admin/users" <> _), do: "users"
  defp nav_for("/admin/logs/config" <> _), do: "logs-config"
  defp nav_for("/admin/media/settings" <> _), do: "media-settings"
  defp nav_for("/admin/dashboard"), do: "dashboard"
  defp nav_for("/admin/config/claim-mapping"), do: "claim-mapping"
  defp nav_for("/admin/config/role-mapping"), do: "role-mapping"
  defp nav_for(path), do: if(String.ends_with?(path, "/revoke"), do: "oauth-approved-clients", else: "oauth-pending-clients")

  # 200 notice page (not an error): same shell, no-store / no-framing headers of the OAuth admin pages come from the router
  defp unproven(conn, back_path) do
    conn
    |> put_status(200)
    |> Phoenix.Controller.put_view(html: Nebu.Admin.OAuthClientsHTML)
    |> Phoenix.Controller.put_layout(html: {Nebu.Admin.Layouts, :live})
    |> assign(:page_title, "Action not carried out")
    |> assign(:active_nav, nav_for(back_path))
    |> assign(:bootstrap_completed, true)
    |> assign(:back_path, back_path)
    |> Phoenix.Controller.render(:activation_unproven)
    |> halt()
  end

  # 403 page, rendered inside the admin shell; the back link names the page the admin came from (a confirm page or a list)
  defp forbidden(conn, back_path) do
    conn
    |> put_status(403)
    |> Phoenix.Controller.put_view(html: Nebu.Admin.OAuthClientsHTML)
    |> Phoenix.Controller.put_layout(html: {Nebu.Admin.Layouts, :live})
    |> assign(:page_title, "Request refused")
    |> assign(:active_nav, nav_for(back_path))
    |> assign(:bootstrap_completed, true)
    |> assign(:back_path, back_path)
    |> Phoenix.Controller.render(:fetch_metadata)
    |> halt()
  end

  @doc """
  Story admin-reauth-button-flow: assigns `:reauth` = `%{fresh?, minutes, href}` for the marker-gated form(s) bound to `path`, the SAME page path the
  form's `gate(conn, :marker, path)` checks. Every render path of such a page (GET and each re-render) must pipe through this, so the primary control
  shows the "Sign in again" link or the submit button as the marker is NOW. `href` is built from the server side `path` only.
  """
  @spec assign_reauth(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def assign_reauth(conn, path) do
    href = Auth.reauth_start_path(path)

    case Auth.reauth_remaining_minutes(conn, path) do
      {:ok, minutes} -> assign(conn, :reauth, %{fresh?: true, minutes: minutes, href: href})
      :stale -> assign(conn, :reauth, %{fresh?: false, minutes: nil, href: href})
    end
  end

  @doc "The Matrix user id (else the `sub`) of the signed-in admin, or nil."
  @spec actor_id(Plug.Conn.t()) :: String.t() | nil
  def actor_id(conn) do
    case conn.assigns[:current_user] do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) and sub != "" -> sub
      _ -> nil
    end
  end

  @doc "One audit row (`target_type` `oauth_client`, outcome `success`) through the audit writer seam: `:ok | {:error, reason}`; a raising writer is an error."
  @spec write_audit(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def write_audit(actor, action, target_id, metadata) do
    case audit_writer().log(actor, action, "oauth_client", target_id, metadata, "success", nil) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    e -> {:error, {:raised, e.__struct__}}
  end

  @doc """
  One audit row for a `server_config` change (`target_type` `server_config`, outcome `success`) through the audit writer seam:
  `:ok | {:error, reason}`; a raising writer is an error. Used inside the transaction of `Nebu.OAuth.save_switch/2`.
  """
  @spec write_config_audit(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def write_config_audit(actor, action, target_id, metadata) do
    case audit_writer().log(actor, action, "server_config", target_id, metadata, "success", nil) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    e -> {:error, {:raised, e.__struct__}}
  end

  @doc """
  Saves the `server_config` keys of a PRIVILEGED admin form and its audit row in ONE transaction (story admin-config-audit-atomic, follow-up `dh`;
  `Nebu.Admin.DB.save_config_audited/2`). Options: `:action` (the `@known_actions` entry), `:target_id`, `:metadata` (the new values only), `:label`
  (a fixed text for the log), `:form` (an atom naming the form: the log line and the test seams), `:unaudited_ok` (the change is a way back: it is applied even when the
  audit row cannot be written) and `:narrowing` (a 1-arity function of the stored values of the changed keys that re-checks `unaudited_ok` inside the transaction of the retry, under a row lock). Actor = the admin's Matrix id (else the `sub`), a missing actor is a failed audit.

  `{:ok, :audited}`, `{:ok, :unaudited}` (applied without its row: tell the admin), `{:error, :audit}` (NOT saved because the row could not be
  written) or `{:error, :db}` (not saved). Every failure logs ONE value-free ERROR naming `label` and the error type, never a value or the actor.
  """
  @spec save_config_audited(Plug.Conn.t(), %{String.t() => String.t()}, keyword()) :: {:ok, :audited | :unaudited} | {:error, :audit | :db}
  def save_config_audited(conn, changes, opts) do
    actor = actor_id(conn)
    label = Keyword.fetch!(opts, :label)

    audit = fn ->
      if is_binary(actor) do
        write_config_audit(actor, Keyword.fetch!(opts, :action), Keyword.fetch!(opts, :target_id), Keyword.fetch!(opts, :metadata))
      else
        {:error, :no_actor}
      end
    end

    case Nebu.Admin.DB.save_config_audited(changes, audit: audit, unaudited_ok: Keyword.get(opts, :unaudited_ok, false), form: Keyword.get(opts, :form), narrowing: Keyword.get(opts, :narrowing)) do
      {:ok, %{audited: true}} ->
        {:ok, :audited}

      {:ok, %{audited: false}} ->
        {:ok, :unaudited}

      {:error, {:audit, _reason}} ->
        Logger.error("admin: the #{label} change was not saved, its audit row could not be written")
        {:error, :audit}

      {:error, reason} ->
        Logger.error("admin: the #{label} change could not be saved: #{error_type(reason)}")
        {:error, :db}
    end
  end

  @doc "The flash of a save that was REFUSED because its audit row could not be written (nothing was changed)."
  @spec audit_refused_flash(String.t()) :: String.t()
  def audit_refused_flash(what),
    do: "#{what} not saved: the audit entry could not be written, so nothing was changed. Try again; if it persists, ask the operator to check the database and the server log."

  @doc "The flash of a roll-back path that was applied although its audit row could not be written."
  @spec unaudited_flash(String.t()) :: String.t()
  def unaudited_flash(what),
    do: "#{what} saved, but the audit entry could not be written (it is missing from the Audit Log). Ask the operator to check the database and the server log."

  @doc """
  True when every token of `new` is a token of `stored` (a narrowing, the empty value included: the way back of a list). `separator` `:comma` or
  `:space`; `downcase: true` compares case-insensitively. A `stored` value that is not text counts as the empty set.
  """
  @spec subset?(term(), term(), :comma | :space, keyword()) :: boolean()
  def subset?(new, stored, separator, opts \\ []) do
    tokens = fn
      v when is_binary(v) ->
        v
        |> String.split(if(separator == :comma, do: ",", else: ~r/\s+/))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&if(Keyword.get(opts, :downcase, false), do: String.downcase(&1), else: &1))

      _ ->
        []
    end

    MapSet.subset?(MapSet.new(tokens.(new)), MapSet.new(tokens.(stored)))
  end

  defp audit_writer, do: Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

  @doc "A log-safe description of an error: SQLSTATE / struct / atom only, never a message, a row or a reason text."
  @spec error_type(term()) :: String.t()
  def error_type(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  def error_type(%{__struct__: struct}), do: inspect(struct)
  def error_type(reason) when is_atom(reason), do: inspect(reason)
  def error_type({tag, _detail}) when is_atom(tag), do: inspect(tag)
  def error_type(_reason), do: "unexpected error"

  @doc "`Client \"<name>\"` (shortened), or `Client <id>` when unnamed. HEEx escapes the flash text."
  @spec client_label(map() | nil, String.t()) :: String.t()
  def client_label(%{metadata: %{"client_name" => name}}, _client_id) when is_binary(name) and name != "",
    do: "Client \"#{String.slice(name, 0, 60)}#{if String.length(name) > 60, do: "…"}\""

  def client_label(_registration, client_id), do: "Client #{client_id}"

  @doc "Percent-encoded client id for a path segment."
  @spec seg(String.t()) :: String.t()
  def seg(client_id), do: URI.encode(client_id, &URI.char_unreserved?(&1))
end
