defmodule Nebu.Admin.AdminReauthButtonFlowConfigTest do
  @moduledoc """
  Story `admin-reauth-button-flow`, forms 1 - 3 on `/admin/config` (SSO schemes, SSO origins, OAuth 2.0 authorization server switch), all bound to the ONE
  marker path `/admin/config`, and the two forms of the page that stay plain submits (OIDC scopes, OIDC refresh mode). Scenarios 1 - 5 of the story.

  The page decides at render time through `Nebu.Admin.Auth.reauth_fresh(conn, "/admin/config")`: stale = the link "Sign in again to save" (href =
  `Nebu.Admin.Auth.reauth_start_path("/admin/config")`) instead of the submit; fresh = the normal submit and a validity line in the hint element.
  See `Nebu.Admin.ReauthButtonFlowSupport` for the exact markup contract. No database: the config reader, the writers and the audit writer are the test seams
  of `config_sso_trust_hardening_test.exs` / `config_oauth_switch_test.exs`.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @page "/admin/config"
  @config_forms S.forms_of(@page)
  @issuer "https://chat.example.com"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :reauth_flow_config_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    test_pid = self()
    T.put_env_scoped(:admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    T.put_env_scoped(:reauth_flow_config_sink, self())
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)
    T.clear_oauth_config()

    for {key, label} <- [admin_config_sso_origins_writer: :origins, admin_config_sso_schemes_writer: :schemes, admin_config_scopes_writer: :scopes, admin_config_refresh_mode_writer: :refresh_mode] do
      Application.put_env(:nebu_http, key, fn changes ->
        send(test_pid, {:written, label, changes})
        :ok
      end)
    end

    Application.put_env(:nebu_http, :oauth_switch_tx, fn changes, audit ->
      send(test_pid, {:written, :oauth_switch, changes})

      case audit && audit.() do
        nil -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:audit, reason}}
      end
    end)

    on_exit(fn ->
      T.clear_oauth_config()

      for k <- [:admin_server_config_reader, :admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_scopes_writer, :admin_config_refresh_mode_writer, :oauth_switch_tx] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # the test env logs at :warning: a test that asserts that nothing leaks into the DEBUG log must admit it
  defp debug_logging! do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  defp refute_nothing_written do
    refute_received {:written, _}
    refute_received {:written, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
  end

  defp all_stale!(doc) do
    for form <- @config_forms, do: S.assert_stale!(doc, form)
    S.assert_plain_submit!(doc, "form#oidc-scopes-form", "Save scopes")
    S.assert_plain_submit!(doc, "form#oidc-refresh-mode-form", "Save refresh mode")
  end

  defp all_fresh!(doc, minutes) do
    for form <- @config_forms, do: S.assert_fresh!(doc, form, minutes)
    S.assert_plain_submit!(doc, "form#oidc-scopes-form", "Save scopes")
    S.assert_plain_submit!(doc, "form#oidc-refresh-mode-form", "Save refresh mode")
  end

  # ── scenario 1: without a fresh sign-in the primary control is a link ────────────────────────

  describe "scenario 1 - stale: Sign in again link" do
    for form <- @config_forms do
      test "#{form.key}: link with exact text and href, described by the hint, no submit" do
        conn = S.get(@page)
        assert conn.status == 200
        link = S.assert_stale!(S.doc(conn), unquote(Macro.escape(form)))
        assert S.norm(link) == "Sign in again to save"
      end
    end

    test "the three forms share the ONE marker path /admin/config: the three links carry the same href" do
      hrefs = S.get(@page) |> S.doc() |> S.signin_hrefs()
      assert hrefs == List.duplicate(Auth.reauth_start_path("/admin/config"), 3)
      assert Auth.reauth_start_path("/admin/config") == "/admin/login/start?mode=reauth&return_to=%2Fadmin%2Fconfig"
    end

    test "scopes and refresh mode stay plain submits in every marker state" do
      for marker <- [nil, [ago: 30], [ago: 310], [path: "/admin/config/claim-mapping"]] do
        doc = S.get(@page, marker) |> S.doc()
        S.assert_plain_submit!(doc, "form#oidc-scopes-form", "Save scopes")
        S.assert_plain_submit!(doc, "form#oidc-refresh-mode-form", "Save refresh mode")
      end
    end

    test "the link is built from the page path: no query string parameter reaches it" do
      conn = S.get("/admin/config?return_to=%2Fadmin%2Fdashboard&mode=reauth&leak=secret-qs-77&sso_extra_redirect_schemes=secret-qs-78")
      doc = S.doc(conn)
      assert S.signin_hrefs(doc) == List.duplicate(Auth.reauth_start_path("/admin/config"), 3)
      refute conn.resp_body =~ "secret-qs-7"
    end

    test "the old hint wording is gone from the page and the hint ids stay" do
      conn = S.get(@page)
      refute conn.resp_body =~ "If you are asked to sign in again"
      for id <- ["sso-schemes-reauth-hint", "sso-origins-reauth-hint", "oauth-switch-reauth-hint"], do: assert([_] = Floki.find(S.doc(conn), "##{id}"))
    end

    test "the inputs of the forms stay editable and keep their names (a change can be typed before the sign-in)" do
      doc = S.get(@page) |> S.doc()

      for {selector, name} <- [{"form#sso-schemes-form", "sso_extra_redirect_schemes"}, {"form#sso-origins-form", "sso_redirect_allowed_origins"}, {"form#oauth-switch-form", "oauth_issuer_url"}] do
        assert [f] = Floki.find(doc, selector)
        assert [input] = Floki.find(f, ~s(input[name="#{name}"]))
        assert Floki.attribute(input, "disabled") == []
      end
    end
  end

  # ── scenario 2: with a fresh sign-in the normal button and the validity line ─────────────────

  describe "scenario 2 - fresh: submit and validity line" do
    for form <- @config_forms do
      test "#{form.key}: normal submit, validity line with minutes and one save" do
        conn = S.get(@page, ago: 30)
        assert conn.status == 200
        button = S.assert_fresh!(S.doc(conn), unquote(Macro.escape(form)), 4)
        assert S.norm(button) == unquote(form.normal)
      end
    end

    test "one marker bound to /admin/config unlocks ALL THREE forms at once" do
      all_fresh!(S.get(@page, ago: 30) |> S.doc(), 4)
    end

    test "the minutes are the remaining whole minutes, rounded down" do
      for {ago, minutes} <- [{30, 4}, {130, 2}, {190, 1}, {250, :less}, {270, :less}] do
        all_fresh!(S.get(@page, ago: ago) |> S.doc(), minutes)
      end
    end

    test "a marker made just now says 4 or 5 minutes (never more, never 'less than a minute')" do
      doc = S.get(@page, ago: 0) |> S.doc()

      for form <- @config_forms do
        text = S.assert_fresh_hint!(doc, form, :any)
        assert text =~ ~r/\b(4|5) (more )?minutes\b/i
      end
    end

    test "the page of a fresh marker has no sign-in link at all" do
      assert S.get(@page, ago: 30) |> S.doc() |> S.signin_hrefs() == []
    end

    test "the state is decided per request: aged past 300 s the links are back" do
      S.get(@page, ago: 280) |> S.doc() |> all_fresh!(:less)
      S.get(@page, ago: 320) |> S.doc() |> all_stale!()
    end
  end

  # ── scenario 3: after a successful save the link comes back ────────────────────────────────────

  describe "scenario 3 - the link comes back after a save" do
    test "SSO schemes saved: the next page (real cookie) shows the three links again" do
      post = S.post("/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "myorg-matrix"}, @page, ago: 10)
      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [@page]
      assert_received {:written, :schemes, %{"sso_extra_redirect_schemes" => "myorg-matrix"}}

      next = S.next_get(post, @page)
      assert next.status == 200
      all_stale!(S.doc(next))
    end

    test "SSO origins saved: the three links come back" do
      post = S.post("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://ok.example"}, @page, ago: 10)
      assert post.status in [302, 303]
      assert_received {:written, :origins, _}
      all_stale!(S.next_get(post, @page) |> S.doc())
    end

    test "OAuth switch saved: the three links come back" do
      post = S.post("/admin/config/oauth-switch", %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer, "oauth_activation_ack" => "true"}, @page, ago: 10)
      assert post.status in [302, 303]
      assert_received {:written, :oauth_switch, %{"oauth_enabled" => "true"}}
      all_stale!(S.next_get(post, @page) |> S.doc())
    end

    test "a validation error keeps the marker: the re-render is still fresh" do
      for {path, params} <- [
            {"/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "bad scheme!"}},
            {"/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "http://plain-http.example"}},
            {"/admin/config/oauth-switch", %{"oauth_enabled" => "true", "oauth_issuer_url" => "not a url", "oauth_activation_ack" => "true"}}
          ] do
        post = S.post(path, params, @page, ago: 30)
        assert post.status == 200, path
        all_fresh!(S.doc(post), 4)
        assert post.private.plug_session["admin_reauth"] != nil, path
        refute_nothing_written()
      end
    end

    test "a scopes save does not touch the marker: the forms keep their state" do
      post = S.post("/admin/config/scopes", %{"matrix_oidc_extra_scopes" => "profile", "admin_oidc_extra_scopes" => "profile"}, @page, ago: 30)
      assert post.status in [302, 303]
      assert_received {:written, :scopes, _}
      all_fresh!(S.next_get(post, @page) |> S.doc(), 4)
    end

    test "a rejected scopes value re-renders in the state of the marker" do
      bad = %{"matrix_oidc_extra_scopes" => "bad;scope", "admin_oidc_extra_scopes" => ""}
      stale = S.post("/admin/config/scopes", bad)
      assert stale.status == 200
      all_stale!(S.doc(stale))

      fresh = S.post("/admin/config/scopes", bad, @page, ago: 30)
      assert fresh.status == 200
      all_fresh!(S.doc(fresh), 4)
      refute_nothing_written()
    end

    test "a refresh mode save without a valid value re-renders in the state of the marker" do
      stale = S.post("/admin/config/refresh-mode", %{"matrix_oidc_refresh_mode" => "bogus"})
      assert stale.status == 200
      all_stale!(S.doc(stale))
      all_fresh!(S.post("/admin/config/refresh-mode", %{"matrix_oidc_refresh_mode" => "bogus"}, @page, ago: 30) |> S.doc(), 4)
    end
  end

  # ── scenario 4: the marker expires while the page is open ───────────────────────────────────────

  describe "scenario 4 - marker expires while the page is open" do
    for {key, path, params, canary} <- [
          {:sso_schemes, "/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "canary-scheme-zq81"}, "canary-scheme-zq81"},
          {:sso_origins, "/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://canary-origin-zq82.example"}, "canary-origin-zq82"},
          {:oauth_switch, "/admin/config/oauth-switch", %{"oauth_enabled" => "true", "oauth_issuer_url" => "https://canary-issuer-zq83.example", "oauth_activation_ack" => "true"}, "canary-issuer-zq83"}
        ] do
      test "#{key}: refused after 300 s, redirect to the sign-in, nothing saved, no value leaks" do
        debug_logging!()
        form = S.form(unquote(key))
        # 1. the page was rendered in the fresh state ...
        S.assert_fresh!(S.get(@page, ago: 20) |> S.doc(), form, 4)

        # 2. ... and the marker is older than 300 s when the button is pressed
        {post, log} = with_log([level: :debug], fn -> S.post(unquote(path), unquote(Macro.escape(params)), @page, ago: 310) end)

        assert post.status in [302, 303]
        assert get_resp_header(post, "location") == [Auth.reauth_start_path("/admin/config")]
        [location] = get_resp_header(post, "location")
        refute location =~ unquote(canary), "no form value in the redirect URL"
        refute location =~ "canary"
        refute post.resp_body =~ unquote(canary)
        refute_nothing_written()
        refute log =~ unquote(canary), "no form value in any log line"
        refute log =~ S.sub(), "no marker content in any log line"
        refute log =~ "admin_reauth"

        # 3. the page the admin lands on after the refusal is rendered stale: the link, no submit, and nothing of the refused POST is replayed or prefilled
        S.assert_stale!(S.get(@page, ago: 310) |> S.doc(), form)
        S.assert_no_replay!(post, @page, [unquote(canary)], ago: 310)
      end
    end

    test "at the edge: 270 s old is fresh (less than a minute), 310 s old is stale" do
      S.assert_fresh!(S.get(@page, ago: 270) |> S.doc(), S.form(:sso_schemes), :less)
      S.assert_stale!(S.get(@page, ago: 310) |> S.doc(), S.form(:sso_schemes))
    end

    test "a marker from the far future never makes a page fresh" do
      all_stale!(S.get(@page, ago: -120) |> S.doc())
    end
  end

  # ── scenario 5: a fresh sign-in for another page does not unlock this page ─────────────────────

  describe "scenario 5 - another marker does not unlock" do
    for {label, other} <- [
          {"claim mapping", "/admin/config/claim-mapping"},
          {"role mapping", "/admin/config/role-mapping"},
          {"media settings", "/admin/media/settings"},
          {"an approve confirm page", "/admin/oauth/registrations/c1/approve"},
          {"a revoke confirm page", "/admin/oauth/clients/c1/revoke"},
          {"the config page with a trailing slash", "/admin/config/"}
        ] do
      test "a marker bound to #{label} leaves the three forms stale" do
        all_stale!(S.get(@page, path: unquote(other)) |> S.doc())
      end
    end

    test "a fresh marker of another subject leaves the three forms stale" do
      all_stale!(S.get(@page, sub: "somebody-else") |> S.doc())
    end

    test "a marker without a path (the old unbound shape) leaves the three forms stale" do
      conn =
        S.admin_conn(:get, @page)
        |> put_session("admin_reauth", T.fresh_marker(S.sub(), 5, "auth_time", nil))
        |> S.call()

      all_stale!(S.doc(conn))
    end

    test "the link never returns to another page, whatever marker the session holds" do
      for marker <- [nil, [path: "/admin/config/claim-mapping"], [path: "/admin/media/settings"], [ago: 400]] do
        doc = S.get(@page, marker) |> S.doc()
        S.assert_clean_links!(doc, ["/admin/config"])
        assert length(S.signin_hrefs(doc)) == 3, "stale: three links, not none (a vacuous check proves nothing)"
      end
    end
  end

  # ── no secret, form value or marker content in a link or a log line ────────────────────────────

  describe "no secret or form value in links or logs" do
    test "a rejected value shown again in its field never reaches a link of the page (fresh and stale), and no log line carries it" do
      debug_logging!()

      {fresh, log} =
        with_log([level: :debug], fn -> S.post("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "http://leak-me-91.example"}, @page, ago: 30) end)

      assert fresh.status == 200
      doc = S.doc(fresh)
      S.assert_clean_links!(doc, ["/admin/config"])
      refute doc |> Floki.find("a") |> Enum.flat_map(&Floki.attribute(&1, "href")) |> Enum.any?(&(&1 =~ "leak-me-91"))
      refute log =~ "leak-me-91"
    end

    test "rendering the page in either state logs no marker content and no form value" do
      debug_logging!()

      log =
        capture_log([level: :debug], fn ->
          for marker <- [nil, [ago: 30], [ago: 310], [path: "/admin/config/claim-mapping"]], do: S.get(@page, marker)
        end)

      refute log =~ S.sub()
      refute log =~ "admin_reauth"
      refute log =~ "return_to"
    end
  end
end
