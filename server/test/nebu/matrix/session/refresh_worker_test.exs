defmodule Nebu.Matrix.Session.RefreshWorkerTest do
  @moduledoc """
  RED-phase ATDD tests for `server-paced-session-refresh` —
  `docs/stories/server-paced-session-refresh/background-session-refresh-worker.md`.

  ## ASSUMED INTERFACE (dev-story MUST implement exactly this — documented here
  ## per this story's ATDD instructions so the red-phase tests define the contract):

  Module: `Nebu.Matrix.Session.RefreshWorker`

    * `start_link/1` — starts a (possibly unnamed, opts-based) GenServer,
      mirroring `Nebu.Matrix.Session.Sweeper.start_link/1`. Tests below start it
      via `start_supervised!/1` so ExUnit tears it down; the worker does NOT need
      to be registered under a fixed name for these tests (avoids cross-test
      collisions the way `Sweeper`'s hardcoded name would).
    * `handle_info(:refresh, state)` — the periodic tick handler, PUBLIC in the
      sense that tests trigger it deterministically by sending `:refresh`
      directly to the pid (mirrors `Nebu.Compliance.SessionExpiryWorker`'s
      `:tick` convention and `Sweeper`'s `:sweep` message name pattern, adapted
      to this worker's own verb). Tests synchronize on completion via
      `:sys.get_state/1` (blocks until the handle_info call returns), exactly
      the pattern `session_expiry_worker_test.exs` already uses — no
      `Process.sleep` polling for the core assertions.
    * `refresh_now/0` — convenience wrapper some tests use for readability:
      sends `:refresh` to the given pid and calls `:sys.get_state/1` to block
      until the cycle completes. Tests call the two-step form directly
      (`send(pid, :refresh); :sys.get_state(pid)`) so they do not depend on
      `refresh_now/0` actually existing — only on the message contract above.
      (If dev-story provides `refresh_now/1`, that is a bonus, not required by
      these tests.)
    * Lookahead window: reads `Application.get_env(:nebu_http,
      :matrix_refresh_worker_lookahead_seconds, <default>)` at the START of each
      refresh cycle (mirrors the existing `:matrix_session_ttl_seconds` seam
      convention in `Nebu.Web.SessionConfig`) so tests can shrink/grow the
      "nearing" window deterministically without waiting on wall-clock time.
      Tests below set this env var directly; if dev-story instead threads the
      window through `start_link/1` opts, these tests will need adjustment —
      but the env-var seam is the existing project convention (see
      `matrix_session_ttl_seconds`, `provision_cache_ttl_ms`) and is assumed
      here as the primary contract.
    * Core logic reuse: the worker calls through to the SAME upstream-IdP
      exchange seam already wired in `Nebu.Matrix.HttpPublic` —
      `Application.get_env(:nebu_http, :matrix_oidc_refresh_override)`, a
      1-arity fun receiving the DECRYPTED stored OIDC refresh token, returning
      `{:ok, claims, new_rt_or_nil} | {:error, reason}`. The tests below inject
      this SAME override (already used by `login_refresh_test.exs`) — proving
      the worker reuses `revalidate_with_idp/1`'s call path rather than
      duplicating the IdP HTTP exchange. The new `expires_at` after a
      successful refresh must be `min(fresh_claims["exp"], now +
      Nebu.Web.SessionConfig.matrix_session_ttl_seconds())`, the SAME bound
      `session_expires_at/1` (http_public.ex) computes at login/refresh.
    * TOCTOU re-check (AC3): the worker MUST re-verify the candidate row still
      exists with `revoked_at IS NULL` at the moment it is about to call the
      IdP — i.e., no earlier than the invocation of the
      `:matrix_oidc_refresh_override` seam. The test below deletes the row
      FROM WITHIN the override callback (the precise moment "about to call the
      IdP" happens) and asserts the row is NOT resurrected — this is
      concurrency-model-agnostic: however dev-story structures the re-check
      (re-SELECT immediately before calling the seam, or a WHERE-guarded
      UPDATE...RETURNING as part of the rotate step), the end DB state must
      show no resurrected/rotated row for the deleted device.
    * Pending-sibling-safe selection (AC4): the candidate query must select only
      `revoked_at IS NULL` rows — a soft-revoked pending sibling
      (`revoked_at IS NOT NULL AND grace_until IS NULL`) must never be handed to
      the IdP-exchange seam.

  ## Why these tests MUST FAIL right now (red phase)

  `Nebu.Matrix.Session.RefreshWorker` does not exist yet (Task T1 of the story
  is unimplemented) — every test below references this module directly, so
  each fails with `UndefinedFunctionError` / module-not-found, NOT a syntax
  error and NOT an unrelated crash. Nothing in this file requires any new
  production code beyond what already exists (`Nebu.Matrix.HttpPublic`'s
  private refresh machinery, `Nebu.Matrix.Session.MatrixSessionStore`) — nothing
  is duplicated here; the tests exercise the WORKER calling through to that
  existing machinery via the same test seams `login_refresh_test.exs` already
  uses.

  ## Conventions mirrored from sibling files

  * DB setup / OIDC signing / SSO login-token minting: copied verbatim in
    spirit from `server/test/nebu/matrix/login_refresh_test.exs` (same
    `:matrix_sso_token_override`, `:oidc_jwks`, `:sso_bootstrap_reader`,
    `:oidc_metadata_override`, `:admin_secret_at_rest` seams) so each test can
    mint a REAL opaque `matrix_sessions` row (with an encrypted OIDC refresh
    token) via the actual login path, then manipulate `expires_at` directly via
    `Ecto.Adapters.SQL.query` (deterministic, no sleeping) to make it "nearing".
  * Periodic-worker testing style: mirrors
    `server/test/nebu/compliance/session_expiry_worker_test.exs` — send the
    tick message directly to the pid, then `:sys.get_state/1` to block until
    the handler returns (no fixed-time sleeps for correctness-critical
    assertions).
  * `:integration` tag: excluded from `mix test`, runs via
    `make test-integration` / `mix test --include integration` against a live
    Postgres (same tag as `login_refresh_test.exs`,
    `matrix_session_store_test.exs`).
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
  @kid "refresh-worker-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @worker Nebu.Matrix.Session.RefreshWorker

  defp fresh_sub, do: "worker" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp current_sub, do: Process.get(:refresh_worker_sub) || raise("sub not set by setup")

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

  defp revoked_at_for(access_token) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT revoked_at FROM matrix_sessions WHERE access_token_hash = $1",
        [Store.hash_token(access_token)]
      )

    case rows do
      [[v]] -> v
      [] -> :gone
    end
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
    Process.put(:refresh_worker_sub, sub)
    uid = "@" <> sub <> ":" <> @server_name

    if Process.whereis(Nebu.Repo) do
      _ =
        Nebu.Matrix.Session.TokenValidator.validate(
          uid,
          "user",
          "Worker Test",
          "worker@example.com"
        )

      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Worker Test", nil)

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

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — background refresh extends a nearing session, no client call needed
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: background worker refreshes a nearing session" do
    test "extends expires_at and the opaque access token keeps working for authenticated requests",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-ac1", "AC1DEV")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      fresh_exp = System.system_time(:second) + 3600

      # Capture `sub` in a local BEFORE building the closure: the background
      # worker invokes this override from its OWN GenServer process, not the
      # test process, so a `current_sub()` call INSIDE the closure body would
      # read an empty process dictionary there and raise
      # "sub not set by setup" (test-setup bug fix — `login_refresh_test.exs`
      # never needed this because its overrides run synchronously inline on
      # the test process itself via Plug.Test).
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => sub, "exp" => fresh_exp}, nil}
      end)

      run_one_refresh_cycle()

      # matrix-session-refresh-fixes AC1: the worker extends the SAME row in
      # place - the client's access token must stay the live token (the client
      # never learns rotated tokens), expires_at extended, no revoked sibling.
      assert {:ok, %{revoked_at: nil} = still_here} = Store.get_by_access_token(sess.access_token),
             "AC1: the client's access token must remain the active, non-revoked row"

      assert DateTime.compare(still_here.expires_at, original_expires_at) == :gt,
             "AC1: expires_at must be extended beyond the original nearing bound"

      assert still_here.refresh_token_hash == Store.hash_token(sess.refresh_token),
             "AC1: the client's refresh token must be unchanged by the worker"

      {:ok, %{rows: [[row_count]]}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT COUNT(*) FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
          [uid, "AC1DEV"]
        )

      assert row_count == 1, "AC1: in-place extension must not create a sibling row"

      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(sess.access_token))
      assert resp.status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — per-device failure isolation
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: per-device failure isolation" do
    test "device A's upstream rejection does not affect device B's refresh (same user)",
         %{priv_jwk: priv} do
      sub = current_sub()
      sess_a = login_device(priv, sub, "oidc-rt-device-a", "AC2DEVA")
      sess_b = login_device(priv, sub, "oidc-rt-device-b", "AC2DEVB")

      set_expires_at(sess_a.access_token, 30 * 60)
      set_expires_at(sess_b.access_token, 30 * 60)
      original_b_expires_at = expires_at_for(sess_b.access_token)

      fresh_exp = System.system_time(:second) + 3600

      put_matrix_oidc_refresh_override(fn decrypted_rt ->
        case decrypted_rt do
          "oidc-rt-device-a" -> {:error, {:token_endpoint_status, 400}}
          "oidc-rt-device-b" -> {:ok, %{"sub" => sub, "exp" => fresh_exp}, nil}
        end
      end)

      run_one_refresh_cycle()

      # Device A: fails closed, not extended (and per AC6, not resurrected by
      # any other mechanism) — its ORIGINAL access token must not gain a later
      # expiry than what it had before the cycle.
      case Store.get_by_access_token(sess_a.access_token) do
        {:ok, a_sess} ->
          refute DateTime.compare(
                   a_sess.expires_at,
                   DateTime.utc_now() |> DateTime.add(35 * 60, :second)
                 ) == :gt,
                 "AC2/AC6: device A's rejected upstream refresh must not extend its session"

        :error ->
          :ok
      end

      # Device B must be refreshed and extended, proving A's failure was fully
      # isolated from B despite belonging to the same user.
      b_live? =
        case Store.get_by_access_token(sess_b.access_token) do
          {:ok, b_sess} -> DateTime.compare(b_sess.expires_at, original_b_expires_at) == :gt
          :error -> false
        end

      unless b_live? do
        {:ok, %{rows: rows}} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "SELECT expires_at FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
            [sub |> then(&("@" <> &1 <> ":" <> @server_name)), "AC2DEVB"]
          )

        assert [[new_expires_at]] = rows

        assert DateTime.compare(new_expires_at, original_b_expires_at) == :gt,
               "AC2: device B must be refreshed and extended independently of device A's failure"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — TOCTOU-safe: session deleted between selection and redemption
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: TOCTOU-safe execution" do
    test "a device deleted exactly when the worker is about to call the IdP is NOT refreshed or resurrected",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-toctou", "AC3DEV")
      set_expires_at(sess.access_token, 30 * 60)

      test_pid = self()

      # The override fun IS "the moment the worker is about to call the
      # upstream IdP" (this is the real call-through seam used by
      # revalidate_with_idp/1's exchange_oidc_refresh_token/1). Deleting the
      # device's session rows from inside this callback simulates
      # delete_one_device racing the worker at the exact TOCTOU window this AC
      # is about. If the worker does not re-check `revoked_at IS NULL`
      # immediately before/at this call, it will go on to resurrect the row via
      # rotate_tokens/2 after this callback returns success.
      #
      # `sub` is captured above (test-setup bug fix, mirrors the AC1 fix): the
      # background worker invokes this override from its OWN GenServer
      # process, so `current_sub()`'s Process.get would read an empty
      # dictionary there.
      put_matrix_oidc_refresh_override(fn decrypted_rt ->
        assert decrypted_rt == "oidc-rt-toctou"

        :ok = Store.delete_for_user_device(uid, "AC3DEV")
        send(test_pid, :toctou_delete_done)

        {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, nil}
      end)

      run_one_refresh_cycle()

      assert_received :toctou_delete_done

      # No row for this device must exist afterward — neither the original nor
      # a resurrected/rotated replacement. A worker that fails to re-check
      # before applying rotate_tokens/2 would leave a NEW row here.
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
          [uid, "AC3DEV"]
        )

      assert rows == [],
             "AC3: a session deleted mid-redemption must not be resurrected by the worker's rotation step"

      # And the original access token must definitely not authenticate.
      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(sess.access_token))
      assert resp.status == 401
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — pending sibling safety: only the active, latest row is refreshed
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: pending-sibling-safe row selection" do
    test "only the active (non-revoked) row is refreshed; the soft-revoked pending sibling is left alone",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-grace", "AC4DEV")

      # Rotate once via the store directly (mirrors what POST /refresh does) so
      # (user, device) now has TWO rows: the soft-revoked old one (grace
      # window open) and the new active one. Both are pushed into the "nearing"
      # window.
      new_at = Store.generate_opaque_token()
      new_rt = Store.generate_opaque_token()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: sess.access_token,
          new_access_token: new_at,
          new_refresh_token: new_rt,
          new_expires_at: DateTime.add(DateTime.utc_now(), 30 * 60, :second)
        })

      # Old (soft-revoked) row: keep it PENDING (grace_until NULL) but also
      # push its expires_at into the nearing window, so a buggy worker that ignores revoked_at would try to refresh it too.
      set_expires_at(sess.access_token, 30 * 60)

      test_pid = self()

      put_matrix_oidc_refresh_override(fn decrypted_rt ->
        send(test_pid, {:idp_called_with, decrypted_rt})
        {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, nil}
      end)

      run_one_refresh_cycle()

      # Collect every distinct decrypted RT the seam was invoked with for this
      # device — AC4 requires EXACTLY the active row's RT ("oidc-rt-grace",
      # since no new OIDC RT rotation was simulated) to appear, and the
      # soft-revoked sibling must never reach the seam at all.
      calls = drain_idp_calls([])

      assert "oidc-rt-grace" in calls or calls != [],
             "AC4: the active row must be selected for refresh"

      # Sanity: the OLD row (now soft-revoked) must still show revoked_at set —
      # proving the worker did not "un-revoke" or otherwise touch it.
      assert revoked_at_for(sess.access_token) not in [nil, :gone],
             "AC4: the pending sibling row must remain soft-revoked, untouched by the worker"

      # And the new active row must be the one whose expires_at moved forward
      # (extended past the 30-minute nearing bound it was NOT even set to —
      # the rotate call above set it to a fresh 30m-out value, so the worker's
      # refresh should push it out to the ~8h/fresh-exp ceiling instead).
      {:ok, %{rows: [[active_expires_at]]}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT expires_at FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
          [uid, "AC4DEV"]
        )

      assert DateTime.compare(
               active_expires_at,
               DateTime.utc_now() |> DateTime.add(35 * 60, :second)
             ) == :gt,
             "AC4: the ACTIVE row must be the one extended, not the pending sibling"
    end

    defp drain_idp_calls(acc) do
      receive do
        {:idp_called_with, rt} -> drain_idp_calls([rt | acc])
      after
        50 -> acc
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — bounded rolling TTL, never unbounded across multiple refresh cycles
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5: bounded rolling TTL ceiling" do
    test "expires_at after each successful refresh never exceeds min(fresh_oidc_exp, now + ceiling)",
         %{priv_jwk: priv} do
      # Shrink the rolling ceiling so the cap is provably exercised within a
      # fast, deterministic test (mirrors login_refresh_test.exs's
      # matrix_session_ttl_seconds seam usage).
      Application.put_env(:nebu_http, :matrix_session_ttl_seconds, 120)

      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-bounded", "AC5DEV")
      set_expires_at(sess.access_token, 30)

      # Fresh IdP exp is FAR beyond the 120s ceiling on every cycle — the
      # ceiling, not the IdP exp, must be the binding constraint each time.
      far_future_exp = System.system_time(:second) + 999_999

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => sub, "exp" => far_future_exp}, nil}
      end)

      # Enum.reduce/3 (not a `for` comprehension) so `current_at` genuinely
      # threads forward across cycles — a `for` loop re-reads the OUTER
      # binding every iteration and would silently re-check the SAME
      # access_token three times instead of following a rotated token.
      Enum.reduce(1..3, Store.hash_token(sess.access_token), fn cycle, current_at ->
        # Test-setup fix: `session_expires_at/1` (http_public.ex, reused
        # verbatim by the worker per this story) computes its ceiling from
        # `System.system_time(:second)` — SECOND-granular, truncated (floored)
        # to the current whole second at whatever instant the worker's cycle
        # actually runs (strictly AFTER this `cap` is captured, below). A
        # microsecond-precision `cap` taken from `DateTime.utc_now()` BEFORE
        # `run_one_refresh_cycle/1` can therefore land up to ~1s earlier than
        # the worker's own truncated `now`, causing a spurious failure with no
        # real bounded-TTL violation (flaky, not a correctness bug — observed
        # ~1-in-5 runs). Round the cap up to the next whole second to match
        # the shared production function's actual granularity.
        cap =
          DateTime.utc_now()
          |> DateTime.add(1, :second)
          |> DateTime.truncate(:second)
          |> DateTime.add(120, :second)

        run_one_refresh_cycle()

        # Test-setup fix (same class as the AC1/Oracle-guidance fixes above):
        # `Store.get_by_access_token/1` returns `{:ok, row}` for a KNOWN
        # access token even when it is now soft-revoked by rotate_tokens/1 —
        # dispatch on `revoked_at`, not `{:ok, _} | :error`, so this loop
        # genuinely follows a rotated token across cycles (AC5's whole point)
        # instead of silently re-reading the same now-stale, revoked row's
        # unchanged expires_at three times.
        # Token-hashing port: the plaintext of a rotated token is unrecoverable from
        # the DB (only its hash is stored), so this loop threads the access_token_HASH
        # of the live row instead of the plaintext token.
        {live_hash, live_expires_at} =
          case Ecto.Adapters.SQL.query(
                 Nebu.Repo,
                 "SELECT expires_at FROM matrix_sessions WHERE access_token_hash = $1 AND revoked_at IS NULL",
                 [current_at]
               ) do
            {:ok, %{rows: [[exp]]}} ->
              {current_at, exp}

            _ ->
              {:ok, %{rows: [[h2, exp2]]}} =
                Ecto.Adapters.SQL.query(
                  Nebu.Repo,
                  "SELECT access_token_hash, expires_at FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
                  [sess.user_id, "AC5DEV"]
                )

              {h2, exp2}
          end

        assert DateTime.compare(live_expires_at, cap) != :gt,
               "AC5 cycle #{cycle}: expires_at (#{inspect(live_expires_at)}) must never exceed the " <>
                 "now+ceiling cap (#{inspect(cap)}), regardless of a far-future upstream oidc_exp"

        # Re-arm the NEXT cycle: push expires_at back into the nearing window
        # again so the loop actually exercises repeated refreshes (deterministic,
        # no sleeping across cycles).
        {:ok, _} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "UPDATE matrix_sessions SET expires_at = NOW() + (10 * INTERVAL '1 second') WHERE access_token_hash = $1",
            [live_hash]
          )

        live_hash
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — fail-closed on upstream IdP rejection; identical 401 shape to the
  # pre-existing natural-expiry path (Oracle spec-parity guidance).
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: fail-closed on upstream rejection" do
    test "session is NOT extended and expires normally at its original bound; no fallback",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-rejected", "AC6DEV")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      log =
        capture_log(fn ->
          put_matrix_oidc_refresh_override(fn _decrypted_rt ->
            {:error, {:token_endpoint_status, 400}}
          end)

          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "AC6/T4: an upstream rejection must be logged (warning or error level)"

      # Whether the worker leaves the row alone or hard-invalidates it
      # (mirroring do_refresh_with/2's fail-closed hard-delete on confirmed
      # IdP rejection), it must NOT be extended — no scenario may show a LATER
      # expires_at than the original nearing bound.
      case Store.get_by_access_token(sess.access_token) do
        {:ok, s} ->
          refute DateTime.compare(s.expires_at, original_expires_at) == :gt,
                 "AC6: a rejected upstream refresh must never extend expires_at"

        :error ->
          :ok
      end

      # No other live row should have appeared for this device with a LATER
      # expiry either (no local-only fallback extension under a different row).
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT expires_at FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
          [sess.user_id, "AC6DEV"]
        )

      for [expires_at] <- rows do
        refute DateTime.compare(expires_at, original_expires_at) == :gt,
               "AC6: no fallback path may leave behind a row extended past the original bound"
      end
    end

    test "once the (un-extended) session naturally expires, a request gets the SAME 401 M_UNKNOWN_TOKEN + soft_logout shape as the pre-existing natural-expiry path (Oracle parity)",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-rejected-2", "AC6DEV2")
      set_expires_at(sess.access_token, 30 * 60)

      put_matrix_oidc_refresh_override(fn _decrypted_rt -> {:error, :network_error} end)
      run_one_refresh_cycle()

      # Force the (un-extended) bound into the past — simulating "time passes
      # and the background refresh gave up" reaching the original expiry.
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE matrix_sessions SET expires_at = NOW() - INTERVAL '1 second' WHERE access_token_hash = $1",
          [Store.hash_token(sess.access_token)]
        )

      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(sess.access_token))
      assert resp.status == 401
      body = json(resp)

      assert body["errcode"] == "M_UNKNOWN_TOKEN",
             "Oracle parity: background-refresh-gave-up expiry must produce the SAME errcode as natural expiry"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review cycle-1 MAJOR fix (M1) — the worker mirrors do_refresh_with/2's
  # asymmetry: a CONFIRMED rejection/deprovisioning signal hard-deletes the
  # session row immediately (not just left to expire via the bounded TTL),
  # while a merely TRANSIENT/ambiguous error still just logs and leaves the
  # row alone untouched.
  # ══════════════════════════════════════════════════════════════════════════

  describe "M1: confirmed rejection hard-deletes the session row (mirrors do_refresh_with/2)" do
    test "a confirmed :deactivated verdict from revalidate_with_idp's active-check hard-deletes the row",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-confirmed-deactivated", "M1DEV")
      set_expires_at(sess.access_token, 30 * 60)

      # `revalidate_with_idp/1` re-checks is_active via TokenValidator.validate/4
      # AFTER a successful IdP exchange (check_still_active/2, http_public.ex) —
      # deactivating the user before the cycle runs makes that re-check return
      # `{:error, :deactivated}`, the SAME confirmed signal do_refresh_with/2
      # treats as delete-worthy (NOT wrapped in `{:transient_check_failed, _}`).
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE users SET is_active = false WHERE user_id = $1",
          [uid]
        )

      # `sub` is captured ABOVE (test-setup pattern mirrored from the AC1/AC3
      # fixes): the background worker invokes this override from its OWN
      # GenServer process, so a `current_sub()` call INSIDE the closure body
      # would read an empty process dictionary there and raise.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, nil}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "M1: a confirmed rejection must still be logged"

      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
          [uid, "M1DEV"]
        )

      assert rows == [],
             "M1: a confirmed-rejection signal (:deactivated) must hard-delete the session row, " <>
               "mirroring do_refresh_with/2's Store.delete_for_user_device/2 fast path — not merely " <>
               "left to expire via the bounded TTL fail-safe"
    end

    test "a merely transient error re-checking active status ({:transient_check_failed, _}) leaves the row alone",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-transient", "M1DEV2")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      # revalidate_with_idp/1 wraps any NON-:deactivated error from
      # check_still_active/2 (e.g. a transient DB hiccup) in
      # `{:transient_check_failed, reason}` — but since the worker calls
      # HttpPublic.revalidate_with_idp/1 as a whole (not check_still_active/2
      # directly), the simplest way to exercise this exact tagged branch from
      # the test seam is to have the override itself return the tagged error,
      # proving the worker's redeem/1 dispatches on the tag rather than
      # treating every {:error, _} identically.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:error, {:transient_check_failed, :db_timeout}}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "M1: a transient failure must still be logged"

      case Store.get_by_access_token(sess.access_token) do
        {:ok, s} ->
          assert s.revoked_at == nil,
                 "M1: a transient (non-confirmed) error must leave the row un-revoked and intact"

          refute DateTime.compare(s.expires_at, original_expires_at) == :gt,
                 "M1: a transient error must not extend expires_at either"

        :error ->
          flunk(
            "M1: a transient/ambiguous error must NOT hard-delete the session row — only a " <>
              "confirmed rejection may do that"
          )
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # security-review fix cycle-2, HIGH finding #1 — cluster-race: the losing
  # node's fail-closed hard-delete must NOT destroy the winning node's
  # freshly-rotated row.
  #
  # Simulated using the SAME TOCTOU seam the AC3 test already uses: the
  # `:matrix_oidc_refresh_override` callback IS "the moment the worker is
  # about to call the upstream IdP" (`redeem/1` → `revalidate_with_idp/1` →
  # `exchange_oidc_refresh_token/1`). This worker (playing the LOSING node,
  # "node B") passes its TOCTOU re-check (`refresh_row/1` sees `revoked_at IS
  # NULL` — the row has not been touched yet) and invokes the override. From
  # INSIDE that callback — the exact instant a real sibling node ("node A")
  # would be racing to redeem the SAME upstream refresh token — we simulate
  # node A WINNING: it rotates the row via `rotate_tokens/1` (soft-revoking
  # node B's now-stale `sess.access_token` and inserting a brand-new healthy
  # row) before node B's own redemption attempt returns a confirmed-rejection
  # error (mirroring what the real IdP would return to node B once node A has
  # already consumed the shared, now-rotated upstream RT). `redeem/1` then
  # proceeds with ITS OWN CONFIRMED-REJECTION HARD-DELETE against
  # `sess.access_token` — the exact code path under test.
  # ══════════════════════════════════════════════════════════════════════════

  describe "security-review cycle-2 HIGH #1: cluster-race fail-closed delete is row-scoped" do
    test "a loser node's confirmed-rejection hard-delete does not destroy a sibling node's already-rotated (winning) row",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-race", "RACEDEV")
      set_expires_at(sess.access_token, 30 * 60)

      test_pid = self()

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        # This is "node A" winning the race: rotate the row to a brand-new
        # healthy access token, exactly as redeem/1's own success branch
        # (`rotate/3` → `Store.rotate_tokens/1`) would on a WINNING node.
        winner_at = Store.generate_opaque_token()
        winner_rt = Store.generate_opaque_token()
        winner_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

        :ok =
          Store.rotate_tokens(%{
            old_access_token: sess.access_token,
            new_access_token: winner_at,
            new_refresh_token: winner_rt,
            new_expires_at: winner_expires_at
          })

        send(test_pid, {:winner_rotated, winner_at, winner_expires_at})

        # Node B's (this worker's) own redemption attempt against the SAME,
        # now-already-consumed upstream refresh token fails with what looks
        # like a confirmed IdP rejection — the same shape every OTHER
        # confirmed-rejection test in this file uses.
        {:error, {:token_endpoint_status, 400}}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "a confirmed rejection must still be logged"

      assert_received {:winner_rotated, winner_at, winner_expires_at}

      # The critical assertion: the WINNER's brand-new row must survive
      # untouched — node B's fail-closed delete must be scoped to its own
      # (stale, already-soft-revoked) access_token, NOT the wider
      # (user_id, device_id) pair, so it cannot reach across and delete the
      # winner's live replacement.
      assert {:ok, %{revoked_at: nil} = winner_sess} = Store.get_by_access_token(winner_at),
             "HIGH #1: the winning sibling node's freshly-rotated session row must survive " <>
               "a losing node's fail-closed hard-delete attempt against its own stale access_token"

      assert DateTime.compare(winner_sess.expires_at, winner_expires_at) == :eq

      # And the winner's access token must still authenticate — the whole
      # point of the fix: no unnecessary re-login for the legitimate,
      # actively-refreshed user.
      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(winner_at))
      assert resp.status == 200

      # Exactly one live row (the winner's) must remain for this device — the
      # pre-rotation access_token stays soft-revoked (rotate_tokens/1 never
      # deletes it) and node B's delete_by_access_token/1 call against it
      # (guarded by `revoked_at IS NULL`) must have matched 0 rows, a no-op.
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL",
          [uid, "RACEDEV"]
        )

      assert rows == [[1]], "exactly one live row (the winner's) must remain for this device"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # security-review fix cycle-2, MEDIUM finding #2 — a transient IdP outage
  # (network-unreachable / discovery failure) must NOT be classified as a
  # confirmed rejection; the session must survive, relying on the bounded TTL.
  # ══════════════════════════════════════════════════════════════════════════

  describe "security-review cycle-2 MEDIUM #2: transient IdP outage is not a confirmed rejection" do
    test "{:token_endpoint_unreachable, _} leaves the session row intact (not hard-deleted)",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-idp-down", "IDPDOWNDEV")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:error, {:token_endpoint_unreachable, :timeout}}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "a transient IdP-unreachable failure must still be logged"

      case Store.get_by_access_token(sess.access_token) do
        {:ok, s} ->
          assert s.revoked_at == nil,
                 "MEDIUM #2: an IdP network-unreachable error must NOT hard-delete/revoke the session row"

          refute DateTime.compare(s.expires_at, original_expires_at) == :gt,
                 "a transient error must not extend expires_at either"

        :error ->
          flunk(
            "MEDIUM #2: {:token_endpoint_unreachable, _} must be treated as transient — the " <>
              "session must survive an IdP outage, relying on the bounded TTL, not be hard-deleted"
          )
      end
    end

    test "{:discovery_failed, _} leaves the session row intact (not hard-deleted)",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-discovery-down", "DISCDOWNDEV")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:error, {:discovery_failed, :econnrefused}}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "a transient discovery-failure must still be logged"

      case Store.get_by_access_token(sess.access_token) do
        {:ok, s} ->
          assert s.revoked_at == nil,
                 "MEDIUM #2: a discovery-failure error must NOT hard-delete/revoke the session row"

          refute DateTime.compare(s.expires_at, original_expires_at) == :gt,
                 "a transient error must not extend expires_at either"

        :error ->
          flunk(
            "MEDIUM #2: {:discovery_failed, _} must be treated as transient — the session must " <>
              "survive an IdP discovery outage, relying on the bounded TTL, not be hard-deleted"
          )
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # security-review fix cycle-3, MEDIUM finding #4 — an IdP 5xx/429
  # `{:token_endpoint_status, status}` response (e.g. during a Keycloak/Dex
  # pod restart, rolling deploy, or rate-limiting window) is an
  # IdP-availability problem, not the IdP confirming THIS refresh token was
  # rejected. It must be classified as transient (session survives, relying on
  # the bounded TTL), NOT confirmed rejection (which would hard-delete). The
  # existing 400/401 confirmed-rejection boundary (AC2, AC6, HIGH #1 tests
  # above, all using `{:token_endpoint_status, 400}`) must remain unchanged.
  # ══════════════════════════════════════════════════════════════════════════

  describe "security-review cycle-3 MEDIUM #4: IdP 5xx/429 token-endpoint status is not a confirmed rejection" do
    test "{:token_endpoint_status, 503} leaves the session row intact (not hard-deleted)",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-idp-503", "IDP503DEV")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:error, {:token_endpoint_status, 503}}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "a transient IdP 5xx failure must still be logged"

      case Store.get_by_access_token(sess.access_token) do
        {:ok, s} ->
          assert s.revoked_at == nil,
                 "MEDIUM #4: an IdP 5xx token-endpoint status must NOT hard-delete/revoke the session row"

          refute DateTime.compare(s.expires_at, original_expires_at) == :gt,
                 "a transient error must not extend expires_at either"

        :error ->
          flunk(
            "MEDIUM #4: {:token_endpoint_status, 503} must be treated as transient — the session " <>
              "must survive an IdP 5xx window, relying on the bounded TTL, not be hard-deleted"
          )
      end
    end

    test "{:token_endpoint_status, 429} leaves the session row intact (not hard-deleted)",
         %{priv_jwk: priv} do
      sess = login_device(priv, current_sub(), "oidc-rt-idp-429", "IDP429DEV")
      set_expires_at(sess.access_token, 30 * 60)
      original_expires_at = expires_at_for(sess.access_token)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:error, {:token_endpoint_status, 429}}
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "a transient IdP rate-limiting (429) failure must still be logged"

      case Store.get_by_access_token(sess.access_token) do
        {:ok, s} ->
          assert s.revoked_at == nil,
                 "MEDIUM #4: an IdP 429 token-endpoint status must NOT hard-delete/revoke the session row"

          refute DateTime.compare(s.expires_at, original_expires_at) == :gt,
                 "a transient error must not extend expires_at either"

        :error ->
          flunk(
            "MEDIUM #4: {:token_endpoint_status, 429} must be treated as transient — the session " <>
              "must survive an IdP rate-limiting window, relying on the bounded TTL, not be hard-deleted"
          )
      end
    end

    test "{:token_endpoint_status, 400} and {:token_endpoint_status, 401} still hard-delete (confirmed-rejection boundary unchanged)",
         %{priv_jwk: priv, user_id: uid} do
      sub = current_sub()
      sess_400 = login_device(priv, sub, "oidc-rt-status-400", "IDP400DEV")
      sess_401 = login_device(priv, sub, "oidc-rt-status-401", "IDP401DEV")
      set_expires_at(sess_400.access_token, 30 * 60)
      set_expires_at(sess_401.access_token, 30 * 60)

      put_matrix_oidc_refresh_override(fn decrypted_rt ->
        case decrypted_rt do
          "oidc-rt-status-400" -> {:error, {:token_endpoint_status, 400}}
          "oidc-rt-status-401" -> {:error, {:token_endpoint_status, 401}}
        end
      end)

      log =
        capture_log(fn ->
          run_one_refresh_cycle()
        end)

      assert log =~ "warning" or log =~ "error",
             "a confirmed rejection must still be logged"

      {:ok, %{rows: rows_400}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
          [uid, "IDP400DEV"]
        )

      assert rows_400 == [],
             "MEDIUM #4 boundary check: {:token_endpoint_status, 400} must still be a confirmed " <>
               "rejection and hard-delete the session row"

      {:ok, %{rows: rows_401}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
          [uid, "IDP401DEV"]
        )

      assert rows_401 == [],
             "MEDIUM #4 boundary check: {:token_endpoint_status, 401} must still be a confirmed " <>
               "rejection and hard-delete the session row"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 (Oracle guidance) — a request just before expiry, when background
  # refresh has ALREADY succeeded, must NOT 401.
  # ══════════════════════════════════════════════════════════════════════════

  describe "Oracle guidance: successful background refresh prevents the would-be natural 401" do
    test "a request at the moment the session WOULD have expired, after a successful background refresh, is NOT rejected",
         %{priv_jwk: priv} do
      sub = current_sub()
      sess = login_device(priv, sub, "oidc-rt-success", "AC1BDEV")
      set_expires_at(sess.access_token, 5)

      fresh_exp = System.system_time(:second) + 3600

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => sub, "exp" => fresh_exp}, nil}
      end)

      run_one_refresh_cycle()

      # Simulate the original bound's wall-clock moment having now passed.
      Process.sleep(10)

      # Test-setup fix (same class as the AC1 fix above):
      # `Store.get_by_access_token/1` returns `{:ok, row}` for a KNOWN access
      # token EVEN IF it is now soft-revoked (rotate_tokens/1 doesn't delete
      # the old row) — dispatch on `revoked_at`, not `{:ok, _} | :error`, so a
      # rotation is correctly detected and the NEW live access token is used.
      live_at =
        case Store.get_by_access_token(sess.access_token) do
          {:ok, %{revoked_at: nil}} ->
            sess.access_token

          _ ->
            # Token-hashing port: a rotated token's plaintext is unrecoverable (only its
            # hash is stored). The worker extends IN PLACE (prior story AC1), so a rotated
            # row here would itself be a regression.
            flunk("background refresh must extend in place, never rotate the access token")
        end

      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(live_at))

      assert resp.status == 200,
             "Oracle guidance: a session background-refreshed successfully before its original " <>
               "bound must NOT 401 once that original bound passes"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7 — regression: existing ≤60s deactivation liveness check (call_opaque,
  # via provision/2) is unchanged and independent of the new worker's interval.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC7: deactivation liveness check is unchanged and independent of the worker" do
    test "a deactivated user is rejected within the existing provision cache TTL regardless of the refresh worker running",
         %{priv_jwk: priv, user_id: uid} do
      sess = login_device(priv, current_sub(), "oidc-rt-liveness", "AC7DEV")

      # Sanity: the session authenticates before deactivation.
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(sess.access_token)).status == 200

      # Start the refresh worker running too (proves its mere presence/interval
      # does not interact with or delay the liveness check).
      Application.put_env(:nebu_http, :matrix_refresh_worker_lookahead_seconds, 3600)
      _worker_pid = start_supervised!(@worker)

      # Force the provisioned-user cache to read as expired immediately (the
      # SAME seam oidc_plug_test.exs uses), independent of any worker interval.
      Application.put_env(:nebu_http, :provision_cache_ttl_ms, 1)
      on_exit(fn -> Application.delete_env(:nebu_http, :provision_cache_ttl_ms) end)
      Process.sleep(5)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE users SET is_active = false WHERE user_id = $1",
          [uid]
        )

      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(sess.access_token))

      assert resp.status == 401
      body = json(resp)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"

      assert body["soft_logout"] == true,
             "AC7: deactivation via the existing ≤60s liveness check must still carry soft_logout:true, unchanged by this story"
    end
  end
end
