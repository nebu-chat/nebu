defmodule Nebu.Web.ConfigLiveRefreshModeTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-refresh-mode-config`, AC5 + AC6 (runtime
  change via the Admin UI config surface `/admin/config`).

  Today `Nebu.Admin.ConfigLive` is a READ-ONLY table of `server_config` — it has no
  controls. This story adds two refresh-mode selectors (Matrix + Admin), each
  writing to `server_config` via the existing admin config write path
  (`Nebu.Admin.DB.upsert_server_config/1`), with the current value reflected and a
  hint that surfaces the Dex caveat (AC6).

  ## Two layers

    * RENDER (unit suite, no Repo): `ConfigLive.mount/3` already degrades to an
      empty config when `Nebu.Repo` is absent, so the page still renders. We assert
      the two mode selectors and the Dex-caveat hint are present in the markup.
      FAILS today (read-only table, no selectors).

    * ROUND-TRIP (`@moduletag :integration`, live Repo): changing each selector
      upserts `server_config` and the new value is read back / reflected as the
      selected option. Controlled via the REAL `upsert_server_config/1` — NO DB
      mock (CLAUDE.md / story note).

  ## Crash/restart — NOT APPLICABLE

  ConfigLive is stateless / DB-backed (re-reads server_config on mount —
  Persistenz Option C). No GenServer state to recover.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  defp mount_config do
    live_isolated(Plug.Test.conn(:get, "/admin/config"), Nebu.Admin.ConfigLive,
      session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
    )
  end

  # ── RENDER (AC6 transparency + AC5 controls present) ──────────────────────────

  describe "render: mode selectors + Dex-caveat hint (AC5/AC6)" do
    test "renders a Matrix refresh-mode selector with offline + online options" do
      {:ok, _view, html} = mount_config()

      assert html =~ "matrix_oidc_refresh_mode"
      # Both enum values selectable for the Matrix client.
      assert html =~ ~r/matrix_oidc_refresh_mode[\s\S]*offline/
      assert html =~ ~r/matrix_oidc_refresh_mode[\s\S]*online/
    end

    test "renders an Admin refresh-mode selector with offline + online options" do
      {:ok, _view, html} = mount_config()

      assert html =~ "admin_oidc_refresh_mode"
      assert html =~ ~r/admin_oidc_refresh_mode[\s\S]*offline/
      assert html =~ ~r/admin_oidc_refresh_mode[\s\S]*online/
    end

    test "surfaces the Dex caveat in the hint text (AC6)" do
      {:ok, _view, html} = mount_config()

      # The hint MUST tell operators Dex issues a refresh token only with
      # offline_access (online disables refresh on Dex) — verbatim concept.
      assert html =~ ~r/Dex/
      assert html =~ ~r/offline_access/
      assert html =~ ~r/refresh token/i
    end
  end

  # ── ROUND-TRIP (AC5 persists + reflects, live Repo) ───────────────────────────

  describe "runtime change persists to server_config (AC5)" do
    @describetag :integration

    setup do
      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM server_config WHERE key IN ('matrix_oidc_refresh_mode','admin_oidc_refresh_mode')",
            []
          )
        end
      end)

      :ok
    end

    test "changing the Matrix mode upserts server_config and the new value is read back" do
      {:ok, view, _html} = mount_config()

      # The dev wires a phx-change/phx-submit form (e.g. "save_refresh_mode") that
      # routes through Nebu.Admin.DB.upsert_server_config/1. Submit Matrix=online.
      view
      |> form("form[phx-submit='save_refresh_mode'], form[phx-change='save_refresh_mode']", %{
        "matrix_oidc_refresh_mode" => "online"
      })
      |> render_change()

      {:ok, cfg} = Nebu.Admin.DB.get_server_config()
      assert cfg["matrix_oidc_refresh_mode"] == "online"

      # And re-mounting reflects the persisted value as selected.
      {:ok, _v2, html2} = mount_config()
      assert html2 =~ ~r/value="online"[^>]*selected|selected[^>]*value="online"/
    end

    test "changing the Admin mode upserts server_config and the new value is read back" do
      {:ok, view, _html} = mount_config()

      view
      |> form("form[phx-submit='save_refresh_mode'], form[phx-change='save_refresh_mode']", %{
        "admin_oidc_refresh_mode" => "offline"
      })
      |> render_change()

      {:ok, cfg} = Nebu.Admin.DB.get_server_config()
      assert cfg["admin_oidc_refresh_mode"] == "offline"
    end
  end
end
