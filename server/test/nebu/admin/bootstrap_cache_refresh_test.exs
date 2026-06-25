defmodule Nebu.Admin.BootstrapCacheRefreshTest do
  @moduledoc """
  Regression test for C-1 (oidc-env-optional-bootstrap, cycle-1):
  `complete_bootstrap` MUST trigger `OidcConfig.refresh()` and
  `JwksCache.refresh()` after the DB transaction commits, so that the
  newly-written OIDC values (issuer, audience, jwks_uri) are immediately
  visible to `OidcPlug` without waiting for the next TTL-based refresh.

  ## Why this test exists

  Before the fix, `do_complete_bootstrap/2` promoted the OIDC config into
  `server_config` but never called `OidcConfig.refresh()`. The ETS cache
  retained nil values, causing OidcPlug to reject every Matrix Bearer token
  with 401 until either a process restart or the next scheduled TTL refresh
  (up to 5 minutes).

  ## Test strategy

  `complete_bootstrap/2` calls the real `OidcConfig.refresh()` only when
  `seam_installed?()` is false AND `running?(Nebu.Repo)` is true. In the
  unit suite neither condition holds. To keep the test fast and DB-free we
  use the `:bootstrap_cache_refresh_hook` seam (a 0-arity fun installed via
  Application env) that `complete_bootstrap/2` invokes in place of the real
  Process.whereis/refresh calls when present.

  The seam is prod-absent and only consulted when installed, so it never
  silences the real refresh in production.

  ## Crash/restart — NOT APPLICABLE (stateless DB-backed confirm, Persistenz C).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @client_id "nebu-client"
  @client_secret "test-secret"
  @at_rest_key "bootstrap-cache-refresh-test-key"

  defp build_draft do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    %{
      "instance_name" => "test-nebu",
      "oidc_issuer" => @issuer,
      "oidc_client_id" => @client_id,
      "oidc_client_secret" => encrypted,
      "oidc_audience" => "nebu-audience",
      "oidc_jwks_uri" => "https://dex.example.com/.well-known/jwks.json",
      "oidc_user_id_claim" => "sub",
      "oidc_displayname_claim" => "name",
      "oidc_email_claim" => "email",
      "bootstrap_sub" => "kai",
      "bootstrap_claims" => Jason.encode!([["groups", "instance_admin"]])
    }
  end

  defp install_store(draft) do
    store = start_supervised!({Agent, fn -> %{draft: draft, config: %{}} end})

    dispatcher = fn
      :load_draft, [] -> {:ok, Agent.get(store, & &1.draft)}
      :put_draft, [k, v] -> Agent.update(store, &put_in(&1, [:draft, k], v)) && :ok
      :clear_draft, [] -> Agent.update(store, &%{&1 | draft: %{}}) && :ok
      :put_config, [k, v] -> Agent.update(store, &put_in(&1, [:config, k], v)) && :ok
      :bootstrap_completed?, [] -> {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    store
  end

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  setup do
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    on_exit(fn ->
      for k <- [
            :admin_secret_at_rest,
            :admin_bootstrap_store,
            :bootstrap_cache_refresh_hook
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # ── C-1 regression: refresh hook is called after bootstrap completion ──────────

  test "C-1: bootstrap completion triggers the cache-refresh hook" do
    # Install a hook that records whether it was called.
    refresh_called = :counters.new(1, [])

    Application.put_env(:nebu_http, :bootstrap_cache_refresh_hook, fn ->
      :counters.add(refresh_called, 1, 1)
    end)

    install_store(build_draft())

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    # Sanity: confirm completed (redirected to dashboard, not bounced to login).
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    assert :counters.get(refresh_called, 1) == 1,
           "Expected the bootstrap_cache_refresh_hook to be called exactly once " <>
             "after bootstrap completes, but call count was #{:counters.get(refresh_called, 1)}. " <>
             "C-1 fix: Auth.complete_bootstrap/2 must invoke OidcConfig.refresh() + " <>
             "JwksCache.refresh() after the DB transaction commits."
  end

  test "C-1: hook is NOT called when bootstrap is already completed (guard)" do
    refresh_called = :counters.new(1, [])

    Application.put_env(:nebu_http, :bootstrap_cache_refresh_hook, fn ->
      :counters.add(refresh_called, 1, 1)
    end)

    # Pre-seed config with bootstrap_completed = "true" so the guard fires.
    store =
      start_supervised!({Agent, fn -> %{draft: build_draft(), config: %{"bootstrap_completed" => "true"}} end})

    dispatcher = fn
      :load_draft, [] -> {:ok, Agent.get(store, & &1.draft)}
      :put_draft, [k, v] -> Agent.update(store, &put_in(&1, [:draft, k], v)) && :ok
      :clear_draft, [] -> Agent.update(store, &%{&1 | draft: %{}}) && :ok
      :put_config, [k, v] -> Agent.update(store, &put_in(&1, [:config, k], v)) && :ok
      :bootstrap_completed?, [] -> {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    # Guard fires: already-completed redirects to /admin/login, not /admin/dashboard.
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/login"]

    # Refresh hook must NOT have been called because complete_bootstrap was never reached.
    assert :counters.get(refresh_called, 1) == 0,
           "Cache-refresh hook must not be called when bootstrap is already completed"
  end

  test "C-1: hook is NOT called when bootstrap identity is missing (guard)" do
    refresh_called = :counters.new(1, [])

    Application.put_env(:nebu_http, :bootstrap_cache_refresh_hook, fn ->
      :counters.add(refresh_called, 1, 1)
    end)

    # Draft without bootstrap_sub — the identity guard should reject the request.
    draft_without_sub = build_draft() |> Map.delete("bootstrap_sub")
    install_store(draft_without_sub)

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    # Guard fires: missing sub → redirect to /admin/login?error=auth_failed.
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/login?error=auth_failed"]

    assert :counters.get(refresh_called, 1) == 0,
           "Cache-refresh hook must not be called when bootstrap identity is absent"
  end

  # ── M-2 regression: audience required when not set via env ───────────────────────

  test "M-2: oidc_audience is promoted to server_config by complete_bootstrap" do
    Application.delete_env(:nebu_http, :oidc_audience)

    store = install_store(build_draft())

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)

    assert config["oidc_audience"] == "nebu-audience",
           "Expected server_config[\"oidc_audience\"] to be \"nebu-audience\" after bootstrap, " <>
             "got #{inspect(config["oidc_audience"])}. " <>
             "M-2 fix: do_complete_bootstrap/2 must promote oidc_audience from the draft."
  end
end
