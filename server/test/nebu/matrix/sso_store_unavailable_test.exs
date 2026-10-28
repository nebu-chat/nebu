defmodule Nebu.Matrix.SsoStoreUnavailableTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), security review SEC #2 (Logging Law):
  a `GenServer.call` timeout or `noproc` of the node-local `Nebu.Matrix.SsoStore` used to make the REQUEST process
  exit with the whole call message (id_token, IdP refresh token, redirect URL, loginToken) in the crash log
  (`format_status/1` only redacts the store's OWN crash report). Reachable by flooding the single store process.

  Contract:

    * every `SsoStore` call (`put_state` / `pop_state` / `peek_state` / `put_login_token` / `pop_login_token` /
      `put_confirm` / `pop_confirm` / `peek_confirm`) catches the `:exit`: the `put_*` functions return
      `{:error, :unavailable}`, the `pop_*` / `peek_*` functions return `:error`;
    * the call timeout is 5000 ms; a compile-guarded seam `:nebu_http, :sso_store_call_timeout_ms` (read only under
      `Mix.env() == :test`) lets these tests force a timeout quickly: the store is SUSPENDED (`:sys.suspend/1`);
    * the redirect leg answers `503` `M_UNAVAILABLE`; the callback and the confirm routes never raise: a `put_confirm`
      / `put_login_token` failure is the existing `503` `unavailable` page, a `pop_*` / `peek_*` miss is the existing
      `400` answer (`M_UNKNOWN` at the callback, the `invalid_state` page at the confirm routes);
    * nothing secret reaches the log: no id_token, IdP refresh token, loginToken or redirect URL, and no
      `GenServer.call` exit report of the request process.

  Plug level, IdP stubbed, no DB.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.SsoStore
  alias Nebu.OAuth.TestSupport, as: T

  @url "https://unlisted.example/cb"

  setup do
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.sso_no_trusted_origins!()
    T.sso_origins!([])
    T.drop_confirm_entries!()
    T.drop_token_entries!()
    T.put_env_scoped(:sso_store_call_timeout_ms, 50)
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      if pid = Process.whereis(SsoStore), do: (try do :sys.resume(pid) catch _, _ -> :ok end)
      T.restore_rate_limits()
      T.drop_confirm_entries!()
      T.drop_token_entries!()
    end)

    {:ok, priv: priv}
  end

  # the store does not answer for the duration of `fun`; resumed afterwards (queued calls then run late)
  defp suspended(fun) do
    :ok = :sys.suspend(SsoStore)

    try do
      fun.()
    after
      :ok = :sys.resume(SsoStore)
    end
  end

  defp entry, do: T.confirm_entry_fixture()

  describe "SEC #2 — every SsoStore call survives an unresponsive store" do
    test "put_* answer {:error, :unavailable}, pop_* / peek_* answer :error; nothing exits" do
      results =
        suspended(fn ->
          %{
            put_state: SsoStore.put_state("s-key", %{verifier: "v", nonce: "n", redirect_url: "http://localhost"}, 600),
            put_token: SsoStore.put_login_token("t-key", "id-token", 30, oidc_refresh_token: "rt"),
            put_confirm: apply(SsoStore, :put_confirm, ["c-key", entry(), 300]),
            pop_state: SsoStore.pop_state("s-key"),
            peek_state: SsoStore.peek_state("s-key"),
            pop_token: SsoStore.pop_login_token("t-key"),
            pop_confirm: apply(SsoStore, :pop_confirm, ["c-key"]),
            peek_confirm: apply(SsoStore, :peek_confirm, ["c-key"])
          }
        end)

      assert results.put_state == {:error, :unavailable}
      assert results.put_token == {:error, :unavailable}
      assert results.put_confirm == {:error, :unavailable}
      assert results.pop_state == :error
      assert results.peek_state == :error
      assert results.pop_token == :error
      assert results.pop_confirm == :error
      assert results.peek_confirm == :error
    end

    test "after the store resumed it serves again (the failures were not sticky)" do
      suspended(fn -> assert apply(SsoStore, :put_confirm, ["late-key", entry(), 300]) == {:error, :unavailable} end)
      assert apply(SsoStore, :put_confirm, ["ok-key", entry(), 300]) == :ok
      assert {:ok, _} = apply(SsoStore, :peek_confirm, ["ok-key"])
    end
  end

  describe "story sso-confirm-bucket-order — an unreachable store is a MISS" do
    test "a live-format cookie answers invalid_state (no crash) and is charged to the per-address miss bucket, never to a binding bucket" do
      ip = T.unique_ip()
      T.drain!("sso_confirm_miss", ip, 10, 600, 1)
      cookie = {T.sso_confirm_cookie_name(), String.duplicate("F", 43)}

      first = suspended(fn -> T.sso_confirm_get(cookie, ip: ip) end)
      T.assert_confirm_error(first, 400, "invalid_state")
      second = suspended(fn -> T.sso_confirm_get(cookie, ip: ip) end)
      T.assert_confirm_error(second, 429, "rate_limited")
    end

    test "a request without a cookie never asks the store (a suspended store does not delay it: no timeout, no warning)" do
      log =
        capture_log(fn ->
          started = System.monotonic_time(:millisecond)
          conn = suspended(fn -> T.sso_confirm_get(nil) end)
          send(self(), {:elapsed, System.monotonic_time(:millisecond) - started, conn})
        end)

      assert_received {:elapsed, ms, conn}
      T.assert_confirm_error(conn, 400, "invalid_state")
      assert ms < 40, "answered without waiting for the store (call timeout is 50 ms), took #{ms} ms"
      refute log =~ ~r/SsoStore|unavailable/i
    end
  end

  describe "SEC #2 — the HTTP surface answers instead of crashing" do
    test "the redirect leg answers 503 M_UNAVAILABLE when the state cannot be stored" do
      conn = suspended(fn -> T.sso_redirect([], redirect_url: @url) end)
      assert conn.status == 503
      assert T.json(conn)["errcode"] == "M_UNAVAILABLE"
      assert T.location(conn) == nil, "no redirect to the IdP"
    end

    test "the callback never raises when the state cannot be read: a 400 (state miss) or the 503 page, no token, no cookie", %{priv: priv} do
      flow = T.sso_start!(@url)
      before = T.sso_token_keys()
      conn = suspended(fn -> T.sso_finish(flow, priv) end)
      assert conn.status in [400, 503]
      assert T.location(conn) == nil
      assert T.sso_confirm_set_cookies(conn) == []
      assert T.sso_token_keys() == before
    end

    test "the confirmation page is served from the table, its POST answers an error page (invalid_state or unavailable): never a crash, never a token", %{priv: priv} do
      cb = T.legacy_callback!(priv, T.unique_sub(), @url)
      T.assert_confirm_redirect(cb)
      {_, value, _} = T.sso_confirm_cookie(cb)
      pair = {T.sso_confirm_cookie_name(), value}
      before = T.sso_token_keys()

      get = suspended(fn -> T.sso_confirm_get(pair) end)
      post = suspended(fn -> T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "continue"}], cookie: pair) end)

      # story admin-config-audit-atomic D6: the page lookup reads the ETS table directly, so the GET of a LIVE binding is served even while the store
      # process does not answer (no token is minted by a GET); the POST consumes the entry through the process and answers the error page
      assert get.status == 200
      assert T.location(get) == nil
      assert T.login_tokens_of(get) == []

      assert post.status in [400, 503]
      assert post.resp_body =~ ~r/<main[^>]*data-page="sso-confirm-error"/
      assert post.resp_body =~ ~r/data-error="(invalid_state|unavailable)"/
      assert T.location(post) == nil
      assert T.login_tokens_of(post) == []

      assert T.sso_token_keys() == before
    end
  end

  describe "SEC #2 — the Logging Law holds for the request process" do
    test "no id_token, refresh token, loginToken or redirect URL, and no GenServer.call exit report, reaches the log", %{priv: priv} do
      cb = T.legacy_callback!(priv, T.unique_sub(), @url)
      {_, value, _} = T.sso_confirm_cookie(cb)
      pair = {T.sso_confirm_cookie_name(), value}

      secret = %{
        id_token: "ID-TOKEN-MARK-" <> T.rand(6),
        oidc_refresh_token: "IDP-RT-MARK-" <> T.rand(6),
        redirect_url: "https://mark.example/REDIRECT-URL-MARK-" <> T.rand(4),
        login_token: "LOGIN-TOKEN-MARK-" <> T.rand(6)
      }

      log =
        capture_log(fn ->
          suspended(fn ->
            apply(SsoStore, :put_confirm, ["mark-c", entry_with(secret), 300])
            SsoStore.put_login_token(secret.login_token, secret.id_token, 30, oidc_refresh_token: secret.oidc_refresh_token)
            SsoStore.put_state("mark-s", %{verifier: "v", nonce: "n", redirect_url: secret.redirect_url, uia_session: nil}, 600)
            SsoStore.pop_login_token(secret.login_token)
            T.sso_confirm_get(pair)
            T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "continue"}], cookie: pair)
            T.sso_redirect([], redirect_url: "https://redirect-leg.example/cb")
          end)

          Logger.flush()
        end)

      for {name, marker} <- secret, do: refute(log =~ marker, "#{name} leaked into the log")
      refute log =~ "exited in: GenServer.call", "a call timeout must not escape as an exit"
      refute log =~ "** (exit)", "no exit report of the request process"
      refute log =~ "$gen_call", "the raw call message must never be printed"
    end
  end

  defp entry_with(secret),
    do: T.confirm_entry_fixture(%{id_token: secret.id_token, oidc_refresh_token: secret.oidc_refresh_token, redirect_url: secret.redirect_url})

  describe "review cycle 2 (INFO-3) — an unavailable token store is a 503, never a dud loginToken" do
    test "mint_login_token reports {:error, :unavailable} while the store does not answer" do
      {opaque, result} = suspended(fn -> Nebu.Matrix.SsoLogin.mint_login_token("id-token", nil) end)
      assert is_binary(opaque)
      assert result == {:error, :unavailable}
    end

    test "a callback for a LISTED target whose token store stops answering after the state was read answers 503 M_UNAVAILABLE, no Location", %{priv: priv} do
      T.sso_origins!(["https://listed.example"])
      flow = T.sso_start!("https://listed.example/cb")
      claims = %{"sub" => T.unique_sub(), "nonce" => flow.nonce}
      jwt = T.sign_id_token(priv, claims)

      Application.put_env(:nebu_http, :matrix_sso_token_override, fn ->
        :ok = :sys.suspend(SsoStore)
        {:ok, jwt, "idp-rt"}
      end)

      conn =
        try do
          Plug.Test.conn(:get, "/_matrix/client/v3/login/sso/redirect/oidc?code=c&state=" <> flow.state)
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        after
          if pid = Process.whereis(SsoStore), do: (try do :sys.resume(pid) catch _, _ -> :ok end)
        end

      assert conn.status == 503
      assert T.json(conn)["errcode"] == "M_UNAVAILABLE"
      assert T.location(conn) == nil
    end
  end

  describe "review cycle 2 — a swallowed exit logs ONE throttled WARNING with the exit tag only" do
    test "two failing calls give one warning naming `timeout`, nothing of the call message" do
      log =
        capture_log(fn ->
          suspended(fn ->
            apply(SsoStore, :put_confirm, ["w-1", T.confirm_entry_fixture(%{id_token: "WARN-ID-TOKEN-MARK"}), 300])
            apply(SsoStore, :put_confirm, ["w-2", entry(), 300])
          end)

          Logger.flush()
        end)

      assert length(Regex.scan(~r/\[warning\] matrix SSO: the SSO store did not answer reason=timeout/, log)) == 1, log
      refute log =~ "WARN-ID-TOKEN-MARK"
      refute log =~ "$gen_call"
    end
  end
end
