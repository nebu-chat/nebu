defmodule Nebu.Web.OidcPlugTest do
  @moduledoc """
  RED-phase ATDD test for the oidc-middleware-migration story.

  AC1: A validly-signed Keycloak/Dex Bearer token → request proceeds and the
       user's Matrix ID is available in `conn.assigns.current_user`.

  These tests reference modules that DO NOT EXIST YET and therefore MUST FAIL
  (compile error / undefined function) until the dev phase implements:

    * `Nebu.Web.Plugs.OidcPlug`  — the Bearer-token validating Plug
    * `Nebu.Web.JwksCache`        — the JWKS key cache (injectable, no network in tests)

  ## Injectability design (read this before implementing)

  The plug MUST verify the JWT against a JWK public key WITHOUT making a
  network call during tests. The agreed seam:

    * `Nebu.Web.JwksCache.keys/0` returns the list of cached JWK maps
      (each map has "kty", "n", "e", "kid", ...).
    * In tests we set `Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])`
      and `Nebu.Web.JwksCache.keys/0` reads that override when present
      (so no GenServer / network is needed for unit tests). Alternatively the
      dev may make the JWKS source a configurable module — either way the test
      injects the public JWK and never hits the network.

  The plug selects the matching key by the token header `kid`, verifies the
  signature + standard claims (iss, aud, exp) via
  `Assent.JWTAdapter.verify/3`, and on success assigns
  `conn.assigns.current_user` = `"@" <> sub <> ":" <> server_name`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import Bitwise

  @server_name "test.local"
  @issuer "https://dex.example.com/dex"
  @audience "nebu-gateway"
  @kid "test-key-1"

  setup do
    # Generate an RSA keypair in-test. The private key signs the JWT; the matching
    # public JWK is injected so the plug can verify WITHOUT a network call.
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

    priv_map = Map.put(priv_map, "kid", @kid)

    # Configure server_name + OIDC validation params for deterministic assertions.
    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    # Inject the public JWK so JwksCache.keys/0 returns it (no network).
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    {:ok, priv_jwk: priv_map}
  end

  # Sign a JWT (RS256) with the in-test private key, embedding the @kid in the header.
  defp sign_jwt(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp future_exp, do: System.system_time(:second) + 3600

  # Take a well-formed compact JWS (header.payload.signature), base64url-decode
  # the signature segment, flip one byte, re-encode, and rejoin. The result is a
  # structurally valid JWS with a wrong signature — it must fail verification.
  defp corrupt_signature(token) do
    [header, payload, sig_b64] = String.split(token, ".", parts: 3)

    sig = Base.url_decode64!(sig_b64, padding: false)
    <<first, rest::binary>> = sig
    flipped = <<bxor(first, 0x01), rest::binary>>
    tampered_sig = Base.url_encode64(flipped, padding: false)

    Enum.join([header, payload, tampered_sig], ".")
  end

  @opts Nebu.Web.Plugs.OidcPlug.init([])

  test "valid Bearer token sets conn.assigns.current_user and does not halt", %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "kai",
      "exp" => future_exp(),
      "iat" => System.system_time(:second)
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    refute conn.halted, "valid token must not halt the connection"
    assert conn.assigns[:current_user] == "@kai:#{@server_name}",
           "current_user must be the Matrix ID @<sub>:<server_name>"
  end

  test "tampered token (broken signature) → 401 M_UNKNOWN_TOKEN", %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "kai",
      "exp" => future_exp()
    }

    token = sign_jwt(claims, priv_jwk)
    # Corrupt the SIGNATURE segment of a well-formed JWS so the token keeps a
    # valid compact shape (header.payload.signature) but fails verification:
    # base64url-decode the 3rd segment, flip one byte, re-encode, rejoin.
    tampered = corrupt_signature(token)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> tampered)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "invalid signature must halt"
    assert conn.status == 401

    content_type =
      get_resp_header(conn, "content-type") |> List.first() |> to_string()

    assert String.contains?(content_type, "application/json")

    body = Jason.decode!(conn.resp_body)
    assert body["errcode"] == "M_UNKNOWN_TOKEN"
  end

  test "token with NO exp claim → 401 M_UNKNOWN_TOKEN (MINOR-3)", %{priv_jwk: priv_jwk} do
    # A correctly-signed token that simply omits `exp` must be rejected — an
    # absent expiry means the token never expires, which we do not accept.
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "kai"
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "a token without exp must halt"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  test "token with missing sub claim → 401 M_UNKNOWN_TOKEN (MINOR-4)", %{priv_jwk: priv_jwk} do
    # Without a `sub` we cannot build a Matrix user ID — reject instead of
    # accepting "@:server" with a nonsense identity.
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "exp" => future_exp()
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "a token without sub must halt"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    refute conn.assigns[:current_user], "no current_user may be assigned for a sub-less token"
  end

  test "token with empty-string sub claim → 401 M_UNKNOWN_TOKEN (MINOR-4)", %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "",
      "exp" => future_exp()
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "an empty-string sub must halt"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  # ── matrix-api-migration security hardening (test-review MINOR-2) ──────────

  test "alg:none token → 401 M_UNKNOWN_TOKEN (MEDIUM-2)", %{priv_jwk: _priv_jwk} do
    # Craft an unsigned JWT (alg:none, empty signature segment). The alg allowlist
    # must reject it before any key selection / signature verification.
    header = %{"alg" => "none", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)

    payload =
      %{"iss" => @issuer, "aud" => @audience, "sub" => "kai", "exp" => future_exp()}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    token = header <> "." <> payload <> "."

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "alg:none must halt"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    refute conn.assigns[:current_user]
  end

  test "HS256 token signed with the RSA public key as HMAC secret → 401 (alg-confusion, MEDIUM-2)",
       %{priv_jwk: _priv_jwk} do
    # Classic alg-confusion: the attacker takes the published RSA public key and
    # uses it as an HMAC shared secret to sign an HS256 token. A naive verifier
    # that trusts the header alg would verify it with the same public key. The
    # alg allowlist (asymmetric-only) must reject HS256 outright.
    pub_jwk = Application.get_env(:nebu_http, :oidc_jwks) |> List.first()
    hmac_secret = Jason.encode!(pub_jwk)

    claims = %{"iss" => @issuer, "aud" => @audience, "sub" => "attacker", "exp" => future_exp()}

    jws = %{"alg" => "HS256", "kid" => @kid}
    oct = JOSE.JWK.from_oct(hmac_secret)
    signed = JOSE.JWT.sign(oct, jws, claims)
    {_, token} = JOSE.JWS.compact(signed)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "HS256 must be rejected by the alg allowlist"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    refute conn.assigns[:current_user]
  end

  test "token with a wrong issuer → 401 M_UNKNOWN_TOKEN (MEDIUM-3 fail-closed)",
       %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => "https://evil.example.com/dex",
      "aud" => @audience,
      "sub" => "kai",
      "exp" => future_exp()
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "a wrong iss must halt"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    refute conn.assigns[:current_user]
  end

  test "token with a wrong/missing audience → 401 M_UNKNOWN_TOKEN (MEDIUM-3 fail-closed)",
       %{priv_jwk: priv_jwk} do
    # aud points at a different client → must be rejected.
    claims = %{
      "iss" => @issuer,
      "aud" => "some-other-client",
      "sub" => "kai",
      "exp" => future_exp()
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "a wrong aud must halt"
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    refute conn.assigns[:current_user]
  end

  # ── matrix-api-migration cycle-2: provisioning cache TTL (MINOR-6) ─────────
  #
  # The provisioning cache must not be permanent: once an entry is older than
  # the TTL it has to read as a MISS so the next request re-runs
  # TokenValidator.validate, which re-checks deactivation. This proves a user
  # who is deactivated AFTER their first successful request is blocked once the
  # cache entry expires (within 60s in production) — matching the Go gateway's
  # 60s is_active/status cache instead of being accepted for the whole node
  # lifetime.
  #
  # Determinism: we never sleep for the TTL. Instead we drive the two cache
  # states directly:
  #   * a FRESH entry  → cache hit  → validator is NOT called → request proceeds
  #   * an EXPIRED entry (cached far in the past) → cache miss → validator IS
  #     called; it now returns {:error, :deactivated} → request rejected.
  # `Nebu.Repo` is registered to a dummy process so the plug's `running?(Repo)`
  # guard is satisfied without a real DB, and `validator_module` is overridden
  # with a counting fake so we can assert whether validate was re-invoked. The
  # deactivated path never reaches the profile upsert, so no DB query is needed.
  describe "provisioning cache TTL (MINOR-6)" do
    @provisioned_table :nebu_http_provisioned_users

    defmodule FakeDeactivatedValidator do
      @moduledoc false
      @behaviour Nebu.Matrix.Session.TokenValidator

      # Count every call so the test can prove whether the cache short-circuited.
      @impl true
      def validate(_user_id, _role, _display_name, _email) do
        :counters.add(counter(), 1, 1)
        {:error, :deactivated}
      end

      def counter do
        case :persistent_term.get({__MODULE__, :counter}, nil) do
          nil ->
            ref = :counters.new(1, [])
            :persistent_term.put({__MODULE__, :counter}, ref)
            ref

          ref ->
            ref
        end
      end

      def reset, do: :counters.put(counter(), 1, 0)
      def calls, do: :counters.get(counter(), 1)
    end

    setup do
      # Make `running?(Nebu.Repo)` true without a real Ecto repo: a dummy named
      # process is enough for the Process.whereis/1 guard in the plug.
      {:ok, repo_pid} = Agent.start_link(fn -> :ok end)

      previously_registered =
        case Process.whereis(Nebu.Repo) do
          nil ->
            Process.register(repo_pid, Nebu.Repo)
            false

          _ ->
            # A real Repo is already running (integration profile) — leave it.
            true
        end

      Application.put_env(:session_manager, :validator_module, FakeDeactivatedValidator)
      FakeDeactivatedValidator.reset()

      # Start from a clean cache table so prior tests cannot leak entries.
      if :ets.whereis(@provisioned_table) != :undefined do
        :ets.delete_all_objects(@provisioned_table)
      end

      on_exit(fn ->
        Application.delete_env(:session_manager, :validator_module)
        Application.delete_env(:nebu_http, :provision_cache_ttl_ms)

        if not previously_registered and Process.alive?(repo_pid) do
          Agent.stop(repo_pid)
        end

        if :ets.whereis(@provisioned_table) != :undefined do
          :ets.delete_all_objects(@provisioned_table)
        end
      end)

      :ok
    end

    # Ensure the ETS table exists, then seed a cache entry for `user_id` whose
    # monotonic timestamp is `age_ms` old. A small positive age with a small TTL
    # yields an expired entry; age 0 with a large TTL yields a fresh one.
    defp seed_cache(user_id, age_ms) do
      case :ets.whereis(@provisioned_table) do
        :undefined ->
          :ets.new(@provisioned_table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          :ok
      end

      cached_at = System.monotonic_time(:millisecond) - age_ms
      :ets.insert(@provisioned_table, {user_id, cached_at})
    end

    test "a FRESH cache entry is a hit: validate is NOT re-invoked and the request proceeds",
         %{priv_jwk: priv_jwk} do
      user_id = "@kai:#{@server_name}"
      # Long TTL, freshly cached → must be treated as a hit.
      Application.put_env(:nebu_http, :provision_cache_ttl_ms, 60_000)
      seed_cache(user_id, 0)

      claims = %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => "kai",
        "exp" => future_exp()
      }

      token = sign_jwt(claims, priv_jwk)

      conn =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      refute conn.halted, "a fresh cache hit must not re-validate or block"
      assert conn.assigns[:current_user] == user_id

      assert FakeDeactivatedValidator.calls() == 0,
             "a fresh cache entry must short-circuit provisioning (no validate call)"
    end

    test "an EXPIRED cache entry is a miss: validate is re-invoked and a now-deactivated user is rejected",
         %{priv_jwk: priv_jwk} do
      user_id = "@kai:#{@server_name}"

      # Tiny TTL + an entry aged well past it ⇒ the entry must read as expired
      # WITHOUT sleeping. (TTL 0 also works; we use 1ms / age 1000ms for clarity.)
      Application.put_env(:nebu_http, :provision_cache_ttl_ms, 1)
      seed_cache(user_id, 1000)

      claims = %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => "kai",
        "exp" => future_exp()
      }

      token = sign_jwt(claims, priv_jwk)

      conn =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert FakeDeactivatedValidator.calls() == 1,
             "an expired cache entry must force a fresh validate (deactivation re-check)"

      assert conn.halted, "a re-validated, now-deactivated user must be blocked"
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
      refute conn.assigns[:current_user]
    end
  end

  # ── bugfix-jwt-soft-logout MAJOR-1 (test-review gap): primary deactivation
  # branch of call_jwt/2 ───────────────────────────────────────────────────
  #
  # This is DISTINCT from the "provisioning cache TTL" describe block above:
  # that block proves the ~60s TTL'd provisioned-user CACHE RE-CHECK path
  # (oidc_plug.ex ~447-477, reached via `provisioned?/1` reading a seeded,
  # expired cache entry) also rejects a since-deactivated user. This test
  # instead exercises the PRIMARY, non-cached `case provision(user_id, claims)
  # do :deactivated -> ...` clause directly inside `call_jwt/2`
  # (oidc_plug.ex:126-129) — a brand-new user_id with no cache entry at all,
  # so `provision/2` falls straight through to `do_provision/2` on the very
  # first request.
  #
  # AC2 of bugfix-jwt-soft-logout requires every call_jwt/2 failure branch
  # OTHER than {:error, :expired} to never gain `soft_logout`. A deactivated
  # account is a HARD logout (the operator explicitly disabled the account,
  # it is not a merely-aged-out token), so this pins that the response must
  # NOT carry `soft_logout` — guarding against a future overly-broad fix.
  describe "deactivated account (primary, non-cached call_jwt/2 branch)" do
    @provisioned_table :nebu_http_provisioned_users

    defmodule FakeDeactivatedValidatorPrimary do
      @moduledoc false
      @behaviour Nebu.Matrix.Session.TokenValidator

      @impl true
      def validate(_user_id, _role, _display_name, _email), do: {:error, :deactivated}
    end

    setup do
      # Make `running?(Nebu.Repo)` true without a real Ecto repo, so `provision/2`
      # does not short-circuit to `:ok` via the `not running?(Nebu.Repo)` guard.
      {:ok, repo_pid} = Agent.start_link(fn -> :ok end)

      previously_registered =
        case Process.whereis(Nebu.Repo) do
          nil ->
            Process.register(repo_pid, Nebu.Repo)
            false

          _ ->
            true
        end

      Application.put_env(:session_manager, :validator_module, FakeDeactivatedValidatorPrimary)

      # Clean cache table so no stale/fresh entry from another test lets this
      # brand-new user_id short-circuit provisioning via the cache-hit path.
      if :ets.whereis(@provisioned_table) != :undefined do
        :ets.delete_all_objects(@provisioned_table)
      end

      on_exit(fn ->
        Application.delete_env(:session_manager, :validator_module)

        if not previously_registered and Process.alive?(repo_pid) do
          Agent.stop(repo_pid)
        end

        if :ets.whereis(@provisioned_table) != :undefined do
          :ets.delete_all_objects(@provisioned_table)
        end
      end)

      :ok
    end

    test "a valid, non-expired, correctly-signed JWT for a deactivated user → 401 M_UNKNOWN_TOKEN with NO soft_logout",
         %{priv_jwk: priv_jwk} do
      # Distinct sub from every other test in this file so there is no chance
      # of an ETS provisioned-cache entry leaking in from a different test.
      claims = %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => "deactivated-user-primary",
        "exp" => future_exp()
      }

      token = sign_jwt(claims, priv_jwk)

      conn =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert conn.halted, "a deactivated account must halt"
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"
      assert body["error"] == "Account has been deactivated"

      refute Map.has_key?(body, "soft_logout"),
             "a deactivated account is a HARD logout — soft_logout must not be present"

      refute conn.assigns[:current_user]
    end
  end

  # ── matrix-api-migration F-1: logout token denylist ───────────────────────
  #
  # A token that verifies (signature + alg + iss + aud + exp) but has been
  # revoked via POST /logout must be rejected by OidcPlug with 401
  # M_UNKNOWN_TOKEN. The full login→use→logout→reuse round-trip is exercised at
  # the HTTP layer in matrix_router_test (integration); here we prove the plug's
  # denylist consult in isolation, by jti and by token-hash.
  describe "token denylist (F-1)" do
    @denylist_table :nebu_http_token_denylist

    setup do
      if :ets.whereis(@denylist_table) != :undefined do
        :ets.delete_all_objects(@denylist_table)
      end

      on_exit(fn ->
        if :ets.whereis(@denylist_table) != :undefined do
          :ets.delete_all_objects(@denylist_table)
        end
      end)

      :ok
    end

    test "a denylisted token (by jti) → 401 M_UNKNOWN_TOKEN even though it verifies",
         %{priv_jwk: priv_jwk} do
      exp = future_exp()
      claims = %{"iss" => @issuer, "aud" => @audience, "sub" => "kai", "exp" => exp, "jti" => "tok-1"}
      token = sign_jwt(claims, priv_jwk)

      # Same token is accepted BEFORE revocation (control).
      ok_conn =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      refute ok_conn.halted, "a valid, non-revoked token must be accepted"
      assert ok_conn.assigns[:current_user] == "@kai:#{@server_name}"

      # Revoke by jti, then the SAME token must be rejected.
      Nebu.Web.TokenDenylist.revoke("tok-1", token, exp)

      denied =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert denied.halted, "a revoked token must halt"
      assert denied.status == 401
      assert Jason.decode!(denied.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
      refute denied.assigns[:current_user]
    end

    # bugfix-jwt-soft-logout AC2: ONLY the `check_exp/1` → `{:error, :expired}`
    # branch of call_jwt/2 gains `soft_logout`. A revoked/denylisted token is a
    # HARD logout (the token was explicitly invalidated, not merely aged out) —
    # this pins that a future blanket "always add soft_logout" fix would be
    # wrong, by asserting the key is entirely absent here.
    test "a denylisted token (by jti) → 401 response has NO soft_logout key",
         %{priv_jwk: priv_jwk} do
      exp = future_exp()
      claims = %{"iss" => @issuer, "aud" => @audience, "sub" => "kai", "exp" => exp, "jti" => "tok-2"}
      token = sign_jwt(claims, priv_jwk)

      Nebu.Web.TokenDenylist.revoke("tok-2", token, exp)

      denied =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert denied.halted
      assert denied.status == 401
      body = Jason.decode!(denied.resp_body)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"
      refute Map.has_key?(body, "soft_logout"),
             "a revoked/denylisted token is a HARD logout — soft_logout must not be present"
    end

    test "a denylisted token (by hash, no jti claim) → 401 M_UNKNOWN_TOKEN",
         %{priv_jwk: priv_jwk} do
      exp = future_exp()
      claims = %{"iss" => @issuer, "aud" => @audience, "sub" => "kai", "exp" => exp}
      token = sign_jwt(claims, priv_jwk)

      # No jti in claims → revocation keys on the token hash.
      Nebu.Web.TokenDenylist.revoke(nil, token, exp)

      denied =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert denied.halted
      assert denied.status == 401
      assert Jason.decode!(denied.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "a valid token assigns access_token + oidc_claims so logout can revoke it",
         %{priv_jwk: priv_jwk} do
      claims = %{"iss" => @issuer, "aud" => @audience, "sub" => "kai", "exp" => future_exp()}
      token = sign_jwt(claims, priv_jwk)

      conn =
        conn(:post, "/_matrix/client/v3/logout")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      refute conn.halted
      assert conn.assigns[:access_token] == token
      assert conn.assigns[:oidc_claims]["sub"] == "kai"
    end
  end
end
