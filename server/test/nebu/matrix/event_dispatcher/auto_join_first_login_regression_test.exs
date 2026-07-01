defmodule Nebu.Matrix.EventDispatcher.AutoJoinFirstLoginRegressionTest do
  @moduledoc """
  Regression test for bugfix "Autojoin funktioniert nicht" (2026-07-01).

  ## Confirmed root cause

  `POST /_matrix/client/v3/login` (`Nebu.Matrix.HttpPublic.do_login/1`) — the ONLY
  entry point a real Matrix client (Element Web, FluffyChat, curl against the CS
  API, ...) uses to authenticate — calls
  `Nebu.Matrix.Session.TokenValidator.validate/4` DIRECTLY and then responds. It
  NEVER called `Nebu.Matrix.EventDispatcher.Server.validate_token/2`.

  The personal-room-creation + auto-join-room/space `Task.start` trigger lived
  EXCLUSIVELY inside `EventDispatcher.Server.validate_token/2` — a function that,
  per a full-repo grep (`grep -rn "EventDispatcher.Server.validate_token"
  server/lib/`), has NO production caller at all. It is only ever invoked directly
  by unit tests (see `auto_join_rooms_test.exs`, `auto_join_spaces_test.exs`,
  etc.), which is why all of those tests were green while the feature was
  completely broken for real users: they never exercised the real HTTP `/login`
  route, only the orphaned gRPC-shaped handler function in isolation.

  This test reproduces the bug the way the reporting user hit it: a genuinely
  brand-new user (never seen before, no pre-provisioning in `setup/0`) performs a
  real `POST /_matrix/client/v3/login` against the actual `Nebu.Web.Router`, with
  a real Postgres-backed `rooms` row carrying `is_auto_join = true, status =
  'active'`. Before the fix: `room_members` never gains a row for this user for
  the auto-join room, because the real login path never called
  `ensure_auto_join_memberships/1`. After the fix: `HttpPublic.provision_and_respond/6`
  calls the shared `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2`
  entry point, exactly mirroring what `validate_token/2` already did — so the
  brand-new user is auto-joined.

  Tagged `:integration` — requires a live Postgres (`NEBU_DB_URL`) and the real
  Application supervision tree (Horde room supervisor, `:pg` scope). Run via
  `make test-integration` / `make test-integration-elixir`.

  No `Process.sleep` timing hack: the fire-and-forget auto-join `Task.start` is
  observed by joining the room's real `:pg` broadcast group (`"room:\#{room_id}"`)
  BEFORE triggering login, then `assert_receive/2`-ing the `m.room.member` /
  `"join"` event that `Nebu.Matrix.Room.Server`'s `join/2` handler broadcasts
  AFTER it has durably written the `room_members` row
  (`emit_membership_event/3` in `server.ex`, called only after
  `db_module().insert_member/2` returns `:ok`). This is the exact production
  wake-up mechanism `/sync` long-polling already relies on — no polling loop, no
  arbitrary timing guess, and it fails fast via `assert_receive`'s built-in
  timeout when the join never happens (the pre-fix state).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  @server_name "test.local"
  @issuer "https://idp.example.com/realms/nebu"
  @audience "nebu-client"
  @kid "autojoin-first-login-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  @auto_join_room_id "!autojoin-regression-room:test.local"

  defp fresh_sub, do: "ajfl" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp future_exp, do: System.system_time(:second) + 3600

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      # No live Postgres in this run (plain `mix test`, NEBU_DB_URL unset) — the
      # :integration tag already excludes this from `mix test` by default
      # (test_helper.exs), but guard defensively in case someone force-includes it.
      :ok
    else
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

      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => @issuer,
        "authorization_endpoint" => @authorize,
        "token_endpoint" => @token_endpoint,
        "jwks_uri" => @issuer <> "/jwks"
      })

      prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      sub = fresh_sub()
      user_id = "@" <> sub <> ":" <> @server_name

      # GIVEN: a real auto-join room exists in Postgres (is_auto_join=true,
      # status='active') — exactly the admin-configured state from the bug report.
      now_ms = System.system_time(:millisecond)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          """
          INSERT INTO rooms (room_id, name, visibility, created_at, is_auto_join, status)
          VALUES ($1, 'Autojoin Regression Room', 'private', $2, true, 'active')
          ON CONFLICT (room_id) DO UPDATE SET is_auto_join = true, status = 'active'
          """,
          [@auto_join_room_id, now_ms]
        )

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          _ =
            Ecto.Adapters.SQL.query(
              Nebu.Repo,
              "DELETE FROM room_members WHERE room_id = $1 AND user_id = $2",
              [@auto_join_room_id, user_id]
            )

          for table <- ["device_one_time_keys", "device_keys", "devices", "matrix_sessions", "profiles", "users"] do
            _ =
              Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM #{table} WHERE user_id = $1", [user_id])
          end
        end

        Nebu.Web.OidcTestSupport.clear()

        for k <- [:server_name, :oidc_jwks, :oidc_metadata_override] do
          Application.delete_env(:nebu_http, k)
        end

        case prev_rl do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end
      end)

      {:ok, priv_jwk: priv_jwk, user_id: user_id, sub: sub}
    end
  end

  defp sign_id_token(priv_jwk, sub) do
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
    compact
  end

  defp call(method, path, body) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Message-passing sync anchor: after the fix, ensure_auto_join_memberships/1
  # starts the room's GenServer (Nebu.Matrix.Room.RoomSupervisor.start_room/1)
  # before calling join/2, so the room process — and its :pg group — is
  # guaranteed to exist once this returns. Joining the group BEFORE triggering
  # login means the test process is guaranteed to observe the join broadcast
  # (no race between "start the room" and "subscribe").
  defp join_room_broadcast_group(room_id) do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
    :pg.join("room:#{room_id}", self())
  end

  describe "regression: brand-new user's first login via the real POST /login route" do
    test "is auto-joined to an is_auto_join=true, status=active room", %{
      priv_jwk: priv,
      user_id: user_id,
      sub: sub
    } do
      if Process.whereis(Nebu.Repo) do
        # Precondition: this user has genuinely never logged in before.
        {:ok, %{rows: pre_rows}} =
          Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT 1 FROM users WHERE user_id = $1", [user_id])

        assert pre_rows == [],
          "test setup invariant violated: #{user_id} must not already exist (fresh_sub/0 collision?)"

        # Subscribe to the auto-join room's :pg broadcast group BEFORE login, so
        # we cannot miss the join broadcast to a race.
        join_room_broadcast_group(@auto_join_room_id)

        id_token = sign_id_token(priv, sub)

        # WHEN: the real Matrix client login flow happens — exactly what Element
        # Web / FluffyChat / any CS-API client does on first login.
        resp =
          call(:post, "/_matrix/client/v3/login", %{
            "type" => "m.login.token",
            "token" => id_token
          })

        assert resp.status == 200,
          "first login must succeed (got #{resp.status}: #{resp.resp_body})"

        body = json(resp)
        assert body["user_id"] == user_id

        # THEN: the user must actually be auto-joined to the room — observed via
        # the real m.room.member "join" event broadcast that Room.Server emits
        # ONLY after the room_members row is durably written (emit_membership_event/3
        # runs after db_module().insert_member/2 returns :ok). Before the fix: this
        # message is NEVER received — POST /login never triggered
        # ensure_auto_join_memberships/1 at all (validate_token/2 has no caller).
        assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^user_id,
                          "content" => %{"membership" => "join"}}},
                        2_000,
                        "REGRESSION: #{user_id}'s first login via the real POST /_matrix/client/v3/login " <>
                          "route did not result in an m.room.member join broadcast for the auto-join room " <>
                          "#{@auto_join_room_id} within 2s. The real login path " <>
                          "(Nebu.Matrix.HttpPublic.do_login/1) must trigger the same post-login " <>
                          "auto-join provisioning as EventDispatcher.Server.validate_token/2."

        # Defense-in-depth: don't rely solely on the :pg broadcast. Directly
        # confirm the row was durably written to Postgres, in case a future
        # change to Room.Server ever reorders "broadcast" ahead of "durable
        # write" (emit_membership_event/3 is documented to run only after
        # db_module().insert_member/2 returns :ok — assert that invariant here
        # too, independently of the message-passing observation above).
        {:ok, %{rows: member_rows}} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "SELECT 1 FROM room_members WHERE room_id = $1 AND user_id = $2",
            [@auto_join_room_id, user_id]
          )

        assert member_rows == [[1]],
          "REGRESSION: room_members has no durable row for #{user_id} in " <>
            "#{@auto_join_room_id} even though a join broadcast was observed — " <>
            "the :pg broadcast and the durable write have diverged."
      end
    end
  end
end
