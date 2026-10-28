defmodule Nebu.Admin.ConfigOAuthSwitchSafariTest do
  @moduledoc """
  Story `admin-oauth-switch`, AC2 (decision D4) with the Safari rules of story `safari-fetch-metadata-compat`: the OAuth switch
  form (`POST /admin/config/oauth-switch`) uses the SAME mechanism as the two SSO trust forms, no third one. The five request
  shapes of `config_safari_fetch_metadata_test.exs` (a Chrome / Firefox set, b Safari set + proof, c Safari set without proof =
  notice, d fetch / iframe / cross-origin / a missing Site-Mode-Dest, e `Sec-Fetch-User` present and not `?1` or the proof on a
  non-WebKit engine) hold for it in BOTH directions (on and off). No database: the config reader, the transaction function of
  `Nebu.OAuth.SwitchStore` (`:oauth_switch_tx`) and the audit writer are stubbed.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-oauth-switch-safari-bas", 3)
  @path "/admin/config"
  @post "/admin/config/oauth-switch"
  @issuer "https://chat.example.com"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :oauth_switch_safari_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, [{"oauth_enabled", "true"}, {"oauth_issuer_url", @issuer}]} end)

    Application.put_env(:nebu_http, :oauth_switch_tx, fn changes, audit ->
      send(test_pid, {:tx, changes})
      if audit, do: audit.()
      :ok
    end)

    T.put_env_scoped(:oauth_switch_safari_sink, self())
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_server_config_reader, :oauth_switch_tx], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp admin_conn(method, path, params) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
  end

  defp with_marker(conn), do: put_session(conn, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @path))
  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp chrome(params), do: admin_conn(:post, @post, params) |> with_marker() |> T.put_strict_fetch_headers() |> put_req_header("user-agent", T.chrome_user_agent())
  defp safari(params, proof?), do: admin_conn(:post, @post, if(proof?, do: T.with_click_proof(params), else: params)) |> with_marker() |> T.put_safari_fetch_headers()
  defp refused?(conn), do: conn.status == 403 and conn.resp_body =~ ~s(data-error="fetch_metadata")

  defp refute_nothing_written do
    refute_received {:tx, _}
    refute_received {:audit, _, _, _, _, _, _, _}
  end

  for {label, params} <- [
        {"switching off (the kill switch)", %{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer}},
        {"changing the issuer while on", %{"oauth_enabled" => "true", "oauth_issuer_url" => "https://other.example.com", "oauth_activation_ack" => "true"}}
      ] do
    describe "#{label}: the five request shapes" do
      test "(a) Chrome / Firefox set with Sec-Fetch-User: ?1 and no proof => saved (redirect)" do
        conn = chrome(unquote(Macro.escape(params))) |> call()
        assert conn.status in [302, 303], "got #{conn.status}"
        assert_received {:tx, _}
      end

      test "(b) Safari set (no Sec-Fetch-User) + proof => saved (redirect), audited, the marker consumed" do
        conn = safari(unquote(Macro.escape(params)), true) |> call()
        assert conn.status in [302, 303], "got #{conn.status}"
        assert_received {:tx, _}
        assert_received {:audit, "@admin:test.local", "oauth_switch_changed", _, _, _, "success", _}
        assert conn.private.plug_session["admin_reauth"] == nil
      end

      test "(c) Safari set without proof => 200 notice page, nothing written or audited, marker kept, the save repeatable" do
        {conn, log} = with_log(fn -> safari(unquote(Macro.escape(params)), false) |> call() end)
        assert conn.status == 200
        refute refused?(conn)
        assert conn.resp_body =~ ~s(data-page="oauth-activation-unproven")
        assert [back] = Floki.parse_document!(conn.resp_body) |> Floki.find(~s(a[data-role="back-to-list"]))
        assert Floki.attribute(back, "href") == [@path]
        refute_nothing_written()
        assert conn.private.plug_session["admin_reauth"]["path"] == @path
        assert log =~ ~r/click proof|activation/i
        refute log =~ "other.example.com"
        assert get_resp_header(conn, "cache-control") == ["no-store"]

        again = safari(unquote(Macro.escape(params)), true) |> call()
        assert again.status in [302, 303]
        assert_received {:tx, _}
      end

      for {why, header, value} <- [
            {"fetch() (mode cors)", "sec-fetch-mode", "cors"},
            {"fetch() (dest empty)", "sec-fetch-dest", "empty"},
            {"an iframe", "sec-fetch-dest", "iframe"},
            {"cross-site", "sec-fetch-site", "cross-site"},
            {"same-site", "sec-fetch-site", "same-site"}
          ] do
        test "(d) Safari + proof + #{why} => 403, nothing written" do
          conn = safari(unquote(Macro.escape(params)), true) |> put_req_header(unquote(header), unquote(value)) |> call()
          assert refused?(conn)
          refute_nothing_written()
        end
      end

      for header <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest) do
        test "(d) Safari + proof + #{header} missing => 403, never the notice" do
          assert refused?(safari(unquote(Macro.escape(params)), true) |> delete_req_header(unquote(header)) |> call())
          assert refused?(safari(unquote(Macro.escape(params)), false) |> delete_req_header(unquote(header)) |> call())
          refute_nothing_written()
        end
      end

      test "(e) Sec-Fetch-User present and not ?1 with the proof => 403; the proof on Chrome / Firefox / no User-Agent => 403" do
        for value <- ["?0", "1", ""] do
          assert refused?(safari(unquote(Macro.escape(params)), true) |> put_req_header("sec-fetch-user", value) |> call())
        end

        for ua <- [T.chrome_user_agent(), T.firefox_user_agent(), nil] do
          c = safari(unquote(Macro.escape(params)), true) |> delete_req_header("user-agent")
          c = if ua, do: put_req_header(c, "user-agent", ua), else: c
          assert refused?(call(c)), "UA #{inspect(ua)}"
        end

        refute_nothing_written()
      end

      test "the notice comes before the marker, the proof does not skip the marker" do
        unproven = admin_conn(:post, @post, unquote(Macro.escape(params))) |> T.put_safari_fetch_headers() |> call()
        assert unproven.status == 200 and unproven.resp_body =~ "oauth-activation-unproven"

        proven = admin_conn(:post, @post, T.with_click_proof(unquote(Macro.escape(params)))) |> T.put_safari_fetch_headers() |> call()
        assert proven.status in [302, 303]
        assert (proven |> get_resp_header("location") |> List.first()) =~ "/admin/login/start"
        refute_nothing_written()
      end

      test "the proof field is not stored and not audited: only the two oauth keys reach the transaction" do
        conn = safari(unquote(Macro.escape(params)), true) |> call()
        assert conn.status in [302, 303]
        assert_received {:tx, changes}
        assert Map.keys(changes) |> Enum.sort() == ["oauth_enabled", "oauth_issuer_url"]
        assert_received {:audit, _, _, _, _, meta, _, _}
        refute inspect(meta) =~ "click_proof"
      end
    end
  end

  describe "switching ON (the activation itself): the same gate" do
    setup do
      Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
      :ok
    end

    @on %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer, "oauth_activation_ack" => "true"}

    test "(a) Chrome / Firefox => saved" do
      conn = chrome(@on) |> call()
      assert conn.status in [302, 303]
      assert_received {:tx, %{"oauth_enabled" => "true"}}
    end

    test "(b) Safari + proof => saved and audited" do
      conn = safari(@on, true) |> call()
      assert conn.status in [302, 303]
      assert_received {:tx, %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}}
      assert_received {:audit, _, "oauth_switch_changed", _, _, %{"enabled_after" => true}, "success", _}
    end

    test "(c) Safari without proof => the notice page, nothing written" do
      conn = safari(@on, false) |> call()
      assert conn.status == 200 and conn.resp_body =~ "oauth-activation-unproven"
      refute_nothing_written()
    end

    test "(d) Safari + proof + fetch() => 403" do
      conn = safari(@on, true) |> put_req_header("sec-fetch-mode", "cors") |> call()
      assert refused?(conn)
      refute_nothing_written()
    end
  end

  describe "the form carries the hidden _click_proof field and the page loads the shared script" do
    test "the form has the empty hidden field with data-click-proof; the admin layout loads app.js, which equals the shared script" do
      page = admin_conn(:get, @path, %{}) |> call()
      assert page.status == 200
      doc = Floki.parse_document!(page.resp_body)
      assert [form] = Floki.find(doc, "form#oauth-switch-form")
      assert [field] = Floki.find(form, ~s(input[type="hidden"][name="_click_proof"]))
      assert Floki.attribute(field, "data-click-proof") != []
      assert Floki.attribute(field, "value") in [[""], []]
      assert Floki.find(doc, ~s(script[src*="app.js"])) != []

      app_js = File.read!(Path.expand("../../../priv/static/assets/app.js", __DIR__))
      assert app_js =~ Nebu.Web.ClickProofScript.script()
    end
  end
end
