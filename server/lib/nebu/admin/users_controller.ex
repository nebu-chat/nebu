defmodule Nebu.Admin.UsersController do
  @moduledoc """
  HTTP controller for the Admin Users page (admin-http-refactor story) and the
  per-user device-management detail page (device-management S4).

  GET /admin/users renders the user list as dead HTML. GET /admin/users/:user_id
  renders a user detail page with that user's device list (S4 AC1). Two
  state-changing POSTs manage a device, both Post-Redirect-Get:

    * POST /admin/users/:user_id/devices/:device_id/rename  → rename_device/2 (S4 AC2)
    * POST /admin/users/:user_id/devices/:device_id          → delete_device/2 (S4 AC3,
      via _method=DELETE / Plug.MethodOverride)

  The device operations are user-scoped through the `Nebu.Matrix` facade (ADR-020) —
  the Admin domain never reaches into `Nebu.Matrix.DeviceKeyStore` /
  `Session.DeviceBinding` directly. Both write an audit row (S4 AC4) through the
  `:compliance, :audit_writer` env seam (matching the project-wide audit indirection).

  ADR-018: SQL inline in the action, no domain model.
  ADR-019: Single OTP app — all code under Nebu.Admin.
  ADR-020: cross-domain calls go through Nebu.Matrix only.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  # story admin-forms-gate-sweep: the strict fetch metadata of a user-clicked form submit (Safari: the click proof) before anything is read or changed
  import Nebu.Admin.OAuthAdminHelpers, only: [click_gate: 2]
  plug :click_gate when action in [:rename_device, :delete_device]

  @sql_list_users """
  SELECT user_id, system_role, is_active, created_at
  FROM users
  ORDER BY created_at DESC, user_id
  LIMIT 500
  """

  def index(conn, _params) do
    users = load_users()

    conn
    |> assign(:users, users)
    |> assign(:page_title, "Users")
    |> assign(:active_nav, "users")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  # ── GET /admin/users/search?q=… — add-member typeahead JSON ───────────────────
  #
  # admin-add-user-autocomplete: the add-member input on the room/space detail pages is
  # a CSP-safe vanilla-JS fetch widget (no LiveView, no inline JS). It calls this action
  # with `?q=<query>` and renders the returned user_ids as a suggestion listbox.
  #
  # Security:
  #   * Behind `plug Nebu.Admin.Auth, :require_admin` (controller-wide) — anonymous
  #     callers are redirected to /admin/login (no JSON leaked).
  #   * The query is bound as a SQL PARAMETER ($1) inside `Nebu.Admin.DB.search_users/2`
  #     (no interpolation — SQLi-safe) with ILIKE-metacharacter escaping.
  #   * `Nebu.Admin.UserSuggest` enforces a >=2-char minimum (no DB hit below it) and a
  #     fixed LIMIT (enumeration / DoS guard). Not user-scoped data → no IDOR surface;
  #     it returns only public Matrix user ids, the same data the Users page lists.
  #   * Display of the returned user_ids is HTML-escaped client-side (textContent), so a
  #     crafted user_id cannot inject markup.
  def search(conn, params) do
    query = to_string(params["q"] || "")
    # Always delegate to the shared suggestion layer — it owns the >=2-char gate, the
    # LIMIT cap, and the `:admin_user_searcher` test seam. The controller adds no SQL of
    # its own (ADR-018: query logic is not duplicated here).
    users = Enum.map(Nebu.Admin.UserSuggest.search(query), &%{user_id: &1.user_id})
    json(conn, %{users: users})
  end

  # ── GET /admin/users/:user_id — per-user device detail page (S4 AC1) ──────────

  def show(conn, %{"user_id" => user_id}) do
    # Phoenix already percent-decodes path segments. URI.decode here is a no-op
    # for standard Matrix ids (localpart grammar forbids literal %). Left as-is
    # for compatibility with older calls that pass pre-encoded ids directly.
    user_id = URI.decode(user_id)
    devices = list_devices(user_id)

    conn
    |> assign(:user_id, user_id)
    |> assign(:devices, devices)
    |> assign(:page_title, user_id)
    |> assign(:active_nav, "users")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:show)
  end

  # ── POST /admin/users/:user_id/devices/:device_id/rename (S4 AC2) ─────────────

  def rename_device(conn, %{"user_id" => user_id, "device_id" => device_id} = params) do
    # Phoenix already percent-decodes path segments. URI.decode here is a no-op
    # for standard Matrix ids (localpart grammar forbids literal %). Left as-is
    # for compatibility with older calls that pass pre-encoded ids directly.
    user_id = URI.decode(user_id)
    device_id = URI.decode(device_id)
    display_name = String.trim(params["display_name"] || "")
    actor = actor_id(conn)
    redirect_path = "/admin/users/#{enc(user_id)}"

    # User-scoped facade call — always the ROUTE user_id (no IDOR — SECURITY-2).
    case do_rename_device(user_id, device_id, display_name) do
      :ok ->
        write_audit(actor, "device_renamed", device_id, user_id, "success", nil)

        conn
        |> put_flash(:info, "Device renamed")
        |> redirect(to: redirect_path)

      :error ->
        write_audit(actor, "device_renamed", device_id, user_id, "failure", "rename_failed")

        conn
        |> put_flash(:error, "Could not rename device")
        |> redirect(to: redirect_path)
    end
  end

  # ── DELETE /admin/users/:user_id/devices/:device_id (via _method=DELETE) (AC3) ─

  def delete_device(conn, %{"user_id" => user_id, "device_id" => device_id}) do
    # Phoenix already percent-decodes path segments. URI.decode here is a no-op
    # for standard Matrix ids (localpart grammar forbids literal %). Left as-is
    # for compatibility with older calls that pass pre-encoded ids directly.
    user_id = URI.decode(user_id)
    device_id = URI.decode(device_id)
    actor = actor_id(conn)
    redirect_path = "/admin/users/#{enc(user_id)}"

    # Revokes the bound session(s) + removes all key material (S3 kill-switch) in one atomic teardown,
    # always scoped to the ROUTE user_id (no IDOR — SECURITY-2). Idempotent. story
    # oauth-legacy-coexistence (C12): a failed teardown is shown as an error and audited as a
    # failure instead of crashing the controller.
    case do_delete_device(user_id, device_id) do
      :ok ->
        write_audit(actor, "device_deleted", device_id, user_id, "success", nil)

        conn
        |> put_flash(:info, "Device revoked")
        |> redirect(to: redirect_path)

      _error ->
        write_audit(actor, "device_deleted", device_id, user_id, "failure", "delete_failed")

        conn
        |> put_flash(:error, "Device could not be revoked, please try again")
        |> redirect(to: redirect_path)
    end
  end

  # ── Device seams (ADR-020 facade by default, app-env injectable for tests) ────

  defp list_devices(user_id) do
    case Application.get_env(:nebu_http, :admin_device_lister) do
      fun when is_function(fun, 1) -> fun.(user_id)
      _ -> Nebu.Matrix.list_user_devices(user_id)
    end
  end

  defp do_rename_device(user_id, device_id, display_name) do
    case Application.get_env(:nebu_http, :admin_device_renamer) do
      fun when is_function(fun, 3) -> fun.(user_id, device_id, display_name)
      _ -> Nebu.Matrix.rename_user_device(user_id, device_id, display_name)
    end
  end

  defp do_delete_device(user_id, device_id) do
    case Application.get_env(:nebu_http, :admin_device_deleter) do
      fun when is_function(fun, 2) -> fun.(user_id, device_id)
      _ -> Nebu.Matrix.delete_user_device(user_id, device_id)
    end
  end

  # ── Audit (routed through the :compliance, :audit_writer seam — INFO-1) ───────

  defp write_audit(actor, action, device_id, user_id, outcome, error_detail) do
    audit_writer().log(
      actor,
      action,
      "device",
      device_id,
      %{"user_id" => user_id},
      outcome,
      error_detail
    )
  end

  defp audit_writer do
    Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
  end

  # ── Data loading ──────────────────────────────────────────────────────────────

  defp load_users do
    case Application.get_env(:nebu_http, :admin_users_loader) do
      fun when is_function(fun, 0) ->
        result = fun.()
        if is_list(result), do: result, else: []

      _ ->
        if running?(Nebu.Repo) do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_list_users, []) do
            {:ok, %{rows: rows}} ->
              Enum.map(rows, fn [user_id, role, is_active, created_at] ->
                %{user_id: user_id, role: role, is_active: !!is_active, created_at: created_at}
              end)

            _ ->
              []
          end
        else
          []
        end
    end
  end

  defp actor_id(conn) do
    case conn.assigns[:current_user] do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> nil
    end
  end

  defp enc(id), do: URI.encode(id, &URI.char_unreserved?(&1))

  defp running?(name), do: Process.whereis(name) != nil
end
