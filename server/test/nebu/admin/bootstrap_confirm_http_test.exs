defmodule Nebu.Admin.BootstrapConfirmHttpTest do
  @moduledoc """
  HTTP-level integration test for `POST /admin/bootstrap/select-claim`
  (bugfix/fix-matrix-sso-redirect-missing — admin bootstrap confirm crash).

  ## The bug this test exists to catch

  Every prior bootstrap test (`bootstrap_oidc_flow_test.exs`) called
  `Nebu.Admin.Auth.bootstrap_confirm_claim/2` DIRECTLY with a hand-built conn,
  bypassing the real HTTP stack. The select-claim confirm is the ONLY plain HTTP
  form POST in the admin UI (everything else is LiveView over the websocket), so
  the full POST path was never exercised:

      Nebu.Web.Router (Nebu.Web.Plugs.JsonBody → Plug.Parsers JSON, pass: */*)
        → match "/admin/*" → Nebu.Admin.Endpoint.call/2
          → Plug.Parsers [:urlencoded] → :admin_session (Plug.Session)
            → Nebu.Admin.Router :browser pipeline (fetch_session, protect_from_forgery)
              → LoginController.confirm_claim → Auth.bootstrap_confirm_claim/2

  PRIMARY exception (masked in prod behind a secondary RenderErrors MatchError):
  `Plug.CSRFProtection.InvalidCSRFTokenError`. `Nebu.Web.Plugs.JsonBody` ran
  `Plug.Parsers` with `pass: ["*/*"]` on the urlencoded admin POST. With no
  matching parser but a passing mime, Plug.Parsers moved `conn.body_params` away
  from `%Plug.Conn.Unfetched{}` WITHOUT reading/parsing the urlencoded body. The
  admin endpoint's own `Plug.Parsers [:urlencoded]` then short-circuited (it only
  parses while `body_params` is still `Unfetched`), so the `_csrf_token` form field
  was never decoded → `protect_from_forgery` rejected the POST.

  ## What this test drives

  The REAL `Nebu.Web.Router` (the production entry point, including JsonBody) for
  BOTH the GET that renders the select-claim page (to obtain a genuine,
  session-bound CSRF token + the `_nebu_admin_key` cookie) AND the form POST. CSRF
  is NOT disabled — the token is the real one minted on the rendered page and the
  cookie is recycled between the two requests exactly as a browser does.

  ## Crash/restart — NOT APPLICABLE

  Stateless request handler over the signed session + a DB read/write (Persistenz
  Option C). No GenServer state to recover.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)

  @issuer "https://dex.example.com/dex"
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"
  @client_id "nebu-admin"
  @client_secret "super-secret-oidc-value"
  @at_rest_key "bootstrap-at-rest-test-key"

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
      :bootstrap_completed?, [] ->
        {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    store
  end

  setup do
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      for k <- [
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

  # ── helpers ─────────────────────────────────────────────────────────────────

  # A fresh conn pre-loaded with secret_key_base (Bandit/Phoenix would set this in
  # production; Plug.Test does not), routed through the REAL production router.
  defp router_call(method, path, body, headers) do
    base =
      if body do
        conn(method, path, body)
      else
        conn(method, path)
      end

    conn = %{base | secret_key_base: @secret_key_base}

    conn =
      Enum.reduce(headers, conn, fn
        {_k, nil}, c -> c
        {k, v}, c -> put_req_header(c, k, v)
      end)

    Nebu.Web.Router.call(conn, Nebu.Web.Router.init([]))
  end

  # The set-cookie value the browser would replay on the next request.
  defp session_cookie(conn) do
    conn
    |> get_resp_header("set-cookie")
    |> Enum.map(&(&1 |> String.split(";", parts: 2) |> hd()))
    |> Enum.find(&String.starts_with?(&1, "_nebu_admin_key="))
  end

  defp csrf_token(html) do
    [_, raw] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html)
    # The page HTML-escapes the value (Phoenix.HTML); decode the entities back.
    raw
    |> String.replace("&amp;", "&")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  # Drives the bootstrap-mode OIDC callback through the REAL router. It verifies a
  # (stubbed) token and renders the select-claim page, writing the CSRF secret into
  # the _nebu_admin_key session cookie. Returns {csrf_token, cookie}.
  defp render_select_claim_page do
    Application.put_env(:nebu_http, :admin_oidc_token_override, fn ->
      {:ok,
       %{
         "sub" => "kai",
         "email" => "kai@example.com",
         "nonce" => "the-nonce",
         "groups" => ["dev", "instance_admin"]
       }}
    end)

    cookie = login_state_cookie()

    conn =
      router_call(:get, "/admin/callback?code=auth-code&state=the-state", nil, [
        {"cookie", cookie}
      ])

    assert conn.status == 200, "callback should render select-claim page, got #{conn.status}"
    body = conn.resp_body
    assert body =~ ~s(name="admin_group_claim")

    {csrf_token(body), session_cookie(conn)}
  end

  # Seeds the in-flight OIDC login state into a signed _nebu_admin_key cookie (as
  # login_start would have). We run login_start through the router with the
  # bootstrap draft installed, which writes {state,verifier,nonce,exp,mode} into the
  # session and 302s to the IdP; we keep only its Set-Cookie. To make the callback's
  # state check pass we pin state/nonce by going through login_start and reusing
  # whatever it generated — but the callback token override echoes a fixed nonce, so
  # we instead seed a deterministic login state directly via a tiny session-writing
  # request through the admin endpoint pipeline.
  defp login_state_cookie do
    login_state = %{
      "state" => "the-state",
      "verifier" => "the-verifier",
      "nonce" => "the-nonce",
      "exp" => System.system_time(:second) + 600,
      "mode" => "bootstrap"
    }

    conn = %{conn(:get, "/admin/login") | secret_key_base: @secret_key_base}

    conn
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("admin_oidc_login", login_state)
    |> resp(200, "")
    |> send_resp()
    |> session_cookie()
  end

  # ── happy path: valid claim → 302 /admin/dashboard via the REAL stack ─────────

  test "POST select-claim with a valid CSRF token + discovered claim → 302 /admin/dashboard" do
    store = install_store(false)
    {token, cookie} = render_select_claim_page()

    refute token in [nil, ""]
    refute cookie in [nil, ""]

    body = URI.encode_query(%{"_csrf_token" => token, "admin_group_claim" => "instance_admin"})

    conn =
      router_call(:post, "/admin/bootstrap/select-claim", body, [
        {"content-type", "application/x-www-form-urlencoded"},
        {"cookie", cookie}
      ])

    # Must NOT crash — a redirect, not a 500 / empty body.
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)
    assert config["admin_group_claim"] == "instance_admin"
    assert config["bootstrap_completed"] == "true"
    assert config["oidc_issuer"] == @issuer

    # Admin session minted (a fresh _nebu_admin_key cookie).
    assert session_cookie(conn) =~ "_nebu_admin_key="
  end

  # ── CSRF is REQUIRED — a POST without it is rejected, not silently accepted ───

  test "POST select-claim WITHOUT a CSRF token is rejected (CSRF protection intact)" do
    store = install_store(false)
    {_token, cookie} = render_select_claim_page()

    body = URI.encode_query(%{"admin_group_claim" => "instance_admin"})

    # protect_from_forgery rejects the missing token by raising
    # Plug.CSRFProtection.InvalidCSRFTokenError. With the render_errors fix this is
    # now the CLEAN primary exception (previously it was masked by a secondary
    # `(MatchError) ... []` from RenderErrors.put_formats with an empty :formats
    # list). The admin endpoint renders a 403 body and Phoenix re-raises the original
    # error (Bandit serves the already-sent 403 in production). The security
    # properties asserted here: CSRF was NOT disabled (it raises) AND the request
    # never completes bootstrap or writes the claim.
    # Nebu.Web.Router (Plug.Router) wraps the raised exception in a
    # Plug.Conn.WrapperError whose :reason is the CSRF error. We assert the wrapper
    # and confirm the wrapped reason is the CSRF rejection (NOT the previous
    # MatchError from RenderErrors). In production Bandit serves the already-rendered
    # 403 from this re-raise.
    err =
      assert_raise Plug.Conn.WrapperError, fn ->
        router_call(:post, "/admin/bootstrap/select-claim", body, [
          {"content-type", "application/x-www-form-urlencoded"},
          {"accept", "text/html"},
          {"cookie", cookie}
        ])
      end

    assert %Plug.CSRFProtection.InvalidCSRFTokenError{} = err.reason

    config = Agent.get(store, & &1.config)
    refute config["bootstrap_completed"] == "true"
    refute Map.has_key?(config, "admin_group_claim")
  end

  # ── out-of-token claim value is rejected (Kassandra C1) ───────────────────────

  test "POST select-claim with a claim value NOT in the verified token is rejected" do
    store = install_store(false)
    {token, cookie} = render_select_claim_page()

    body = URI.encode_query(%{"_csrf_token" => token, "admin_group_claim" => "all"})

    conn =
      router_call(:post, "/admin/bootstrap/select-claim", body, [
        {"content-type", "application/x-www-form-urlencoded"},
        {"cookie", cookie}
      ])

    assert conn.status == 302
    refute get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)
    refute config["admin_group_claim"] == "all"
    refute config["bootstrap_completed"] == "true"
  end

  # ── already-complete instance is inert (AC5) ──────────────────────────────────

  test "POST select-claim is inert once bootstrap is complete (AC5)" do
    store = install_store(true)
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "attacker"))

    # Mint a CSRF token bound to a fresh session (the callback itself is inert when
    # complete, so we cannot render the page; we still drive the REAL router POST).
    {token, cookie} = csrf_for_fresh_session()

    body = URI.encode_query(%{"_csrf_token" => token, "admin_group_claim" => "all"})

    conn =
      router_call(:post, "/admin/bootstrap/select-claim", body, [
        {"content-type", "application/x-www-form-urlencoded"},
        {"cookie", cookie}
      ])

    # Refused — redirect to /admin/login, never /admin/dashboard. Must NOT crash.
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/login"]
    refute Agent.get(store, &(&1.config["admin_group_claim"])) == "all"
  end

  # Mints a CSRF token + matching _nebu_admin_key cookie for a brand-new session,
  # the way protect_from_forgery + get_csrf_token couple them within one request.
  # protect_from_forgery installs the before_send that persists the unmasked CSRF
  # secret into the session, so the token validates on the subsequent POST.
  defp csrf_for_fresh_session do
    conn =
      %{conn(:get, "/admin/login") | secret_key_base: @secret_key_base}
      |> Nebu.Admin.Endpoint.admin_session([])
      |> fetch_session()
      |> Phoenix.Controller.protect_from_forgery()

    token = Plug.CSRFProtection.get_csrf_token()
    conn = conn |> resp(200, "") |> send_resp()
    {token, session_cookie(conn)}
  end
end
