defmodule Nebu.Admin.BootstrapOidcFlowTest do
  @moduledoc """
  RED-phase ATDD tests for `bugfix/fix-bootstrap-wizard-oidc-flow`.

  The bug: the Elixir Bootstrap Wizard never authenticates the operator via OIDC and
  never lets them pick the admin-group claim — it just writes a hardcoded
  `admin_group_claim = "instance_admin"`. The Go-parity flow (mirrored here) is:

      step 3 "Connect with OIDC"  → GET /admin/login/start?mode=bootstrap
        → 302 to the IdP (PKCE/state/nonce, creds from the bootstrap_draft)
      Dex login → GET /admin/callback (mode=bootstrap)
        → token verified but NO admin-group gate; render /admin/bootstrap/select-claim
      operator picks a claim + Confirm → POST /admin/bootstrap/select-claim
        → write admin_group_claim, promote draft → server_config, bootstrap_completed=true,
          mint admin session, redirect /admin/dashboard

  Security (AC5): the whole mode=bootstrap leg must be INERT once
  `bootstrap_completed == "true"` — it must not let an unauthenticated party re-pick the
  admin claim or overwrite OIDC config after setup.

  ## Seams (ADR-018, no live Repo in the unit suite)

    * `:admin_bootstrap_store` — the same injectable draft/config dispatcher
      `Nebu.Admin.BootstrapLive` + `Nebu.Admin.Auth.bootstrap_completed?/0` already use.
    * `:oidc_metadata_override` — discovery doc (authorization/token endpoints).
    * `:admin_oidc_token_override` — short-circuits the code→token exchange + ID-token
      verify (the only network/crypto leg) so the callback's state/nonce/mode/draft/render
      logic runs end-to-end in-process. Mirrors the existing `:oidc_metadata_override` seam.

  ## Crash/restart — NOT APPLICABLE

  The login/callback/confirm legs are stateless request handlers over the signed session
  + a DB read/write (Persistenz Option C). No GenServer state to recover.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"
  @client_id "nebu-admin"
  @client_secret "super-secret-oidc-value"
  @at_rest_key "bootstrap-at-rest-test-key"

  # In-memory draft + config store backing the inline-SQL seam. Pre-seeds a draft that
  # has reached step 3 (instance + OIDC + claim mapping), with the secret encrypted at
  # rest exactly as the wizard stores it. `completed?` toggles bootstrap_completed.
  defp install_store(completed?) do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    draft = %{
      "instance_name" => "test-nebu",
      "oidc_issuer" => @issuer,
      "oidc_client_id" => @client_id,
      "oidc_client_secret" => encrypted,
      # MINOR-1 (cycle-2): oidc_audience is required by do_complete_bootstrap/2 when
      # NEBU_OIDC_AUDIENCE is not set. All bootstrap confirm tests must include it.
      "oidc_audience" => "nebu-audience",
      "oidc_user_id_claim" => "sub",
      "oidc_displayname_claim" => "name",
      "oidc_email_claim" => "email"
    }

    config = if completed?, do: %{"bootstrap_completed" => "true"}, else: %{}

    store = start_supervised!({Agent, fn -> %{draft: draft, config: config} end})

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

  setup do
    # oidc-bootstrap-only-config (ADR-022): bootstrap-mode resolves issuer + client
    # from the draft; normal-mode resolves issuer via OidcConfig and the single admin
    # client via the :admin_oidc_config_reader seam. Configure both so the normal-mode
    # callback can reach the admin-group gate (instead of failing config resolution).
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)
      _ -> nil
    end)
    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :admin_secret_at_rest,
            :oidc_metadata_override,
            :admin_bootstrap_store,
            :admin_oidc_token_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  # Pre-fills a valid login state (as login_start would have written) so the callback's
  # state/nonce checks pass; `mode` mirrors the value login_start stored.
  defp with_login_state(conn, mode) do
    put_session(conn, "admin_oidc_login", %{
      "state" => "the-state",
      "verifier" => "the-verifier",
      "nonce" => "the-nonce",
      "exp" => System.system_time(:second) + 600,
      "mode" => mode
    })
  end

  # ── Test 1 — login_start mode=bootstrap reads draft creds → 302 to IdP ────────────

  test "login_start mode=bootstrap reads draft creds and 302s to the IdP with PKCE/state/nonce" do
    install_store(false)

    conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{"mode" => "bootstrap"})

    assert conn.halted
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, @authorization_endpoint <> "?")

    params = URI.parse(location).query |> URI.decode_query()
    assert params["response_type"] == "code"
    assert params["client_id"] == @client_id
    assert params["code_challenge_method"] == "S256"
    assert byte_size(params["state"]) > 8
    assert byte_size(params["nonce"]) > 8

    login_state = get_session(conn, "admin_oidc_login")
    assert login_state["mode"] == "bootstrap"
    assert login_state["state"] == params["state"]
    assert login_state["nonce"] == params["nonce"]
  end

  test "login_start mode=bootstrap is INERT once bootstrap is complete (AC5)" do
    install_store(true)

    conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{"mode" => "bootstrap"})

    assert conn.halted
    # Refused: not a 302 to the IdP authorize endpoint.
    refute match?([@authorization_endpoint <> "?" <> _], get_resp_header(conn, "location"))

    case get_resp_header(conn, "location") do
      [loc] -> refute String.starts_with?(loc, @authorization_endpoint)
      _ -> :ok
    end
  end

  # ── Test 2 — callback mode=bootstrap does NOT enforce admin claim, renders select-claim ─

  test "callback mode=bootstrap renders select-claim WITHOUT enforcing the admin gate" do
    install_store(false)

    # Verified token WITHOUT the admin group claim — the bootstrap callback must NOT 403.
    Application.put_env(:nebu_http, :admin_oidc_token_override, fn ->
      {:ok, %{"sub" => "kai", "email" => "kai@example.com", "nonce" => "the-nonce", "groups" => ["dev", "instance_admin"]}}
    end)

    conn =
      session_conn(:get, "/admin/callback")
      |> with_login_state("bootstrap")
      |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

    assert conn.halted
    # Not a 403 (admin gate skipped) and not a redirect to /admin/login.
    refute conn.status == 403
    body = conn.resp_body || ""
    refute body =~ "Access denied"

    # Renders the select-claim page listing the token's discovered claim values as options.
    assert conn.status == 200
    assert body =~ "instance_admin"
    assert body =~ ~s(name="admin_group_claim")
    assert body =~ ~s(value="instance_admin")
  end

  test "callback mode=bootstrap stores the authenticated sub/email in the draft for confirm" do
    store = install_store(false)

    Application.put_env(:nebu_http, :admin_oidc_token_override, fn ->
      {:ok, %{"sub" => "kai", "email" => "kai@example.com", "nonce" => "the-nonce", "groups" => ["instance_admin"]}}
    end)

    session_conn(:get, "/admin/callback")
    |> with_login_state("bootstrap")
    |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

    assert Agent.get(store, &(&1.draft["bootstrap_sub"])) == "kai"
    assert Agent.get(store, &(&1.draft["bootstrap_email"])) == "kai@example.com"
  end

  # ── Test 3 — confirm writes admin_group_claim + bootstrap_completed + mints session ─

  test "confirm writes the chosen claim, promotes draft→config, completes bootstrap, mints session" do
    store = install_store(false)
    # The callback would have stored these; seed them directly for the confirm-only test.
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "kai"))
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_email"], "kai@example.com"))
    # The callback also stashes the verified token's discovered claim values (C1).
    Agent.update(
      store,
      &put_in(&1, [:draft, "bootstrap_claims"], Jason.encode!([["groups", "instance_admin"]]))
    )

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    assert conn.halted
    assert conn.status == 302
    assert [loc] = get_resp_header(conn, "location")
    assert loc == "/admin/dashboard"

    config = Agent.get(store, & &1.config)
    assert config["admin_group_claim"] == "instance_admin"
    assert config["bootstrap_completed"] == "true"
    assert config["instance_name"] == "test-nebu"
    assert config["oidc_issuer"] == @issuer
    assert config["oidc_client_id"] == @client_id
    # The promoted secret is still the encrypted blob (never plaintext).
    refute config["oidc_client_secret"] == @client_secret
    assert Nebu.Admin.BootstrapLive.decrypt_secret(config["oidc_client_secret"]) == @client_secret

    # Draft cleared, admin session minted.
    assert Agent.get(store, & &1.draft) == %{}
    user = get_session(conn, "current_user")
    assert user["admin"] == true
    assert user["sub"] == "kai"
  end

  # ── Test 4 — confirm is inert once bootstrap complete (AC5 security) ──────────────

  test "confirm is REFUSED once bootstrap is complete and does not overwrite config (AC5)" do
    store = install_store(true)
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "attacker"))

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "all"})

    assert conn.halted
    # Refused — never reaches /admin/dashboard authenticated.
    refute get_resp_header(conn, "location") == ["/admin/dashboard"]
    refute conn.status == 302 and get_resp_header(conn, "location") == ["/admin/dashboard"]

    # No admin_group_claim overwrite, no minted session.
    refute Agent.get(store, &(&1.config["admin_group_claim"])) == "all"
    assert get_session(conn, "current_user") == nil
  end

  # ── Test 5 — C1 claim-value injection: confirm only accepts a discovered claim value ─

  test "confirm REJECTS an admin_group_claim value not in the stashed discovered set (C1)" do
    store = install_store(false)
    # Prior bootstrap-mode callback authenticated the operator and stashed the discovered
    # claim VALUES from the verified token (here: only "instance_admin" and "kai").
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "kai"))
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_email"], "kai@example.com"))

    # Stash exactly as bootstrap_callback/2 does: JSON list of [key, value] lists.
    discovered =
      Auth.extract_discovered_claims(%{"sub" => "kai", "groups" => ["instance_admin"]})
      |> Enum.map(fn {k, v} -> [k, v] end)

    Agent.update(store, &put_in(&1, [:draft, "bootstrap_claims"], Jason.encode!(discovered)))

    # Operator (or attacker driving the POST) submits an arbitrary value that was NOT in
    # the verified token's claims — must be refused: no config write, no completion, no session.
    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "all"})

    assert conn.halted
    refute get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)
    refute config["admin_group_claim"] == "all"
    refute config["bootstrap_completed"] == "true"
    assert get_session(conn, "current_user") == nil
  end

  test "confirm ACCEPTS an admin_group_claim value that IS in the stashed discovered set (C1)" do
    store = install_store(false)
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "kai"))
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_email"], "kai@example.com"))

    # Stash exactly as bootstrap_callback/2 does: JSON list of [key, value] lists.
    discovered =
      Auth.extract_discovered_claims(%{"sub" => "kai", "groups" => ["instance_admin"]})
      |> Enum.map(fn {k, v} -> [k, v] end)

    Agent.update(store, &put_in(&1, [:draft, "bootstrap_claims"], Jason.encode!(discovered)))

    # The submitted value IS a member of the verified token's discovered claims → success.
    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    assert conn.halted
    assert conn.status == 302
    assert [loc] = get_resp_header(conn, "location")
    assert loc == "/admin/dashboard"

    config = Agent.get(store, & &1.config)
    assert config["admin_group_claim"] == "instance_admin"
    assert config["bootstrap_completed"] == "true"

    user = get_session(conn, "current_user")
    assert user["admin"] == true
    assert user["sub"] == "kai"
  end

  test "callback mode=bootstrap stashes the discovered claim values for confirm validation (C1)" do
    store = install_store(false)

    Application.put_env(:nebu_http, :admin_oidc_token_override, fn ->
      {:ok, %{"sub" => "kai", "email" => "kai@example.com", "nonce" => "the-nonce", "groups" => ["dev", "instance_admin"]}}
    end)

    session_conn(:get, "/admin/callback")
    |> with_login_state("bootstrap")
    |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

    stashed = Agent.get(store, & &1.draft["bootstrap_claims"])
    assert is_binary(stashed)
    decoded = Jason.decode!(stashed)
    # The stash is exactly the set rendered on the select-claim page (extract_discovered_claims).
    expected =
      Auth.extract_discovered_claims(%{
        "sub" => "kai",
        "email" => "kai@example.com",
        "nonce" => "the-nonce",
        "groups" => ["dev", "instance_admin"]
      })

    # Stored as JSON list of [key, value] pairs; compare as sets of values present.
    values = Enum.map(decoded, fn [_k, v] -> v end) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(["instance_admin", "dev", "kai"]), values)
    assert length(decoded) == length(expected)
  end

  test "select-claim GET / confirm is REFUSED for a non-bootstrap (normal) login mode" do
    install_store(false)

    # A normal login (mode != bootstrap) must not be able to render the select-claim
    # page via the callback — the admin gate still applies on that path.
    Application.put_env(:nebu_http, :admin_oidc_token_override, fn ->
      {:ok, %{"sub" => "kai", "email" => "kai@example.com", "nonce" => "the-nonce", "groups" => ["users"]}}
    end)

    conn =
      session_conn(:get, "/admin/callback")
      |> with_login_state(nil)
      |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

    assert conn.halted
    # Normal mode + no admin claim → 403 (gate enforced), NOT a select-claim render.
    assert conn.status == 403
  end
end
