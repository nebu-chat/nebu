defmodule Nebu.Web.AccountDataTest do
  @moduledoc """
  Acceptance tests (RED phase) for DURABLE global account_data + /sync delivery
  (story: account-data-durability, epic client-crypto-setup).

  Today `Nebu.Matrix.AccountDataStore` is ETS (volatile, node-local) and `/sync`
  returns `"account_data" => []`. Element stores its secret-storage / recovery
  material (`m.secret_storage.default_key`, `m.secret_storage.key.<id>`, the
  client-encrypted private cross-signing keys `m.cross_signing.*`) in GLOBAL
  account_data. If that is lost on restart or never delivered via `/sync`, Element
  treats recovery as not configured and re-prompts.

  This story makes account_data:
    * DURABLE — PostgreSQL (migration 000011_account_data), read-on-start, keyed by
      (user_id, type), content stored opaquely as JSON.
    * DELIVERED — `/sync` top-level `account_data.events` = [{type, content}, …]:
      full on initial sync, changed-only on incremental sync.

  Content is OPAQUE (ADR-011): the server stores/returns it byte-for-byte and never
  parses or decrypts it.

  Layers:
    * PURE UNIT (no DB): auth/404 guards that reject before any DB call. These run
      in the DB-less `--warnings-as-errors` container.
    * `@moduletag :integration`: durability (read in a fresh process → real Postgres
      row) + /sync (initial full, incremental changed-only). These need the Repo.

  Written FIRST (red): AccountDataStore is still ETS, has no `list/1` / change-marker,
  and `/sync` does not populate `account_data.events`.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "account-data-test-key-1"
  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirror cross_signing_test.exs) ─────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600

  defp setup_oidc_keys do
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

    Application.put_env(:nebu_http, :server_name, @server_name)
    # OIDC issuer/audience now resolve via the OidcConfig seam (ADR-022 bootstrap-only;
    # the env path was removed by oidc-bootstrap-only-e2e-regressions on main).
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    Map.put(priv_map, "kid", @kid)
  end

  defp bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => future_exp(),
      "iat" => System.system_time(:second)
    }

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    {"@" <> sub <> ":" <> @server_name, compact}
  end

  defp call(method, path, body, headers) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  defp put_account_data(uid, token, type, body) do
    call(
      :put,
      "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{URI.encode_www_form(type)}",
      body,
      auth(token)
    )
  end

  defp get_account_data(uid, token, type) do
    call(
      :get,
      "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{URI.encode_www_form(type)}",
      nil,
      auth(token)
    )
  end

  # Extract the account_data events list from a /sync response body, type-keyed.
  defp account_data_by_type(sync_body) do
    (get_in(sync_body, ["account_data", "events"]) || [])
    |> Map.new(fn ev -> {ev["type"], ev["content"]} end)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — auth guard + 404 absent (pure unit, no DB: rejects before any DB call)
  # ══════════════════════════════════════════════════════════════════════════

  describe "account_data auth + absent guards (no DB)" do
    setup do
      priv = setup_oidc_keys()
      {uid_alice, token_alice} = bearer_for("ad-alice", priv)
      {uid_bob, token_bob} = bearer_for("ad-bob", priv)
      {:ok, alice: uid_alice, alice_token: token_alice, bob: uid_bob, bob_token: token_bob}
    end

    test "PUT another user's account_data → 403 M_FORBIDDEN (rejects before DB)", %{
      bob: uid_bob,
      alice_token: token_alice
    } do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"
      conn = put_account_data(uid_bob, token_alice, type, %{"injected" => "by_alice"})
      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "GET another user's account_data → 403 M_FORBIDDEN (rejects before DB)", %{
      alice: uid_alice,
      bob_token: token_bob
    } do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"
      conn = get_account_data(uid_alice, token_bob, type)
      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 / AC2 / AC6 — durable store: PUT persists to Postgres, survives a process
  # boundary (read in a fresh Task), content opaque byte-for-byte.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AccountDataStore durability (integration)" do
    @describetag :integration

    test "AC2 Persistenz: put then a fresh-process get returns the stored content (read-on-start, Postgres)" do
      if Process.whereis(Nebu.Repo) do
        uid = "@ad-durable-#{:erlang.unique_integer([:positive])}:test.local"
        type = "m.secret_storage.default_key"
        json_body = Jason.encode!(%{"algorithm" => "m.secret_storage.v1.aes-hmac-sha2", "key" => "OPAQUE"})

        :ok = Nebu.Matrix.AccountDataStore.put(uid, type, json_body)

        # Read in a SEPARATE process: if the store grew an in-process/ETS cache, a
        # same-process read could mask a missing Postgres row. A freshly-spawned
        # Task forces the durable (read-on-start, Postgres-backed) path — the
        # Persistenz-Strategie = PostgreSQL durability proof, not a mere round-trip.
        result =
          Task.async(fn -> Nebu.Matrix.AccountDataStore.get(uid, type) end)
          |> Task.await(5000)

        assert result == {:ok, json_body}
      else
        assert true
      end
    end

    test "AC6 opacity: content is stored & returned byte-for-byte (no parse/decrypt)" do
      if Process.whereis(Nebu.Repo) do
        uid = "@ad-opaque-#{:erlang.unique_integer([:positive])}:test.local"
        type = "m.cross_signing.master"
        # Deliberately NOT a JSON object the server would normally produce: an
        # opaque client-encrypted blob string. The store must round-trip it verbatim.
        opaque = ~s({"encrypted":"+/=base64ish\\u0000ZZZ","not":["a","key","object"]})

        :ok = Nebu.Matrix.AccountDataStore.put(uid, type, opaque)

        assert {:ok, ^opaque} =
                 Task.async(fn -> Nebu.Matrix.AccountDataStore.get(uid, type) end)
                 |> Task.await(5000)
      else
        assert true
      end
    end

    test "AC3 absent: get for an unseen type returns :error (→ 404 at the HTTP layer)" do
      if Process.whereis(Nebu.Repo) do
        uid = "@ad-absent-#{:erlang.unique_integer([:positive])}:test.local"
        assert :error = Nebu.Matrix.AccountDataStore.get(uid, "m.never.stored")
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 / AC2 / AC3 — HTTP PUT/GET round-trip + 404 against the durable store.
  # ══════════════════════════════════════════════════════════════════════════

  describe "PUT/GET account_data over HTTP, durable (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("ad-http-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "AD HTTP", "adhttp@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC1/AC2: PUT then GET returns exactly the stored body", %{user_id: uid, token: token} do
      type = "m.secret_storage.key.#{:erlang.unique_integer([:positive])}"
      stored_body = %{"algorithm" => "m.secret_storage.v1.aes-hmac-sha2", "iv" => "OPAQUEiv"}

      put_conn = put_account_data(uid, token, type, stored_body)
      assert put_conn.status == 200
      assert json(put_conn) == %{}

      get_conn = get_account_data(uid, token, type)
      assert get_conn.status == 200
      assert json(get_conn) == stored_body
    end

    test "AC3: GET for an unseen type → 404 M_NOT_FOUND", %{user_id: uid, token: token} do
      type = "m.never.#{:erlang.unique_integer([:positive])}"
      conn = get_account_data(uid, token, type)
      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "AC1: second PUT overwrites; GET returns latest", %{user_id: uid, token: token} do
      type = "m.secret_storage.default_key"
      put_account_data(uid, token, type, %{"v" => 1})
      put_account_data(uid, token, type, %{"v" => 2})
      conn = get_account_data(uid, token, type)
      assert conn.status == 200
      assert json(conn) == %{"v" => 2}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — initial /sync includes ALL of the user's global account_data.
  # ══════════════════════════════════════════════════════════════════════════

  describe "initial /sync delivers all global account_data (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("ad-initsync-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "AD Init", "adinit@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC4: two stored entries both appear in initial sync account_data.events as {type, content}",
         %{user_id: uid, token: token} do
      content_a = %{"algorithm" => "m.secret_storage.v1.aes-hmac-sha2", "key" => "DEFAULT"}
      content_b = %{"encrypted" => "OPAQUE-CROSS-SIGNING-MASTER"}

      assert put_account_data(uid, token, "m.secret_storage.default_key", content_a).status == 200
      assert put_account_data(uid, token, "m.cross_signing.master", content_b).status == 200

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200

      by_type = account_data_by_type(json(sync))
      assert by_type["m.secret_storage.default_key"] == content_a
      assert by_type["m.cross_signing.master"] == content_b
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — incremental /sync (with since) includes ONLY entries changed after the
  # since token; unchanged entries are omitted.
  # ══════════════════════════════════════════════════════════════════════════

  describe "incremental /sync delivers only changed account_data (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("ad-incsync-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "AD Inc", "adinc@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC5: after the initial sync delivers an entry, an incremental sync returns ONLY a newly-PUT entry",
         %{user_id: uid, token: token} do
      # 1) store an OLD entry, then initial-sync so the client has it + a since token
      old = %{"old" => true}
      assert put_account_data(uid, token, "m.old.entry", old).status == 200

      first = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert first.status == 200
      since = json(first)["next_batch"]
      assert is_binary(since)

      # initial sync delivered the old entry (sanity)
      assert account_data_by_type(json(first))["m.old.entry"] == old

      # 2) PUT a NEW entry after the since token
      new = %{"new" => true}
      assert put_account_data(uid, token, "m.new.entry", new).status == 200

      # 3) incremental sync since the token → only the new entry, NOT the old one
      inc =
        call(
          :get,
          "/_matrix/client/v3/sync?since=#{URI.encode_www_form(since)}",
          nil,
          auth(token)
        )

      assert inc.status == 200
      by_type = account_data_by_type(json(inc))

      assert by_type["m.new.entry"] == new
      refute Map.has_key?(by_type, "m.old.entry"),
             "unchanged entry must be omitted from incremental sync, got: #{inspect(Map.keys(by_type))}"
    end
  end
end
