defmodule Nebu.Matrix.SsoRedirectConfirmLoggingTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC13 / D12 (No Sensitive Data
  in Logs law), scoped from the CALLBACK onward: `CaptureLog` at DEBUG over the callback, `GET`, Continue, Cancel,
  a refused POST and `POST /login` contains no loginToken, `id_token`, IdP refresh token, binding cookie value or
  its hash, CSRF token, or the redirect URL's path, query or fragment (test URL with distinctive markers). The
  redirect leg is NOT in scope: its own DEBUG line keeps the redirectUrl visible today (story L-2, follow-up i5 =
  mask it), so every flow here starts the leg BEFORE the capture. The INFO lines of D12 appear with the host only:

      matrix SSO: redirect confirmation shown host=<host>
      matrix SSO: redirect confirmation confirmed host=<host> / ... declined host=<host>

  `Nebu.Web.Plugs.RequestLogger`: the confirm path's query string is logged names-only
  (`@names_only_query_paths`), the POST body is never captured (JsonBody skip), `Location` / `Set-Cookie` are not
  part of the capture. Plug level, IdP stubbed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.drop_confirm_entries!()
    T.drop_token_entries!()
    T.sso_no_trusted_origins!()
    T.sso_origins!([])
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.restore_rate_limits()
      T.drop_confirm_entries!()
    end)

    {:ok, priv: priv}
  end

  defp assert_no_secrets(log, secrets) do
    for {name, value} <- secrets, is_binary(value), byte_size(value) >= 6 do
      refute String.contains?(log, value), "secret #{name} leaked into the log"
    end
  end

  defp query_strings(log) do
    ~r/"query_string":"((?:[^"\\]|\\.)*)"/
    |> Regex.scan(log)
    |> Enum.map(fn [_, qs] -> qs end)
  end

  @url "https://Logs.Unlisted.Example:8443/PATH-MARKER-1?query=QUERY-MARKER-2#FRAG-MARKER-3"

  describe "AC13 — a full flow at DEBUG: Continue" do
    test "no token, id_token, refresh token, cookie, hash, CSRF token, path, query or fragment in the log; INFO lines carry the host", %{priv: priv} do
      idp_rt = "idp-rt-LOGMARK-" <> T.rand(8)
      sub = T.unique_sub()
      # the redirect leg is NOT part of AC13: its DEBUG line keeps the redirectUrl visible today (story L-2)
      flow = T.sso_start!(@url)

      {secrets, log} =
        with_log(fn ->
          cb = T.sso_finish(flow, priv, sub: sub, idp_rt: idp_rt)
          T.assert_confirm_redirect(cb)
          {_name, cookie, _raw} = T.sso_confirm_cookie(cb)
          entry = T.confirm_entry(cookie)
          page = T.sso_confirm_get(cb)
          csrf = T.csrf_from(page)

          # a refused POST first (cross-site), then the real Continue
          bad =
            T.sso_confirm_post([{"csrf_token", csrf}, {"decision", "continue"}],
              cookie: cb,
              origin: "https://evil-log.example.org",
              headers: [{"sec-fetch-site", "cross-site"}]
            )

          T.assert_confirm_error(bad, 403, "forbidden")
          post = T.confirm!(cb, :continue)
          token = T.assert_continue_redirect(post)

          [
            {"login token", token},
            {"id_token", entry.id_token},
            {"idp refresh token", idp_rt},
            {"binding cookie", cookie},
            {"cookie hash hex", T.sha256_hex(cookie)},
            {"cookie hash b64", Base.url_encode64(:crypto.hash(:sha256, cookie), padding: false)},
            {"csrf token", csrf},
            {"location header", T.location(post)},
            {"path", "PATH-MARKER-1"},
            {"query", "QUERY-MARKER-2"},
            {"fragment", "FRAG-MARKER-3"},
            {"origin of the refused post", "evil-log.example.org"}
          ]
        end)

      assert_no_secrets(log, secrets)
      assert log =~ "[info] matrix SSO: redirect confirmation shown host=logs.unlisted.example:8443"
      assert log =~ "[info] matrix SSO: redirect confirmation confirmed host=logs.unlisted.example:8443"
      assert log =~ "[warning] matrix SSO: confirmation request refused"
    end
  end

  describe "AC13 — Cancel" do
    test "declined host=<host>, nothing else of the URL", %{priv: priv} do
      flow = T.sso_start!(@url)

      {secrets, log} =
        with_log(fn ->
          cb = T.sso_finish(flow, priv, idp_rt: "idp-rt-CANCELMARK-1")
          {_, cookie, _} = T.sso_confirm_cookie(cb)
          csrf = T.csrf_from(T.sso_confirm_get(cb))
          cancel = T.confirm!(cb, :cancel)
          assert cancel.status == 200
          [{"cookie", cookie}, {"csrf", csrf}, {"path", "PATH-MARKER-1"}, {"query", "QUERY-MARKER-2"}, {"fragment", "FRAG-MARKER-3"}, {"idp rt", "idp-rt-CANCELMARK-1"}]
        end)

      assert_no_secrets(log, secrets)
      assert log =~ "[info] matrix SSO: redirect confirmation declined host=logs.unlisted.example:8443"
    end
  end

  describe "AC13 — the redirect leg and the callback" do
    test "the callback query stays names-only; no path, query or fragment of the target is logged by the callback", %{priv: priv} do
      flow = T.sso_start!(@url)
      log = capture_log(fn -> T.sso_finish(flow, priv) end)

      callback_qs = log |> query_strings() |> Enum.filter(&(&1 =~ "code="))
      assert [qs | _] = callback_qs
      assert qs =~ "code=***" and qs =~ "state=***", "callback query values are masked: #{qs}"
      # the callback's INFO / debug lines must not carry the target path, query or fragment
      for marker <- ["PATH-MARKER-1", "QUERY-MARKER-2", "FRAG-MARKER-3"], do: refute(log =~ marker, "#{marker} leaked into the callback log")
    end

    test "a rejected redirectUrl logs only the value-free WARNING (unchanged)" do
      log = capture_log(fn -> T.sso_redirect([], redirect_url: "https://evil.example\\@PATH-MARKER-1.example/") end)
      assert log =~ "[warning] matrix SSO: redirectUrl rejected by allowlist"
      # the leg's own DEBUG request line keeps the redirectUrl by design (L-2); the WARNING itself is value-free
      warnings = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]"))
      assert warnings != []
      for line <- warnings, do: refute(line =~ "PATH-MARKER-1", "the WARNING must not carry the URL: #{line}")
    end
  end

  describe "AC13 — RequestLogger on the confirm path" do
    test "GET /sso/confirm?... keeps only the parameter names (also with a trailing slash)" do
      for path <- ["/_matrix/client/v3/login/sso/confirm", "/_matrix/client/v3/login/sso/confirm/"] do
        log =
          capture_log([level: :debug], fn ->
            T.sso_confirm_get(nil, query: "?csrf_token=CN-CSRF-VALUE&decision=CN-DECISION-VALUE&state=CN-STATE-VALUE")
            Plug.Test.conn(:get, path <> "?csrf_token=CN-CSRF-VALUE&decision=CN-DECISION-VALUE")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
          end)

        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "csrf_token=***" and qs =~ "decision=***", "#{path}: #{qs}"
        for v <- ~w(CN-CSRF-VALUE CN-DECISION-VALUE CN-STATE-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end

    test "POST /sso/confirm: neither the query string values nor the form body values nor the cookie reach the DEBUG log" do
      log =
        capture_log([level: :debug], fn ->
          Plug.Test.conn(:post, "/_matrix/client/v3/login/sso/confirm?csrf_token=CQ-QUERY-VALUE", "csrf_token=CB-BODY-CSRF-VALUE&decision=continue")
          |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
          |> Plug.Conn.put_req_header("cookie", "nebu_sso_confirm=CK-COOKIE-VALUE")
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        end)

      assert [qs | _] = query_strings(log)
      assert qs =~ "csrf_token=***"
      for v <- ~w(CQ-QUERY-VALUE CB-BODY-CSRF-VALUE CK-COOKIE-VALUE), do: refute(log =~ v, "#{v} leaked into the DEBUG log")
    end

    test "Location and Set-Cookie are not part of the DEBUG capture (pinned)", %{priv: priv} do
      flow = T.sso_start!(@url)

      {cookie, log} =
        with_log(fn ->
          cb = T.sso_finish(flow, priv)
          {_, cookie, _raw} = T.sso_confirm_cookie(cb)
          cookie
        end)

      refute log =~ cookie
      refute log =~ ~r/set-cookie/i
      refute log =~ ~r/"location"/i
    end
  end

  describe "AC13 — POST /login with the token (needs the DB)" do
    @describetag :integration

    test "the redeemed loginToken and the id_token never reach the log", %{priv: priv} do
      flow = T.sso_start!("https://unlisted.example/cb")

      {secrets, log} =
        with_log(fn ->
          cb = T.sso_finish(flow, priv)
          {_, cookie, _} = T.sso_confirm_cookie(cb)
          entry = T.confirm_entry(cookie)
          token = T.confirm!(cb, :continue) |> T.assert_continue_redirect()
          login = T.sso_token_login(token)
          assert login.status == 200
          [{"login token", token}, {"id_token", entry.id_token}, {"access token", T.json(login)["access_token"]}]
        end)

      assert_no_secrets(log, secrets)
    end
  end
end
