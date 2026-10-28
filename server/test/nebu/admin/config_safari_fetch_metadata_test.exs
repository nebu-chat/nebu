defmodule Nebu.Admin.ConfigSafariFetchMetadataTest do
  @moduledoc """
  Story `safari-fetch-metadata-compat`, AC2 / AC3 / AC4 for the two legacy-SSO trust forms of `/admin/config`
  (`POST /admin/config/sso-origins`, `/sso-schemes`; gate `:marker` bound to `/admin/config`): the five request shapes of
  `safari_admin_actions_test.exs` (a Chrome set, b Safari set + proof, c Safari set without proof = notice, d fetch / iframe /
  cross-origin / missing Site-Mode-Dest, e `Sec-Fetch-User` present and not `?1` or the proof on a non-WebKit engine) and the
  hidden `_click_proof` field of both forms. No database: the writers and the config reader are stubbed like in
  `config_sso_trust_hardening_test.exs`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-safari-fetch-meta-b", 2)
  @path "/admin/config"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :safari_config_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_config_sso_origins_writer, fn changes ->
      send(test_pid, {:written, :origins, changes})
      :ok
    end)
    Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
      send(test_pid, {:written, :schemes, changes})
      :ok
    end)
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    T.put_env_scoped(:safari_config_audit_sink, self())
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_server_config_reader], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp admin_conn(method, path, params \\ nil) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> then(fn c -> if params, do: Map.put(c, :body_params, params) |> Map.put(:params, params), else: c end)
  end

  defp with_marker(conn), do: put_session(conn, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @path))
  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp chrome(path, params), do: admin_conn(:post, path, params) |> with_marker() |> T.put_strict_fetch_headers() |> put_req_header("user-agent", T.chrome_user_agent())
  defp safari(path, params, proof?), do: admin_conn(:post, path, if(proof?, do: T.with_click_proof(params), else: params)) |> with_marker() |> T.put_safari_fetch_headers()
  defp refused?(conn), do: conn.status == 403 and conn.resp_body =~ ~s(data-error="fetch_metadata")

  defp refute_nothing_written do
    refute_received {:written, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
  end

  for {label, path, params, kind} <- [
        {"origins", "/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://ok.example"}, :origins},
        {"schemes", "/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "myorg-matrix"}, :schemes}
      ] do
    describe "#{label}: the five request shapes" do
      test "(a) Chrome / Firefox set with Sec-Fetch-User: ?1 and no proof => saved (redirect), as before" do
        conn = chrome(unquote(path), unquote(Macro.escape(params))) |> call()
        assert conn.status in [302, 303]
        assert_received {:written, unquote(kind), _}
      end

      test "(b) Safari set (no Sec-Fetch-User) + proof => saved (redirect)" do
        conn = safari(unquote(path), unquote(Macro.escape(params)), true) |> call()
        assert conn.status in [302, 303], "got #{conn.status}"
        assert_received {:written, unquote(kind), _}
      end

      test "(c) Safari set without proof => 200 notice page, nothing written or audited, marker kept, the save repeatable" do
        {conn, log} = with_log(fn -> safari(unquote(path), unquote(Macro.escape(params)), false) |> call() end)
        assert conn.status == 200
        refute refused?(conn)
        assert conn.resp_body =~ ~s(data-page="oauth-activation-unproven")
        assert [back] = Floki.parse_document!(conn.resp_body) |> Floki.find(~s(a[data-role="back-to-list"]))
        assert Floki.attribute(back, "href") == [@path]
        assert Floki.text(back) =~ ~r/configuration page/i
        refute_nothing_written()
        assert conn.private.plug_session["admin_reauth"]["path"] == @path, "the marker is still bound to the page"
        assert log =~ ~r/click proof|activation/i
        refute log =~ "ok.example"
        assert get_resp_header(conn, "cache-control") == ["no-store"]

        again = safari(unquote(path), unquote(Macro.escape(params)), true) |> call()
        assert again.status in [302, 303]
        assert_received {:written, unquote(kind), _}
      end

      for {why, header, value} <- [
            {"fetch() (mode cors, dest empty)", "sec-fetch-mode", "cors"},
            {"fetch() (dest empty)", "sec-fetch-dest", "empty"},
            {"an iframe", "sec-fetch-dest", "iframe"},
            {"cross-site", "sec-fetch-site", "cross-site"},
            {"same-site", "sec-fetch-site", "same-site"}
          ] do
        test "(d) Safari + proof + #{why} => 403 refusal page, nothing written" do
          conn = safari(unquote(path), unquote(Macro.escape(params)), true) |> put_req_header(unquote(header), unquote(value)) |> call()
          assert refused?(conn)
          refute_nothing_written()
        end
      end

      for header <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest) do
        test "(d) Safari + proof + #{header} missing => 403, never the notice" do
          conn = safari(unquote(path), unquote(Macro.escape(params)), true) |> delete_req_header(unquote(header)) |> call()
          assert refused?(conn)
          assert refused?(safari(unquote(path), unquote(Macro.escape(params)), false) |> delete_req_header(unquote(header)) |> call())
          refute_nothing_written()
        end
      end

      test "(e) Sec-Fetch-User present and not ?1 with the proof => 403; the proof on Chrome / Firefox / no User-Agent without Sec-Fetch-User => 403" do
        for value <- ["?0", "1", ""] do
          assert refused?(safari(unquote(path), unquote(Macro.escape(params)), true) |> put_req_header("sec-fetch-user", value) |> call())
        end

        for ua <- [T.chrome_user_agent(), T.firefox_user_agent(), nil] do
          c = safari(unquote(path), unquote(Macro.escape(params)), true) |> delete_req_header("user-agent")
          c = if ua, do: put_req_header(c, "user-agent", ua), else: c
          assert refused?(call(c)), "UA #{inspect(ua)}"
        end

        refute_nothing_written()
      end

      test "order: the notice before the marker; the proof does not skip the marker (no marker + proof => redirect to the sign-in)" do
        params = unquote(Macro.escape(params))
        unproven = admin_conn(:post, unquote(path), params) |> T.put_safari_fetch_headers() |> call()
        assert unproven.status == 200 and unproven.resp_body =~ "oauth-activation-unproven"

        proven = admin_conn(:post, unquote(path), T.with_click_proof(params)) |> T.put_safari_fetch_headers() |> call()
        assert proven.status in [302, 303]
        assert (proven |> get_resp_header("location") |> List.first()) =~ "/admin/login/start"
        refute_nothing_written()
      end

      test "the proof field is not stored: only the real setting reaches the writer" do
        conn = safari(unquote(path), unquote(Macro.escape(params)), true) |> call()
        assert conn.status in [302, 303]
        assert_received {:written, unquote(kind), changes}
        refute inspect(changes) =~ "click_proof"
      end
    end
  end

  describe "AC4 — the forms of /admin/config carry the hidden _click_proof field" do
    test "sso-origins, sso-schemes, scopes and refresh-mode forms have an empty data-click-proof field" do
      page = admin_conn(:get, @path) |> call()
      assert page.status == 200
      doc = Floki.parse_document!(page.resp_body)

      for id <- ["sso-origins-form", "sso-schemes-form", "oidc-scopes-form", "oidc-refresh-mode-form"] do
        assert [form] = Floki.find(doc, "form##{id}")
        assert [field] = Floki.find(form, ~s(input[type="hidden"][name="_click_proof"]))
        assert Floki.attribute(field, "data-click-proof") != []
        assert Floki.attribute(field, "value") in [[""], []]
      end


    end
  end
end
