defmodule Nebu.Admin.ReauthComponents do
  @moduledoc """
  Story admin-reauth-button-flow: the primary control and the hint of a marker-gated admin form, decided by the SERVER when the page is rendered.

  `@reauth` is the assign of `Nebu.Admin.OAuthAdminHelpers.assign_reauth/2` (`%{fresh?, minutes, href}`). Stale: a link styled as a button to the sign-in
  of the page (`Nebu.Admin.Auth.reauth_start_path/1`), so the admin signs in BEFORE entering the change. Fresh: the normal submit button and a validity
  line in the hint element. The server-side gates do not depend on this markup.
  """
  use Phoenix.Component

  attr :reauth, :map, required: true
  attr :id, :string, required: true
  attr :class, :string, default: "mt-2 text-sm text-base-content/70"
  attr :keys, :boolean, default: false, doc: "the storage target: the access key and the secret key are never filled in (said in both states)"

  def reauth_hint(assigns) do
    ~H"""
    <p id={@id} class={@class}>
      <%= if @reauth.fresh? do %>
        When this page was opened, your fresh sign-in was valid for {validity(@reauth.minutes)} and for one save on this page.
        <%= if @keys do %>
          The access key and the secret key are never filled in for you. Test Connection needs no new sign-in.
        <% end %>
      <% else %>
        <%= if @keys do %>
          Sign in first, then enter the connection details: Test Connection does not use up the sign-in, so you can test and then save.
          The access key and the secret key are never filled in for you.
        <% else %>
          Sign in again first: you come back to this page and can then enter your change and save it.
        <% end %>
        Anything you type before signing in is lost.
      <% end %>
    </p>
    """
  end

  attr :reauth, :map, required: true
  attr :class, :string, required: true
  attr :link_class, :string, default: nil, doc: "the class of the stale link when it differs from the submit's (a destructive submit must not style the sign-in link as destructive)"
  attr :describedby, :string, required: true
  attr :link_text, :string, default: "Sign in again to save"
  attr :rest, :global, doc: "attributes of the submit button only (data-role, aria-label): the link carries none of them"

  slot :inner_block, required: true

  def reauth_control(assigns) do
    ~H"""
    <button :if={@reauth.fresh?} type="submit" class={@class} aria-describedby={@describedby} {@rest}>{render_slot(@inner_block)}</button>
    <a :if={!@reauth.fresh?} href={@reauth.href} class={@link_class || @class} aria-describedby={@describedby}>{@link_text}</a>
    """
  end

  @doc "The remaining validity as text: `less than a minute` (0), `1 minute`, `N minutes` (whole minutes, rounded down)."
  @spec validity(0..5) :: String.t()
  def validity(0), do: "less than a minute"
  def validity(1), do: "1 minute"
  def validity(minutes), do: "#{minutes} minutes"
end
