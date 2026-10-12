defmodule Nebu.Matrix.Session.RefreshSemanticsTest do
  @moduledoc """
  RED-phase ATDD tests for `matrix-session-refresh-fixes` /
  `docs/stories/matrix-session-refresh-fixes/refresh-worker-and-retry-semantics.md`
  (AC1-AC8). Oracle input: `_bmad-output/nebu/epics/matrix-session-refresh-fixes/
  step-results/refresh-worker-and-retry-semantics/oracle-context.md`.

  All behaviour is observed through public surfaces only: the `Nebu.Web.Router`
  (`POST /_matrix/client/v3/refresh`, authenticated `GET /account/whoami`), the
  `RefreshWorker` cycle (message `:refresh`, same driving pattern as
  `refresh_worker_test.exs`) and raw SQL on `matrix_sessions` (row state).
  No new function names are referenced, so the file compiles before the fix.

  Seam: `:matrix_oidc_refresh_override` steers IdP outcomes (transient vs.
  confirmed). "Time passes" is simulated by backdating ALL nullable timestamp
  columns of a device's rows (`shift_device_timestamps/2`), never by sleeping;
  `expires_at` is deliberately NOT shifted (session bound).

  Tagged `:integration` (needs Postgres) - run with `mix test --include integration`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  @moduletag :integration

  alias Nebu.Matrix.SsoStore
  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  @server_name "test.local"
  @issuer "https://idp.example.com/realms/nebu"
  @audience "nebu-client"
  @kid "refresh-semantics-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @worker Nebu.Matrix.Session.RefreshWorker

  defp fresh_sub, do: "sem" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp current_sub, do: Process.get(:refresh_semantics_sub) || raise("sub not set by setup")

  @router_opts Nebu.Web.Router.init([])

  defp future_exp, do: System.system_time(:second) + 3600

  defp setup_oidc do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.put("kid", @kid)
      |> Map.put("alg", "RS256")
      |> Map.put("use", "sig")

    priv_jwk = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :admin_secret_at_rest, "refresh-worker-test-internal-secret")

    encrypted_secret = Nebu.Admin.BootstrapLive.encrypt_secret("shhh")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> encrypted_secret
      _ -> nil
    end)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :server_name,
            :oidc_jwks,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_sso_token_override,
            :admin_secret_at_rest,
            :matrix_oidc_refresh_override,
            :matrix_refresh_worker_lookahead_seconds,
            :matrix_session_ttl_seconds
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    priv_jwk
  end

  defp sign_id_token(priv_jwk, overrides) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => current_sub(),
          "exp" => future_exp(),
          "iat" => System.system_time(:second)
        },
        overrides
      )

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp auth(token), do: [{"authorization", "Bearer " <> token}]
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # Runs the real SSO redirect→callback flow with an injected token exchange
  # that ALSO yields an OIDC refresh token, returning the single-use opaque
  # loginToken to redeem at POST /login. Copied from login_refresh_test.exs —
  # this is the ONLY way to get a genuinely-encrypted oidc_refresh_token column
  # into matrix_sessions without reaching into SecretBox internals.
  defp mint_login_token(priv, oidc_refresh_token, sub) do
    the_sub = sub || current_sub()
    redirect_url = "http://localhost:7070/#/home"

    init =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(redirect_url)
      )

    assert init.status == 302, "SSO redirect must 302 to set up the login-token flow"
    params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    state = params["state"]
    nonce = params["nonce"]

    id_token = sign_id_token(priv, %{"sub" => the_sub, "nonce" => nonce})

    Application.put_env(:nebu_http, :matrix_sso_token_override, fn ->
      {:ok, id_token, oidc_refresh_token}
    end)

    cb =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <>
          URI.encode_www_form(state)
      )

    assert cb.status == 302
    cb_query = cb |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    login_token = cb_query["loginToken"]
    assert is_binary(login_token) and login_token != ""
    login_token
  end

  # Logs in a fresh device for `sub` with `device_id`, returning
  # %{access_token, refresh_token, user_id}. Uses the real login path so the
  # matrix_sessions row has a genuinely-encrypted oidc_refresh_token column.
  defp login_device(priv, sub, oidc_rt, device_id) do
    login_token = mint_login_token(priv, oidc_rt, sub)

    resp =
      call(:post, "/_matrix/client/v3/login", %{
        "type" => "m.login.token",
        "token" => login_token,
        "refresh_token" => true,
        "device_id" => device_id
      })

    assert resp.status == 200
    body = json(resp)
    assert body["device_id"] == device_id

    %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      user_id: body["user_id"]
    }
  end

  # Forces a session's expires_at to a specific offset from NOW (deterministic,
  # no sleeping) — makes it "nearing" (within the worker's lookahead window) or
  # "not nearing" as needed by each test.
  defp set_expires_at(access_token, seconds_from_now) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "UPDATE matrix_sessions SET expires_at = NOW() + ($2 * INTERVAL '1 second') WHERE access_token_hash = $1",
        [Store.hash_token(access_token), seconds_from_now]
      )

    :ok
  end

  defp expires_at_for(access_token) do
    {:ok, %{rows: [[expires_at]]}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT expires_at FROM matrix_sessions WHERE access_token_hash = $1",
        [Store.hash_token(access_token)]
      )

    expires_at
  end

  defp put_matrix_oidc_refresh_override(fun) do
    Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fun)
    on_exit(fn -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_override) end)
  end

  # Starts the worker under test via start_supervised! (ExUnit-managed
  # teardown), sets a generous lookahead window covering the offsets used in
  # these tests, then triggers exactly ONE synchronous refresh cycle.
  #
  # Test-setup fix (dev-story, pre-existing bug in this helper): some tests
  # (AC5) call this helper MULTIPLE times within a single test to exercise
  # repeated refresh cycles. ExUnit's start_supervised!/1 raises
  # `{:already_started, pid}` if a child with the same (module-derived) id is
  # still alive from an earlier call in the SAME test — so a naive
  # unconditional start_supervised! only works the first time. Stopping any
  # previously-started instance first (idempotent — a no-op the first time)
  # makes the helper safely callable any number of times per test, without
  # changing what any test asserts.
  defp run_one_refresh_cycle(lookahead_seconds \\ 3600) do
    Application.put_env(:nebu_http, :matrix_refresh_worker_lookahead_seconds, lookahead_seconds)
    _ = stop_supervised(@worker)
    pid = start_supervised!(@worker)
    send(pid, :refresh)
    :sys.get_state(pid)
    pid
  end

  setup do
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    priv = setup_oidc()

    sub = fresh_sub()
    Process.put(:refresh_semantics_sub, sub)
    uid = "@" <> sub <> ":" <> @server_name

    if Process.whereis(Nebu.Repo) do
      _ =
        Nebu.Matrix.Session.TokenValidator.validate(
          uid,
          "user",
          "Sem Test",
          "sem@example.com"
        )

      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Sem Test", nil)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          for table <- ["matrix_sessions", "profiles", "users"] do
            _ =
              Ecto.Adapters.SQL.query(
                Nebu.Repo,
                "DELETE FROM #{table} WHERE user_id = $1",
                [uid]
              )
          end
        end
      end)
    end

    {:ok, priv_jwk: priv, user_id: uid}
  end

  # ── additional helpers for this story ──────────────────────────────────────

  @refresh_path "/_matrix/client/v3/refresh"
  @whoami_path "/_matrix/client/v3/account/whoami"

  defp refresh(rt, headers \\ []), do: call(:post, @refresh_path, %{"refresh_token" => rt}, headers)
  defp whoami(at), do: call(:get, @whoami_path, nil, auth(at))

  defp idp_ok(sub, new_oidc_rt \\ nil) do
    put_matrix_oidc_refresh_override(fn _decrypted_rt ->
      {:ok, %{"sub" => sub, "exp" => future_exp()}, new_oidc_rt}
    end)
  end

  defp idp_error(reason) do
    put_matrix_oidc_refresh_override(fn _decrypted_rt -> {:error, reason} end)
  end

  # All rows (any state) of a device, as maps. Selects only columns that exist
  # today, so the helper is independent of how the fix marks "consumed".
  defp device_rows(uid, device_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        """
        SELECT access_token_hash, refresh_token_hash, oidc_refresh_token, expires_at, revoked_at
          FROM matrix_sessions WHERE user_id = $1 AND device_id = $2
        """,
        [uid, device_id]
      )

    Enum.map(rows, fn [at_hash, rt_hash, oidc, exp, rev] ->
      %{
        access_token_hash: at_hash,
        refresh_token_hash: rt_hash,
        oidc_refresh_token: oidc,
        expires_at: exp,
        revoked_at: rev
      }
    end)
  end

  defp active_rows(uid, device_id), do: Enum.filter(device_rows(uid, device_id), &is_nil(&1.revoked_at))

  # Simulates "N seconds have passed" for a device's rows WITHOUT sleeping: every
  # nullable bookkeeping timestamp (created_at / revoked_at / grace_until) moves
  # into the past. expires_at is NOT touched (it is the session bound).
  defp shift_device_timestamps(uid, device_id, seconds) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        """
        UPDATE matrix_sessions
           SET created_at  = created_at  - ($3 * INTERVAL '1 second'),
               revoked_at  = revoked_at  - ($3 * INTERVAL '1 second'),
               grace_until = grace_until - ($3 * INTERVAL '1 second')
         WHERE user_id = $1 AND device_id = $2
        """,
        [uid, device_id, seconds]
      )

    :ok
  end

  defp set_device_expires_at(uid, device_id, seconds_from_now) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "UPDATE matrix_sessions SET expires_at = NOW() + ($3 * INTERVAL '1 second') WHERE user_id = $1 AND device_id = $2",
        [uid, device_id, seconds_from_now]
      )

    :ok
  end

  defp refute_soft_logout_true(conn) do
    refute json(conn)["soft_logout"] == true,
           "a destroyed session must NOT carry soft_logout: true (client must discard state); body=#{conn.resp_body}"
  end

  # Logs in, with a refresh round-trip so the device has an old (rotated-out) and
  # a new token pair. Returns {original_session, refresh_response_body}.
  defp login_and_rotate(priv, device_id) do
    sub = current_sub()
    sess = login_device(priv, sub, "oidc-rt-" <> device_id, device_id)
    idp_ok(sub)
    resp = refresh(sess.refresh_token)
    assert resp.status == 200, "precondition: first /refresh must succeed, got #{resp.status} #{resp.resp_body}"
    {sess, json(resp)}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — worker extends IN PLACE (tokens unchanged, no sibling, no grace)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: worker extends the session in place" do
    setup %{priv_jwk: priv} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-ac1", "SEMAC1")
      set_expires_at(sess.access_token, 30 * 60)
      {:ok, sub: sub, sess: sess, original_expires_at: expires_at_for(sess.access_token)}
    end

    test "access token and refresh token are unchanged, expires_at is extended",
         %{sub: sub, sess: sess, user_id: uid, original_expires_at: orig} do
      idp_ok(sub)
      run_one_refresh_cycle()

      assert [row] = active_rows(uid, "SEMAC1")
      assert row.access_token_hash == Store.hash_token(sess.access_token), "AC1: worker must not rotate the access token"
      assert row.refresh_token_hash == Store.hash_token(sess.refresh_token), "AC1: worker must not rotate the refresh token"
      assert DateTime.compare(row.expires_at, orig) == :gt, "AC1: expires_at must be extended in place"
    end

    test "no new row and no revoked / grace sibling is created", %{sub: sub, user_id: uid} do
      idp_ok(sub)
      run_one_refresh_cycle()

      rows = device_rows(uid, "SEMAC1")
      assert length(rows) == 1, "AC1: exactly one row per device after a worker cycle, got #{length(rows)}"
      assert Enum.all?(rows, &is_nil(&1.revoked_at)), "AC1: no revoked_at may be set by the worker"
    end

    test "a provider-rotated OIDC refresh token is stored in place (encrypted), tokens unchanged",
         %{sub: sub, sess: sess, user_id: uid} do
      idp_ok(sub, "oidc-rt-ROTATED-by-idp")
      [before] = active_rows(uid, "SEMAC1")
      run_one_refresh_cycle()

      assert [row] = active_rows(uid, "SEMAC1")
      assert row.access_token_hash == Store.hash_token(sess.access_token)
      assert row.oidc_refresh_token != before.oidc_refresh_token,
             "AC1: the rotated OIDC RT must replace the stored blob on the SAME row"

      assert {:ok, "oidc-rt-ROTATED-by-idp"} = Nebu.Web.SecretBox.decrypt(row.oidc_refresh_token)
    end

    test "expires_at stays capped at now + ceiling even if the IdP exp is far in the future",
         %{user_id: uid} do
      ceiling = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      far = System.system_time(:second) + 10 * ceiling

      put_matrix_oidc_refresh_override(fn _ -> {:ok, %{"sub" => "x", "exp" => far}, nil} end)
      run_one_refresh_cycle()

      assert [row] = active_rows(uid, "SEMAC1")
      cap = DateTime.add(DateTime.utc_now(), ceiling + 5, :second)
      assert DateTime.compare(row.expires_at, cap) != :gt, "AC1: expires_at must respect session_expires_at/1 cap"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — worker and client refresh do not invalidate each other
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: worker and client refresh coexist" do
    test "after a worker cycle the client's access token still authenticates (200)",
         %{priv_jwk: priv} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-ac2a", "SEMAC2A")
      set_expires_at(sess.access_token, 30 * 60)
      idp_ok(sub)
      run_one_refresh_cycle()

      resp = whoami(sess.access_token)
      assert resp.status == 200, "AC2: client AT must survive a worker cycle, got #{resp.status} #{resp.resp_body}"
    end

    test "after a worker cycle the client's refresh token still works on /refresh (200)",
         %{priv_jwk: priv} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-ac2b", "SEMAC2B")
      set_expires_at(sess.access_token, 30 * 60)
      idp_ok(sub)
      run_one_refresh_cycle()

      resp = refresh(sess.refresh_token)
      assert resp.status == 200, "AC2: client RT must survive a worker cycle, got #{resp.status} #{resp.resp_body}"
      assert is_binary(json(resp)["access_token"])
    end

    test "client /refresh then worker cycle: exactly one non-revoked row holding the client's latest tokens",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-ac2c", "SEMAC2C")
      idp_ok(sub)
      body = json(refresh(sess.refresh_token))
      set_device_expires_at(uid, "SEMAC2C", 30 * 60)
      run_one_refresh_cycle()

      assert [row] = active_rows(uid, "SEMAC2C")
      assert row.access_token_hash == Store.hash_token(body["access_token"])
      assert row.refresh_token_hash == Store.hash_token(body["refresh_token"])
      assert whoami(body["access_token"]).status == 200
      assert refresh(body["refresh_token"]).status == 200
    end

    test "worker cycle then client /refresh: exactly one non-revoked row holding the tokens last returned",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-ac2d", "SEMAC2D")
      set_expires_at(sess.access_token, 30 * 60)
      idp_ok(sub)
      run_one_refresh_cycle()
      body = json(refresh(sess.refresh_token))

      assert [row] = active_rows(uid, "SEMAC2D")
      assert row.access_token_hash == Store.hash_token(body["access_token"])
      assert row.refresh_token_hash == Store.hash_token(body["refresh_token"])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — old RT stays valid until the new AT / RT is used (not just 60 s)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: old refresh token valid until new tokens are used" do
    test "refresh response has access_token, integer expires_in_ms, rotated refresh_token, same device",
         %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMAC3A")

      assert is_binary(body["access_token"]) and body["access_token"] != sess.access_token
      assert is_integer(body["expires_in_ms"]) and body["expires_in_ms"] > 0
      assert is_binary(body["refresh_token"]) and body["refresh_token"] != sess.refresh_token

      # Old row is rotated away (revoked_at set), the new row is the single active one.
      rows = device_rows(uid, "SEMAC3A")
      assert length(rows) == 2
      old_row = Enum.find(rows, &(&1.access_token_hash == Store.hash_token(sess.access_token)))
      assert old_row.revoked_at != nil, "the old row must be marked rotated-away"
      assert [new_row] = active_rows(uid, "SEMAC3A")
      assert new_row.access_token_hash == Store.hash_token(body["access_token"])
      assert new_row.refresh_token_hash == Store.hash_token(body["refresh_token"])
      assert whoami(body["access_token"]).status == 200
      assert json(whoami(body["access_token"]))["device_id"] == "SEMAC3A", "device_id must not change on refresh"
    end

    test "old RT still yields 200 after >60 s (backdated) while the new tokens are unused",
         %{priv_jwk: priv, user_id: uid} do
      {sess, _body} = login_and_rotate(priv, "SEMAC3B")
      shift_device_timestamps(uid, "SEMAC3B", 600)

      resp = refresh(sess.refresh_token)

      assert resp.status == 200,
             "AC3: old RT must stay valid beyond 60 s until the new token is used, got #{resp.status} #{resp.resp_body}"

      assert is_binary(json(resp)["access_token"])
    end

    test "old RT can be replayed repeatedly while the new tokens are unused (lost-response retries)",
         %{priv_jwk: priv, user_id: uid} do
      {sess, _body} = login_and_rotate(priv, "SEMAC3C")
      shift_device_timestamps(uid, "SEMAC3C", 600)

      assert refresh(sess.refresh_token).status == 200
      shift_device_timestamps(uid, "SEMAC3C", 600)
      assert refresh(sess.refresh_token).status == 200,
             "AC3: a second replay of the unconsumed old RT must still succeed"
    end

    test "bound: old RT is never valid beyond the session's expires_at", %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMAC3D")
      shift_device_timestamps(uid, "SEMAC3D", 600)
      set_device_expires_at(uid, "SEMAC3D", -1)

      # Difference to AC4F (expired AT + CURRENT RT => 200): an expired session may
      # still be revived with its CURRENT refresh token, but the bound caps the
      # rotated-away (old) RT: it is never valid beyond the session's expires_at.
      resp = refresh(sess.refresh_token)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)

      # An unserved old RT past the bound is just unknown - it must not destroy
      # the session: the NEW (current) RT still works.
      assert refresh(body["refresh_token"]).status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — consumed RT: 401 without soft_logout, device-scoped invalidation
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: consumed refresh token" do
    test "after the new AT was used on an authenticated endpoint the old RT is 401 M_UNKNOWN_TOKEN without soft_logout",
         %{priv_jwk: priv} do
      {sess, body} = login_and_rotate(priv, "SEMAC4A")
      assert whoami(body["access_token"]).status == 200

      resp = refresh(sess.refresh_token)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)
    end

    test "same after >60 s have passed (consumption does not depend on the clock)", %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMAC4B")
      assert whoami(body["access_token"]).status == 200
      shift_device_timestamps(uid, "SEMAC4B", 600)

      resp = refresh(sess.refresh_token)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)
    end

    test "after the NEW refresh token was redeemed the old RT is 401 M_UNKNOWN_TOKEN without soft_logout",
         %{priv_jwk: priv} do
      {sess, body} = login_and_rotate(priv, "SEMAC4C")
      assert refresh(body["refresh_token"]).status == 200

      resp = refresh(sess.refresh_token)
      assert resp.status == 401,
             "AC4: old RT must be rejected once the new RT was redeemed, got #{resp.status} #{resp.resp_body}"

      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)
    end

    test "reuse of the consumed RT invalidates the device's session (current AT and RT stop working)",
         %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMAC4D")
      assert whoami(body["access_token"]).status == 200
      assert refresh(sess.refresh_token).status == 401

      assert active_rows(uid, "SEMAC4D") == [], "AC4: reuse must hard-invalidate this device's session rows"
      who = whoami(body["access_token"])
      assert who.status == 401
      assert json(who)["errcode"] == "M_UNKNOWN_TOKEN"
      assert refresh(body["refresh_token"]).status == 401
    end

    test "reuse invalidation is scoped to ONE device: other devices of the same user keep working",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      other = login_device(priv, sub, "oidc-rt-other-device", "SEMAC4OTHER")
      {sess, body} = login_and_rotate(priv, "SEMAC4E")
      assert whoami(body["access_token"]).status == 200
      assert refresh(sess.refresh_token).status == 401

      assert whoami(other.access_token).status == 200, "AC4: other device's AT must stay valid"
      assert length(active_rows(uid, "SEMAC4OTHER")) == 1
      assert refresh(other.refresh_token).status == 200, "AC4: other device's RT must stay valid"
    end

    test "expired AT with a still-valid RT: authenticated request is 401 M_UNKNOWN_TOKEN + soft_logout: true",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-expired", "SEMAC4F")
      set_expires_at(sess.access_token, -1)

      resp = whoami(sess.access_token)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      assert json(resp)["soft_logout"] == true

      # ... and the RT can still bring the session back.
      idp_ok(current_sub())
      assert refresh(sess.refresh_token).status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — cluster safety: atomic single-row statements, one winner
  # (A worker-vs-/refresh overlap cannot be forced deterministically; the test below
  # only asserts the invariants that must hold whichever interleaving occurs. The DB
  # pool must allow the 8 concurrent requests - see config/test.exs pool_size.)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5: concurrent /refresh with the same token" do
    test "never 5xx, at least one winner, exactly one non-revoked row per device afterwards",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-race", "SEMAC5A")
      idp_ok(sub)

      responses =
        1..8
        |> Task.async_stream(fn _ -> refresh(sess.refresh_token) end, max_concurrency: 8, timeout: 30_000)
        |> Enum.map(fn {:ok, conn} -> conn end)

      statuses = Enum.map(responses, & &1.status)
      assert Enum.all?(statuses, &(&1 in [200, 401])), "AC5: losers must be consistent 200/401, got #{inspect(statuses)}"
      assert 200 in statuses, "AC5: one concurrent refresh must win"
      assert length(active_rows(uid, "SEMAC5A")) == 1, "AC5: exactly one non-revoked row per device"

      for r <- responses, r.status == 401 do
        assert json(r)["errcode"] == "M_UNKNOWN_TOKEN"
      end

      # Every 200 is a complete, consistent token response ...
      ok = Enum.filter(responses, &(&1.status == 200))

      for r <- ok do
        b = json(r)
        assert is_binary(b["access_token"]) and is_binary(b["refresh_token"]) and is_integer(b["expires_in_ms"])
      end

      # ... and at least one of them carries the token pair that is now ACTIVE and usable.
      [active] = active_rows(uid, "SEMAC5A")

      winner = Enum.find(ok, fn r -> Store.hash_token(json(r)["access_token"]) == active.access_token_hash end)
      assert winner, "AC5: the last winner's access token must be the active row's"

      assert whoami(json(winner)["access_token"]).status == 200
    end

    test "a concurrent worker cycle and client /refresh leave exactly one active row and a usable session",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-race2", "SEMAC5B")
      set_expires_at(sess.access_token, 30 * 60)
      idp_ok(sub)

      t1 = Task.async(fn -> refresh(sess.refresh_token) end)
      run_one_refresh_cycle()
      resp = Task.await(t1, 30_000)

      assert resp.status in [200, 401]
      assert [row] = active_rows(uid, "SEMAC5B")

      # Only hashes are stored: the active row's plaintext must be one of the tokens the
      # client knows (the original, extended in place, or the one /refresh just issued).
      known = [sess.access_token] ++ if(resp.status == 200, do: [json(resp)["access_token"]], else: [])
      live = Enum.find(known, &(Store.hash_token(&1) == row.access_token_hash))
      assert live, "AC5: the active row must belong to a token the client holds"
      assert whoami(live).status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — worker failure handling unchanged (in-place semantics)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: worker failure handling" do
    for {label, reason} <- [
          unreachable: {:token_endpoint_unreachable, :timeout},
          discovery: {:discovery_failed, :nxdomain},
          status_503: {:token_endpoint_status, 503},
          status_429: {:token_endpoint_status, 429},
          transient_check: {:transient_check_failed, :db_down}
        ] do
      test "transient #{label}: row untouched (same tokens, same expires_at, not revoked)",
           %{priv_jwk: priv, user_id: uid} do
        sess = login_device(priv, current_sub(), "oidc-rt-w-#{unquote(label)}", "SEMAC6T")
        set_expires_at(sess.access_token, 30 * 60)
        before = device_rows(uid, "SEMAC6T")
        idp_error(unquote(Macro.escape(reason)))
        run_one_refresh_cycle()

        assert device_rows(uid, "SEMAC6T") == before
        assert whoami(sess.access_token).status == 200
      end
    end

    for {label, reason} <- [status_400: {:token_endpoint_status, 400}, status_401: {:token_endpoint_status, 401}, invalid_grant: :invalid_grant] do
      test "confirmed rejection #{label}: exactly this device's row is deleted, other devices untouched",
           %{priv_jwk: priv, user_id: uid} do
        sub = current_sub()
        other = login_device(priv, sub, "oidc-rt-w-other", "SEMAC6OTHER")
        victim = login_device(priv, sub, "oidc-rt-w-victim-#{unquote(label)}", "SEMAC6C")
        set_expires_at(victim.access_token, 30 * 60)
        # Only the victim's OIDC RT is rejected.
        put_matrix_oidc_refresh_override(fn
          "oidc-rt-w-victim-" <> _ -> {:error, unquote(Macro.escape(reason))}
          _other -> {:ok, %{"sub" => sub, "exp" => future_exp()}, nil}
        end)

        run_one_refresh_cycle()

        assert device_rows(uid, "SEMAC6C") == []
        assert length(active_rows(uid, "SEMAC6OTHER")) == 1
        assert whoami(other.access_token).status == 200
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7 — /refresh: transient => 503 (never 4xx), session intact, retry works
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC7: transient failures on /refresh are 503" do
    for {label, reason} <- [
          unreachable: {:token_endpoint_unreachable, :econnrefused},
          discovery: {:discovery_failed, :nxdomain},
          status_500: {:token_endpoint_status, 500},
          status_502: {:token_endpoint_status, 502},
          status_503: {:token_endpoint_status, 503},
          status_429: {:token_endpoint_status, 429},
          transient_check: {:transient_check_failed, :db_down}
        ] do
      test "#{label} -> 503, session row intact, later retry with the SAME refresh token succeeds",
           %{priv_jwk: priv, user_id: uid} do
        sub = current_sub()
        sess = login_device(priv, sub, "oidc-rt-t-#{unquote(label)}", "SEMAC7T")
        before = device_rows(uid, "SEMAC7T")

        idp_error(unquote(Macro.escape(reason)))
        resp = refresh(sess.refresh_token)

        assert resp.status == 503,
               "AC7: transient #{inspect(unquote(Macro.escape(reason)))} must be 503 (clients log out on 4xx), got #{resp.status} #{resp.resp_body}"

        assert json(resp)["errcode"] in ["M_UNKNOWN", "M_LIMIT_EXCEEDED"]
        assert [retry_after] = get_resp_header(resp, "retry-after")
        assert String.to_integer(retry_after) > 0, "AC7: 503 must carry a positive Retry-After"
        refute_soft_logout_true(resp)
        assert device_rows(uid, "SEMAC7T") == before, "AC7: transient failure must leave the session row untouched"

        idp_ok(sub)
        retry = refresh(sess.refresh_token)
        assert retry.status == 200, "AC7: retry with the same RT must succeed, got #{retry.status} #{retry.resp_body}"
      end
    end

    test "repeated transient failures never consume or revoke the session", %{priv_jwk: priv, user_id: uid} do
      sess = login_device(priv, current_sub(), "oidc-rt-t-repeat", "SEMAC7R")
      before = device_rows(uid, "SEMAC7R")
      idp_error({:token_endpoint_unreachable, :timeout})

      for _ <- 1..3, do: assert(refresh(sess.refresh_token).status == 503)
      assert device_rows(uid, "SEMAC7R") == before
      assert whoami(sess.access_token).status == 200
    end
  end

  describe "AC7: confirmed rejection on /refresh is 401 and invalidates the session" do
    for {label, reason} <- [
          idp_400: {:token_endpoint_status, 400},
          idp_401: {:token_endpoint_status, 401},
          invalid_grant: :invalid_grant,
          deactivated: :deactivated
        ] do
      test "#{label} -> 401 M_UNKNOWN_TOKEN (no soft_logout), session rows removed",
           %{priv_jwk: priv, user_id: uid} do
        sess = login_device(priv, current_sub(), "oidc-rt-c-#{unquote(label)}", "SEMAC7C")
        idp_error(unquote(Macro.escape(reason)))

        resp = refresh(sess.refresh_token)
        assert resp.status == 401
        assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
        refute_soft_logout_true(resp)
        assert device_rows(uid, "SEMAC7C") == []
        assert whoami(sess.access_token).status == 401
      end
    end

    test "undecryptable stored OIDC refresh token (decrypt failure) -> 401, session invalidated",
         %{priv_jwk: priv, user_id: uid} do
      sess = login_device(priv, current_sub(), "oidc-rt-c-decrypt", "SEMAC7D")

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE matrix_sessions SET oidc_refresh_token = 'not-a-valid-ciphertext' WHERE user_id = $1 AND device_id = $2",
          [uid, "SEMAC7D"]
        )

      idp_ok(current_sub())
      resp = refresh(sess.refresh_token)
      assert resp.status == 401
      refute_soft_logout_true(resp)
      assert device_rows(uid, "SEMAC7D") == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — no tokens / OIDC refresh tokens in logs (No-Sensitive-Data law)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: log redaction" do
    defp refute_secrets_logged(log, secrets) do
      for secret <- secrets do
        refute log =~ secret, "a secret leaked into the logs: #{String.slice(secret, 0, 8)}..."
      end
    end

    test "/refresh transient failure logs no access token, refresh token or OIDC refresh token",
         %{priv_jwk: priv} do
      oidc_rt = "oidc-rt-log-transient-SECRET"
      sess = login_device(priv, current_sub(), oidc_rt, "SEMLOG1")
      idp_error({:token_endpoint_unreachable, {:econnrefused, oidc_rt}})

      log = capture_log(fn -> assert refresh(sess.refresh_token).status == 503 end)
      refute_secrets_logged(log, [sess.access_token, sess.refresh_token, oidc_rt])
    end

    test "/refresh confirmed rejection logs no access token, refresh token or OIDC refresh token",
         %{priv_jwk: priv} do
      oidc_rt = "oidc-rt-log-confirmed-SECRET"
      sess = login_device(priv, current_sub(), oidc_rt, "SEMLOG2")
      idp_error({:token_endpoint_status, 400})

      log = capture_log(fn -> assert refresh(sess.refresh_token).status == 401 end)
      refute_secrets_logged(log, [sess.access_token, sess.refresh_token, oidc_rt])
    end

    test "/refresh success and consumed-token reuse log no secrets", %{priv_jwk: priv} do
      oidc_rt = "oidc-rt-log-reuse-SECRET"
      sess = login_device(priv, current_sub(), oidc_rt, "SEMLOG3")
      idp_ok(current_sub())

      log =
        capture_log(fn ->
          body = json(refresh(sess.refresh_token))
          assert whoami(body["access_token"]).status == 200
          assert refresh(sess.refresh_token).status == 401
          send(self(), {:new_tokens, body})
        end)

      assert_received {:new_tokens, body}
      refute_secrets_logged(log, [sess.access_token, sess.refresh_token, oidc_rt, body["access_token"], body["refresh_token"]])
    end

    test "worker transient failure logs no secrets", %{priv_jwk: priv} do
      oidc_rt = "oidc-rt-log-worker-t-SECRET"
      sess = login_device(priv, current_sub(), oidc_rt, "SEMLOG4")
      set_expires_at(sess.access_token, 30 * 60)
      idp_error({:token_endpoint_unreachable, {:timeout, oidc_rt}})

      log = capture_log(fn -> run_one_refresh_cycle() end)
      refute_secrets_logged(log, [sess.access_token, sess.refresh_token, oidc_rt])
    end

    test "worker confirmed rejection and success log no secrets", %{priv_jwk: priv} do
      oidc_rt = "oidc-rt-log-worker-c-SECRET"
      sess = login_device(priv, current_sub(), oidc_rt, "SEMLOG5")
      set_expires_at(sess.access_token, 30 * 60)
      idp_error({:token_endpoint_status, 401})
      log = capture_log(fn -> run_one_refresh_cycle() end)
      refute_secrets_logged(log, [sess.access_token, sess.refresh_token, oidc_rt])

      sess2 = login_device(priv, current_sub(), oidc_rt <> "2", "SEMLOG6")
      set_expires_at(sess2.access_token, 30 * 60)
      idp_ok(current_sub(), "oidc-rt-ROTATED-log-SECRET")
      log2 = capture_log(fn -> run_one_refresh_cycle() end)
      refute_secrets_logged(log2, [sess2.access_token, sess2.refresh_token, oidc_rt <> "2", "oidc-rt-ROTATED-log-SECRET"])
    end
  end

  describe "/refresh request validation and unchanged edge cases (spec)" do
    test "garbage refresh token -> 401 M_UNKNOWN_TOKEN without soft_logout" do
      resp = refresh(:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)
    end

    test "missing refresh_token -> 400 M_MISSING_PARAM" do
      resp = call(:post, @refresh_path, %{})
      assert resp.status == 400
      assert json(resp)["errcode"] == "M_MISSING_PARAM"
    end

    test "refresh keeps the device_id of the session", %{priv_jwk: priv, user_id: uid} do
      {_sess, body} = login_and_rotate(priv, "SEMDEV")
      assert [row] = active_rows(uid, "SEMDEV")
      assert row.access_token_hash == Store.hash_token(body["access_token"])
    end

    test "login without refresh_token:true is unchanged: no refresh_token, no opaque session row",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, "oidc-rt-plain", current_sub())

      resp =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "device_id" => "SEMPLAIN"
        })

      assert resp.status == 200
      refute Map.has_key?(json(resp), "refresh_token")
      assert device_rows(uid, "SEMPLAIN") == []
    end

    test "rate limited /refresh -> 429 M_LIMIT_EXCEEDED with retry_after_ms" do
      Application.put_env(:nebu_http, :rate_limit_disabled, false)
      ip = {10, 77, :rand.uniform(250), :rand.uniform(250)}

      statuses_and_bodies =
        for _ <- 1..40 do
          conn =
            conn(:post, @refresh_path, Jason.encode!(%{"refresh_token" => "garbage"}))
            |> put_req_header("content-type", "application/json")
            |> Map.put(:remote_ip, ip)

          Nebu.Web.Router.call(conn, @router_opts)
        end

      limited = Enum.find(statuses_and_bodies, &(&1.status == 429))
      assert limited, "rate limiter must kick in for /refresh"
      body = json(limited)
      assert body["errcode"] == "M_LIMIT_EXCEEDED"
      assert is_integer(body["retry_after_ms"]), "spec: 429 must carry retry_after_ms, got #{limited.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Review cycle 1 (M1 / M2 / M3)
  # ══════════════════════════════════════════════════════════════════════════

  describe "review cycle 1" do
    test "M1: RT0 consumed between resolve and rotate (during the IdP call) issues NO tokens, 401 without soft_logout, device invalidated",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      {sess, body} = login_and_rotate(priv, "SEMM1")
      new_at = body["access_token"]

      # The IdP round trip is where the legitimate client uses its new AT, which
      # consumes the (still pending when resolved) presented RT0.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        :ok = Nebu.Matrix.Session.MatrixSessionStore.mark_access_token_used(new_at)
        {:ok, %{"sub" => sub, "exp" => future_exp()}, nil}
      end)

      resp = refresh(sess.refresh_token)

      assert resp.status == 401,
             "M1: a consumed RT must not be rotated, got #{resp.status} #{resp.resp_body}"

      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)
      refute Map.has_key?(json(resp), "access_token")
      assert active_rows(uid, "SEMM1") == [], "M1/AC4: reuse invalidates the device's session"
      assert length(device_rows(uid, "SEMM1")) == 0
    end

    test "M2: exhausted rotation-race retries answer 503 + Retry-After and leave the session intact",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-m2", "SEMM2")
      idp_ok(sub)

      # Force every rotation attempt to lose its race while the session stays intact.
      Application.put_env(:nebu_http, :matrix_refresh_rotate_override, fn _params -> :error end)
      on_exit(fn -> Application.delete_env(:nebu_http, :matrix_refresh_rotate_override) end)

      resp = refresh(sess.refresh_token)

      assert resp.status == 503, "M2: got #{resp.status} #{resp.resp_body}"
      assert [retry_after] = get_resp_header(resp, "retry-after")
      assert String.to_integer(retry_after) > 0
      assert [row] = active_rows(uid, "SEMM2")
      assert row.access_token_hash == Store.hash_token(sess.access_token)
      assert whoami(sess.access_token).status == 200

      Application.delete_env(:nebu_http, :matrix_refresh_rotate_override)
      assert refresh(sess.refresh_token).status == 200
    end

    test "M2b: an ArgumentError raised inside rotate (safe_rotate rescue) answers 503 + Retry-After, session intact",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-m2b", "SEMM2B")
      idp_ok(sub)

      Application.put_env(:nebu_http, :matrix_refresh_rotate_override, fn _params ->
        raise ArgumentError, "rotate_tokens/1: invalid params"
      end)

      on_exit(fn -> Application.delete_env(:nebu_http, :matrix_refresh_rotate_override) end)

      resp = refresh(sess.refresh_token)

      assert resp.status == 503, "M2b: got #{resp.status} #{resp.resp_body}"
      assert [retry_after] = get_resp_header(resp, "retry-after")
      assert String.to_integer(retry_after) > 0
      refute Map.has_key?(json(resp), "access_token")
      assert [row] = active_rows(uid, "SEMM2B")
      assert row.access_token_hash == Store.hash_token(sess.access_token)
      assert whoami(sess.access_token).status == 200
    end

    test "M3: worker losing the race against a client /refresh stores the provider-rotated OIDC RT on the active row",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-m3", "SEMM3")
      set_expires_at(sess.access_token, 30 * 60)
      calls = :atomics.new(1, [])
      test_pid = self()

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        claims = %{"sub" => sub, "exp" => future_exp()}

        case :atomics.add_get(calls, 1, 1) do
          1 ->
            # Worker's IdP call: while it is in flight the client refreshes.
            send(test_pid, {:client_refresh, refresh(sess.refresh_token).status})
            {:ok, claims, "rotated-oidc-rt-m3"}

          _ ->
            {:ok, claims, nil}
        end
      end)

      run_one_refresh_cycle()

      assert_received {:client_refresh, 200}
      assert [row] = active_rows(uid, "SEMM3")
      refute row.access_token_hash == Store.hash_token(sess.access_token)
      assert {:ok, "rotated-oidc-rt-m3"} = Nebu.Web.SecretBox.decrypt(row.oidc_refresh_token)
    end
  end

  describe "review cycle 2" do

    # Polls pg_stat_activity until a backend is blocked on a lock while running a
    # statement matching `pattern` (state-based sync, no guessing sleeps).
    #
    # M-2: the file is `async: false`, and the poll is pinned to the concrete lock
    # holder: only a backend whose `pg_blocking_pids/1` contains `blocker_pid` (the
    # backend pid captured inside the holding connection) and whose statement matches
    # `pattern` counts. The polling connection itself is excluded.
    defp await_lock_wait(pattern, blocker_pid, attempts \\ 500) do
      {:ok, %{rows: [[n]]}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE $1 AND $2 = ANY(pg_blocking_pids(pid)) AND pid <> pg_backend_pid()",
          [pattern, blocker_pid]
        )

      cond do
        n >= 1 -> :ok
        attempts == 0 -> flunk("no backend blocked on a lock held by #{blocker_pid} for #{pattern}")
        true ->
          receive do
          after
            10 -> await_lock_wait(pattern, blocker_pid, attempts - 1)
          end
      end
    end

    defp backend_pid do
      {:ok, %{rows: [[pid]]}} = Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT pg_backend_pid()", [])
      pid
    end

    test "M1': a pending RT consumed by a transaction that started AFTER the rotation began is seen as consumed",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-m1b", "SEMM1B")
      test_pid = self()
      new_at1 = Store.generate_opaque_token()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: sess.access_token,
          new_access_token: new_at1,
          new_refresh_token: Store.generate_opaque_token(),
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # RT0 (sess.refresh_token) is now PENDING; AT1 is the active row.
      # Connection C holds the active row's lock, so the rotation (txn start T0)
      # blocks in its first statement; connection A then starts a LATER
      # transaction (NOW() > T0), consumes RT0 and holds the row lock; only then
      # is C released so the rotation reaches its FOR UPDATE re-check and blocks
      # on A. After A commits, the rotation must see RT0 as CONSUMED.
      holder_c =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            {:ok, _} =
              Ecto.Adapters.SQL.query(
                Nebu.Repo,
                "SELECT 1 FROM matrix_sessions WHERE access_token_hash = $1 FOR UPDATE",
                [Store.hash_token(new_at1)]
              )

            send(test_pid, {:c_locked, backend_pid()})
            receive do: (:c_release -> :ok)
          end)
        end)

      c_pid =
        receive do
          {:c_locked, pid} -> pid
        after
          10_000 -> flunk("timed out waiting for connection C lock")
        end


      issued_at = Store.generate_opaque_token()
      issued_rt = Store.generate_opaque_token()

      rotation =
        Task.async(fn ->
          Store.rotate_tokens(%{
            old_access_token: new_at1,
            new_access_token: issued_at,
            new_refresh_token: issued_rt,
            new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
            replay_refresh_token: sess.refresh_token
          })
        end)

      # Rotation transaction has begun (T0) and is blocked on C's lock.
      await_lock_wait("%UPDATE matrix_sessions%revoked_at = NOW()%", c_pid)

      consumer_a =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            {:ok, %{num_rows: 1}} =
              Ecto.Adapters.SQL.query(
                Nebu.Repo,
                "UPDATE matrix_sessions SET grace_until = NOW() WHERE refresh_token_hash = $1 AND grace_until IS NULL",
                [Store.hash_token(sess.refresh_token)]
              )

            send(test_pid, {:a_locked, backend_pid()})
            receive do: (:a_commit -> :ok)
          end)
        end)

      a_pid =
        receive do
          {:a_locked, pid} -> pid
        after
          10_000 -> flunk("timed out waiting for connection A lock")
        end


      # Release C: the rotation proceeds and must block on A's row lock.
      send(holder_c.pid, :c_release)
      assert {:ok, _} = Task.await(holder_c)
      await_lock_wait("%SELECT 1 FROM matrix_sessions%refresh_token_hash%FOR UPDATE%", a_pid)

      send(consumer_a.pid, :a_commit)
      assert {:ok, _} = Task.await(consumer_a)

      assert Task.await(rotation, 10_000) == {:error, :consumed},
             "M1': a token consumed (by a later-starting txn) while the rotation waited must be CONSUMED"

      assert [] = for r <- device_rows(uid, "SEMM1B"), r.access_token_hash == Store.hash_token(issued_at), do: r
      assert [row] = active_rows(uid, "SEMM1B")
      assert row.access_token_hash == Store.hash_token(new_at1)
    end
  end

  describe "review cycle 3/4 (Kassandra F-1 / F-2 / F-3 / N-1 / N-3, M-1)" do
    defp set_created_at(access_token, seconds_ago) do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE matrix_sessions SET created_at = NOW() - ($2 * INTERVAL '1 second') WHERE access_token_hash = $1",
          [Store.hash_token(access_token), seconds_ago]
        )

      :ok
    end

    defp created_at_for(access_token) do
      {:ok, %{rows: [[c]]}} =
        Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT created_at FROM matrix_sessions WHERE access_token_hash = $1", [
          Store.hash_token(access_token)
        ])

      c
    end

    # F-1 ---------------------------------------------------------------------
    test "F-1: a worker cycle does NOT extend a row beyond created_at + session TTL",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      sess = login_device(priv, sub, "oidc-rt-f1a", "SEMF1A")
      set_expires_at(sess.access_token, 5 * 60)
      # cap = created_at + ttl = now + 10 min (< IdP exp = now + 1h): still a candidate
      # (not yet at the cap), but the extension must stop exactly at the cap.
      set_created_at(sess.access_token, ttl - 600)
      orig = expires_at_for(sess.access_token)
      idp_ok(sub)

      run_one_refresh_cycle()

      assert [row] = active_rows(uid, "SEMF1A")
      assert row.access_token_hash == Store.hash_token(sess.access_token)
      cap = DateTime.add(created_at_for(sess.access_token), ttl, :second)

      assert DateTime.compare(row.expires_at, cap) != :gt,
             "F-1: in-place extension must be capped at created_at + TTL"

      # M-1: never SHORTENED either
      assert DateTime.compare(row.expires_at, orig) != :lt,
             "M-1: the worker must be strictly extending, never shorten expires_at"
    end

    test "F-1: a worker cycle still extends within the cap", %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      sess = login_device(priv, sub, "oidc-rt-f1b", "SEMF1B")
      set_expires_at(sess.access_token, 30 * 60)
      # cap = now + 2h; the IdP exp (now + 1h) is below it, so it is what is applied.
      set_created_at(sess.access_token, ttl - 7200)
      orig = expires_at_for(sess.access_token)
      idp_ok(sub)

      run_one_refresh_cycle()

      assert [row] = active_rows(uid, "SEMF1B")
      assert DateTime.compare(row.expires_at, orig) == :gt, "F-1: extension within the cap must still happen"
    end

    test "M-1: extend_in_place never shortens expires_at when the cap lies below the current value",
         %{priv_jwk: priv, user_id: uid} do
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      sess = login_device(priv, current_sub(), "oidc-rt-m1", "SEMM1")
      set_expires_at(sess.access_token, 30 * 60)
      # cap (created_at + ttl) is 100 s in the PAST, i.e. below the current expires_at.
      set_created_at(sess.access_token, ttl + 100)
      orig = expires_at_for(sess.access_token)

      new_exp = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert :ok = Nebu.Matrix.Session.MatrixSessionStore.extend_in_place(sess.access_token, new_exp, nil)

      assert [row] = active_rows(uid, "SEMM1")
      assert DateTime.compare(row.expires_at, orig) == :eq, "M-1: cap in the past => expires_at unchanged"
    end

    test "M-1: extend_in_place extends up to (not beyond) the cap and never below the current value",
         %{priv_jwk: priv, user_id: uid} do
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      sess = login_device(priv, current_sub(), "oidc-rt-m1b", "SEMM1B")
      set_expires_at(sess.access_token, 60)
      set_created_at(sess.access_token, ttl - 600)
      cap = DateTime.add(created_at_for(sess.access_token), ttl, :second)

      far = DateTime.add(DateTime.utc_now(), 7200, :second)
      assert :ok = Nebu.Matrix.Session.MatrixSessionStore.extend_in_place(sess.access_token, far, nil)
      assert [row] = active_rows(uid, "SEMM1B")
      assert DateTime.compare(row.expires_at, cap) == :eq

      # a smaller proposed value must not lower it again
      soon = DateTime.add(DateTime.utc_now(), 120, :second)
      assert :ok = Nebu.Matrix.Session.MatrixSessionStore.extend_in_place(sess.access_token, soon, nil)
      assert [row2] = active_rows(uid, "SEMM1B")
      assert DateTime.compare(row2.expires_at, cap) == :eq
    end

    # N-3 ---------------------------------------------------------------------
    test "N-3: a row already at/over the absolute cap causes NO IdP call in a worker cycle",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      sess = login_device(priv, sub, "oidc-rt-n3", "SEMN3")
      set_expires_at(sess.access_token, 30 * 60)
      set_created_at(sess.access_token, ttl + 100)
      orig = expires_at_for(sess.access_token)

      test_pid = self()

      put_matrix_oidc_refresh_override(fn _rt ->
        send(test_pid, :idp_called)
        {:ok, %{"sub" => sub, "exp" => future_exp()}, nil}
      end)

      run_one_refresh_cycle()

      refute_received :idp_called
      assert [row] = active_rows(uid, "SEMN3")
      assert DateTime.compare(row.expires_at, orig) == :eq
    end

    # F-2 ---------------------------------------------------------------------
    # RT0 was rotated away (pending). An attacker replays RT0, which rotates the
    # device's active row (AT1 -> AT2); AT1 stays soft-revoked + pending.
    defp takeover_setup(priv, device_id) do
      {sess, body} = login_and_rotate(priv, device_id)
      attacker = refresh(sess.refresh_token)
      assert attacker.status == 200, "precondition: replay of the pending RT0 must succeed"
      {body, json(attacker)}
    end

    # N-1 (cycle 4): the plug answers EVERY soft-revoked AT (pending or consumed) with
    # 401 + soft_logout:true and never deletes. Reuse detection lives on /refresh only.
    test "N-1 (a) passive attacker: victim's superseded AT -> soft_logout, device intact, victim recovers via pending RT",
         %{priv_jwk: priv, user_id: uid} do
      {victim, attacker} = takeover_setup(priv, "SEMF2A")
      shift_device_timestamps(uid, "SEMF2A", 600)

      log =
        capture_log(fn ->
          resp = whoami(victim["access_token"])
          assert resp.status == 401
          assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
          assert json(resp)["soft_logout"] == true
        end)

      refute log =~ victim["access_token"]
      refute log =~ attacker["access_token"]
      assert [_] = active_rows(uid, "SEMF2A"), "device must stay intact (no delete in the plug)"

      # The victim's RT1 is still pending: refresh wins the device back from the attacker.
      idp_ok(current_sub())
      recovered = refresh(victim["refresh_token"])
      assert recovered.status == 200
      assert whoami(json(recovered)["access_token"]).status == 200
      assert whoami(attacker["access_token"]).status == 401
    end

    test "N-1 (b) ACTIVE attacker: whoami(AT2)=200 -> whoami(AT1)=401 soft_logout -> refresh(RT1)=401 + device destroyed",
         %{priv_jwk: priv, user_id: uid} do
      {victim, attacker} = takeover_setup(priv, "SEMF2B")

      # The attacker uses his new AT at once; this consumes the victim's pending RT1.
      assert whoami(attacker["access_token"]).status == 200

      resp = whoami(victim["access_token"])
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      assert json(resp)["soft_logout"] == true
      assert [_] = active_rows(uid, "SEMF2B"), "plug must not delete anything"

      # Victim refreshes with the (now consumed) RT1 -> reuse -> both logged out.
      log =
        capture_log(fn ->
          r = refresh(victim["refresh_token"])
          assert r.status == 401
          refute_soft_logout_true(r)
        end)

      refute log =~ victim["refresh_token"]
      refute log =~ attacker["refresh_token"]
      assert device_rows(uid, "SEMF2B") == [], "reuse on /refresh must destroy the device (visible end of takeover)"
      assert whoami(attacker["access_token"]).status == 401
      assert refresh(attacker["refresh_token"]).status == 401
    end

    test "N-1 (c) in-flight old AT right after a normal rotation (pending) -> soft_logout, nothing deleted",
         %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMF2C")
      old_at = sess.access_token

      assert hd(Enum.reject(device_rows(uid, "SEMF2C"), &is_nil(&1.revoked_at))).access_token_hash ==
               Store.hash_token(old_at)

      resp = whoami(old_at)
      assert resp.status == 401
      assert json(resp)["soft_logout"] == true
      assert length(device_rows(uid, "SEMF2C")) == 2
      assert whoami(body["access_token"]).status == 200
    end

    test "N-1 (d) in-flight old AT after the client already used the new AT (consumed) -> soft_logout, nothing deleted",
         %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMF2D")
      old_at = sess.access_token

      assert hd(Enum.reject(device_rows(uid, "SEMF2D"), &is_nil(&1.revoked_at))).access_token_hash ==
               Store.hash_token(old_at)
      assert whoami(body["access_token"]).status == 200

      resp = whoami(old_at)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      assert json(resp)["soft_logout"] == true
      assert length(device_rows(uid, "SEMF2D")) == 2, "no delete in the plug, ever"
      assert whoami(body["access_token"]).status == 200
    end

    # F-3 ---------------------------------------------------------------------
    # N-7 (cycle 5): "live device" must mean "has a redeemable RT", exactly what the
    # `:current` path accepts. An active row whose expires_at has passed is still
    # redeemable, so reuse of a consumed RT must still be detected and delete the device.
    test "N-7: reuse is detected even when the attacker's active row is already expired",
         %{priv_jwk: priv, user_id: uid} do
      {victim, attacker} = takeover_setup(priv, "SEMN7")
      assert whoami(attacker["access_token"]).status == 200

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE matrix_sessions SET expires_at = NOW() - INTERVAL '1 minute' WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
          [uid, "SEMN7"]
        )

      resp = refresh(victim["refresh_token"])
      assert resp.status == 401
      refute_soft_logout_true(resp)
      assert device_rows(uid, "SEMN7") == [], "N-7: expired-but-redeemable active row must not hide reuse"
      assert refresh(attacker["refresh_token"]).status == 401
    end

    test "F-3: an OLD consumed RT (outside the reuse bound) is a plain 401 and does NOT delete the device",
         %{priv_jwk: priv, user_id: uid} do
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      {sess, body} = login_and_rotate(priv, "SEMF3A")
      assert whoami(body["access_token"]).status == 200
      shift_device_timestamps(uid, "SEMF3A", ttl + 100)

      resp = refresh(sess.refresh_token)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute_soft_logout_true(resp)

      assert length(active_rows(uid, "SEMF3A")) == 1, "F-3: outside the bound the device must NOT be deleted"
      assert whoami(body["access_token"]).status == 200
    end

    test "F-3: a consumed RT of a device with NO live active row is a plain 401, nothing is deleted",
         %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMF3B")
      assert whoami(body["access_token"]).status == 200

      # Truly dead device: no active (redeemable) row left at all.
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
          [uid, "SEMF3B"]
        )

      assert refresh(sess.refresh_token).status == 401
      assert length(device_rows(uid, "SEMF3B")) == 1, "F-3: no live device -> reuse path must not delete"
    end

    test "F-3: inside the bound (young consumed RT, live device) reuse still invalidates the device",
         %{priv_jwk: priv, user_id: uid} do
      {sess, body} = login_and_rotate(priv, "SEMF3C")
      assert whoami(body["access_token"]).status == 200
      shift_device_timestamps(uid, "SEMF3C", 600)

      assert refresh(sess.refresh_token).status == 401
      assert device_rows(uid, "SEMF3C") == []
    end
  end
end
