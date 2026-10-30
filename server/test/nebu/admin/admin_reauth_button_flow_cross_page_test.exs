defmodule Nebu.Admin.AdminReauthButtonFlowCrossPageTest do
  @moduledoc """
  Story `admin-reauth-button-flow`, scenario 5 as a matrix over the four pages that need no database (`/admin/config`, `/admin/config/claim-mapping`,
  `/admin/config/role-mapping`, `/admin/media/settings`): a marker is bound to ONE page path (`Nebu.Admin.Auth.reauth_fresh/2`), so of all the markers below only
  the one of the page itself turns its forms from the link into the submit button, and every form of a shared-marker page (three on `/admin/config`, two on
  `/admin/media/settings`) changes with it. A page that asks `reauth_fresh/2` for the wrong path (a copied constant, a neighbour's page) is caught here.

  The approve / revoke confirm pages are in `admin_reauth_button_flow_confirm_test.exs` (they need rows in the database).
  """
  use ExUnit.Case, async: false

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @pages [S.config_path(), S.claim_path(), S.role_path(), S.media_path()]
  # every path a marker may be bound to: the four pages, a confirm page of a client, and near misses of the page paths
  @markers @pages ++
             [
               S.approve_path("c1"),
               S.revoke_path("c1"),
               "/admin/oauth/registrations",
               "/admin/config/",
               "/admin/config/scopes",
               "/admin/media/settings/storage",
               "/admin/dashboard"
             ]

  setup do
    T.put_env_scoped(:admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _key -> nil end)
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)
    Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
    Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

    on_exit(fn ->
      for k <- [:admin_server_config_reader, :admin_oidc_config_reader, :media_config_source, :media_storage_config_loader, :media_storage_env_reader], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  describe "the marker of one page unlocks that page and no other" do
    for page <- @pages, marker <- @markers do
      if page == marker do
        test "#{page}: its own marker turns every form of the page fresh" do
          doc = S.get(unquote(page), ago: 30) |> S.doc()
          for form <- S.forms_of(unquote(page)), do: S.assert_fresh!(doc, form, 4)
        end
      else
        test "#{page}: a marker bound to #{marker} leaves every form stale" do
          doc = S.get(unquote(page), path: unquote(marker), ago: 30) |> S.doc()
          for form <- S.forms_of(unquote(page)), do: S.assert_stale!(doc, form)
        end
      end
    end
  end

  describe "the shared-marker pages change as ONE unit" do
    test "/admin/config: all three forms fresh together, all three stale together" do
      fresh = S.get(S.config_path(), ago: 30) |> S.doc()
      stale = S.get(S.config_path()) |> S.doc()
      forms = S.forms_of(S.config_path())
      assert length(forms) == 3
      for form <- forms, do: S.assert_fresh!(fresh, form, 4)
      for form <- forms, do: S.assert_stale!(stale, form)
    end

    test "/admin/media/settings: both forms fresh together, both stale together" do
      fresh = S.get(S.media_path(), ago: 30) |> S.doc()
      stale = S.get(S.media_path()) |> S.doc()
      forms = S.forms_of(S.media_path())
      assert length(forms) == 2
      for form <- forms, do: S.assert_fresh!(fresh, form, 4)
      for form <- forms, do: S.assert_stale!(stale, form)
    end
  end

  describe "the sign-in link of a page returns to that page only" do
    test "every page, every marker: the links are exactly reauth_start_path of the page path" do
      for page <- @pages, marker <- [nil | Enum.map(@markers, &[path: &1])] do
        doc = S.get(page, marker) |> S.doc()
        S.assert_clean_links!(doc, [page])
        own? = marker == [path: page]
        assert (S.signin_hrefs(doc) == []) == own?, "links exactly when the marker is not the page's own (#{page}, #{inspect(marker)})"
      end
    end
  end
end
