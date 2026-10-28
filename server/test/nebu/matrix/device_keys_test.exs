defmodule Nebu.Web.DeviceKeysTest do
  @moduledoc """
  Acceptance tests for the stateful device-key directory (bugfix:
  fix-device-key-registration). These lock in the Matrix CS API v1.18 contract
  that makes Element register a device cleanly WITHOUT activating E2EE:

      POST /_matrix/client/v3/keys/upload  — persists device_keys + counts OTKs,
                                             returns real one_time_key_counts
      POST /_matrix/client/v3/keys/query   — echoes back stored device_keys
      GET  /_matrix/client/v3/devices      — lists the user's devices
      PUT  /rooms/{id}/state/m.room.encryption — 403 (guardrail, ADR-011)

  The directory is PostgreSQL-backed (cluster-correct per ADR-020: upload and
  query may land on different nodes), so the round-trip / list / durability
  tests are `:integration`. The E2EE guardrail rejects before any DB call, so
  it runs in the DB-less unit layer.

  Written FIRST (red) — the handlers are no-op stubs until implemented.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "device-keys-test-key-1"
  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirror matrix_client_compat_test.exs) ──────────────────

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

  defp device_keys_obj(uid, device_id) do
    %{
      "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
      "device_id" => device_id,
      "keys" => %{
        "curve25519:#{device_id}" => "3C5BFWi2Y8MaVvjM8M22DBmh24PmgR0nPvJOIArzgyI",
        "ed25519:#{device_id}" => "lEuiRJBit0IG6nUf5pUzWTUEsRVVe/HJkoKuEww9ULI"
      },
      "signatures" => %{
        uid => %{
          "ed25519:#{device_id}" =>
            "dSO80A01XiigH3uBiDVx/EjzaoycHcjq9lfQX0uWsqxl2giMIiSPR8a4d291W1ihKJL/a+myXS367WT6NAIcBA"
        }
      },
      "user_id" => uid
    }
  end

  defp otk(id) do
    {"signed_curve25519:#{id}",
     %{
       "key" => "j3fR3HemM16M7CWhoI4Sk5ZsdmdfQHsKL1xuSft6MS#{String.slice(id, 0, 1)}",
       "signatures" => %{"@x" => %{"ed25519:DEV" => "sig"}}
     }}
  end

  # ════════════════════════════════════════════════════════════════════════
  # E2EE guardrail — no DB (rejected before any Core call, ADR-011)
  # ════════════════════════════════════════════════════════════════════════

  describe "E2EE guardrail — m.room.encryption is forbidden (no DB)" do
    setup do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("e2ee-guard", priv)
      {:ok, token: token}
    end

    test "PUT .../state/m.room.encryption → 403 M_FORBIDDEN", %{token: token} do
      room = URI.encode_www_form("!room:test.local")

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{room}/state/m.room.encryption",
          %{"algorithm" => "m.megolm.v1.aes-sha2"},
          auth(token)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "PUT .../state/m.room.encryption/ (with state_key) → 403 M_FORBIDDEN", %{token: token} do
      room = URI.encode_www_form("!room:test.local")

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{room}/state/m.room.encryption/",
          %{"algorithm" => "m.megolm.v1.aes-sha2"},
          auth(token)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end
  end

  describe "/keys/upload per-request cap (no DB)" do
    setup do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("otk-cap", priv)
      {:ok, token: token}
    end

    test "upload with > 100 one_time_keys → 400 M_INVALID_PARAM (rejected before DB)", %{token: token} do
      many = Map.new(1..101, fn i -> otk("CAP#{i}") end)
      conn = call(:post, "/_matrix/client/v3/keys/upload", %{"one_time_keys" => many}, auth(token))
      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Stateful directory — INTEGRATION (PostgreSQL-backed, needs the OTP tree)
  # ════════════════════════════════════════════════════════════════════════

  describe "device-key directory round-trip (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("dk-user-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "DK User", "dk@example.com")
      end

      {:ok, user_id: uid, token: token, device_id: "DEV#{n}"}
    end

    test "AC1+AC2: upload device_keys + 5 OTKs, then query echoes the device",
         %{user_id: uid, token: token, device_id: device_id} do
      dk = device_keys_obj(uid, device_id)
      one_time_keys = Map.new(["AAA1", "AAA2", "AAA3", "AAA4", "AAA5"], &otk/1)

      up =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => dk, "one_time_keys" => one_time_keys},
          auth(token)
        )

      assert up.status == 200
      # AC1: counts reflect the 5 signed_curve25519 OTKs actually uploaded.
      assert json(up)["one_time_key_counts"]["signed_curve25519"] == 5

      q =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{uid => []}}, auth(token))

      assert q.status == 200
      body = json(q)

      device = body["device_keys"][uid][device_id]
      assert is_map(device), "query must echo back the uploaded device for #{uid}/#{device_id}"
      # AC2: returned object equals what was uploaded (keys/algorithms/signatures).
      assert device["keys"] == dk["keys"]
      assert device["algorithms"] == dk["algorithms"]
      assert device["user_id"] == uid
      assert device["device_id"] == device_id
      # AC2: plus an `unsigned` property (per spec; device_display_name optional).
      assert is_map(device["unsigned"])

      # Cross-signing maps + failures still present (empty) — no cross-signing.
      for key <- ~w(master_keys self_signing_keys user_signing_keys failures) do
        assert is_map(body[key])
      end
    end

    test "AC1: a second OTK-only upload accumulates the count",
         %{user_id: uid, token: token, device_id: device_id} do
      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => device_keys_obj(uid, device_id), "one_time_keys" => Map.new(["B1", "B2"], &otk/1)},
          auth(token)
        )

      up2 =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"one_time_keys" => Map.new(["B3", "B4", "B5"], &otk/1)},
          auth(token)
        )

      assert up2.status == 200
      # 2 + 3 = 5 unclaimed keys held for this device.
      assert json(up2)["one_time_key_counts"]["signed_curve25519"] == 5
    end

    test "AC2: query for an unknown user → empty device_keys, empty failures",
         %{token: token} do
      q =
        call(
          :post,
          "/_matrix/client/v3/keys/query",
          %{"device_keys" => %{"@stranger:test.local" => []}},
          auth(token)
        )

      assert q.status == 200
      body = json(q)
      assert body["device_keys"] == %{}
      assert body["failures"] == %{}
    end

    test "AC5: GET /devices lists the uploaded device",
         %{user_id: uid, token: token, device_id: device_id} do
      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => device_keys_obj(uid, device_id)},
          auth(token)
        )

      conn = call(:get, "/_matrix/client/v3/devices", nil, auth(token))
      assert conn.status == 200
      ids = Enum.map(json(conn)["devices"], & &1["device_id"])
      assert device_id in ids
    end

    test "AC5: GET /devices/{deviceId} for an unknown device → 404 M_NOT_FOUND", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/devices/NOPE_NO_SUCH_DEVICE", nil, auth(token))
      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
    end
  end

  describe "whoami device_id (integration, opaque session)" do
    @describetag :integration

    test "AC3: whoami returns device_id for an opaque session" do
      if Process.whereis(Nebu.Repo) do
        _priv = setup_oidc_keys()
        n = :erlang.unique_integer([:positive])
        uid = "@dk-whoami-#{n}:test.local"
        device_id = "WHOAMIDEV#{n}"
        at = Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token()

        :ok =
          Nebu.Matrix.Session.MatrixSessionStore.create(%{
            access_token: at,
            refresh_token: Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token(),
            user_id: uid,
            device_id: device_id,
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          })

        conn = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(at))
        assert conn.status == 200
        body = json(conn)
        assert body["user_id"] == uid
        assert body["device_id"] == device_id
      else
        assert true
      end
    end
  end

  describe "/sync OTK count (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("dk-sync-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "DK Sync", "dks@example.com")
      end

      {:ok, user_id: uid, token: token, device_id: "SYNCDEV#{n}"}
    end

    test "AC4: device_one_time_keys_count reflects uploaded OTKs",
         %{user_id: uid, token: token, device_id: device_id} do
      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{
            "device_keys" => device_keys_obj(uid, device_id),
            "one_time_keys" => Map.new(["S1", "S2", "S3"], &otk/1)
          },
          auth(token)
        )

      conn = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert conn.status == 200
      body = json(conn)
      # best-effort device resolution (JWT carries no device_id): single-device user → exact.
      assert body["device_one_time_keys_count"]["signed_curve25519"] == 3
      assert is_list(body["device_unused_fallback_key_types"])
    end
  end

  describe "E2EE guardrail — createRoom initial_state bypass (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("dk-enc-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "DK Enc", "dke@example.com")
      end

      {:ok, token: token}
    end

    test "AC6: createRoom with m.room.encryption in initial_state does NOT encrypt the room",
         %{token: token} do
      create =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{
            "name" => "enc-bypass-attempt",
            "initial_state" => [
              %{"type" => "m.room.encryption", "state_key" => "", "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}}
            ]
          },
          auth(token)
        )

      assert create.status == 200
      room_id = json(create)["room_id"]

      # The forbidden initial_state entry must have been skipped — no encryption state event.
      # story oauth-room-summary-unrecognized (af): changed deliberately. This used to probe
      # `GET /rooms/{id}/state/m.room.encryption`, which is NOT a routed endpoint (only the PUT state routes
      # exist): its former 404 was the router fall-through, so the check was vacuous (and RU11a keeps that
      # 404 M_NOT_FOUND until follow-up bf implements the GET). The assertion reads the persisted events
      # instead, with a positive control: the SAME query finds the room's m.room.create row.
      count_events = fn type ->
        %{rows: [[n]]} =
          Ecto.Adapters.SQL.query!(
            Nebu.Repo,
            "SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2",
            [room_id, type]
          )

        n
      end

      assert count_events.("m.room.create") >= 1, "positive control: the query must see the room's create event"
      encryption_events = count_events.("m.room.encryption")
      assert encryption_events == 0, "room must not carry m.room.encryption (got #{encryption_events} events)"
    end
  end

  describe "DeviceKeyStore durability (integration)" do
    @describetag :integration

    test "AC7: persisted device_keys survive a fresh read (no in-process cache)" do
      if Process.whereis(Nebu.Repo) do
        uid = "@dk-durable-#{:erlang.unique_integer([:positive])}:test.local"
        device_id = "DURABLE1"
        dk = device_keys_obj(uid, device_id)

        :ok = Nebu.Matrix.DeviceKeyStore.put_device_keys(uid, device_id, dk)

        # Fresh query path (no caller-held state) — mirrors a different node / restart.
        result = Nebu.Matrix.DeviceKeyStore.query_devices([uid])
        assert get_in(result, [uid, device_id, "keys"]) == dk["keys"]
      else
        # DB-less unit container: nothing to assert (integration-only).
        assert true
      end
    end
  end
end
