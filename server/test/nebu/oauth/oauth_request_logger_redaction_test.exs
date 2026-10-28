defmodule Nebu.OAuth.OAuthRequestLoggerRedactionTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC15 / D20 (No
  Sensitive Data in Logs law): `Nebu.Web.Plugs.RequestLogger`'s DEBUG query-string capture keeps
  ONLY the parameter names (`client_id=***&redirect_uri=***...`) for `/oauth2/authorize` and the
  shared IdP callback `/_matrix/client/v3/login/sso/redirect/oidc` (route-aware branch in
  `redacted_query_string/1`, like the send/state route awareness). Other paths keep today's
  behaviour.

  Driven through the full router with OAuth DISABLED (404/unavailable responses): the masking is
  a property of the request path, not of the endpoint outcome. No DB.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.disable_oauth()
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.clear_oauth_config()
    end)

    :ok
  end

  defp debug_log(fun), do: capture_log([level: :debug], fun)

  defp query_strings(log) do
    ~r/"query_string":"((?:[^"\\]|\\.)*)"/
    |> Regex.scan(log)
    |> Enum.map(fn [_, qs] -> qs end)
  end

  describe "AC15 — /oauth2/authorize: values masked, names kept" do
    test "client_id, redirect_uri, state, nonce, code_challenge, scope values never appear" do
      secrets = %{
        "client_id" => "cid-VALUE-1",
        "redirect_uri" => "https://app.example.com/cb?leak=REDIRECT-VALUE",
        "state" => "STATE-VALUE-xyz",
        "nonce" => "NONCE-VALUE-abc",
        "code_challenge" => "CHALLENGE-VALUE-0123456789012345678901234567",
        "scope" => "openid urn:matrix:client:device:DEVICE-VALUE"
      }

      log = debug_log(fn -> T.get("/oauth2/authorize?" <> URI.encode_query(secrets)) end)

      assert [qs | _] = query_strings(log), "the DEBUG line must carry a query_string field"
      for name <- Map.keys(secrets), do: assert(qs =~ "#{name}=***", "parameter name #{name} must be kept: #{qs}")

      for {_k, v} <- secrets, part <- ~w(VALUE-1 REDIRECT-VALUE STATE-VALUE NONCE-VALUE CHALLENGE-VALUE DEVICE-VALUE),
          String.contains?(v, part) do
        refute log =~ part, "#{part} leaked into the DEBUG log"
      end
    end
  end

  describe "AC15 — shared IdP callback: code AND state masked (o2. and legacy alike)" do
    test "code=...&state=o2.... is masked to names only" do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      log = debug_log(fn -> T.callback([{"code", "IDP-CODE-VALUE"}, {"state", state}]) end)

      assert [qs | _] = query_strings(log)
      assert qs =~ "code=***"
      assert qs =~ "state=***"
      refute log =~ "IDP-CODE-VALUE"
      refute log =~ state
      refute log =~ String.slice(state, 3, 20)
    end

    test "an IdP error callback: error_description values are not logged either" do
      log =
        debug_log(fn ->
          T.callback([{"error", "access_denied"}, {"error_description", "IDP-DESCRIPTION-VALUE"}, {"state", "o2.x"}])
        end)

      refute log =~ "IDP-DESCRIPTION-VALUE"
    end
  end

  describe "AC15 (review cycle 1, MINOR 2) — a trailing slash does not bypass the names-only masking" do
    test "/oauth2/authorize/ and the callback with a trailing slash are masked as well" do
      for path <- ["/oauth2/authorize/", "/oauth2/authorize//", "/_matrix/client/v3/login/sso/redirect/oidc/"] do
        log = debug_log(fn -> T.get(path <> "?state=TS-STATE-VALUE&nonce=TS-NONCE-VALUE&code=TS-CODE-VALUE") end)
        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "state=***" and qs =~ "nonce=***", "#{path}: #{qs}"
        for v <- ~w(TS-STATE-VALUE TS-NONCE-VALUE TS-CODE-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end
  end

  describe "AC15 — other paths keep today's query-string capture" do
    test "/sync keeps non-secret values and still redacts access_token" do
      log = debug_log(fn -> T.get("/_matrix/client/v3/sync?since=s1-KEEP&access_token=TOKEN-SECRET") end)
      assert log =~ "s1-KEEP", "non-OAuth paths are not masked wholesale"
      refute log =~ "TOKEN-SECRET"
    end

    test "/sso/redirect (legacy initiation) is not on the masked list" do
      log = debug_log(fn -> T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("https://keep.example.com/x")) end)
      assert log =~ "keep.example.com"
    end
  end
  # ── story 3 (oauth-token-endpoint, AC19 / T23): /oauth2/token joins @names_only_query_paths ──

  describe "AC19 (story 3) — /oauth2/token: query values masked, names kept" do
    test "POST and GET /oauth2/token?... keep only the parameter names" do
      for method <- [:post, :get] do
        log =
          debug_log(fn ->
            Plug.Test.conn(method, "/oauth2/token?client_id=TK-CLIENT-VALUE&state=TK-STATE-VALUE&redirect_uri=TK-REDIRECT-VALUE", "")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
          end)

        assert [qs | _] = query_strings(log), "no query_string logged for #{method}"
        assert qs =~ "client_id=***" and qs =~ "state=***" and qs =~ "redirect_uri=***", qs
        for v <- ~w(TK-CLIENT-VALUE TK-STATE-VALUE TK-REDIRECT-VALUE), do: refute(log =~ v, "#{v} leaked (#{method})")
      end
    end

    test "a trailing slash does not bypass the masking" do
      log = debug_log(fn -> T.get("/oauth2/token/?client_id=TS-TOKEN-CLIENT") end)
      assert [qs | _] = query_strings(log)
      assert qs =~ "client_id=***"
      refute log =~ "TS-TOKEN-CLIENT"
    end
  end

  # ── story 4 (oauth-token-revocation-logout, AC12 / R22): /oauth2/revoke joins @names_only_query_paths ──
  # Revoke is LIVE while OAuth is disabled (R13): a query string is a 400 there, the masking is a
  # property of the path. Red today: `/oauth2/revoke` is not on the names-only list.

  describe "AC12 (story 4) — /oauth2/revoke: query values masked, names kept" do
    test "POST /oauth2/revoke?token=... (also /oauth2/revoke/ and //oauth2//revoke) keeps only the names" do
      # dev-story fix: `Plug.Test.conn(:post, "//oauth2//revoke")` parses "//oauth2" as the URI
      # AUTHORITY (host "oauth2", path "//revoke"), which never reaches the route at all; the full
      # URL keeps the doubled slashes in `request_path`, as Bandit delivers them.
      for path <- ["/oauth2/revoke", "/oauth2/revoke/", "http://localhost//oauth2//revoke"] do
        log =
          debug_log(fn ->
            Plug.Test.conn(:post, path <> "?token=RV-TOKEN-VALUE&token_type_hint=RV-HINT-VALUE&client_id=RV-CLIENT-VALUE", "")
            |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
          end)

        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "token=***" and qs =~ "token_type_hint=***" and qs =~ "client_id=***", "#{path}: #{qs}"
        for v <- ~w(RV-TOKEN-VALUE RV-HINT-VALUE RV-CLIENT-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end
  end

  # ── story 6 (oauth-account-management, A22): /account and /account/reauth names-only ──

  describe "A22 (story 6) — /account query strings: names only" do
    test "GET /account?action=...&device_id=... and /account/reauth?... keep only the parameter names" do
      for path <- ["/account", "/account/", "/account/reauth"] do
        log = debug_log(fn -> T.get(path <> "?action=org.matrix.device_view&device_id=ACCT-DEV-VALUE&session_id=ACCT-SID-VALUE") end)
        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "device_id=***" and qs =~ "action=***", "#{path}: #{qs}"
        for v <- ~w(ACCT-DEV-VALUE ACCT-SID-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end
  end
  # ── story oauth-authorize-freshness (FR17 / AC14): /oauth2/consent names-only, body never captured ──
  # The masking is a property of the path (OAuth disabled here: the 404 pages still go through the logger).

  describe "FR17 (P3) — /oauth2/consent: query values masked, names kept, the form body never captured" do
    test "GET /oauth2/consent?... (also with a trailing slash) keeps only the parameter names" do
      for path <- ["/oauth2/consent", "/oauth2/consent/", "http://localhost//oauth2//consent"] do
        log =
          debug_log(fn ->
            Plug.Test.conn(:get, path <> "?csrf_token=CN-CSRF-VALUE&decision=CN-DECISION-VALUE&state=CN-STATE-VALUE")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
          end)

        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "csrf_token=***" and qs =~ "decision=***" and qs =~ "state=***", "#{path}: #{qs}"
        for v <- ~w(CN-CSRF-VALUE CN-DECISION-VALUE CN-STATE-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end

    test "POST /oauth2/consent: neither the query string values nor the form body values reach the DEBUG log" do
      log =
        debug_log(fn ->
          Plug.Test.conn(:post, "/oauth2/consent?csrf_token=CQ-QUERY-VALUE", "csrf_token=CB-BODY-CSRF-VALUE&decision=allow")
          |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
          |> Plug.Conn.put_req_header("cookie", "nebu_oauth_consent=CK-COOKIE-VALUE")
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        end)

      assert [qs | _] = query_strings(log)
      assert qs =~ "csrf_token=***"
      for v <- ~w(CQ-QUERY-VALUE CB-BODY-CSRF-VALUE CK-COOKIE-VALUE), do: refute(log =~ v, "#{v} leaked into the DEBUG log")
    end

    test "the router skips JsonBody for /oauth2/consent (FormPost parses the form itself)" do
      src = File.read!(Path.expand("../../../lib/nebu/web/plugs/json_body.ex", __DIR__)) |> String.replace(~r/#[^\n]*/, "")
      assert src =~ ~r/\[\s*"oauth2"\s*,\s*"consent"\s*(\||\])/, "JsonBody must skip [\"oauth2\", \"consent\" | _] like the account / token paths"
    end
  end

  # ── story legacy-sso-redirect-confirmation (G3-3, D12 / AC13): the confirmation page route joins @names_only_query_paths ──
  # The masking is a property of the path (OAuth disabled here: the answers still go through the logger). The full
  # flow with the INFO lines is in `server/test/nebu/matrix/sso_redirect_confirm_logging_test.exs`.

  describe "G3-3 — /_matrix/client/v3/login/sso/confirm: query values masked, names kept, the form body never captured" do
    @confirm_path "/_matrix/client/v3/login/sso/confirm"

    test "GET ...?csrf_token=...&decision=...&state=... (also with a trailing slash) keeps only the parameter names" do
      for path <- [@confirm_path, @confirm_path <> "/", "http://localhost/" <> @confirm_path] do
        log =
          debug_log(fn ->
            Plug.Test.conn(:get, path <> "?csrf_token=SC-CSRF-VALUE&decision=SC-DECISION-VALUE&state=SC-STATE-VALUE")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
          end)

        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "csrf_token=***" and qs =~ "decision=***" and qs =~ "state=***", "#{path}: #{qs}"
        for v <- ~w(SC-CSRF-VALUE SC-DECISION-VALUE SC-STATE-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end

    test "POST: neither the query string values nor the form body values nor the cookie reach the DEBUG log" do
      log =
        debug_log(fn ->
          Plug.Test.conn(:post, @confirm_path <> "?csrf_token=SQ-QUERY-VALUE", "csrf_token=SB-BODY-CSRF-VALUE&decision=continue")
          |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
          |> Plug.Conn.put_req_header("cookie", "nebu_sso_confirm=SK-COOKIE-VALUE")
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        end)

      assert [qs | _] = query_strings(log)
      assert qs =~ "csrf_token=***"
      for v <- ~w(SQ-QUERY-VALUE SB-BODY-CSRF-VALUE SK-COOKIE-VALUE), do: refute(log =~ v, "#{v} leaked into the DEBUG log")
    end

    test "the router skips JsonBody for the confirm path (the form is parsed from the RAW body, body_params stay unfetched)" do
      src =
        File.read!(Path.expand("../../../lib/nebu/web/plugs/json_body.ex", __DIR__))
        |> String.replace(~r/"""[\s\S]*?"""/, "")
        |> String.replace(~r/#[^\n]*/, "")

      assert src =~ ~r/\[\s*"_matrix"\s*,\s*"client"\s*,\s*"v3"\s*,\s*"login"\s*,\s*"sso"\s*,\s*"confirm"\s*\|\s*_\s*\]/
    end
  end
end
