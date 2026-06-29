defmodule Nebu.Matrix.DeviceStoreTest do
  @moduledoc """
  RED-phase acceptance tests for story S1 "Device registry model"
  (epic: device-management).

  S1 makes a device a FIRST-CLASS entity (a `devices` table, migration 000010)
  with its own identity + metadata, separate from the optional `device_keys`
  crypto blob it may publish. A device must be listable/manageable even when the
  client never uploads E2EE device keys (a "keyless" device).

  These tests are written FIRST and are expected to FAIL against the current
  codebase, which:
    * has NO `devices` table (only `device_keys`, migration 000009), and
    * has NO `Nebu.Matrix.DeviceKeyStore.upsert_device/3` function.

  They reference the not-yet-existing `upsert_device/3` and assert the keyless
  device appears via `list_devices/1`, `get_device/2`, and `GET /devices` while
  being EXCLUDED from `query_devices/1` (Matrix /keys/query semantics: only
  devices with published keys appear).

  The store API (per AC3 / story Dev Notes) stays in ONE module —
  `Nebu.Matrix.DeviceKeyStore` — to which S1 adds `upsert_device/3`.

  Helper patterns (setup_oidc_keys/0, bearer_for/2, call/4, json/1, auth/1,
  device_keys_obj/2) mirror Nebu.Web.DeviceKeysTest so the contract is
  expressed identically across both suites.

  DB-touching scenarios are `:integration`, `async: false`, and gated on
  `Process.whereis(Nebu.Repo)` exactly like device_keys_test.exs.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.DeviceKeyStore

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "device-store-test-key-1"
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

  # ════════════════════════════════════════════════════════════════════════
  # T1 — Keyless device: identity exists in `devices` without any key upload.
  #
  #   RED: DeviceKeyStore.upsert_device/3 does not exist yet, and there is no
  #   `devices` table to back it — so a device only ever appears once keys are
  #   uploaded. This test demands the opposite (AC1 + AC3 + AC4).
  # ════════════════════════════════════════════════════════════════════════

  describe "AC1/AC3/AC4: keyless device via upsert_device/3 (integration)" do
    @describetag :integration

    setup do
      _priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      uid = "@dev-store-keyless-#{n}:#{@server_name}"
      {:ok, user_id: uid, device_id: "KEYLESS#{n}"}
    end

    test "upsert_device + no key upload: list_devices includes it, query_devices does NOT",
         %{user_id: uid, device_id: device_id} do
      if Process.whereis(Nebu.Repo) do
        # AC3: device identity is created WITHOUT any crypto-key upload.
        # (upsert_device/3 does not exist yet → this call raises → RED.)
        :ok = DeviceKeyStore.upsert_device(uid, device_id, display_name: "Phone")

        # AC4: a KEYLESS device is listed with its display_name.
        devices = DeviceKeyStore.list_devices(uid)
        ids = Enum.map(devices, & &1["device_id"])

        assert device_id in ids,
               "list_devices/1 must include the keyless device #{device_id} (sourced from `devices`)"

        listed = Enum.find(devices, &(&1["device_id"] == device_id))
        assert listed["display_name"] == "Phone"

        # AC4: get_device/2 returns the keyless device too.
        got = DeviceKeyStore.get_device(uid, device_id)
        assert is_map(got)
        assert got["device_id"] == device_id
        assert got["display_name"] == "Phone"

        # AC3: query_devices/1 (Matrix /keys/query) MUST omit a device with no
        # published keys — joins devices+device_keys, only key-bearing devices.
        q = DeviceKeyStore.query_devices([uid])

        refute match?(%{^uid => %{^device_id => _}}, q),
               "query_devices/1 must EXCLUDE a keyless device (no published keys)"

        # MINOR-3: upsert_device/3 is idempotent — calling it again with a CHANGED
        # display_name UPDATES the same row rather than inserting a duplicate.
        :ok = DeviceKeyStore.upsert_device(uid, device_id, display_name: "Phone 2")

        again = DeviceKeyStore.list_devices(uid)

        assert Enum.count(again, &(&1["device_id"] == device_id)) == 1,
               "a second upsert_device/3 must not duplicate the (user_id, device_id) row"

        updated = Enum.find(again, &(&1["device_id"] == device_id))
        assert updated["display_name"] == "Phone 2", "the changed display_name must be applied"
      else
        # DB-less unit container: integration-only assertion, nothing to do.
        assert true
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # T2 — Key upload upserts the device row first (AC2).
  #
  #   RED: today a device exists ONLY inside device_keys, there is no separate
  #   `devices` row for get_device/2 to read. After S1, /keys/upload must upsert
  #   the `devices` row, so get_device/2 (reading `devices`) returns it AND
  #   query_devices/1 echoes the published keys.
  # ════════════════════════════════════════════════════════════════════════

  describe "AC2: /keys/upload upserts the devices row (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("dev-store-upload-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "DS Upload", "ds-up@example.com")
      end

      {:ok, user_id: uid, token: token, device_id: "DEV2_#{n}"}
    end

    test "uploading device_keys creates a `devices` row and query_devices echoes it",
         %{user_id: uid, token: token, device_id: device_id} do
      if Process.whereis(Nebu.Repo) do
        dk = device_keys_obj(uid, device_id)

        up =
          call(
            :post,
            "/_matrix/client/v3/keys/upload",
            %{"device_keys" => dk},
            auth(token)
          )

        assert up.status == 200

        # AC2: a `devices` row now exists for the uploaded device. get_device/2
        # reads device IDENTITY from `devices` (not from device_keys).
        got = DeviceKeyStore.get_device(uid, device_id)
        assert is_map(got), "uploading keys must upsert a `devices` row for #{device_id}"
        assert got["device_id"] == device_id

        # AC3: query_devices/1 echoes the published-key device.
        q = DeviceKeyStore.query_devices([uid])
        assert get_in(q, [uid, device_id, "keys"]) == dk["keys"]
      else
        assert true
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # T3 — Backfill: a pre-existing device_keys row (Stackit ran 000009 before
  #      this migration) becomes a `devices` row carrying display_name/created_at.
  #
  #   The migration runs once at stack boot, so we exercise the SAME outcome via
  #   the store/HTTP path: a device_keys row whose device must be visible in the
  #   `devices`-sourced surfaces. We seed a device_keys row DIRECTLY (mirroring a
  #   row written by the shipped 000009) and assert the device-identity surfaces
  #   reflect it. This is the practical ExUnit expression of the backfill (a
  #   pure-migration assertion is impractical here — documented choice).
  #
  #   RED: get_device/2 / list_devices/1 will be re-sourced from `devices`; until
  #   the migration + backfill exist, the seeded row has no `devices` counterpart.
  # ════════════════════════════════════════════════════════════════════════

  describe "AC1: backfill pre-existing device_keys → devices (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("dev-store-backfill-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "DS Backfill", "ds-bf@example.com")
      end

      {:ok, user_id: uid, token: token, device_id: "PRE009_#{n}"}
    end

    test "a directly-seeded device_keys row is reflected in `devices`-sourced surfaces",
         %{user_id: uid, token: token, device_id: device_id} do
      if Process.whereis(Nebu.Repo) do
        now = System.system_time(:millisecond)
        dk = device_keys_obj(uid, device_id)
        display_name = "Pre-Existing Laptop"

        # Simulate a row written by the SHIPPED 000009 migration: a device_keys
        # row that exists with NO corresponding `devices` row (the state of a
        # Stackit DB before 000010 backfills).
        {:ok, _} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            """
            INSERT INTO device_keys
              (user_id, device_id, device_keys_json, display_name, last_seen_ts, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $6)
            ON CONFLICT (user_id, device_id) DO NOTHING
            """,
            [uid, device_id, Jason.encode!(dk), display_name, now, now]
          )

        # The 000010 migration's backfill ran once at stack boot, BEFORE this test seeded the
        # device_keys row above — so we cannot rely on that boot-time backfill to cover a row
        # inserted now. Instead we exercise the SAME idempotent backfill statement that the
        # 000010 up-migration ships, which is the practical ExUnit expression of "the backfill
        # path is exercised" from the story's T3 (a real second migration run is impractical in
        # a single live test VM). This is byte-for-byte the migration's backfill SQL.
        {:ok, _} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            """
            INSERT INTO devices (user_id, device_id, display_name, last_seen_ts, created_at, updated_at)
            SELECT user_id, device_id, display_name, last_seen_ts, created_at, updated_at
            FROM device_keys
            WHERE user_id = $1 AND device_id = $2
            ON CONFLICT (user_id, device_id) DO NOTHING
            """,
            [uid, device_id]
          )

        # AC1: after backfill the device IDENTITY surfaces (sourced from
        # `devices`) must reflect the pre-existing row, carrying display_name.
        got = DeviceKeyStore.get_device(uid, device_id)
        assert is_map(got), "backfill must produce a `devices` row for pre-existing #{device_id}"
        assert got["device_id"] == device_id
        assert got["display_name"] == display_name

        # AC4: GET /devices lists the backfilled device.
        conn = call(:get, "/_matrix/client/v3/devices", nil, auth(token))
        assert conn.status == 200
        ids = Enum.map(json(conn)["devices"], & &1["device_id"])
        assert device_id in ids, "GET /devices must list the backfilled device #{device_id}"

        # MINOR-1: assert the backfill guarantee is REAL at the SQL level — for THIS user no
        # device_keys row is an orphan (every (user_id, device_id) in device_keys has a matching
        # `devices` row). 000010 backfills existing rows; put_device_keys upserts the devices row
        # first for new ones. Scoped to this test's user so leftover seed data from other suites/
        # runs (which may seed device_keys directly) can't make this assertion flaky.
        {:ok, %{rows: [[orphans]]}} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            """
            SELECT count(*)::int
            FROM device_keys dk
            LEFT JOIN devices d USING (user_id, device_id)
            WHERE dk.user_id = $1 AND d.user_id IS NULL
            """,
            [uid]
          )

        assert orphans == 0,
               "every device_keys row for #{uid} must have a matching devices row (backfill invariant); found #{orphans} orphan(s)"
      else
        assert true
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # T4 — New behavior regression marker: GET /devices lists a KEYLESS device.
  #
  #   We do NOT duplicate device_keys_test.exs. The single NEW contract worth
  #   locking at the HTTP layer is that a device created via upsert_device/3 with
  #   NO key upload still appears in GET /devices (AC4) — the behavior the old
  #   device_keys-only model could not express.
  #
  #   RED: upsert_device/3 does not exist; GET /devices is sourced from
  #   device_keys, so a keyless device is invisible there today.
  # ════════════════════════════════════════════════════════════════════════

  describe "AC4: GET /devices lists a KEYLESS device (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      n = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("dev-store-http-keyless-#{n}", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "DS HTTP Keyless", "ds-hk@example.com")
      end

      {:ok, user_id: uid, token: token, device_id: "HTTPKEYLESS#{n}"}
    end

    test "a device created via upsert_device/3 (no key upload) appears in GET /devices",
         %{user_id: uid, token: token, device_id: device_id} do
      if Process.whereis(Nebu.Repo) do
        # Create the device IDENTITY only — no /keys/upload at all.
        # (upsert_device/3 does not exist yet → RED.)
        :ok = DeviceKeyStore.upsert_device(uid, device_id, display_name: "Tablet")

        conn = call(:get, "/_matrix/client/v3/devices", nil, auth(token))
        assert conn.status == 200

        device =
          json(conn)["devices"]
          |> Enum.find(&(&1["device_id"] == device_id))

        assert is_map(device),
               "GET /devices must list the keyless device #{device_id} (sourced from `devices`)"

        # display_name present (set above); spec omits it when unset, never null.
        assert device["display_name"] == "Tablet"
        refute Map.has_key?(device, "display_name") and is_nil(device["display_name"]),
               "display_name must be omitted (never null) when unset (Matrix Device shape)"

        # MINOR-2: GET /devices/{deviceId} for the SAME keyless device → 200 with shape
        # parity to the list entry (AC4: single-device endpoint also sourced from `devices`).
        single = call(:get, "/_matrix/client/v3/devices/#{device_id}", nil, auth(token))
        assert single.status == 200,
               "GET /devices/{deviceId} must return 200 for a keyless device"

        assert json(single) == device,
               "GET /devices/{deviceId} must match the GET /devices list entry shape"
      else
        assert true
      end
    end
  end
end
