defmodule Nebu.Admin.AuthBootstrapGateTest do
  @moduledoc """
  RED-phase ATDD tests for the bug `fix-bootstrap-wizard-unreachable`.

  The bug: on a brand-new (un-bootstrapped) instance the Bootstrap Wizard is
  unreachable. `Nebu.Admin.Auth.on_mount(:require_admin, ...)` gates every
  `live_session :admin` route — including `/admin/bootstrap` — and its catch-all
  branch redirects EVERY unauthenticated mount to `/admin/login`, regardless of
  bootstrap state. Since the admin-group claim + OIDC config can only be written by
  completing the wizard, and the wizard can never be reached without an admin
  session, the operator is dead-locked.

  These tests pin the *intended* gate behaviour (ACs 1–4 of the story). They MUST
  fail against the current `auth.ex` for the RIGHT reason: an unauthenticated mount
  of either BootstrapLive or a non-bootstrap view currently redirects to
  `/admin/login` instead of (AC1) being allowed through or (AC2) being funnelled to
  `/admin/bootstrap`.

  ## How `bootstrap_completed?` is controlled in the unit suite (ADR-018, no live Repo)

  `Nebu.Repo` is not started in `make test-unit-elixir`. The existing
  `Nebu.Admin.Auth.bootstrap_completed?/0` defaults to `true` when the Repo is down,
  so we cannot exercise the `bootstrap_completed? == false` paths (AC1/AC2) without a
  seam. `Nebu.Admin.BootstrapLive` ALREADY consults an injectable
  `:admin_bootstrap_store` dispatcher (`{:bootstrap_completed?, []}` → `{:ok, bool}`)
  for exactly this reason. The fix for this bug must make `Auth.bootstrap_completed?/0`
  consult the SAME seam (or an equivalent override) so the on_mount gate is testable
  and behaves identically in the unit suite and against a live Repo.

  We install that seam here. Until the dev step wires `Auth.bootstrap_completed?/0`
  to honour it, the seam is ignored and `bootstrap_completed?/0` returns `true`
  (Repo down) — which is itself one of the reasons AC1/AC2 stay RED.

  No `socket.view` shortcut: `on_mount/4` reads the mounting LiveView from
  `socket.view`, so each scenario builds a `%Phoenix.LiveView.Socket{view: ...}`.

  ## Crash/restart — NOT APPLICABLE

  `on_mount/4` is pure gate logic over the session + a DB read. There is no GenServer
  state to recover (Persistenz Option C — stateless), so no `Process.exit(:kill)`
  recovery test is required.
  """
  use ExUnit.Case, async: false

  alias Nebu.Admin.Auth

  @bootstrap_view Nebu.Admin.BootstrapLive
  @non_bootstrap_view Nebu.Admin.DashboardLive

  # Install the same injectable bootstrap-state seam BootstrapLive uses, backed by an
  # in-memory Agent. `complete?` toggles what `{:bootstrap_completed?, []}` returns.
  defp install_bootstrap_store(complete?) do
    store = start_supervised!({Agent, fn -> %{completed: complete?} end})

    dispatcher = fn
      :bootstrap_completed?, [] ->
        {:ok, Agent.get(store, & &1.completed)}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    on_exit(fn -> Application.delete_env(:nebu_http, :admin_bootstrap_store) end)
    :ok
  end

  defp socket_for(view), do: %Phoenix.LiveView.Socket{view: view}

  # The destination a `redirect(socket, to: ...)` recorded on the socket, or nil.
  defp redirect_target(%Phoenix.LiveView.Socket{redirected: {:redirect, %{to: to}}}), do: to
  defp redirect_target(_), do: nil

  # ── AC1 — unauthenticated operator reaches the wizard on a fresh instance ────────

  describe "AC1: unauthenticated mount of BootstrapLive while bootstrap is incomplete" do
    setup do
      install_bootstrap_store(false)
      :ok
    end

    test "is allowed through ({:cont, _}) — no redirect to /admin/login" do
      result =
        Auth.on_mount(:require_admin, %{}, %{}, socket_for(@bootstrap_view))

      assert {:cont, socket} = result
      assert redirect_target(socket) == nil
    end
  end

  # ── AC2 — unauthenticated operator on any other admin page is funnelled to the
  #          wizard (NOT to login) while bootstrap is incomplete ───────────────────

  describe "AC2: unauthenticated mount of a non-bootstrap view while bootstrap is incomplete" do
    setup do
      install_bootstrap_store(false)
      :ok
    end

    test "is funnelled to /admin/bootstrap (not /admin/login)" do
      result =
        Auth.on_mount(:require_admin, %{}, %{}, socket_for(@non_bootstrap_view))

      assert {:halt, socket} = result
      assert redirect_target(socket) == "/admin/bootstrap"
    end
  end

  # ── AC3 — once bootstrap is complete, the wizard is admin-gated again (security) ─

  describe "AC3: unauthenticated mount of BootstrapLive once bootstrap is complete" do
    setup do
      install_bootstrap_store(true)
      :ok
    end

    test "is blocked and redirected to /admin/login (wizard re-gated post-setup)" do
      result =
        Auth.on_mount(:require_admin, %{}, %{}, socket_for(@bootstrap_view))

      assert {:halt, socket} = result
      assert redirect_target(socket) == "/admin/login"
    end

    test "an unauthenticated non-bootstrap view is also redirected to /admin/login" do
      result =
        Auth.on_mount(:require_admin, %{}, %{}, socket_for(@non_bootstrap_view))

      assert {:halt, socket} = result
      assert redirect_target(socket) == "/admin/login"
    end
  end

  # ── AC4 — authenticated-admin behaviour unchanged ───────────────────────────────

  describe "AC4: authenticated admin, bootstrap complete" do
    setup do
      install_bootstrap_store(true)
      :ok
    end

    test "reaches BootstrapLive ({:cont, _})" do
      session = %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      assert {:cont, socket} = Auth.on_mount(:require_admin, %{}, session, socket_for(@bootstrap_view))
      assert redirect_target(socket) == nil
    end

    test "reaches any other admin page ({:cont, _})" do
      session = %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      assert {:cont, socket} = Auth.on_mount(:require_admin, %{}, session, socket_for(@non_bootstrap_view))
      assert redirect_target(socket) == nil
    end
  end

  describe "AC4: authenticated admin, bootstrap incomplete (existing funnel preserved)" do
    setup do
      install_bootstrap_store(false)
      :ok
    end

    test "non-bootstrap view is funnelled to /admin/bootstrap" do
      session = %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      assert {:halt, socket} = Auth.on_mount(:require_admin, %{}, session, socket_for(@non_bootstrap_view))
      assert redirect_target(socket) == "/admin/bootstrap"
    end

    test "BootstrapLive itself is allowed through ({:cont, _})" do
      session = %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      assert {:cont, socket} = Auth.on_mount(:require_admin, %{}, session, socket_for(@bootstrap_view))
      assert redirect_target(socket) == nil
    end
  end
end
