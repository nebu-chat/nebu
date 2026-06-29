defmodule Nebu.Web.RegressionSyncLoadTest do
  @moduledoc """
  RED-phase ATDD load + latency test for the `elixir-stack-regression` GATE story
  (epic full-elixir-stack), AC7.

  AC7: Given 200 concurrent `/sync` long-polling clients on a shared room,
       When 50 `m.room.message` events are broadcast over the run,
       Then median event-delivery latency is <= 150ms (BEAM-native, no gRPC hop)
       AND zero events are dropped (all 200 x 50 = 10_000 deliveries are received).

  This is the pure-Elixir-stack baseline: every `/sync` long-poll is served by the
  Elixir router (`Plug.Test`), and each broadcast travels through `:pg` process groups
  straight to the waiting sync tasks — entirely inside the BEAM.

  ## Why it MUST FAIL in the red phase

  The same reason as `sync_concurrent_test.exs`: until the protected `/client/v3/sync`
  handler actually subscribes to the room's `:pg` group and long-polls, the broadcast a
  client sends is never delivered into the waiting syncs — so deliveries are dropped and
  the zero-drop assertion fails. Once the real fan-out lands, the suite measures the
  latency baseline.

  ## Determinism / measurement (no Process.sleep as a substitute)

  Each of the 50 messages is its OWN measurement round:
    1. capture a per-client baseline since-token,
    2. spawn 200 long-poll sync tasks,
    3. record `t0 = System.monotonic_time(:millisecond)` and send ONE message,
    4. `Task.await` each task; the latency for that client/round is
       `t_received - t0` where `t_received` is captured the instant the task's
       long-poll returns (the long-poll itself is the arrival signal — no fixed sleep).
  Latencies from all 10_000 deliveries are pooled; we assert `median <= 150ms` and that
  exactly 10_000 deliveries observed the event (zero drops). `Task.await`'s timeout is a
  generous failsafe against scheduler jitter, NOT the latency gate — the gate is the
  post-hoc median over measured `t_received - t0` values.

  Tagged `:integration` so it is excluded from the default `mix test` run
  (test_helper.exs sets `exclude: [:integration]`) and runs only under the
  integration profile (e.g. `make test-integration` / `--include integration`).
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  # AC7 scale. Kept as module attributes so the intent is explicit and the 10_000
  # total-deliveries figure is derived, never hard-coded in two places.
  @clients 200
  @messages 50
  @median_budget_ms 150

  # Generous per-await failsafe: NOT the latency gate (that is the median assertion).
  @await_budget_ms 30_000
  # Long-poll server-side timeout per round — comfortably larger than the budget so a
  # slow scheduler tick never times the long-poll out before the event is delivered.
  @longpoll_timeout_ms 10_000

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "regression-sync-load-key-1"

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

    # This is a load test: 200 concurrent /sync requests come from the same
    # in-process peer (127.0.0.1), which the per-IP rate limiter would 429. The
    # test exercises sync throughput, not rate limiting — disable it here.
    # (make test-integration sets NEBU_RATE_LIMIT_DISABLED; test-integration-elixir
    # drives the router in-process, so set it directly. Restore on exit.)
    rl_original = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
      Application.put_env(:nebu_http, :rate_limit_disabled, rl_original)
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
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(@router_opts)
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    idx = min(n - 1, max(0, round(p / 100 * (n - 1))))
    Enum.at(sorted, idx)
  end

  # This 200-client × 50-round load test drives the whole router in-process and is
  # legitimately slow under a loaded CI/dev Docker — the default 60s ExUnit timeout
  # is for unit tests, not a load scenario. Give it room to complete; the actual SLA
  # is the median-latency assertion inside the test, not wall-clock setup time.
  @tag timeout: 300_000
  test "200 concurrent /sync clients receive all 50 broadcast events with median latency <= 150ms (AC7)",
       %{priv_jwk: priv_jwk} do
    owner_token = bearer("owner", priv_jwk)

    # 1. Owner creates the shared room.
    create =
      call(:post, "/_matrix/client/v3/createRoom", %{"name" => "regression-fanout-room"}, owner_token)

    assert create.status == 200, "createRoom must succeed to set up the load scenario"
    room_id = Jason.decode!(create.resp_body)["room_id"]
    encoded_room = URI.encode_www_form(room_id)

    # 2. Build 200 DISTINCT Matrix clients: distinct OIDC subject -> distinct bearer ->
    #    distinct provisioned user row and per-user since-token. Each joins the shared room
    #    so a single send fans out to all 200 :pg subscribers.
    client_tokens =
      for i <- 1..@clients do
        token = bearer("regression-client-#{i}", priv_jwk)

        join = call(:post, "/_matrix/client/v3/join/#{encoded_room}", %{}, token)

        assert join.status == 200,
               "regression-client-#{i} must join the shared room to set up the load scenario"

        token
      end

    # 3. Drive 50 measurement rounds. Each round broadcasts ONE message to all 200 clients
    #    and measures per-client delivery latency from the instant the message is sent.
    #    All latencies across all rounds are pooled for the median/p95 assertions, and we
    #    count total deliveries to prove zero drops.
    {all_latencies, total_delivered} =
      Enum.reduce(1..@messages, {[], 0}, fn round, {lat_acc, delivered_acc} ->
        # 3a. Per-client baseline since-token so each long-poll waits for events AFTER now.
        client_since =
          Map.new(client_tokens, fn token ->
            base = call(:get, "/_matrix/client/v3/sync", nil, token)
            assert base.status == 200
            {token, Jason.decode!(base.resp_body)["next_batch"]}
          end)

        # 3b. Spawn 200 concurrent long-poll syncs. Each task captures the monotonic time
        #     the instant its long-poll returns — that is the delivery timestamp.
        sync_tasks =
          for token <- client_tokens do
            since = Map.fetch!(client_since, token)

            Task.async(fn ->
              conn =
                call(
                  :get,
                  "/_matrix/client/v3/sync?since=#{since}&timeout=#{@longpoll_timeout_ms}",
                  nil,
                  token
                )

              {System.monotonic_time(:millisecond), conn}
            end)
          end

        # 3c. Send ONE message; start the round's latency clock at this instant.
        sent_at = System.monotonic_time(:millisecond)

        send_conn =
          call(
            :put,
            "/_matrix/client/v3/rooms/#{encoded_room}/send/m.room.message/regression-txn-#{round}",
            %{"msgtype" => "m.text", "body" => "regression-payload-#{round}"},
            owner_token
          )

        assert send_conn.status == 200
        event_id = Jason.decode!(send_conn.resp_body)["event_id"]

        # 3d. Collect every sync result. Latency = received_at - sent_at, measured purely
        #     from monotonic timestamps (no Process.sleep anywhere). A delivery counts only
        #     if the returned sync body actually carried the event (drop detection).
        results = Enum.map(sync_tasks, fn task -> Task.await(task, @await_budget_ms) end)

        round_latencies =
          for {received_at, conn} <- results,
              conn.status == 200,
              String.contains?(conn.resp_body, event_id) or
                String.contains?(conn.resp_body, "regression-payload-#{round}") do
            received_at - sent_at
          end

        {lat_acc ++ round_latencies, delivered_acc + length(round_latencies)}
      end)

    expected_total = @clients * @messages
    med = median(all_latencies)

    # Zero dropped events: every client must have observed every broadcast.
    assert total_delivered == expected_total,
           "zero events may be dropped: expected #{expected_total} deliveries " <>
             "(#{@clients} clients x #{@messages} messages), got #{total_delivered}"

    # Latency baseline: median delivery latency within the BEAM-native budget.
    assert med <= @median_budget_ms,
           "median /sync delivery latency must be <= #{@median_budget_ms}ms, got #{med}ms " <>
             "(p95=#{percentile(all_latencies, 95)}ms over #{length(all_latencies)} deliveries)"
  end
end
