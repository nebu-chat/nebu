defmodule Nebu.Web.CrossSigningTest do
  @moduledoc """
  Acceptance tests (RED phase) for cross-signing key read-back
  (story: cross-signing-readback). These lock in the Matrix CS API v1.18
  cross-signing contract that makes Element show verified cross-signing state
  WITHOUT activating E2EE (ADR-011):

      POST /_matrix/client/v3/keys/device_signing/upload — persists
            master_key + self_signing_key + user_signing_key (opaque objects)
      POST /_matrix/client/v3/keys/query — ECHOES the stored cross-signing
            keys in master_keys / self_signing_keys / user_signing_keys
      POST /_matrix/client/v3/keys/signatures/upload — merges supplied
            signatures into the stored key object's `signatures` map
      GET  /_matrix/client/v3/sync — after device_signing/upload, the
            uploader's own ID appears in device_lists.changed on the next
            incremental sync
      PUT  /rooms/{id}/state/m.room.encryption — 403 (guardrail, ADR-011)

  The cross-signing directory is PostgreSQL-backed (cluster-correct per
  ADR-020: upload and query may land on different nodes), so the round-trip /
  echo / signature-merge / sync / durability tests are `:integration`.
  Pure rejection paths that reject before any DB call run in the DB-less unit
  layer.

  Written FIRST (red) — today keys/query returns hardcoded empty cross-signing
  maps and device_signing/upload + signatures/upload are no-op stubs, and
  Nebu.Matrix.CrossSigningKeyStore does not exist yet.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "cross-signing-test-key-1"
  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirror device_keys_test.exs) ───────────────────────────

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

  # ── cross-signing fixtures (opaque base64 strings — server never verifies) ──

  defp master_key(uid, pub \\ "MASTERpub0000000000000000000000000000000000") do
    %{
      "user_id" => uid,
      "usage" => ["master"],
      "keys" => %{"ed25519:#{pub}" => pub}
    }
  end

  defp self_signing_key(uid, pub \\ "SSKpub00000000000000000000000000000000000000") do
    %{
      "user_id" => uid,
      "usage" => ["self_signing"],
      "keys" => %{"ed25519:#{pub}" => pub},
      "signatures" => %{
        uid => %{
          "ed25519:MASTERpub0000000000000000000000000000000000" =>
            "MSKsigOverSSK0000000000000000000000000000000000000000000000000000000000000000000000000000"
        }
      }
    }
  end

  defp user_signing_key(uid, pub \\ "USKpub00000000000000000000000000000000000000") do
    %{
      "user_id" => uid,
      "usage" => ["user_signing"],
      "keys" => %{"ed25519:#{pub}" => pub},
      "signatures" => %{
        uid => %{
          "ed25519:MASTERpub0000000000000000000000000000000000" =>
            "MSKsigOverUSK0000000000000000000000000000000000000000000000000000000000000000000000000000"
        }
      }
    }
  end

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

  defp signing_upload_body(uid) do
    %{
      "master_key" => master_key(uid),
      "self_signing_key" => self_signing_key(uid),
      "user_signing_key" => user_signing_key(uid)
    }
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC7 — ADR-011 regression: cross-signing must NOT enable encryption (no DB)
  # ════════════════════════════════════════════════════════════════════════

  describe "E2EE guardrail — m.room.encryption is forbidden (no DB)" do
    setup do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("xs-e2ee-guard", priv)
      {:ok, token: token}
    end

    test "AC7: PUT .../state/m.room.encryption → 403 M_FORBIDDEN", %{token: token} do
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
  end

  # ════════════════════════════════════════════════════════════════════════
  # Cross-signing directory — INTEGRATION (PostgreSQL-backed, needs OTP tree)
  # ════════════════════════════════════════════════════════════════════════

  describe "device_signing/upload + keys/query echo (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("xs-echo-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "XS Echo", "xse@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC1: upload master+self+user signing keys → 200 {}, then keys/query echoes all three",
         %{user_id: uid, token: token} do
      up =
        call(
          :post,
          "/_matrix/client/v3/keys/device_signing/upload",
          signing_upload_body(uid),
          auth(token)
        )

      assert up.status == 200
      assert json(up) == %{}

      q =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{uid => []}}, auth(token))

      assert q.status == 200
      body = json(q)

      assert body["master_keys"][uid] == master_key(uid)
      assert body["self_signing_keys"][uid] == self_signing_key(uid)
      assert body["user_signing_keys"][uid] == user_signing_key(uid)
    end

    test "AC3: keys/query for a user WITH cross-signing populates all three maps; device_keys behaviour unchanged",
         %{user_id: uid, token: token} do
      device_id = "XSDEV1"

      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => device_keys_obj(uid, device_id)},
          auth(token)
        )

      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/device_signing/upload",
          signing_upload_body(uid),
          auth(token)
        )

      q =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{uid => []}}, auth(token))

      assert q.status == 200
      body = json(q)

      # cross-signing maps populated
      assert body["master_keys"][uid] == master_key(uid)
      assert body["self_signing_keys"][uid] == self_signing_key(uid)
      assert body["user_signing_keys"][uid] == user_signing_key(uid)

      # device_keys echo unchanged
      device = body["device_keys"][uid][device_id]
      assert is_map(device)
      assert device["keys"] == device_keys_obj(uid, device_id)["keys"]
    end

    test "AC3: keys/query for a user WITHOUT cross-signing → empty cross-signing maps",
         %{token: token} do
      q =
        call(
          :post,
          "/_matrix/client/v3/keys/query",
          %{"device_keys" => %{"@xs-stranger:test.local" => []}},
          auth(token)
        )

      assert q.status == 200
      body = json(q)
      assert body["master_keys"] == %{}
      assert body["self_signing_keys"] == %{}
      assert body["user_signing_keys"] == %{}
    end
  end

  describe "device_signing/upload idempotency + overwrite protection (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("xs-idem-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "XS Idem", "xsi@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC2: first upload (no existing MSK) → plain 200 {} (no UIA)",
         %{user_id: uid, token: token} do
      up =
        call(
          :post,
          "/_matrix/client/v3/keys/device_signing/upload",
          signing_upload_body(uid),
          auth(token)
        )

      assert up.status == 200
      assert json(up) == %{}
    end

    test "AC2: idempotent re-upload of the SAME keys → 200 {} (no UIA)",
         %{user_id: uid, token: token} do
      body = signing_upload_body(uid)

      first = call(:post, "/_matrix/client/v3/keys/device_signing/upload", body, auth(token))
      assert first.status == 200

      second = call(:post, "/_matrix/client/v3/keys/device_signing/upload", body, auth(token))
      assert second.status == 200
      assert json(second) == %{}
    end

    test "AC2: overwriting existing DIFFERENT keys WITHOUT auth → 403 M_FORBIDDEN",
         %{user_id: uid, token: token} do
      first = call(:post, "/_matrix/client/v3/keys/device_signing/upload", signing_upload_body(uid), auth(token))
      assert first.status == 200

      different = %{
        "master_key" => master_key(uid, "MASTERpubDIFFERENT00000000000000000000000000"),
        "self_signing_key" => self_signing_key(uid, "SSKpubDIFFERENT0000000000000000000000000000"),
        "user_signing_key" => user_signing_key(uid, "USKpubDIFFERENT0000000000000000000000000000")
      }

      overwrite = call(:post, "/_matrix/client/v3/keys/device_signing/upload", different, auth(token))
      assert overwrite.status == 403
      assert json(overwrite)["errcode"] == "M_FORBIDDEN"
    end
  end

  describe "signatures/upload merge into stored device key (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("xs-sig-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "XS Sig", "xss@example.com")
      end

      {:ok, user_id: uid, token: token, device_id: "SIGDEV#{n}"}
    end

    test "AC4: signatures/upload merges a signature into a stored device key, visible in keys/query",
         %{user_id: uid, token: token, device_id: device_id} do
      dk = device_keys_obj(uid, device_id)

      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => dk},
          auth(token)
        )

      ssk_sig =
        "SSKsigOverDevice0000000000000000000000000000000000000000000000000000000000000000000000000000"

      signed_device =
        dk
        |> Map.put("signatures", %{
          uid => %{"ed25519:SSKpub00000000000000000000000000000000000000" => ssk_sig}
        })

      sig_up =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          %{uid => %{device_id => signed_device}},
          auth(token)
        )

      assert sig_up.status == 200
      assert json(sig_up) == %{"failures" => %{}}

      q =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{uid => []}}, auth(token))

      assert q.status == 200
      device = json(q)["device_keys"][uid][device_id]

      assert is_map(device)
      # merged: the new SSK signature is present...
      assert get_in(device, ["signatures", uid, "ed25519:SSKpub00000000000000000000000000000000000000"]) ==
               ssk_sig

      # ...and the original device self-signature is preserved.
      assert get_in(device, ["signatures", uid, "ed25519:#{device_id}"]) ==
               dk["signatures"][uid]["ed25519:#{device_id}"]
    end

    test "AC4: signatures/upload mismatch → 200 with M_INVALID_SIGNATURE in failures",
         %{user_id: uid, token: token, device_id: device_id} do
      dk = device_keys_obj(uid, device_id)

      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => dk},
          auth(token)
        )

      # Submitted object does NOT match the stored key (mismatched keys map).
      mismatched =
        dk
        |> Map.put("keys", %{"ed25519:#{device_id}" => "TAMPEREDdoesNotMatchStored00000000000000000"})
        |> Map.put("signatures", %{
          uid => %{"ed25519:SSKpub00000000000000000000000000000000000000" => "badsig"}
        })

      sig_up =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          %{uid => %{device_id => mismatched}},
          auth(token)
        )

      assert sig_up.status == 200
      body = json(sig_up)
      assert get_in(body, ["failures", uid, device_id, "errcode"]) == "M_INVALID_SIGNATURE"
    end

    # MAJOR-1 regression: the cross-signing signature merge must be validate-THEN-
    # persist. A submitted cross-signing object whose non-signatures parts differ from
    # the stored key must be rejected (M_INVALID_SIGNATURE) WITHOUT mutating the stored
    # `signatures` map — mirrors the device-key mismatch test above but targets a
    # cross-signing key_id.
    test "AC4: signatures/upload cross-signing-key mismatch → M_INVALID_SIGNATURE and stored signatures unchanged",
         %{user_id: uid, token: token} do
      # 1) store the user's cross-signing keys (master/self/user).
      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/device_signing/upload",
          signing_upload_body(uid),
          auth(token)
        )

      # The master key's key_id is the pub part of its single ed25519 entry.
      master = master_key(uid)
      master_key_id = "MASTERpub0000000000000000000000000000000000"

      # 2) target that cross-signing key_id but TAMPER the non-signatures parts
      #    (here: `usage`), and supply a new signature that must NOT be persisted.
      attempted_sig =
        "ATTEMPTEDsigShouldNotPersist0000000000000000000000000000000000000000000000000000000000000000"

      tampered =
        master
        |> Map.put("usage", ["self_signing"])
        |> Map.put("signatures", %{
          uid => %{"ed25519:SSKpub00000000000000000000000000000000000000" => attempted_sig}
        })

      sig_up =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          %{uid => %{master_key_id => tampered}},
          auth(token)
        )

      assert sig_up.status == 200
      body = json(sig_up)
      assert get_in(body, ["failures", uid, master_key_id, "errcode"]) == "M_INVALID_SIGNATURE"

      # 3) keys/query — the stored master key is unchanged and the attempted signature
      #    was NOT persisted (validate-then-persist held).
      q =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{uid => []}}, auth(token))

      assert q.status == 200
      stored_master = json(q)["master_keys"][uid]

      assert stored_master == master,
             "stored master key must be byte-for-byte unchanged after a rejected merge"

      refute get_in(stored_master, [
               "signatures",
               uid,
               "ed25519:SSKpub00000000000000000000000000000000000000"
             ]) == attempted_sig
    end
  end

  describe "device_signing/upload triggers device_lists.changed (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("xs-devlist-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "XS DevList", "xsd@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC5: after device_signing/upload, own user_id appears in device_lists.changed on next incremental sync",
         %{user_id: uid, token: token} do
      # 1) initial sync → grab a since token
      first = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert first.status == 200
      since = json(first)["next_batch"]
      assert is_binary(since)

      # 2) upload cross-signing keys
      up =
        call(
          :post,
          "/_matrix/client/v3/keys/device_signing/upload",
          signing_upload_body(uid),
          auth(token)
        )

      assert up.status == 200

      # 3) incremental sync since the token → own uid in device_lists.changed
      inc =
        call(
          :get,
          "/_matrix/client/v3/sync?since=#{URI.encode_www_form(since)}",
          nil,
          auth(token)
        )

      assert inc.status == 200
      changed = get_in(json(inc), ["device_lists", "changed"]) || []
      assert uid in changed, "expected #{uid} in device_lists.changed, got: #{inspect(changed)}"
    end
  end

  describe "device_signing/upload key-ID collision guard (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("xs-collide-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "XS Collide", "xsc@example.com")
      end

      {:ok, user_id: uid, token: token}
    end

    test "AC6: cross-signing key whose key ID collides with an existing device ID → 400 M_INVALID_PARAM, nothing persisted",
         %{user_id: uid, token: token} do
      device_id = "ABCDEF"

      # 1) register a device with id ABCDEF
      _ =
        call(
          :post,
          "/_matrix/client/v3/keys/upload",
          %{"device_keys" => device_keys_obj(uid, device_id)},
          auth(token)
        )

      # 2) attempt to upload a master_key whose key id is ed25519:ABCDEF
      colliding = %{
        "master_key" => %{
          "user_id" => uid,
          "usage" => ["master"],
          "keys" => %{"ed25519:#{device_id}" => "COLLIDINGpub000000000000000000000000000000"}
        }
      }

      up =
        call(
          :post,
          "/_matrix/client/v3/keys/device_signing/upload",
          colliding,
          auth(token)
        )

      assert up.status == 400
      assert json(up)["errcode"] == "M_INVALID_PARAM"

      # 3) nothing persisted — cross-signing maps still empty
      q =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{uid => []}}, auth(token))

      assert q.status == 200
      body = json(q)
      assert body["master_keys"][uid] == nil
      assert body["self_signing_keys"][uid] == nil
      assert body["user_signing_keys"][uid] == nil
    end
  end

  describe "CrossSigningKeyStore durability (integration)" do
    @describetag :integration

    test "Persistenz: put_keys then a fresh get_keys (no in-process cache) returns the keys" do
      if Process.whereis(Nebu.Repo) do
        uid = "@xs-durable-#{:erlang.unique_integer([:positive])}:test.local"

        keys = %{
          "master_key" => master_key(uid),
          "self_signing_key" => self_signing_key(uid),
          "user_signing_key" => user_signing_key(uid)
        }

        :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(uid, keys)

        # Read back from a SEPARATE process (a real process boundary): if the store
        # ever grew an in-process/ETS cache, a same-process read could mask a missing
        # Postgres row. Reading in a freshly-spawned Task forces the durable
        # (read-on-start, Postgres-backed) path — this is the Persistenz-Strategie =
        # PostgreSQL durability proof (CLAUDE.md "read-on-start test"), not a mere
        # round-trip. These :integration tests run against the live Repo pool (no
        # Ecto sandbox), so the spawned process reads the same committed row.
        result =
          Task.async(fn -> Nebu.Matrix.CrossSigningKeyStore.get_keys(uid) end)
          |> Task.await(5000)

        assert result["master_key"] == master_key(uid)
        assert result["self_signing_key"] == self_signing_key(uid)
        assert result["user_signing_key"] == user_signing_key(uid)
      else
        # DB-less unit container: nothing to assert (integration-only).
        assert true
      end
    end
  end
end
