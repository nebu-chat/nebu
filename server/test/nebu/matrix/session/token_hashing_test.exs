defmodule Nebu.Matrix.Session.TokenHashingTest do
  @moduledoc """
  RED-phase ATDD tests for `matrix-session-refresh-fixes` /
  `docs/stories/matrix-session-refresh-fixes/token-hashing-matrix-sessions.md` (AC1-AC6).
  (AC4, the migration, lives in `token_hashing_migration_test.exs`; AC7 is docs only.)

  ## Contract these tests pin (the story leaves these details open)

    * `MatrixSessionStore.hash_token/1` is PUBLIC and returns the lowercase hex SHA-256
      (64 chars) of the token string.
    * `matrix_sessions` has `access_token_hash` (PK) / `refresh_token_hash` (UNIQUE NOT NULL);
      the plaintext columns `access_token` / `refresh_token` no longer exist.
    * The store API keeps taking PLAINTEXT tokens at the boundary (`create/1`,
      `get_by_access_token/1`, `resolve_refresh_token/1`, `rotate_tokens/1`,
      `mark_access_token_used/1`, `revoke/1`, `extend_in_place/3`, ...). A hash string
      presented where a token is expected must NOT authenticate / match.
    * Session maps returned by the store expose `:access_token_hash` / `:refresh_token_hash`
      and NO plaintext `:access_token` / `:refresh_token` (a token is never read back).
    * `RefreshWorker` and `HttpPublic` therefore need a hash-addressed way to reach a row they
      only know by its hash (e.g. `*_by_hash` store variants) - the tests only observe behaviour.
    * The replay lock statement in `rotate_tokens/1` keeps the text `refresh_token_hash = $1`
      (`refresh_semantics_test.exs` matches `pg_stat_activity` on it).

  ## Ported test files (helpers that read `matrix_sessions` by `access_token`/`refresh_token`)

  Ported to the hash columns / `Store.hash_token/1` WITHOUT weakening any assertion:
    * `test/nebu/matrix/session/refresh_semantics_test.exs` (device_rows/2, set_expires_at/2,
      expires_at_for/1, set_created_at/2, created_at_for/1, the M1' lock tests, every
      `row.access_token ==` / `row.refresh_token ==` comparison; two spots that re-read a
      rotated plaintext token from the DB now use the token the client actually holds)
    * `test/nebu/matrix/session/refresh_worker_test.exs` (set_expires_at/revoked_at_for/
      expires_at_for helpers, the AC5 rolling-ceiling loop now threads the access_token_HASH,
      the "still_here.refresh_token" assertion, the Oracle-guidance test now asserts the worker
      never rotates instead of re-reading a rotated plaintext token)
    * `test/nebu/matrix/session/matrix_session_store_test.exs` (set_column/3, oidc column read)
    * `test/nebu/matrix/login_refresh_test.exs` (expiry backdating, oidc_refresh_token read)
    * `test/nebu/matrix/device_lifecycle_login_test.exs` (expiry backdating)
    * `test/nebu/release_test.exs` (the exact-version-list assertion now requires 000001-000034
      PLUS the new token-hashing migration)
  Reviewed, no change needed (only plaintext tokens at the store API boundary, or table-name
  based cleanup): device_keys_test, device_endpoints_test, sso_login_configured_claim_device_test,
  auto_join_first_login_regression_test, matrix_router_test, request_logger_test,
  migrations_grant_test (000002 GRANT is table-level and survives an in-place ALTER),
  query_telemetry_test (synthetic SQL string, no real column access).

  Tagged `:integration` (needs Postgres). Seam: `:matrix_oidc_refresh_override` steers IdP outcomes.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  require Logger

  @moduletag :integration

  alias Nebu.Matrix.SsoStore
  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  @server_name "test.local"
  @issuer "https://idp.example.com/realms/nebu"
  @audience "nebu-client"
  @kid "token-hashing-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"
  @worker Nebu.Matrix.Session.RefreshWorker
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @refresh_path "/_matrix/client/v3/refresh"
  @whoami_path "/_matrix/client/v3/account/whoami"
  @router_opts Nebu.Web.Router.init([])

  # ── helpers (same seams as refresh_semantics_test.exs) ─────────────────────

  defp fresh_sub, do: "hsh" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp current_sub, do: Process.get(:token_hashing_sub) || raise("sub not set by setup")
  defp future_exp, do: System.system_time(:second) + 3600
  defp opaque, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  defp sha256_hex(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)

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
    Application.put_env(:nebu_http, :admin_secret_at_rest, "token-hashing-test-internal-secret")

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

    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), %{"alg" => "RS256", "kid" => @kid}, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    c =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    c = Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(c, @router_opts)
  end

  defp json(c), do: Jason.decode!(c.resp_body)
  defp auth(token), do: [{"authorization", "Bearer " <> token}]
  defp location(c), do: c |> get_resp_header("location") |> List.first()
  defp refresh(rt), do: call(:post, @refresh_path, %{"refresh_token" => rt})
  defp whoami(at), do: call(:get, @whoami_path, nil, auth(at))

  defp mint_login_token(priv, oidc_refresh_token, sub) do
    init =
      call(:get, "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("http://localhost:7070/#/home"))

    assert init.status == 302
    params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    id_token = sign_id_token(priv, %{"sub" => sub, "nonce" => params["nonce"]})

    Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> {:ok, id_token, oidc_refresh_token} end)

    cb =
      call(:get, "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <> URI.encode_www_form(params["state"]))

    assert cb.status == 302
    cb |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.fetch!("loginToken")
  end

  defp login_device(priv, oidc_rt, device_id) do
    token = mint_login_token(priv, oidc_rt, current_sub())

    resp =
      call(:post, "/_matrix/client/v3/login", %{
        "type" => "m.login.token",
        "token" => token,
        "refresh_token" => true,
        "device_id" => device_id
      })

    assert resp.status == 200, "precondition: login must succeed, got #{resp.resp_body}"
    body = json(resp)
    %{access_token: body["access_token"], refresh_token: body["refresh_token"], user_id: body["user_id"], device_id: device_id}
  end

  defp idp_ok(sub, new_oidc_rt \\ nil) do
    Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fn _rt ->
      {:ok, %{"sub" => sub, "exp" => future_exp()}, new_oidc_rt}
    end)
  end

  defp run_one_refresh_cycle(lookahead_seconds \\ 3600) do
    Application.put_env(:nebu_http, :matrix_refresh_worker_lookahead_seconds, lookahead_seconds)
    _ = stop_supervised(@worker)
    pid = start_supervised!(@worker)
    send(pid, :refresh)
    :sys.get_state(pid)
    pid
  end

  defp sql!(sql, params \\ []) do
    {:ok, %{rows: rows}} = Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
    rows
  end

  defp set_expires_at_by_hash(at, seconds) do
    sql!("UPDATE matrix_sessions SET expires_at = NOW() + ($2 * INTERVAL '1 second') WHERE access_token_hash = $1", [
      sha256_hex(at),
      seconds
    ])
  end

  defp rows_for(uid, device) do
    sql!(
      """
      SELECT access_token_hash, refresh_token_hash, revoked_at, expires_at
        FROM matrix_sessions WHERE user_id = $1 AND device_id = $2
      """,
      [uid, device]
    )
  end

  defp row_text_for_user(uid), do: sql!("SELECT row_to_json(m)::text FROM matrix_sessions m WHERE m.user_id = $1", [uid]) |> List.flatten()

  # Store-level session (no HTTP) with a unique user.
  defp store_session(opts \\ []) do
    at = Keyword.get(opts, :at, opaque())
    rt = Keyword.get(opts, :rt, opaque())
    uid = Keyword.get(opts, :user_id, "@hsh_store_#{System.unique_integer([:positive])}:test.local")
    dev = Keyword.get(opts, :device_id, "HDEV#{System.unique_integer([:positive])}")

    :ok =
      Store.create(%{
        access_token: at,
        refresh_token: rt,
        user_id: uid,
        device_id: dev,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oidc_refresh_token: Keyword.get(opts, :oidc),
        auth_time: Keyword.get(opts, :auth_time)
      })

    on_exit(fn ->
      if Process.whereis(Nebu.Repo), do: sql!("DELETE FROM matrix_sessions WHERE user_id = $1", [uid])
    end)

    %{at: at, rt: rt, user_id: uid, device_id: dev}
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
    Process.put(:token_hashing_sub, sub)
    uid = "@" <> sub <> ":" <> @server_name

    if Process.whereis(Nebu.Repo) do
      _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Hash Test", "hash@example.com")
      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Hash Test", nil)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          for table <- ["matrix_sessions", "profiles", "users"] do
            _ = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM #{table} WHERE user_id = $1", [uid])
          end
        end
      end)
    end

    {:ok, priv_jwk: priv, user_id: uid, sub: sub}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — the single hashing seam
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: Store.hash_token/1 is the single, public hashing seam" do
    test "returns the lowercase hex SHA-256 of the token string" do
      t = opaque()
      assert Store.hash_token(t) == sha256_hex(t)
      assert Store.hash_token(t) =~ @hex64
    end

    test "matches the published SHA-256 test vector for \"abc\"" do
      assert Store.hash_token("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end

    test "is deterministic and input-sensitive" do
      a = opaque()
      assert Store.hash_token(a) == Store.hash_token(a)
      refute Store.hash_token(a) == Store.hash_token(a <> "0")
      refute Store.hash_token("Token") == Store.hash_token("token")
    end

    test "equals the database-side sha256 formula" do
      t = opaque()
      assert [[db]] = sql!("SELECT encode(sha256(convert_to($1::text, 'UTF8')), 'hex')", [t])
      assert Store.hash_token(t) == db
    end

    test "hashes the empty string and non-ASCII tokens by their UTF-8 bytes (no crash)" do
      assert Store.hash_token("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      assert Store.hash_token("tökén") == sha256_hex("tökén")
    end

    test "rejects non-binary input instead of hashing garbage" do
      for bad <- [nil, 123, :atom, %{}, ["list"]] do
        assert_raise_any(fn -> Store.hash_token(bad) end)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — no plaintext token at rest
  # ══════════════════════════════════════════════════════════════════════════

  defp assert_raise_any(fun) do
    try do
      fun.()
      flunk("expected an exception (FunctionClauseError or ArgumentError), none raised")
    rescue
      e in [FunctionClauseError, ArgumentError] -> e
    end
  end

  describe "AC1: schema" do
    test "matrix_sessions has the hash columns and NO plaintext token columns" do
      cols =
        sql!("SELECT column_name FROM information_schema.columns WHERE table_name = 'matrix_sessions' AND table_schema = 'public'")
        |> List.flatten()

      assert "access_token_hash" in cols
      assert "refresh_token_hash" in cols
      refute "access_token" in cols, "AC1: plaintext access_token column must not exist"
      refute "refresh_token" in cols, "AC1: plaintext refresh_token column must not exist"
    end

    test "PRIMARY KEY is access_token_hash; refresh_token_hash is UNIQUE NOT NULL and indexed" do
      assert [["access_token_hash"]] =
               sql!("""
               SELECT a.attname FROM pg_index i
                 JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                WHERE i.indrelid = 'matrix_sessions'::regclass AND i.indisprimary
               """)

      assert [[true]] =
               sql!("""
               SELECT EXISTS (SELECT 1 FROM pg_index i
                 JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                WHERE i.indrelid = 'matrix_sessions'::regclass AND i.indisunique AND NOT i.indisprimary
                  AND i.indnatts = 1 AND a.attname = 'refresh_token_hash')
               """)

      assert [["NO"]] =
               sql!(
                 "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'matrix_sessions' AND column_name = 'refresh_token_hash'"
               )
    end
  end

  describe "AC1: store-level insert" do
    test "a raw row contains the hash columns = sha256_hex(token) and no plaintext substring anywhere" do
      s = store_session()

      assert [[ah, rh]] =
               sql!("SELECT access_token_hash, refresh_token_hash FROM matrix_sessions WHERE user_id = $1", [s.user_id])

      assert ah == sha256_hex(s.at)
      assert rh == sha256_hex(s.rt)

      for text <- row_text_for_user(s.user_id) do
        refute text =~ s.at, "AC1: row_to_json must not contain the plaintext access token"
        refute text =~ s.rt, "AC1: row_to_json must not contain the plaintext refresh token"
      end

      assert [[0]] = sql!("SELECT count(*)::int FROM matrix_sessions m WHERE m::text LIKE '%' || $1 || '%'", [s.at])
      assert [[0]] = sql!("SELECT count(*)::int FROM matrix_sessions m WHERE m::text LIKE '%' || $1 || '%'", [s.rt])
    end

    test "the session is found by the PLAINTEXT tokens and the returned map carries only hashes" do
      s = store_session()

      assert {:ok, sess} = Store.get_by_access_token(s.at)
      assert sess.user_id == s.user_id
      assert sess.access_token_hash == Store.hash_token(s.at)
      assert sess.refresh_token_hash == Store.hash_token(s.rt)
      refute Map.has_key?(sess, :access_token), "AC1/AC2: a token is never read back from the DB"
      refute Map.has_key?(sess, :refresh_token), "AC1/AC2: a token is never read back from the DB"

      assert {:ok, rsess, :current} = Store.resolve_refresh_token(s.rt)
      refute Map.has_key?(rsess, :access_token)
      refute Map.has_key?(rsess, :refresh_token)
      assert rsess.access_token_hash == Store.hash_token(s.at)
    end

    test "creating two sessions with the same access token is rejected (PK on the hash)" do
      s = store_session()

      result =
        try do
          Store.create(%{
            access_token: s.at,
            refresh_token: opaque(),
            user_id: s.user_id,
            device_id: "OTHER",
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          })
        rescue
          e -> {:raised, e}
        end

      assert match?({:raised, _}, result), "AC1: duplicate access token must violate the PK on access_token_hash"
      assert [[1]] = sql!("SELECT count(*)::int FROM matrix_sessions WHERE user_id = $1", [s.user_id])
    end

    test "creating two sessions with the same refresh token is rejected (UNIQUE on the hash)" do
      s = store_session()

      result =
        try do
          Store.create(%{
            access_token: opaque(),
            refresh_token: s.rt,
            user_id: s.user_id,
            device_id: "OTHER",
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          })
        rescue
          e -> {:raised, e}
        end

      assert match?({:raised, _}, result), "AC1: duplicate refresh token must violate the UNIQUE hash column"
      assert [[1]] = sql!("SELECT count(*)::int FROM matrix_sessions WHERE user_id = $1", [s.user_id])
    end
  end

  describe "AC1: HTTP login + refresh leave no plaintext token in the database" do
    test "after login no column of matrix_sessions and no other table contains the AT/RT; hashes match",
         %{priv_jwk: priv, user_id: uid} do
      sess = login_device(priv, "oidc-rt-login-plain", "HSHLOGIN")

      assert [[ah, rh]] =
               sql!("SELECT access_token_hash, refresh_token_hash FROM matrix_sessions WHERE user_id = $1 AND device_id = 'HSHLOGIN'", [uid])

      assert ah == sha256_hex(sess.access_token)
      assert rh == sha256_hex(sess.refresh_token)

      for text <- row_text_for_user(uid) do
        refute text =~ sess.access_token, "AC1: plaintext AT in matrix_sessions"
        refute text =~ sess.refresh_token, "AC1: plaintext RT in matrix_sessions"
      end

      assert_token_absent_from_every_table([sess.access_token, sess.refresh_token])
    end

    test "after a refresh rotation neither the old nor the new tokens appear in any table",
         %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-rot-plain", "HSHROT")
      idp_ok(sub)
      resp = refresh(sess.refresh_token)
      assert resp.status == 200
      body = json(resp)

      rows = rows_for(uid, "HSHROT")
      assert length(rows) == 2

      hashes = Enum.flat_map(rows, fn [a, r | _] -> [a, r] end)

      for t <- [sess.access_token, sess.refresh_token, body["access_token"], body["refresh_token"]] do
        assert sha256_hex(t) in hashes, "AC1: the hash of every minted token is stored"
      end

      assert_token_absent_from_every_table([sess.access_token, sess.refresh_token, body["access_token"], body["refresh_token"]])
    end

    defp assert_token_absent_from_every_table(tokens) do
      tables =
        sql!("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1") |> List.flatten()

      assert "matrix_sessions" in tables

      for table <- tables, t <- tokens do
        assert [[0]] =
                 sql!("SELECT count(*)::int FROM #{table} x WHERE x::text LIKE '%' || $1 || '%'", [t]),
               "AC1: a plaintext token was found in table #{table}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2/AC5 — presenting the stored hash is NOT a credential
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2/AC5: the stored hash is not a bearer / refresh credential" do
    test "plaintext AT authenticates (200); the stored hash string as bearer is 401 M_UNKNOWN_TOKEN",
         %{priv_jwk: priv, user_id: uid} do
      sess = login_device(priv, "oidc-rt-bearer", "HSHBEAR")
      assert whoami(sess.access_token).status == 200

      [[stored_hash]] = sql!("SELECT access_token_hash FROM matrix_sessions WHERE user_id = $1 AND device_id = 'HSHBEAR'", [uid])

      resp = whoami(stored_hash)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      refute resp.resp_body =~ stored_hash, "AC5: an error response must not echo the presented credential"
    end

    test "the stored refresh-token hash cannot be redeemed at /refresh (401)", %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-hash-redeem", "HSHRED")
      idp_ok(sub)

      [[rt_hash]] = sql!("SELECT refresh_token_hash FROM matrix_sessions WHERE user_id = $1 AND device_id = 'HSHRED'", [uid])

      resp = refresh(rt_hash)
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
      assert whoami(sess.access_token).status == 200, "a rejected hash must not damage the real session"
      assert refresh(sess.refresh_token).status == 200
    end

    test "store lookups with a hash string (or a hash of the hash) never match" do
      s = store_session()
      h_at = Store.hash_token(s.at)
      h_rt = Store.hash_token(s.rt)

      assert :error = Store.get_by_access_token(h_at)
      assert :error = Store.get_by_access_token(Store.hash_token(h_at))
      assert :error = Store.resolve_refresh_token(h_rt)
      assert :error = Store.get_auth_context(h_at)
      refute Store.has_open_grace_window?(h_at)
      assert :error = Store.extend_in_place(h_at, DateTime.add(DateTime.utc_now(), 7200, :second), nil)

      assert :error =
               Store.rotate_tokens(%{
                 old_access_token: h_at,
                 new_access_token: opaque(),
                 new_refresh_token: opaque(),
                 new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })

      assert {:ok, _} = Store.get_by_access_token(s.at), "the real token is untouched by all of the above"
    end

    test "revoke/1 and delete_by_access_token/1 given a hash string do not delete the session" do
      s = store_session()
      h_at = Store.hash_token(s.at)

      assert :ok = Store.revoke(h_at)
      assert :ok = Store.delete_by_access_token(h_at)
      assert {:ok, %{revoked_at: nil}} = Store.get_by_access_token(s.at)
    end

    test "an unknown / empty / near-miss token is just :error (no crash, no oracle)" do
      s = store_session()
      assert :error = Store.get_by_access_token("")
      assert :error = Store.get_by_access_token(String.upcase(s.at) <> "x")
      assert :error = Store.get_by_access_token(String.slice(s.at, 0, 63))
      assert :error = Store.resolve_refresh_token("")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — behaviour unchanged (short end-to-end over the hash columns)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: refresh rotation, pending and consumed semantics over hash columns" do
    test "rotate: old row soft-revoked + pending, new row active; pending RT replays; consumed RT is rejected",
         %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-sem", "HSHSEM")
      idp_ok(sub)

      r1 = refresh(sess.refresh_token)
      assert r1.status == 200
      b1 = json(r1)
      refute b1["access_token"] == sess.access_token
      refute b1["refresh_token"] == sess.refresh_token

      rows = rows_for(uid, "HSHSEM")
      assert length(rows) == 2
      old = Enum.find(rows, fn [a | _] -> a == sha256_hex(sess.access_token) end)
      assert [_, _, revoked_at, _] = old
      assert revoked_at != nil, "old row is soft-revoked (rotated away)"
      assert [[grace_null?]] =
               sql!("SELECT grace_until IS NULL FROM matrix_sessions WHERE access_token_hash = $1", [sha256_hex(sess.access_token)])

      assert grace_null?, "old row is PENDING (grace_until NULL) until the new tokens are used"

      # PENDING replay: the client lost the response and retries with the old RT.
      r2 = refresh(sess.refresh_token)
      assert r2.status == 200, "AC3: a pending RT must still be redeemable, got #{r2.resp_body}"

      # The client uses a new AT -> the old RT is CONSUMED.
      assert whoami(json(r2)["access_token"]).status == 200

      # Old AT of a rotated-away row -> soft logout, not an error / not deleted.
      # (Checked BEFORE the consumed-RT reuse below: reuse destroys the device's rows.)
      old_resp = whoami(sess.access_token)
      assert old_resp.status == 401
      assert json(old_resp)["soft_logout"] == true

      r3 = refresh(sess.refresh_token)
      assert r3.status == 401
      assert json(r3)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "reuse of a consumed RT with a live device does not log the device out of other devices",
         %{priv_jwk: priv, sub: sub} do
      a = login_device(priv, "oidc-rt-a", "HSHA")
      b = login_device(priv, "oidc-rt-b", "HSHB")
      idp_ok(sub)

      b1 = json(refresh(a.refresh_token))
      assert whoami(b1["access_token"]).status == 200
      assert refresh(a.refresh_token).status == 401

      assert whoami(b.access_token).status == 200, "AC3: an unrelated device is untouched"
    end

    test "mark_access_token_used consumes pending siblings (plaintext in, hash columns updated)" do
      s = store_session()
      new_at = opaque()
      new_rt = opaque()

      assert :ok =
               Store.rotate_tokens(%{
                 old_access_token: s.at,
                 new_access_token: new_at,
                 new_refresh_token: new_rt,
                 new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })

      assert Store.has_open_grace_window?(new_at)
      assert {:ok, _, :replay} = Store.resolve_refresh_token(s.rt)

      assert :ok = Store.mark_access_token_used(new_at)

      refute Store.has_open_grace_window?(new_at)
      assert {:consumed, _} = Store.resolve_refresh_token(s.rt)

      assert [[false]] =
               sql!("SELECT grace_until IS NULL FROM matrix_sessions WHERE access_token_hash = $1", [Store.hash_token(s.at)])
    end

    test "rotate_tokens with :consume_pending_siblings and :replay_refresh_token keep their semantics" do
      s = store_session()
      at1 = opaque()
      rt1 = opaque()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: s.at,
          new_access_token: at1,
          new_refresh_token: rt1,
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # replaying the pending RT0 while it IS pending works ...
      at2 = opaque()

      assert :ok =
               Store.rotate_tokens(%{
                 old_access_token: at1,
                 new_access_token: at2,
                 new_refresh_token: opaque(),
                 new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
                 replay_refresh_token: s.rt
               })

      # ... after it was consumed it is rejected atomically (nothing issued).
      :ok = Store.mark_access_token_used(at2)
      at3 = opaque()

      assert {:error, :consumed} =
               Store.rotate_tokens(%{
                 old_access_token: at2,
                 new_access_token: at3,
                 new_refresh_token: opaque(),
                 new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
                 replay_refresh_token: s.rt
               })

      assert :error = Store.get_by_access_token(at3)
      assert {:ok, %{revoked_at: nil}} = Store.get_by_access_token(at2), "rolled back: the active row stays active"
    end

    test "F-3: rotate_tokens/1 rejects params carrying BOTH :old_access_token and :old_access_token_hash" do
      s = store_session()
      other = store_session()

      params = %{
        old_access_token: s.at,
        old_access_token_hash: Store.hash_token(other.at),
        new_access_token: opaque(),
        new_refresh_token: opaque(),
        new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert_raise ArgumentError, fn -> Store.rotate_tokens(params) end
      assert {:ok, %{revoked_at: nil}} = Store.get_by_access_token(s.at), "nothing rotated"
      assert {:ok, %{revoked_at: nil}} = Store.get_by_access_token(other.at), "nothing rotated"
    end

    test "I-7: rotate_tokens/1 with NEITHER :old_access_token nor :old_access_token_hash raises ArgumentError" do
      s = store_session()

      params = %{
        new_access_token: opaque(),
        new_refresh_token: opaque(),
        new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert_raise ArgumentError, fn -> Store.rotate_tokens(params) end
      assert {:ok, %{revoked_at: nil}} = Store.get_by_access_token(s.at), "nothing rotated"
    end

    test "rotating an unknown or already revoked access token is :error" do
      s = store_session()
      params = fn old -> %{old_access_token: old, new_access_token: opaque(), new_refresh_token: opaque(), new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)} end

      assert :error = Store.rotate_tokens(params.(opaque()))
      assert :ok = Store.rotate_tokens(params.(s.at))
      assert :error = Store.rotate_tokens(params.(s.at)), "the second rotation of the same (now revoked) AT loses"
    end

    test "concurrent /refresh with the same RT: never 5xx, one active row, only hashes stored",
         %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-race", "HSHRACE")
      idp_ok(sub)

      responses =
        1..6
        |> Task.async_stream(fn _ -> refresh(sess.refresh_token) end, max_concurrency: 6, timeout: 30_000)
        |> Enum.map(fn {:ok, c} -> c end)

      statuses = Enum.map(responses, & &1.status)
      assert Enum.all?(statuses, &(&1 in [200, 401])), "got #{inspect(statuses)}"
      assert 200 in statuses

      active = Enum.filter(rows_for(uid, "HSHRACE"), fn [_, _, rev, _] -> is_nil(rev) end)
      assert length(active) == 1, "AC6: exactly one non-revoked row per device"
      [[ah | _]] = active

      winner = Enum.find(responses, fn r -> r.status == 200 and sha256_hex(json(r)["access_token"]) == ah end)
      assert winner, "the active row's hash must belong to a token a winner received"
      assert whoami(json(winner)["access_token"]).status == 200
    end
  end

  describe "AC3: RefreshWorker extends in place over the hash columns" do
    test "tokens and hashes stay, expires_at grows, client token keeps working",
         %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-worker", "HSHWORK")
      set_expires_at_by_hash(sess.access_token, 30 * 60)
      [[_, _, _, before_exp]] = rows_for(uid, "HSHWORK")
      idp_ok(sub)

      run_one_refresh_cycle()

      assert [[ah, rh, nil, after_exp]] = rows_for(uid, "HSHWORK")
      assert ah == sha256_hex(sess.access_token), "worker must not rotate the access token"
      assert rh == sha256_hex(sess.refresh_token), "worker must not rotate the refresh token"
      assert DateTime.compare(after_exp, before_exp) == :gt
      assert whoami(sess.access_token).status == 200
    end

    test "confirmed IdP rejection hard-deletes exactly the selected row; transient failure keeps it",
         %{priv_jwk: priv, user_id: uid} do
      keep = login_device(priv, "oidc-rt-keep", "HSHKEEP")
      gone = login_device(priv, "oidc-rt-gone", "HSHGONE")
      set_expires_at_by_hash(keep.access_token, 30 * 60)
      set_expires_at_by_hash(gone.access_token, 30 * 60)

      # Only the "gone" device's RT is rejected by the IdP.
      Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fn rt ->
        if rt == "oidc-rt-gone", do: {:error, {:token_endpoint_status, 401}}, else: {:error, {:token_endpoint_unreachable, :timeout}}
      end)

      run_one_refresh_cycle()

      assert rows_for(uid, "HSHGONE") == [], "AC3: confirmed rejection deletes the row (by hash)"
      assert [[_, _, nil, _]] = rows_for(uid, "HSHKEEP"), "AC3: a transient failure must keep the session"
      assert whoami(keep.access_token).status == 200
      assert whoami(gone.access_token).status == 401
    end

    test "candidates are only active, nearing rows (a far-future row is left alone)",
         %{priv_jwk: priv, user_id: uid, sub: sub} do
      near = login_device(priv, "oidc-rt-near", "HSHNEAR")
      far = login_device(priv, "oidc-rt-far", "HSHFAR")
      set_expires_at_by_hash(near.access_token, 30 * 60)
      set_expires_at_by_hash(far.access_token, 30 * 24 * 3600)
      [[_, _, _, far_before]] = rows_for(uid, "HSHFAR")
      [[_, _, _, near_before]] = rows_for(uid, "HSHNEAR")
      idp_ok(sub)

      run_one_refresh_cycle(3600)

      [[_, _, _, far_after]] = rows_for(uid, "HSHFAR")
      [[_, _, _, near_after]] = rows_for(uid, "HSHNEAR")
      assert far_after == far_before
      assert DateTime.compare(near_after, near_before) == :gt
    end

    test "extend_in_place/3 takes the plaintext AT and never shortens expires_at" do
      s = store_session()
      [[exp_before]] = sql!("SELECT expires_at FROM matrix_sessions WHERE access_token_hash = $1", [Store.hash_token(s.at)])

      assert :ok = Store.extend_in_place(s.at, DateTime.add(exp_before, -600, :second), nil)
      [[exp_same]] = sql!("SELECT expires_at FROM matrix_sessions WHERE access_token_hash = $1", [Store.hash_token(s.at)])
      assert DateTime.compare(exp_same, exp_before) != :lt

      assert :error = Store.extend_in_place(opaque(), DateTime.add(exp_before, 600, :second), nil)
    end
  end

  describe "AC3: logout, delete-device, deactivation and UIA lookups over the hash columns" do
    test "POST /logout destroys the session: AT 401, RT 401, rows gone", %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-logout", "HSHLOG")
      idp_ok(sub)
      assert whoami(sess.access_token).status == 200

      resp = call(:post, "/_matrix/client/v3/logout", %{}, auth(sess.access_token))
      assert resp.status == 200

      assert :error = Store.get_by_access_token(sess.access_token)
      assert whoami(sess.access_token).status == 401
      assert refresh(sess.refresh_token).status == 401
      assert rows_for(uid, "HSHLOG") == []
    end

    test "logout also removes the rotated-away (pending) rows of the device", %{priv_jwk: priv, user_id: uid, sub: sub} do
      sess = login_device(priv, "oidc-rt-lp", "HSHLP")
      idp_ok(sub)
      b = json(refresh(sess.refresh_token))
      assert length(rows_for(uid, "HSHLP")) == 2

      assert call(:post, "/_matrix/client/v3/logout", %{}, auth(b["access_token"])).status == 200
      assert rows_for(uid, "HSHLP") == []
      assert refresh(sess.refresh_token).status == 401, "the old pending RT dies with the device"
    end

    test "delete_for_user_device/2 removes every row of that device only" do
      uid = "@hsh_del_#{System.unique_integer([:positive])}:test.local"
      a = store_session(user_id: uid, device_id: "DEL_A")
      b = store_session(user_id: uid, device_id: "DEL_B")

      assert :ok = Store.delete_for_user_device(uid, "DEL_A")

      assert :error = Store.get_by_access_token(a.at)
      assert :error = Store.resolve_refresh_token(a.rt)
      assert {:ok, _} = Store.get_by_access_token(b.at)
    end

    test "delete_for_user/1 (deactivation) removes all of a user's sessions" do
      uid = "@hsh_deact_#{System.unique_integer([:positive])}:test.local"
      a = store_session(user_id: uid, device_id: "DEA_A")
      b = store_session(user_id: uid, device_id: "DEA_B")

      assert :ok = Store.delete_for_user(uid)
      assert :error = Store.get_by_access_token(a.at)
      assert :error = Store.get_by_access_token(b.at)
      assert :error = Store.resolve_refresh_token(b.rt)
    end

    test "delete_by_access_token/1 deletes the ACTIVE row only, never a revoked sibling" do
      s = store_session()
      new_at = opaque()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: s.at,
          new_access_token: new_at,
          new_refresh_token: opaque(),
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert :ok = Store.delete_by_access_token(s.at), "the revoked old row is guarded by revoked_at IS NULL"
      assert {:ok, _} = Store.get_by_access_token(s.at)

      assert :ok = Store.delete_by_access_token(new_at)
      assert :error = Store.get_by_access_token(new_at)
    end

    test "get_auth_context/1 and refresh_auth_time/2 (UIA auth_time lookup) work by plaintext token" do
      s = store_session(auth_time: 1_700_000_000)

      assert {:ok, %{user_id: uid, device_id: dev, auth_time: 1_700_000_000}} = Store.get_auth_context(s.at)
      assert uid == s.user_id and dev == s.device_id
      assert :error = Store.get_auth_context(opaque())

      assert :ok = Store.refresh_auth_time(s.user_id, 1_800_000_000)
      assert {:ok, %{auth_time: 1_800_000_000}} = Store.get_auth_context(s.at)
    end

    test "rotation carries auth_time over verbatim (a refresh is not a fresh authentication)" do
      s = store_session(auth_time: 1_700_000_123)
      new_at = opaque()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: s.at,
          new_access_token: new_at,
          new_refresh_token: opaque(),
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:ok, %{auth_time: 1_700_000_123}} = Store.get_auth_context(new_at)
    end

    test "an expired opaque session is 401 soft_logout (decided by the caller from expires_at)", %{priv_jwk: priv} do
      sess = login_device(priv, "oidc-rt-exp", "HSHEXP")
      set_expires_at_by_hash(sess.access_token, -1)

      resp = whoami(sess.access_token)
      assert resp.status == 401
      assert json(resp)["soft_logout"] == true
    end

    test "cleanup_expired/0 deletes by expires_at and returns the count" do
      s = store_session()
      sql!("UPDATE matrix_sessions SET expires_at = NOW() - INTERVAL '8 days' WHERE access_token_hash = $1", [Store.hash_token(s.at)])
      assert Store.cleanup_expired() >= 1
      assert :error = Store.get_by_access_token(s.at)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — no token / hash in logs or error responses
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5: logs and error responses never contain a token or its hash" do
    # config/test.exs sets the Logger level to :warning, which would make every
    # capture_log below capture nothing (a vacuous "no leak" check). Raise it to :debug
    # for this block (restored afterwards) and prove capturing works via positive controls.
    setup do
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    defp refute_in(text, secrets, where) do
      for s <- secrets do
        refute text =~ s, "AC5: #{where} leaked a secret: #{String.slice(s, 0, 10)}..."
      end
    end

    test "a full login -> whoami -> refresh -> replay -> consumed -> logout cycle logs no token and no hash",
         %{priv_jwk: priv, sub: sub} do
      log =
        capture_log([level: :debug], fn ->
          sess = login_device(priv, "oidc-rt-log-cycle-SECRET", "HSHLOGC")
          idp_ok(sub)
          assert whoami(sess.access_token).status == 200
          b0 = json(refresh(sess.refresh_token))
          # pending replay of the old RT rotates the device's active row again
          b1 = json(refresh(sess.refresh_token))
          assert is_binary(b0["access_token"]) and is_binary(b1["access_token"])
          assert whoami(b1["access_token"]).status == 200
          # a second device, so the logout below is still meaningful after the reuse
          # detection of the consumed RT destroyed the first device's session
          other = login_device(priv, "oidc-rt-log-cycle-other-SECRET", "HSHLOGC2")
          assert refresh(sess.refresh_token).status == 401
          assert whoami(Store.hash_token(sess.access_token)).status == 401
          assert call(:post, "/_matrix/client/v3/logout", %{}, auth(other.access_token)).status == 200
          send(self(), {:minted, sess, b0, b1, other})
        end)

      assert_received {:minted, sess, b0, b1, other}

      tokens = [sess.access_token, sess.refresh_token, b0["access_token"], b0["refresh_token"], b1["access_token"], b1["refresh_token"], other.access_token, other.refresh_token]
      hashes = Enum.map(tokens, &Store.hash_token/1)
      assert log =~ "matrix session refreshed",
             "positive control: info/debug lines must be captured, else the leak checks below are vacuous"

      refute_in(log, tokens, "log (plaintext token)")
      refute_in(log, hashes, "log (token hash)")
      refute_in(log, ["oidc-rt-log-cycle-SECRET"], "log (oidc refresh token)")
    end

    test "a worker cycle (success, transient failure, confirmed rejection) logs no token and no hash",
         %{priv_jwk: priv, sub: sub} do
      ok = login_device(priv, "oidc-rt-log-w-ok-SECRET", "HSHLW1")
      transient = login_device(priv, "oidc-rt-log-w-tr-SECRET", "HSHLW2")
      rejected = login_device(priv, "oidc-rt-log-w-rej-SECRET", "HSHLW3")
      for s <- [ok, transient, rejected], do: set_expires_at_by_hash(s.access_token, 30 * 60)

      Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fn rt ->
        cond do
          rt =~ "w-ok" -> {:ok, %{"sub" => sub, "exp" => future_exp()}, nil}
          rt =~ "w-tr" -> {:error, {:token_endpoint_unreachable, :timeout}}
          true -> {:error, {:token_endpoint_status, 401}}
        end
      end)

      log = capture_log([level: :debug], fn -> run_one_refresh_cycle() end)

      assert log =~ "matrix refresh worker: session revalidated",
             "positive control: worker info lines must be captured, else the leak checks below are vacuous"

      for s <- [ok, transient, rejected] do
        refute_in(log, [s.access_token, s.refresh_token, Store.hash_token(s.access_token), Store.hash_token(s.refresh_token)], "worker log")
      end
    end

    test "store failure paths (delete/rotate on unknown tokens) log no token and no hash" do
      t1 = opaque()
      t2 = opaque()

      log =
        capture_log([level: :debug], fn ->
          Logger.debug("hashing-log-control-line")
          Store.revoke(t1)
          Store.delete_by_access_token(t1)
          Store.rotate_tokens(%{old_access_token: t1, new_access_token: t2, new_refresh_token: opaque(), new_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)})
          Store.get_by_access_token(t1)
          Store.resolve_refresh_token(t2)
        end)

      assert log =~ "hashing-log-control-line", "positive control: debug lines must be captured"
      refute_in(log, [t1, t2, Store.hash_token(t1), Store.hash_token(t2)], "store log")
    end

    test "401 / error responses do not echo the presented token or its hash", %{priv_jwk: priv, sub: sub} do
      sess = login_device(priv, "oidc-rt-err-body", "HSHERR")
      idp_ok(sub)
      bogus = opaque()

      for {resp, presented} <- [
            {whoami(bogus), bogus},
            {whoami(Store.hash_token(sess.access_token)), Store.hash_token(sess.access_token)},
            {refresh(bogus), bogus},
            {refresh(Store.hash_token(sess.refresh_token)), Store.hash_token(sess.refresh_token)}
          ] do
        assert resp.status == 401
        refute_in(resp.resp_body, [presented, Store.hash_token(presented)], "error body")
      end

      ok = whoami(sess.access_token)
      refute_in(ok.resp_body, [sess.access_token, Store.hash_token(sess.access_token)], "whoami body")
    end

    test "PayloadRedactor still redacts access_token / refresh_token (unchanged)" do
      redacted =
        Nebu.Web.Plugs.RequestLogger.PayloadRedactor.redact_payload(%{
          "access_token" => "tok-plain-1",
          "refresh_token" => "tok-plain-2",
          "nested" => %{"access_token" => "tok-plain-3"}
        })

      assert redacted["access_token"] == "***REDACTED***"
      assert redacted["refresh_token"] == "***REDACTED***"
      assert redacted["nested"]["access_token"] == "***REDACTED***"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2/AC5 — static guards on server/lib (single seam, no plaintext SQL)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2/AC5: grep guard on server/lib" do
    @lib Path.expand("../../../../lib", __DIR__)

    # Strips @doc/@moduledoc heredocs and `#` comment lines (prose may still describe the old design).
    defp code_of(path) do
      path
      |> File.read!()
      |> String.replace(~r/@(?:module)?doc\s+(?:~[sS])?"""[\s\S]*?"""/, "")
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      |> Enum.join("\n")
    end

    defp lib_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

    test "no SQL in server/lib compares or selects the plaintext token columns" do
      offenders =
        for f <- lib_files(),
            code = code_of(f),
            re <- [
              ~r/\b(?:WHERE|AND|OR|ON)\s+(?:\w+\.)?(?:access_token|refresh_token)\s*(?:=|!=|<>|IN\b|LIKE\b)/,
              ~r/INSERT\s+INTO\s+matrix_sessions\s*\(\s*access_token\s*,/i,
              ~r/SELECT\s+(?:\w+\.)?(?:access_token|refresh_token)\b\s*(?:,|FROM|\n)/i,
              ~r/SET\s+(?:access_token|refresh_token)\s*=/i
            ],
            Regex.match?(re, code),
            do: {Path.relative_to(f, @lib), inspect(re)}

      assert offenders == [], "AC1/AC5: plaintext token SQL remains in server/lib: #{inspect(offenders)}"
    end

    test "no SQL in server/lib uses LIKE / ILIKE / ~ on the token hash columns (indexed equality only)" do
      offenders =
        for f <- lib_files(),
            Regex.match?(~r/(?:access|refresh)_token_hash\s*(?:NOT\s+)?(?:I?LIKE|~|SIMILAR)/i, code_of(f)),
            do: Path.relative_to(f, @lib)

      assert offenders == []
    end

    test "only the store module and the refresh worker's candidate query touch matrix_sessions" do
      offenders =
        for f <- lib_files(),
            rel = Path.relative_to(f, @lib),
            rel not in ["nebu/matrix/session/matrix_session_store.ex", "nebu/matrix/session/refresh_worker.ex"],
            Regex.match?(~r/\b(?:FROM|INTO|UPDATE|JOIN)\s+matrix_sessions\b/i, code_of(f)),
            do: rel

      assert offenders == [], "AC2: SQL on matrix_sessions outside the store/worker: #{inspect(offenders)}"
    end

    test "no module other than the store hashes tokens independently (single hashing seam)" do
      offenders =
        for f <- lib_files(),
            rel = Path.relative_to(f, @lib),
            rel != "nebu/matrix/session/matrix_session_store.ex",
            code = code_of(f),
            # only modules that deal with Matrix opaque sessions (PKCE/state hashing etc. is unrelated)
            String.contains?(code, "MatrixSessionStore") or String.contains?(code, "matrix_sessions"),
            Regex.match?(~r/:crypto\.hash\(\s*:sha256|sha256\(/, code),
            do: rel

      assert offenders == [], "AC2: token hashing computed outside Store.hash_token/1: #{inspect(offenders)}"
    end

    test "AC6: sibling locking stays deterministic (ORDER BY ... FOR UPDATE) and is now ordered by the hash" do
      code = code_of(Path.join(@lib, "nebu/matrix/session/matrix_session_store.ex"))

      refute code =~ ~r/ORDER\s+BY\s+access_token\b(?!_hash)/i, "AC6: lock order must be by access_token_hash"
      assert code =~ ~r/ORDER\s+BY\s+access_token_hash/i,
             "AC6: multi-row sibling locking is ordered by the hash"

      assert code =~ ~r/refresh_token_hash[\s\S]{0,300}FOR\s+UPDATE/i,
             "AC6: the replay re-check keeps its FOR UPDATE row lock, keyed by refresh_token_hash"
    end

    @hash_keyed ~r/\b(?:get_by_access_token_hash|extend_in_place_by_hash|delete_by_access_token_hash|old_access_token_hash)\b/

    test "F-3: hash-keyed store entry points are only used by RefreshWorker and HttpPublic (pass-the-hash guard)" do
      allowed = [
        "nebu/matrix/session/matrix_session_store.ex",
        "nebu/matrix/session/refresh_worker.ex",
        "nebu/matrix/http_public.ex"
      ]

      offenders =
        for f <- lib_files(),
            rel = Path.relative_to(f, @lib),
            rel not in allowed,
            Regex.match?(@hash_keyed, code_of(f)),
            do: rel

      assert offenders == [], "F-3: hash-keyed store API used outside RefreshWorker/HttpPublic: #{inspect(offenders)}"

      # D-2: pin the number of call sites in http_public.ex (exactly the DB-derived rotate param).
      http = code_of(Path.join(@lib, "nebu/matrix/http_public.ex"))

      assert length(Regex.scan(@hash_keyed, http)) == 1,
             "D-2: http_public.ex must contain exactly one hash-keyed call site (DB-derived only)"
    end

    test "F-3: the hash-keyed store functions are @doc false and carry the pass-the-hash warning" do
      src = File.read!(Path.join(@lib, "nebu/matrix/session/matrix_session_store.ex"))

      for fun <- ~w(get_by_access_token_hash extend_in_place_by_hash delete_by_access_token_hash) do
        assert src =~ ~r/@doc false\n(?:\s*#[^\n]*\n)*\s*@spec #{fun}\(/,
               "F-3: #{fun} must be @doc false (internal)"
      end

      assert src =~ ~r/pass-the-hash/i, "F-3: the store must document the pass-the-hash warning"
    end

    test "the store defines hash_token/1 as a public function and uses it for the SQL parameters" do
      code = code_of(Path.join(@lib, "nebu/matrix/session/matrix_session_store.ex"))
      assert code =~ ~r/\n\s*def hash_token\(/
    end
  end
end
