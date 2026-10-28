defmodule Nebu.OAuth.OAuthRevokeLoggingTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-revocation-logout` (story 4 of epic
  oauth-broker), AC12 / R21 / R22 / Must #34 (No Sensitive Data in Logs law): log capture at
  `:debug` over the AC6 rows (revoked, unknown, malformed, legacy, parse errors, 429, 503, 500)
  and OAuth `/logout` / `/logout/all`. No log line may carry an access / refresh token (presented,
  new or junk), a token hash, the `token_type_hint` VALUE, the PRESENTED `client_id` value, the IdP
  refresh token or its ciphertext, or an Authorization header value. The R21 INFO line carries
  `outcome=` and `client_id_match=`.

  `RequestLogger`: `/oauth2/revoke` joins `@names_only_query_paths` (also with trailing / doubled
  slashes) and its request body is never captured.

  Red today: `/oauth2/revoke` is not routed and not on the names-only list; no revoke INFO line.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_revoke_test_hook], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp debug_log(fun), do: capture_log([level: :debug], fun)
  defp dev, do: "LG" <> String.upcase(T.rand(4))

  defp session(cid, priv, idp_rt \\ nil) do
    opts = [authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())}]
    opts = if idp_rt, do: Keyword.put(opts, :idp_rt, idp_rt), else: opts
    T.session!(cid, @https, priv, opts)
  end

  defp query_strings(log) do
    ~r/"query_string":"((?:[^"\\]|\\.)*)"/
    |> Regex.scan(log)
    |> Enum.map(fn [_, qs] -> qs end)
  end

  defp secrets_of(s) do
    row = T.row_by_at(s.at) || %{}

    %{
      at: s.at,
      rt: s.rt,
      at_hash: T.token_hash(s.at),
      rt_hash: T.token_hash(s.rt),
      idp_rt: s.idp_rt,
      idp_rt_enc: row["oidc_refresh_token"]
    }
  end

  test "revoked / unknown / malformed / legacy / parse-error / 429 / 503 / 500 paths never log a secret (Must #34)", %{cid: cid, priv: priv} do
    s = session(cid, priv, "idp-rt-LOGSECRET-" <> T.rand(6))
    secrets = secrets_of(s)
    uid = T.provision_user!()
    legacy = T.legacy_session!(uid, dev())
    junk_token = "JUNKTOKEN-" <> T.rand(8)
    unknown = T.rand(32)
    presented_client = "PRESENTED-CLIENT-" <> T.rand(6)
    hint_value = "HINTVALUE" <> T.rand(4)
    bearer = "AUTHZVALUE" <> T.rand(8)
    ip = T.unique_ip()

    log =
      debug_log(fn ->
        T.revoke(T.revoke_params(s.at, hint_value, presented_client), headers: [{"authorization", "Bearer " <> bearer}]) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(unknown, "access_token", presented_client)) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(junk_token, hint_value, presented_client)) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(legacy.at, "access_token", presented_client)) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(legacy.rt, "refresh_token")) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(unknown), query: "token=" <> unknown) |> T.assert_revoke_error(400, "invalid_request")
        T.revoke("token=#{unknown}&token=#{junk_token}") |> T.assert_revoke_error(400, "invalid_request")
        T.drain!("oauth_revoke", ip, 60, 600)
        T.revoke(T.revoke_params(unknown, hint_value, presented_client), ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
        T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
        T.revoke(T.revoke_params(unknown, hint_value, presented_client)) |> T.assert_revoke_5xx(503)
        Application.delete_env(:nebu_http, :oauth_session_repo)
        T.inject_revoke_handler_fault!()
        T.revoke(T.revoke_params(unknown, hint_value, presented_client)) |> T.assert_revoke_5xx(500)
      end)

    T.refute_secrets_in_log(log, Map.merge(secrets, %{
      legacy_at: legacy.at,
      legacy_rt: legacy.rt,
      legacy_at_hash: T.token_hash(legacy.at),
      junk: junk_token,
      unknown: unknown,
      unknown_hash: T.token_hash(unknown),
      presented_client_id: presented_client,
      hint: hint_value,
      bearer: bearer
    }))

    refute log =~ "LOGSECRET"
  end

  test "R21: the INFO line names outcome= and client_id_match=; on revoked: user_id, device_id and the STORED client_id", %{cid: cid, priv: priv} do
    s = session(cid, priv)
    a = session(cid, priv)

    log =
      capture_log([level: :info], fn ->
        T.revoke(T.revoke_params(s.at, nil, cid)) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(a.rt, nil, "SOMEOTHERCLIENT")) |> T.assert_revoke_ok()
        T.revoke(T.revoke_params(T.rand(32))) |> T.assert_revoke_ok()
      end)

    assert log =~ "OAuth revoke: outcome=revoked client_id_match=true"
    assert log =~ "OAuth revoke: outcome=revoked client_id_match=false"
    assert log =~ "OAuth revoke: outcome=ignored client_id_match=absent"
    assert log =~ s.user_id and log =~ s.device_id
    assert log =~ cid, "the session's STORED client_id is logged (trusted value)"
    refute log =~ "SOMEOTHERCLIENT", "the PRESENTED client_id is never logged (Trap 15)"
  end

  test "OAuth /logout and /logout/all never log a token, hash or IdP token", %{cid: cid, priv: priv} do
    s = session(cid, priv, "idp-rt-LOGOUTSECRET-" <> T.rand(6))
    a = session(cid, priv, "idp-rt-LOGOUTALL-" <> T.rand(6))
    secrets = Map.merge(secrets_of(s), Map.new(secrets_of(a), fn {k, v} -> {:"all_#{k}", v} end))

    log =
      debug_log(fn ->
        T.logout(s.at) |> T.assert_logout_ok()
        T.logout(a.at, path: :all, body: :object) |> T.assert_logout_ok()
      end)

    T.refute_secrets_in_log(log, secrets)
    refute log =~ "LOGOUTSECRET" or log =~ "LOGOUTALL"
  end

  describe "AC12/R22 — RequestLogger: names-only query string, body never captured" do
    test "POST /oauth2/revoke?token=... keeps only the parameter names (also trailing / doubled slashes)" do
      # dev-story fix: `Plug.Test.conn(:post, "//oauth2//revoke")` parses "//oauth2" as the URI
      # AUTHORITY (host "oauth2", path "//revoke"), which never reaches the route at all; the full
      # URL keeps the doubled slashes in `request_path`, as Bandit delivers them.
      for path <- ["/oauth2/revoke", "/oauth2/revoke/", "http://localhost//oauth2//revoke"] do
        log =
          debug_log(fn ->
            Plug.Test.conn(:post, path <> "?token=QS-TOKEN-VALUE&client_id=QS-CLIENT-VALUE", "")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
          end)

        assert [qs | _] = query_strings(log), "no query_string logged for #{path}"
        assert qs =~ "token=***" and qs =~ "client_id=***", "#{path}: #{qs}"
        for v <- ~w(QS-TOKEN-VALUE QS-CLIENT-VALUE), do: refute(log =~ v, "#{v} leaked for #{path}")
      end
    end

    test "the form body (token, hint, client_id) is never captured by the DEBUG payload line" do
      log =
        debug_log(fn ->
          T.revoke([{"token", "BODY-TOKEN-" <> T.rand(4)}, {"token_type_hint", "BODY-HINT-VALUE"}, {"client_id", "BODY-CLIENT-VALUE"}])
          |> T.assert_revoke_ok()
        end)

      for v <- ~w(BODY-TOKEN- BODY-HINT-VALUE BODY-CLIENT-VALUE), do: refute(log =~ v, "#{v} leaked from the request body")
    end
  end
end
