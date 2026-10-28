defmodule Nebu.OAuth.OAuthTokenRefreshGrantTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint` (story 3), the
  `grant_type=refresh_token` side of `POST /oauth2/token`: AC9 (rotation, Refresh-Retry, reuse,
  client binding, session expiry), AC10 (IdP re-validation `per_refresh` / `off` and the complete
  error mapping incl. every 5xx = `{}` + `Retry-After`, oracle C1), AC11 (scope narrowing over
  HTTP, C3/C12), AC12 (refresh id_token, T15/T16), T19, T28 (IdP refresh-token race guard), T33
  (`expires_in`), Must #14-#22, #26, #35 and the refresh-grant oracle extra tests.

  Sessions are created through the REAL story-2 flow (`T.session!/4`: authorize -> IdP stub ->
  shared callback -> code grant). The IdP refresh is stubbed with `:matrix_oidc_refresh_override`
  (`T.idp_refresh_ok/2`, `T.idp_refresh_error/1`, `T.stub_idp_refresh/1`).

  Red today: `/oauth2/token` is not routed (router plain 404), so `T.session!/4` already fails
  at the code grant; `matrix_sessions` has no `auth_api` / `client_id` / `scope` /
  `session_expires_at` / `oauth_code_hash` columns (migration 000042 missing) and the
  `Nebu.Matrix.oauth_*` facade does not exist.

  Cluster safety: rotation is atomic SQL (proven with N concurrent refreshes of the same refresh
  token: only 200/503, exactly one active row). Determinism: no sleeps; time passes only through
  SQL shifts of `matrix_sessions` timestamps; the rate-limit clock is frozen.
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
    secret = Application.get_env(:nebu_http, :admin_secret_at_rest)

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()

      for k <- [:oauth_repo, :oauth_session_repo, :oauth_user_active_override, :oauth_rotate_override, :oauth_token_test_hook],
          do: Application.delete_env(:nebu_http, k)

      if secret, do: Application.put_env(:nebu_http, :admin_secret_at_rest, secret)
    end)

    {:ok, priv: priv, secret: secret, cid: T.oauth_client!([@https, "http://localhost/cb"])}
  end

  # A live session (stable prefix, no openid) + an IdP stub that accepts every refresh.
  defp live(%{cid: cid, priv: priv}, opts \\ []) do
    s = T.session!(cid, @https, priv, opts)
    T.idp_refresh_ok(s.sub)
    s
  end

  # The exact matrix-js-sdk 41.3.0 shape (openid + unstable prefix + nonce + response_mode=query).
  defp js_live(ctx) do
    live(ctx,
      authorize: %{"scope" => T.js_sdk_scope(), "nonce" => "js-nonce-" <> T.rand(), "response_mode" => "query"}
    )
  end

  defp assert_soft_logout(conn) do
    assert conn.status == 401, "expected 401, got #{conn.status}: #{conn.resp_body}"
    body = T.json(conn)
    assert body["errcode"] == "M_UNKNOWN_TOKEN"
    assert body["soft_logout"] == true
  end

  defp assert_dead(conn) do
    assert conn.status == 401, "expected 401, got #{conn.status}: #{conn.resp_body}"
    assert T.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  defp floor_lifetime(at) do
    %{rows: [[n]]} =
      T.sql!(
        "SELECT floor(extract(epoch FROM expires_at - created_at))::bigint FROM matrix_sessions WHERE access_token_hash = $1",
        [T.token_hash(at)]
      )

    n
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 / T10 — rotation (Must #14, #18, #35)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9/T10 — rotation on every refresh (Must #14, #18, #35)" do
    test "new AT AND RT, old AT superseded at once (soft_logout), new AT authenticates", ctx do
      s = live(ctx)
      body = T.refresh(ctx.cid, s.rt) |> T.assert_token_success()

      refute body["access_token"] == s.at
      refute body["refresh_token"] == s.rt
      assert body["scope"] == s.body["scope"]
      assert_soft_logout(T.whoami(s.at))

      who = T.whoami(body["access_token"])
      assert who.status == 200
      assert T.json(who)["user_id"] == s.user_id
      assert T.json(who)["device_id"] == s.device_id
    end

    test "refresh_token is present in EVERY refresh response (C11), 3 consecutive rotations", ctx do
      s = live(ctx)

      Enum.reduce(1..3, s.rt, fn _, rt ->
        body = T.refresh(ctx.cid, rt) |> T.assert_token_success()
        assert is_binary(body["refresh_token"])
        refute body["refresh_token"] == rt
        body["refresh_token"]
      end)
    end

    test "session_expires_at copied verbatim (never grows), expires_at <= session_expires_at, columns copied", ctx do
      s = live(ctx)
      [first] = T.session_rows(s.user_id, s.device_id)

      Enum.reduce(1..3, s.rt, fn _, rt -> T.refresh!(ctx.cid, rt)["refresh_token"] end)

      rows = T.session_rows(s.user_id, s.device_id)
      assert length(rows) == 4
      assert [_active] = Enum.filter(rows, &is_nil(&1["revoked_at"])), "exactly one active row per device"

      for row <- rows do
        assert row["session_expires_at"] == first["session_expires_at"], "session_expires_at is copied VERBATIM (T3)"
        assert DateTime.compare(row["expires_at"], row["session_expires_at"]) != :gt, "expires_at <= session_expires_at"

        for col <- ~w(client_id scope oauth_code_hash auth_time auth_api),
            do: assert(row[col] == first[col], "#{col} must be copied on rotation (T10)")

        assert row["auth_api"] == "oauth"
        assert row["client_id"] == ctx.cid
      end
    end

    test "per_refresh: the IdP is called with the DECRYPTED stored IdP refresh token (T5)", ctx do
      s = live(ctx)
      T.refresh!(ctx.cid, s.rt)
      assert_received {:idp_refresh, rt}
      assert rt == s.idp_rt
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 / T10 / T11 — Refresh-Retry and reuse (Must #15, #16)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9/T10 — Refresh-Retry: old RT valid until the new tokens are used (Must #15, #16)" do
    test "replay of the pending old RT returns a fresh working pair, session not revoked, one active row", ctx do
      s = live(ctx)
      a = T.refresh!(ctx.cid, s.rt)
      b = T.refresh(ctx.cid, s.rt) |> T.assert_token_success()

      refute b["access_token"] == a["access_token"]
      assert [active] = T.active_rows(s.user_id, s.device_id)
      assert active["access_token_hash"] == T.token_hash(b["access_token"])
      assert T.whoami(b["access_token"]).status == 200
    end

    test "no time window: the pending old RT still works after a simulated 10-minute delay", ctx do
      s = live(ctx)
      a = T.refresh!(ctx.cid, s.rt)

      T.sql!(
        "UPDATE matrix_sessions SET created_at = created_at - interval '10 minutes', revoked_at = revoked_at - interval '10 minutes' " <>
          "WHERE user_id = $1 AND device_id = $2",
        [s.user_id, s.device_id]
      )

      b = T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      refute b["access_token"] == a["access_token"]
      assert T.whoami(b["access_token"]).status == 200
    end

    test "after the NEW AT authenticated a request, the old RT is reuse => invalid_grant, all device rows gone", ctx do
      s = live(ctx)
      a = T.refresh!(ctx.cid, s.rt)
      assert T.whoami(a["access_token"]).status == 200

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == [], "reuse revokes the whole session (T11)"
      assert_dead(T.whoami(a["access_token"]))
      T.refresh(ctx.cid, a["refresh_token"]) |> T.assert_token_error(400, "invalid_grant")
    end

    test "after the NEW RT was redeemed, the old RT is reuse => session revoked", ctx do
      s = live(ctx)
      a = T.refresh!(ctx.cid, s.rt)
      b = T.refresh!(ctx.cid, a["refresh_token"])

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
      assert_dead(T.whoami(b["access_token"]))
    end
  end

  describe "AC9/T11/T12 — reuse, unknown tokens, client binding, dead sessions (AC10 rows)" do
    test "a CONSUMED RT revokes the session even when presented with ANOTHER client's client_id; WARNING logged", ctx do
      s = live(ctx)
      a = T.refresh!(ctx.cid, s.rt)
      assert T.whoami(a["access_token"]).status == 200
      other = T.oauth_client!([@https])

      log = capture_log(fn -> T.refresh(other, s.rt) |> T.assert_token_error(400, "invalid_grant") end)

      assert T.session_rows(s.user_id, s.device_id) == [], "T11: independent of the presented client_id"
      assert log =~ "[warning]", "reuse revocation logs a WARNING (T29)"
      refute log =~ s.rt
      refute log =~ a["access_token"]
    end

    test "an unknown 64-hex refresh token => invalid_grant without side effects", ctx do
      s = live(ctx)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      unknown = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      T.refresh(ctx.cid, unknown) |> T.assert_token_error(400, "invalid_grant")
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
    end

    test "a value that is not 64 lowercase hex => invalid_grant WITHOUT DB access", ctx do
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      for bad <- [String.duplicate("g", 64), String.duplicate("a", 63), String.duplicate("A", 64), String.duplicate("a", 65)] do
        T.refresh(ctx.cid, bad) |> T.assert_token_error(400, "invalid_grant")
      end
    end

    test "an ACCESS token presented as refresh_token => invalid_grant, session untouched (extra oracle test)", ctx do
      s = live(ctx)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      T.refresh(ctx.cid, s.at) |> T.assert_token_error(400, "invalid_grant")
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      assert T.whoami(s.at).status == 200
    end

    test "a LEGACY refresh token => invalid_grant, the legacy row is untouched (T27, Must #28)", ctx do
      uid = T.provision_user!()
      legacy = T.legacy_session!(uid, "LEGACYDEV1")
      before = T.row_by_rt(legacy.rt)

      T.refresh(ctx.cid, legacy.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.row_by_rt(legacy.rt) == before
      assert T.whoami(legacy.at).status == 200
    end

    test "refresh after POST /logout => invalid_grant", ctx do
      s = live(ctx)
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", s.at, body: %{}).status == 200
      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    # story 5 (oauth-legacy-coexistence, C7 / Trap 6): changed deliberately. Story 3 let the OAuth
    # session delete its OWN device via DELETE /devices (fresh-auth window) and then asserted
    # invalid_grant. From story 5 on an OAuth caller is refused with 403 M_FORBIDDEN before any
    # lookup (UIA is not compatible with the OAuth API; device deletion is the account page, story 6),
    # so nothing is deleted and the refresh token keeps working. Deletion of an OAuth device by a
    # LEGACY session of the same user lives in story 4's oauth_logout_test.exs (AC10).
    test "DELETE /devices/{id} by the OAuth session itself => 403, nothing deleted, refresh still works", ctx do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      s = live(ctx, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "DEL" <> String.upcase(T.rand(4)))})
      before = T.rows_snapshot(s.user_id, s.device_id)
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> s.device_id, s.at, body: %{})
      assert conn.status == 403, "DELETE /devices by an OAuth caller: #{conn.status} #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert T.rows_snapshot(s.user_id, s.device_id) == before
      T.idp_refresh_ok(s.sub)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "client mismatch (another APPROVED client) => invalid_grant, NO revocation (T12)", ctx do
      s = live(ctx)
      other = T.oauth_client!([@https])
      snap = T.rows_snapshot(s.user_id, s.device_id)

      T.refresh(other, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "session_expires_at in the past => invalid_grant (Must #18)", ctx do
      s = live(ctx)

      T.sql!(
        "UPDATE matrix_sessions SET session_expires_at = now() - interval '1 second', expires_at = LEAST(expires_at, now() - interval '1 second') " <>
          "WHERE user_id = $1 AND device_id = $2",
        [s.user_id, s.device_id]
      )

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    test "reuse of a CONSUMED refresh token of an EXPIRED session => invalid_grant, no revocation, rows unchanged (T11)", ctx do
      s = live(ctx)
      new = T.refresh!(ctx.cid, s.rt)
      # the new AT authenticates a request => the old RT is CONSUMED
      assert T.whoami(new["access_token"]).status == 200

      T.sql!(
        "UPDATE matrix_sessions SET session_expires_at = now() - interval '1 second', expires_at = LEAST(expires_at, now() - interval '1 second') " <>
          "WHERE user_id = $1 AND device_id = $2",
        [s.user_id, s.device_id]
      )

      snap = T.rows_snapshot(s.user_id, s.device_id)
      assert length(snap) == 2
      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.rows_snapshot(s.user_id, s.device_id) == snap, "a dead session is not 'revoked' again: rows unchanged"
    end

    test "a refresh is allowed although the ACCESS token expired (T3: only session_expires_at bounds it)", ctx do
      s = live(ctx)

      T.sql!(
        "UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE user_id = $1 AND device_id = $2",
        [s.user_id, s.device_id]
      )

      assert_soft_logout(T.whoami(s.at))
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "an extra `Authorization: Bearer <at>` header on a refresh is ignored (T24)", ctx do
      s = live(ctx)
      T.refresh(ctx.cid, s.rt, %{}, headers: [{"authorization", "Bearer " <> s.at}]) |> T.assert_token_success()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 / T13 — scope on refresh (Must #20, C3, C12)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11/T13 — scope on refresh (Must #20, C3, C12)" do
    test "absent scope => the granted scope unchanged", ctx do
      s = live(ctx)
      assert T.refresh!(ctx.cid, s.rt)["scope"] == T.matrix_scope()
    end

    test "empty `scope=` is omitted (RFC 6749 3.1) => 200 with the granted scope", ctx do
      s = live(ctx)
      assert T.refresh!(ctx.cid, s.rt, %{"scope" => ""})["scope"] == T.matrix_scope()
    end

    test "equal scope => 200", ctx do
      s = live(ctx)
      assert T.refresh!(ctx.cid, s.rt, %{"scope" => T.matrix_scope()})["scope"] == T.matrix_scope()
    end

    test "other order => 200, the echo keeps the STORED order", ctx do
      s = live(ctx)
      reordered = "urn:matrix:client:device:AbCdEfGhIj urn:matrix:client:api:*"
      assert T.refresh!(ctx.cid, s.rt, %{"scope" => reordered})["scope"] == T.matrix_scope()
    end

    test "the other prefix for the same tokens => 200, the echo keeps the STORED prefix", ctx do
      s = live(ctx)
      other = T.matrix_scope(T.unstable_prefix())
      assert T.refresh!(ctx.cid, s.rt, %{"scope" => other})["scope"] == T.matrix_scope()
    end

    test "a duplicate token is collapsed (set semantics) => 200", ctx do
      s = live(ctx)
      dup = T.matrix_scope() <> " urn:matrix:client:api:*"
      assert T.refresh!(ctx.cid, s.rt, %{"scope" => dup})["scope"] == T.matrix_scope()
    end

    test "dropping openid => 200 without openid and without id_token; persistent, cannot be widened back", ctx do
      s = js_live(ctx)
      narrowed = T.matrix_scope(T.unstable_prefix())

      conn = T.refresh(ctx.cid, s.rt, %{"scope" => narrowed})
      body = T.assert_token_success(conn, id_token: false)
      assert body["scope"] == narrowed

      body2 = T.refresh(ctx.cid, body["refresh_token"]) |> T.assert_token_success(id_token: false)
      assert body2["scope"] == narrowed, "a narrowed scope is persistent (stored on the new row)"

      snap = T.rows_snapshot(s.user_id, s.device_id)
      T.refresh(ctx.cid, body2["refresh_token"], %{"scope" => T.js_sdk_scope()}) |> T.assert_token_error(400, "invalid_scope")
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
    end

    for {label, scope} <- [
          {"an extra token (openid on a no-openid session)", "openid urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj"},
          {"an extra unknown token", "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj email"},
          {"a missing device token", "urn:matrix:client:api:*"},
          {"another device id", "urn:matrix:client:api:* urn:matrix:client:device:ZZZZZZZZZZ"},
          {"a missing api:* token", "urn:matrix:client:device:AbCdEfGhIj"},
          {"a non-ASCII token", "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj é"}
        ] do
      test "#{label} => invalid_scope, session untouched, the same RT still works", ctx do
        s = live(ctx)
        snap = T.rows_snapshot(s.user_id, s.device_id)

        T.refresh(ctx.cid, s.rt, %{"scope" => unquote(scope)}) |> T.assert_token_error(400, "invalid_scope")
        assert T.rows_snapshot(s.user_id, s.device_id) == snap
        T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 / T15 / T16 — id_token on refresh (Must #26)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12/T15/T16 — id_token on refresh (Must #26)" do
    test "js-sdk session: refreshed id_token verifies (ES256, JWKS kid), no nonce, same iss/sub/aud/auth_time, new iat", ctx do
      s = js_live(ctx)
      {_h1, first} = T.verify_id_token!(s.body["id_token"])

      body = T.refresh(ctx.cid, s.rt) |> T.assert_token_success(id_token: true)
      assert body["scope"] == T.js_sdk_scope(), "the REQUEST's unstable prefix + openid are echoed"
      {header, claims} = T.verify_id_token!(body["id_token"])

      assert header["alg"] == "ES256"
      assert is_binary(header["kid"])
      refute Map.has_key?(claims, "nonce"), "OIDC Core 12.2: a refreshed id_token carries no nonce"

      for c <- ~w(iss sub aud auth_time), do: assert(claims[c] == first[c], "#{c} must be identical to the first id_token")

      assert claims["iss"] == T.issuer()
      assert claims["sub"] == s.user_id
      assert claims["aud"] == ctx.cid
      assert claims["iat"] >= first["iat"]
      assert claims["exp"] - claims["iat"] == 300
    end

    test "Dart/stable session without openid => no id_token on refresh", ctx do
      s = live(ctx)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success(id_token: false)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 / T5 — IdP re-validation per_refresh (Must #21)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10/T5 — per_refresh, TRANSIENT IdP failures => 503 {} + Retry-After, session intact (Must #21)" do
    # Retry-After pinned where RefreshErrors.retry_after_seconds/1 is specific (IdP 429 => 30 s).
    @pinned_retry %{"IdP 429" => "30"}

    for {label, reason} <- [
          {"IdP 503", {:token_endpoint_status, 503}},
          {"IdP 429", {:token_endpoint_status, 429}},
          {"IdP unreachable", {:token_endpoint_unreachable, :timeout}},
          {"discovery failure", {:discovery_failed, :x}}
        ] do
      test "#{label} => 503 {}, rows unchanged, the SAME RT succeeds afterwards", ctx do
        s = live(ctx)
        snap = T.rows_snapshot(s.user_id, s.device_id)
        T.idp_refresh_error(unquote(Macro.escape(reason)))

        conn = T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
        case Map.get(@pinned_retry, unquote(label)) do
          nil -> :ok
          expected -> assert T.header(conn, "retry-after") == expected
        end
        assert T.rows_snapshot(s.user_id, s.device_id) == snap

        T.idp_refresh_ok(s.sub)
        T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      end
    end

    test "DB hiccup re-checking is_active (FailingValidator => transient_check_failed) => 503 {}", ctx do
      s = live(ctx)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      T.put_env_scoped(:validator_module, T.FailingValidator, :session_manager)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      assert T.rows_snapshot(s.user_id, s.device_id) == snap

      Application.delete_env(:session_manager, :validator_module)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end
  end

  describe "AC10/T5 — per_refresh, CONFIRMED rejections => invalid_grant + session revoked (Must #21)" do
    for {label, reason} <- [
          {"IdP 400", {:token_endpoint_status, 400}},
          {"IdP 401", {:token_endpoint_status, 401}},
          {"IdP 403", {:token_endpoint_status, 403}},
          {"IdP invalid_grant", :invalid_grant}
        ] do
      test "#{label} => 400 invalid_grant, every OAuth row of the device deleted", ctx do
        s = live(ctx)
        T.idp_refresh_error(unquote(Macro.escape(reason)))

        T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
        assert T.session_rows(s.user_id, s.device_id) == []
        assert_dead(T.whoami(s.at))
      end
    end

    test "deactivated user (DeactivatedValidator => :deactivated) => invalid_grant + revoked", ctx do
      s = live(ctx)
      T.put_env_scoped(:validator_module, T.DeactivatedValidator, :session_manager)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "decrypt failure of the stored IdP RT => invalid_grant + revoked", ctx do
      s = live(ctx)

      T.sql!(
        "UPDATE matrix_sessions SET oidc_refresh_token = $3 WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
        [s.user_id, s.device_id, String.duplicate("ab", 40)]
      )

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end
  end

  describe "AC10/T5 — provider-rotated IdP refresh token (Must #21)" do
    test "stored ENCRYPTED on the new row; the next refresh presents the rotated value", ctx do
      s = live(ctx)
      rotated = "idp-rt-rotated-" <> T.rand(10)
      T.idp_refresh_ok(s.sub, rotated)

      body = T.refresh!(ctx.cid, s.rt)
      assert_received {:idp_refresh, first}
      assert first == s.idp_rt

      row = T.row_by_at(body["access_token"])
      refute row["oidc_refresh_token"] == rotated, "never plaintext at rest"
      refute String.contains?(row["oidc_refresh_token"] || "", rotated)
      assert {:ok, ^rotated} = Nebu.Web.SecretBox.decrypt(row["oidc_refresh_token"])

      T.idp_refresh_ok(s.sub)
      T.refresh!(ctx.cid, body["refresh_token"])
      assert_received {:idp_refresh, second}
      assert second == rotated
    end
  end

  # story oauth-authorize-freshness (FR15, AC12.4): a refresh now holds a per-device IdP refresh LEASE
  # while it is inside the IdP call, so a refresh nested into the IdP stub would be answered 503 by the
  # lease (that serialization is proven in oauth_refresh_lease_test.exs). The T28 rules (an IdP 400 is
  # not final when a concurrent refresh really redeemed and rotated the IdP RT) remain for an EXPIRED
  # lease: the stub below expires the lease first, exactly what a holder that stalled past its TTL
  # leaves behind, and the nested refresh then claims it.
  describe "AC10/T28 — IdP refresh-token race guard (an expired lease lets the concurrent winner in)" do
    test "a concurrent refresh that won (rotated IdP RT) turns the loser's IdP 400 into a replay, no second IdP call", ctx do
      s = live(ctx)
      counter = :counters.new(1, [])
      pid = self()
      cid = ctx.cid
      sub = s.sub

      T.stub_idp_refresh(fn _rt ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            # The loser's IdP round trip: its lease expired meanwhile, a concurrent refresh of the SAME RT claims it and wins.
            :ok = T.expire_lease!(s.user_id, s.device_id)
            nested = Task.async(fn -> T.refresh(cid, s.rt) end) |> Task.await(30_000)
            send(pid, {:nested_status, nested.status})
            {:error, {:token_endpoint_status, 400}}

          _ ->
            {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, "idp-rt-race-winner-" <> T.rand(6)}
        end
      end)

      body = T.refresh(cid, s.rt) |> T.assert_token_success()
      assert_received {:nested_status, 200}
      assert :counters.get(counter, 1) == 2, "the loser is served as a replay WITHOUT a second IdP call"

      assert [active] = T.active_rows(s.user_id, s.device_id)
      assert active["access_token_hash"] == T.token_hash(body["access_token"])
      assert T.whoami(body["access_token"]).status == 200
      T.refresh(cid, body["refresh_token"]) |> T.assert_token_success()
    end
  end

  describe "AC10/T28 — review cycle 1 (Kassandra F-1, MINOR 4): the race guard cannot be used to bypass re-validation" do
    # Runs `winner` (a nested refresh of the SAME RT, i.e. the "concurrent winner") during the loser's
    # IdP call, then answers the loser's call with `loser_reply`. The loser's lease is expired first
    # (story oauth-authorize-freshness FR15): a LIVE lease would make the nested refresh wait / get 503.
    defp racing_idp(ctx, s, winner_reply, loser_reply) do
      counter = :counters.new(1, [])
      pid = self()
      cid = ctx.cid

      T.stub_idp_refresh(fn _rt ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            :ok = T.expire_lease!(s.user_id, s.device_id)
            nested = Task.async(fn -> T.refresh(cid, s.rt) end) |> Task.await(30_000)
            send(pid, {:nested_status, nested.status})
            loser_reply

          _ ->
            winner_reply
        end
      end)

      counter
    end

    test "a concurrent winner that did NOT rotate the IdP RT does not excuse the loser's IdP 400: final, session revoked", ctx do
      s = live(ctx)
      sub = s.sub
      ok = {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, nil}
      counter = racing_idp(ctx, s, ok, {:error, {:token_endpoint_status, 400}})

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert_received {:nested_status, 200}
      assert :counters.get(counter, 1) == 2
      assert T.session_rows(s.user_id, s.device_id) == [], "a new access-token hash alone proves no valid re-validation: revoked"
    end

    test "both IdP calls answer 400 (the concurrent winner is itself rejected): both invalid_grant, session revoked, never a 200", ctx do
      s = live(ctx)
      counter = racing_idp(ctx, s, {:error, {:token_endpoint_status, 400}}, {:error, {:token_endpoint_status, 400}})

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert_received {:nested_status, 400}
      assert :counters.get(counter, 1) == 2
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "a Nebu-side verdict (IdP 403) is never excused by a concurrent winner that rotated the IdP RT: revoked", ctx do
      s = live(ctx)
      sub = s.sub
      rotated = {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, "idp-rt-race-" <> T.rand(6)}
      _counter = racing_idp(ctx, s, rotated, {:error, {:token_endpoint_status, 403}})

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert_received {:nested_status, 200}
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "a deactivated user (:deactivated) is never excused either", ctx do
      s = live(ctx)
      sub = s.sub
      rotated = {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, "idp-rt-race-" <> T.rand(6)}
      _counter = racing_idp(ctx, s, rotated, {:error, :deactivated})

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end
  end

  describe "T11 — review cycle 1 (MINOR 3): a failing revocation is never answered with a definitive invalid_grant" do
    test "refresh-token reuse + revocation DB error => 503 {} + Retry-After and the session survives; the retry revokes", ctx do
      s = live(ctx)
      fresh = T.refresh!(ctx.cid, s.rt)
      assert T.whoami(fresh["access_token"]).status == 200, "the new AT consumes the old RT"

      remove = T.block_session_deletes!(s.user_id)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      log = capture_log(fn -> send(self(), {:resp, T.refresh(ctx.cid, s.rt)}) end)
      assert_received {:resp, conn}

      T.assert_token_5xx(conn)
      assert T.rows_snapshot(s.user_id, s.device_id) == snap, "the session survives while the revocation failed"
      assert log =~ "[warning]"
      refute log =~ s.rt

      remove.()
      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 / T5 / T19 — off mode (Must #22)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10/T19 — oauth_idp_revalidation = off (Must #22)" do
    setup do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "off"})
      :ok
    end

    test "no IdP call at all => 200", ctx do
      s = T.session!(ctx.cid, @https, ctx.priv)
      pid = self()

      T.stub_idp_refresh(fn rt ->
        send(pid, {:idp_refresh, rt})
        {:error, {:token_endpoint_status, 400}}
      end)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      refute_received {:idp_refresh, _}
    end

    test "deactivated user (users.is_active = false) => invalid_grant + revoked", ctx do
      s = T.session!(ctx.cid, @https, ctx.priv)
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [s.user_id])

      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "DB error on the error-aware is_active read => 503 {}, session intact", ctx do
      s = T.session!(ctx.cid, @https, ctx.priv)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      T.put_env_scoped(:oauth_user_active_override, fn _uid -> {:error, :db} end)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      assert T.rows_snapshot(s.user_id, s.device_id) == snap

      Application.delete_env(:nebu_http, :oauth_user_active_override)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 / T20 / T21 / T22 — every other 5xx is {} + Retry-After (C1), retry works
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10/T20 — 5xx bodies of the refresh grant are exactly {} + Retry-After; the same RT works afterwards" do
    test "DB unavailable (oauth_session_repo NoSuchRepo) => 503 {}", ctx do
      s = live(ctx)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()

      Application.delete_env(:nebu_http, :oauth_session_repo)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "rotation race exhausted (oauth_rotate_override always :error) => 503 {}, session intact", ctx do
      s = live(ctx)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      T.put_env_scoped(:oauth_rotate_override, fn _params -> :error end)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      assert T.whoami(s.at).status == 200

      Application.delete_env(:nebu_http, :oauth_rotate_override)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "a crash inside the rotation (oauth_rotate_override raises) => 503 {}, session intact", ctx do
      s = live(ctx)
      snap = T.rows_snapshot(s.user_id, s.device_id)
      T.put_env_scoped(:oauth_rotate_override, fn _params -> raise ArgumentError, "atdd rotate crash" end)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      assert T.rows_snapshot(s.user_id, s.device_id) == snap

      Application.delete_env(:nebu_http, :oauth_rotate_override)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "signing key unavailable on an openid session => 503 {}, session intact", %{secret: secret} = ctx do
      s = js_live(ctx)
      # `off` mode: no IdP RT decrypt, so the ONLY SecretBox use left is the key generation.
      T.enable_oauth(T.issuer(), %{idp_revalidation: "off"})
      snap = T.rows_snapshot(s.user_id, s.device_id)
      # Empty table => ensure_active_key/0 must generate (SecretBox.encrypt raises without a secret);
      # a per-node cache of decoded key material can therefore not mask the failure.
      T.reset_signing_keys!()
      Application.delete_env(:nebu_http, :admin_secret_at_rest)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      Application.put_env(:nebu_http, :admin_secret_at_rest, secret)
      assert T.rows_snapshot(s.user_id, s.device_id) == snap

      T.refresh(ctx.cid, s.rt) |> T.assert_token_success(id_token: true)
    end

    test "unreadable config (:unknown) => 503 {} + Retry-After: 5 (T22), never 404", ctx do
      s = live(ctx)
      T.unreadable_oauth_config()
      conn = T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      assert T.header(conn, "retry-after") == "5"

      T.enable_oauth()
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end

    test "drained refresh bucket => 503 {} + Retry-After, NEVER 429 (T21, Must #24)", ctx do
      s = live(ctx)
      ip = T.unique_ip()
      T.drain!("oauth_token_refresh", ip, 100, 1200)

      conn = T.refresh(ctx.cid, s.rt, %{}, ip: ip)
      refute conn.status == 429, "a refresh is never answered 429 (spec 6: 429 logs clients out)"
      T.assert_token_5xx(conn)

      T.refresh(ctx.cid, s.rt, %{}, ip: T.unique_ip()) |> T.assert_token_success()
    end

    test "an unexpected exception in the handler => rescued 500 {} + Retry-After", ctx do
      s = live(ctx)
      T.inject_token_handler_fault!()
      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx(500)

      Application.delete_env(:nebu_http, :oauth_token_test_hook)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Concurrency (Must #17)
  # ════════════════════════════════════════════════════════════════════════════

  describe "T10 — concurrent refreshes with the same current RT (Must #17, cluster-safe rotation)" do
    test "N=8 parallel refreshes => only 200/503, exactly one active row, session alive", ctx do
      s = live(ctx)
      cid = ctx.cid

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> T.refresh(cid, s.rt) end) end)
        |> Task.await_many(60_000)

      statuses = Enum.map(results, & &1.status)
      assert Enum.all?(statuses, &(&1 in [200, 503])), "only 200/503, never 400/500: #{inspect(statuses)}"
      assert 200 in statuses

      assert [active] = T.active_rows(s.user_id, s.device_id), "exactly one active row afterwards"

      winner =
        results
        |> Enum.filter(&(&1.status == 200))
        |> Enum.map(&T.json/1)
        |> Enum.find(&(T.token_hash(&1["access_token"]) == active["access_token_hash"]))

      assert winner, "the active row belongs to one of the 200 responses"
      assert T.whoami(winner["access_token"]).status == 200
      T.refresh(cid, winner["refresh_token"]) |> T.assert_token_success()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T33 — expires_in (Must #35)
  # ════════════════════════════════════════════════════════════════════════════

  describe "T33 — expires_in consistent with the stored expires_at (Must #35, C13)" do
    test "expires_in == floor(expires_at - created_at) of the new row (+/- 1 s)", ctx do
      s = live(ctx)
      body = T.refresh!(ctx.cid, s.rt)
      n = floor_lifetime(body["access_token"])
      assert body["expires_in"] <= n
      assert body["expires_in"] >= n - 1
      assert T.whoami(body["access_token"]).status == 200
    end

    test "near the session end expires_in is the remaining session time; no early 401", ctx do
      s = live(ctx)

      T.sql!(
        "UPDATE matrix_sessions SET session_expires_at = now() + interval '100 seconds', " <>
          "expires_at = LEAST(expires_at, now() + interval '100 seconds') WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
        [s.user_id, s.device_id]
      )

      body = T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      assert body["expires_in"] <= 100

      row = T.row_by_at(body["access_token"])
      assert DateTime.compare(row["expires_at"], row["session_expires_at"]) != :gt
      assert T.whoami(body["access_token"]).status == 200
    end
  end
end
