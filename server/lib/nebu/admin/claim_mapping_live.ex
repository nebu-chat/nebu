defmodule Nebu.Admin.ClaimMappingLive do
  @moduledoc """
  OIDC Claim Mapping editor (Go parity: templates/claim-mapping.html).

  Edits which OIDC claims map to the Matrix user id / display name / email
  (server_config: oidc_user_id_claim, oidc_displayname_claim, oidc_email_claim).
  Persists via Nebu.Admin.DB.upsert_server_config (ADR-018).
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @keys ~w(oidc_user_id_claim oidc_displayname_claim oidc_email_claim)
  @defaults %{
    "oidc_user_id_claim" => "name",
    "oidc_displayname_claim" => "name",
    "oidc_email_claim" => "email"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "claim-mapping")
     |> assign(:page_title, "Claim Mapping")
     |> assign(:errors, %{})
     |> assign(:values, current_values())}
  end

  @impl Phoenix.LiveView
  def handle_event("save", params, socket) do
    changes = Map.new(@keys, fn k -> {k, String.trim(params[k] || "")} end)

    # Per-field validation: a claim name must not be empty (an empty user-id claim would
    # break Matrix-ID derivation). Render an inline per-field error and do NOT persist.
    errors = for {k, v} <- changes, v == "", into: %{}, do: {k, "This claim must not be empty."}

    cond do
      errors != %{} ->
        {:noreply, socket |> assign(:values, changes) |> assign(:errors, errors)}

      true ->
        case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.upsert_server_config(changes) do
          :ok ->
            {:noreply,
             socket
             |> assign(:values, changes)
             |> assign(:errors, %{})
             |> put_flash(:info, "Claim mapping updated")}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not save (database unavailable).")}
        end
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">OIDC Claim Mapping</h1>
    <p class="text-text-secondary mb-4">Map IdP token claims to Matrix identity fields.</p>

    <p :if={Phoenix.Flash.get(@flash, :info)} class="alert alert-success mb-4">{Phoenix.Flash.get(@flash, :info)}</p>
    <p :if={Phoenix.Flash.get(@flash, :error)} class="alert alert-error mb-4">{Phoenix.Flash.get(@flash, :error)}</p>

    <form phx-submit="save" class="max-w-md flex flex-col gap-4">
      <.field name="oidc_user_id_claim" label="User ID claim" value={@values["oidc_user_id_claim"]} error={@errors["oidc_user_id_claim"]} />
      <.field name="oidc_displayname_claim" label="Display name claim" value={@values["oidc_displayname_claim"]} error={@errors["oidc_displayname_claim"]} />
      <.field name="oidc_email_claim" label="Email claim" value={@values["oidc_email_claim"]} error={@errors["oidc_email_claim"]} />
      <button type="submit" class="btn btn-primary self-start">Save</button>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :error, :string, default: nil

  defp field(assigns) do
    ~H"""
    <div>
      <label for={@name} class="block text-sm mb-1">{@label}</label>
      <input id={@name} name={@name} value={@value} class="input input-bordered w-full" />
      <p :if={@error} role="alert" data-field={@name} class="text-error text-sm mt-1">{@error}</p>
    </div>
    """
  end

  defp current_values do
    cfg =
      case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
        {:ok, c} -> c
        _ -> %{}
      end

    Map.new(@keys, fn k -> {k, Map.get(cfg, k) || @defaults[k]} end)
  end
end
