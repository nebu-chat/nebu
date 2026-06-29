defmodule Nebu.Web.SyncConcurrentTest do
  @moduledoc """
  RED-phase ATDD test for `matrix-api-migration` AC2 (BEAM-native fan-out).

  AC2: Given 50 Matrix clients with concurrent `/sync` long-polling connections,
       When a message is sent to a shared room,
       Then all 50 clients receive the event within 500ms (no Go→Elixir gRPC hop).

  Each of the 50 clients is a DISTINCT user (distinct OIDC subject → distinct
  bearer token → distinct provisioned user row and per-user since-token), all
  joined to one shared room. Each client is a BEAM Task that calls the Elixir
  router's `GET /_matrix/client/v3/sync` long-poll directly (`Plug.Test`). When a
  single `PUT .../send/m.room.message/{txnId}` is issued, the broadcast travels
  through `:pg` process groups straight to the 50 sync tasks — entirely inside
  the BEAM, no serialization across a gRPC boundary.

  ## Why it MUST FAIL now

  The protected sub-router currently has only a `/client/v3/sync` *stub* that
  returns `{"user_id", "next_batch":"s0"}` immediately — it does not subscribe to
  the room's `:pg` group and does not long-poll. So the message a client sends is
  never delivered into the waiting syncs: no sync response will contain the event,
  and the assertion that all 50 observe it within the 500ms budget fails.

  ## Determinism

  No fixed `sleep`. Each client's sync is `Task.async` with the long-poll itself
  providing the event-arrival signal. We `Task.await` each task with an explicit
  per-task budget derived from a single 500ms wall-clock deadline measured from
  the moment the message is sent. The budget assertion is what proves the timing
  property (AC2), not a hard wait.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  @clients 50
  @budget_ms 500

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "sync-concurrent-key-1"

  @router_opts Nebu.Web.Router.init([])

  setup do
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

    on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    {:ok, priv_jwk: priv_jwk}
  end

  defp bearer(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(@router_opts)
  end

  test "50 concurrent /sync long-polls all receive a sent event within 500ms (AC2)",
       %{priv_jwk: priv_jwk} do
    owner_token = bearer("owner", priv_jwk)

    # 1. Owner creates the shared room.
    create =
      call(:post, "/_matrix/client/v3/createRoom", %{"name" => "fanout-room"}, owner_token)

    assert create.status == 200, "createRoom must succeed to set up the fan-out scenario"
    room_id = Jason.decode!(create.resp_body)["room_id"]
    encoded_room = URI.encode_www_form(room_id)

    # 2. Build 50 DISTINCT Matrix clients (MINOR-5b): 50 separate users, each with
    #    its own OIDC subject → its own bearer token → its own provisioned
    #    user row and per-user since-token. This genuinely models "50 Matrix
    #    clients" (AC2) and exercises the per-user since-token path 50× over,
    #    rather than one user/device fanned out 50 times. Each client joins the
    #    shared room so the single send broadcasts to all 50 :pg subscribers.
    client_tokens =
      for i <- 1..@clients do
        token = bearer("client-#{i}", priv_jwk)

        join = call(:post, "/_matrix/client/v3/join/#{encoded_room}", %{}, token)

        assert join.status == 200,
               "client-#{i} must join the shared room to set up the fan-out scenario"

        token
      end

    # 3. Obtain a baseline since_token per client via an initial (immediate) sync
    #    so each client long-polls for events AFTER this point. Tokens are
    #    per-user, so each baseline is independent.
    client_since =
      Map.new(client_tokens, fn token ->
        base = call(:get, "/_matrix/client/v3/sync", nil, token)
        assert base.status == 200
        {token, Jason.decode!(base.resp_body)["next_batch"]}
      end)

    # 4. Spawn 50 concurrent long-poll sync clients, each as a distinct user
    #    subscribed to the room via its own since_token. They block until the
    #    event arrives or the long-poll times out (the real handler subscribes to
    #    :pg "room:<id>").
    sync_tasks =
      for token <- client_tokens do
        since = Map.fetch!(client_since, token)

        Task.async(fn ->
          call(
            :get,
            "/_matrix/client/v3/sync?since=#{since}&timeout=#{@budget_ms * 8}",
            nil,
            token
          )
        end)
      end

    # 4. Send ONE message and start the 500ms budget clock from this instant.
    sent_at = System.monotonic_time(:millisecond)

    send_conn =
      call(
        :put,
        "/_matrix/client/v3/rooms/#{encoded_room}/send/m.room.message/fanout-txn",
        %{"msgtype" => "m.text", "body" => "fan-out-payload"},
        owner_token
      )

    assert send_conn.status == 200
    event_id = Jason.decode!(send_conn.resp_body)["event_id"]

    # 6. Collect every sync result, then assert the timing property.
    #
    #    IMPORTANT (MINOR-5a): Task.await's timeout here is NOT the 500ms gate.
    #    It is deliberately GENEROUS (`max(remaining, 50) + 200`, plus the long
    #    poll itself runs with timeout=@budget_ms*8) so a slow scheduler tick
    #    never makes await raise before the task has a chance to return. The
    #    actual 500ms guarantee (AC2) is enforced purely by the post-hoc
    #    `elapsed <= @budget_ms` assertion below, measured from `sent_at`. We use
    #    a loose await purely to avoid a flaky :timeout exit; the real timing
    #    judgement is the wall-clock `elapsed` check. No fixed sleeps anywhere.
    results =
      Enum.map(sync_tasks, fn task ->
        remaining = @budget_ms - (System.monotonic_time(:millisecond) - sent_at)
        await_budget = max(remaining, 50) + 200
        Task.await(task, await_budget)
      end)

    elapsed = System.monotonic_time(:millisecond) - sent_at

    assert Enum.all?(results, fn conn -> conn.status == 200 end),
           "every concurrent /sync must return 200"

    saw_event? = fn conn ->
      String.contains?(conn.resp_body, event_id) or
        String.contains?(conn.resp_body, "fan-out-payload")
    end

    delivered = Enum.count(results, saw_event?)

    assert delivered == @clients,
           "all #{@clients} sync clients must receive the sent event; only #{delivered} did"

    assert elapsed <= @budget_ms,
           "all #{@clients} clients must receive the event within #{@budget_ms}ms (took #{elapsed}ms)"
  end
end
