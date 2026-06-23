defmodule Nebu.Admin.DashboardLive do
  @moduledoc """
  Admin Dashboard (Go parity: gateway/internal/admin/templates/dashboard.html).

  Landing page after login: system status (core health), instance info, and headline
  counts (users, rooms). Read-only; inline SQL per ADR-018.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "dashboard")
     |> assign(:page_title, "Dashboard")
     |> assign(:health, health())
     |> assign(:user_count, count("SELECT count(*) FROM users"))
     |> assign(:room_count, count("SELECT count(*) FROM rooms"))
     |> assign(:server_config, server_config())}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Dashboard</h1>

    <section aria-label="System status" class="mb-6">
      <h2 class="text-base font-semibold mb-2">System Status</h2>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <.stat_card label="Core" value={@health.status} tone={status_tone(@health.status)} />
        <.stat_card label="Users" value={to_string(@user_count)} />
        <.stat_card label="Rooms" value={to_string(@room_count)} />
      </div>
    </section>

    <section aria-label="Server info">
      <h2 class="text-base font-semibold mb-2">Server Info</h2>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <.stat_card label="Instance Name" value={Map.get(@server_config, "instance_name", "—")} />
        <.stat_card label="Server Name" value={Map.get(@server_config, "server_name", server_name())} />
        <.stat_card label="Version" value={@health[:version] || "—"} />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body py-4">
        <div class="card-title text-base">{@label}</div>
        <div class={["text-display", @tone]}>{@value}</div>
      </div>
    </div>
    """
  end

  defp status_tone("UP"), do: "text-success"
  defp status_tone("DEGRADED"), do: "text-warning"
  defp status_tone("DOWN"), do: "text-error"
  defp status_tone(_), do: nil

  defp health do
    if function_exported?(Nebu.Health, :check, 0), do: Nebu.Health.check(), else: %{status: "UP"}
  end

  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  defp count(sql) do
    if running?() do
      case Ecto.Adapters.SQL.query(Nebu.Repo, sql, []) do
        {:ok, %{rows: [[n]]}} -> n
        _ -> 0
      end
    else
      0
    end
  end

  defp server_config do
    case running?() && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> cfg
      _ -> %{}
    end
  end

  defp running?, do: Process.whereis(Nebu.Repo) != nil
end
