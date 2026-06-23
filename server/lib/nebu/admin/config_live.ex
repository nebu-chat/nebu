defmodule Nebu.Admin.ConfigLive do
  @moduledoc """
  Admin Configuration overview (Go parity: gateway/internal/admin/templates/config.html).

  Read view of the instance `server_config` key/value store (the OIDC client secret is
  never selected). Claim/Role mapping have their own dedicated editors. Inline SQL via
  Nebu.Admin.DB.get_server_config (ADR-018).

  ## OIDC refresh mode controls (story oidc-refresh-mode-config, AC5/AC6)

  Two native `<select>`s let an admin change the Matrix and Admin OIDC refresh modes at
  runtime. Each write routes through `Nebu.Admin.DB.upsert_server_config/1` (the existing
  admin config write path) and takes effect for subsequent logins/refreshes with no
  redeploy. The value is validated to the `offline|online` enum on the write path — a
  junk value is rejected (the client's default then applies), so server_config can never
  be used to inject an arbitrary OIDC scope. Defaults reflected when unset: Matrix=offline
  / Admin=online.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @refresh_mode_defaults %{
    "matrix_oidc_refresh_mode" => "offline",
    "admin_oidc_refresh_mode" => "online"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "config")
     |> assign(:page_title, "Configuration")
     |> assign(:config, config())}
  end

  # Save one (or both) refresh-mode selectors. Only enum-valid values are persisted;
  # anything else is ignored (no scope injection via server_config). After a successful
  # upsert the config is re-read so the selected option reflects the persisted value.
  @impl Phoenix.LiveView
  def handle_event("save_refresh_mode", params, socket) do
    changes =
      for key <- Map.keys(@refresh_mode_defaults),
          (v = params[key]) in ["offline", "online"],
          into: %{},
          do: {key, v}

    if changes != %{} and Process.whereis(Nebu.Repo) do
      :ok = Nebu.Admin.DB.upsert_server_config(changes)
    end

    {:noreply, assign(socket, :config, config())}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Configuration</h1>
    <p class="text-text-secondary mb-4">
      Instance settings (<code>server_config</code>). Edit OIDC claim and role mapping via
      their dedicated pages.
    </p>

    <%!-- OIDC refresh mode (story oidc-refresh-mode-config, AC5/AC6). Native <select>s so
          the selected value is observable; phx-change routes through upsert_server_config. --%>
    <form id="oidc-refresh-mode-form" phx-change="save_refresh_mode" class="mb-6">
      <h2 class="text-heading font-semibold mb-2">OIDC refresh mode</h2>

      <label class="form-control mt-2">
        <span class="label-text">Matrix client refresh mode</span>
        <select name="matrix_oidc_refresh_mode" aria-label="Matrix refresh mode" class="select select-bordered">
          <option value="offline" selected={refresh_mode(@config, "matrix_oidc_refresh_mode") == "offline"}>
            offline (offline_access)
          </option>
          <option value="online" selected={refresh_mode(@config, "matrix_oidc_refresh_mode") == "online"}>
            online
          </option>
        </select>
      </label>

      <label class="form-control mt-2">
        <span class="label-text">Admin client refresh mode</span>
        <select name="admin_oidc_refresh_mode" aria-label="Admin refresh mode" class="select select-bordered">
          <option value="offline" selected={refresh_mode(@config, "admin_oidc_refresh_mode") == "offline"}>
            offline (offline_access)
          </option>
          <option value="online" selected={refresh_mode(@config, "admin_oidc_refresh_mode") == "online"}>
            online
          </option>
        </select>
      </label>

      <p class="text-sm text-text-secondary mt-2">
        <strong>offline</strong>: long-lived offline refresh token (survives IdP logout);
        works on Dex &amp; Keycloak. Nebu stores the refresh token AES-256-GCM-encrypted
        (server-side for Matrix, in the signed cookie for admin) and caps its own session at 8h.
        <strong>online</strong>: session-bound refresh token (dies on IdP SSO logout).
        <strong>Dex issues a refresh token only when <code>offline_access</code> is requested</strong>
        — so in online mode refresh is disabled on Dex (use offline for Dex).
      </p>
    </form>

    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr><th>Key</th><th>Value</th></tr>
        </thead>
        <tbody>
          <tr :for={{k, v} <- @config}>
            <td class="font-mono text-mono">{k}</td>
            <td class="font-mono text-mono break-all">{v}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Current persisted mode for `key`, falling back to that client's default when unset.
  defp refresh_mode(config, key) do
    case config_value(config, key) do
      v when v in ["offline", "online"] -> v
      _ -> @refresh_mode_defaults[key]
    end
  end

  # @config is always a sorted list of {k, v} tuples (config/0 returns Enum.sort(cfg) or []).
  defp config_value(config, key) when is_list(config), do: List.keyfind(config, key, 0) |> elem_or_nil()

  defp elem_or_nil(nil), do: nil
  defp elem_or_nil({_k, v}), do: v

  defp config do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Enum.sort(cfg)
      _ -> []
    end
  end
end
