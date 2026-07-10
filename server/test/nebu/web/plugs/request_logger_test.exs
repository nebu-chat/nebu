defmodule Nebu.Web.Plugs.RequestLoggerTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/matrix-payload-debug-logging`.

  Story: docs/stories/enhanced-logging/matrix-payload-debug-logging.md

  Extends coverage of `Nebu.Web.Plugs.RequestLogger` (previously only
  INFO-level method/path/status/duration_ms/request_id, asserted in
  `cors_plug_test.exs` / `http_foundation_test.exs`) with DEBUG-level
  request/response payload capture + two-category redaction (AC1-AC3, AC8-AC10).

  ## Why these MUST FAIL right now

  `Nebu.Web.Plugs.RequestLogger.call/2` (server/lib/nebu/web/plugs/request_logger.ex)
  currently only ever logs `%{method:, path:, status:, duration_ms:, request_id:}`
  via `Logger.info/1` — it never reads `conn.body_params`/response body, never
  emits a `request_body`/`response_body` key, and never calls
  `Jason.encode!/1` (the log line is an `inspect`-rendered Elixir map, NOT valid
  JSON — see AC3 test below). Every "at DEBUG" test below therefore fails
  because the key it searches for does not exist in the log output yet.

  ## Test layering

  Driven entirely through `Nebu.Web.Router.call/2` (in-process `Plug.Test`
  conn), matching the pattern in `matrix_router_test.exs` / `cors_plug_test.exs`
  — no live HTTP socket needed. Tests that need a REAL authenticated Matrix
  session (login + sync 200 contract) are tagged `@moduletag :integration`
  (excluded from default `mix test`, run via `make test-integration`) because
  `Nebu.Repo` must be running for the login→provisioning→sync round trip.
  Tests that only need to prove the LOGGER's capture/redaction behaviour
  (regardless of the endpoint's own response) run unauthenticated 401/400/404
  responses through the router and need no DB — these are NOT integration
  tests, mirroring `matrix_router_test.exs`'s "auth gate" describe block.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirrors matrix_router_test.exs) ────────────────────────

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

  defp with_log_level(level, fun) do
    original_level = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original_level)
    end
  end

  # ── M2 regression helpers (bug-fix cycle 5, code-review MAJOR finding) ──────
  # Mirrors `handler_test.exs`'s `ensure_pubsub_started!/0` /
  # `drain_broadcasts/1` helpers (duplicated locally, per that file's own
  # established convention of keeping each test file self-contained).

  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  defp drain_broadcasts(acc \\ []) do
    receive do
      msg -> drain_broadcasts([msg | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — Request body capture at DEBUG (no DB needed: the logger fires
  # regardless of whether the downstream handler accepts/rejects the request)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: request body capture at DEBUG level" do
    test "POST with a JSON body logs a request_body key when DEBUG is enabled" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(:post, "/_matrix/client/v3/login", %{
              "user_id" => "@alice:localhost",
              "password" => "secret123"
            })
          end)
        end)

      assert String.contains?(log_output, "request_body"),
             "DEBUG log must contain a request_body key when DEBUG logging is enabled"
    end

    test "the request_body captured in the log is a decoded structure, not a raw JSON string" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(:post, "/_matrix/client/v3/login", %{
              "user_id" => "@alice:localhost",
              "password" => "secret123"
            })
          end)
        end)

      # AC3: the whole log line is ONE JSON structure. Extract it and decode.
      json_line = extract_json_log_line(log_output)
      decoded = Jason.decode!(json_line)

      assert is_map(decoded["request_body"]),
             "request_body must be a decoded map inside the logged JSON structure, not a string"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — Response body capture at DEBUG
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: response body capture at DEBUG level" do
    test "a JSON response logs a response_body key when DEBUG is enabled" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            # /_matrix/client/versions is unauthenticated and deterministically
            # returns a 200 JSON body without touching the DB — sufficient to
            # prove response-body capture at the logger level.
            call(:get, "/_matrix/client/versions")
          end)
        end)

      assert String.contains?(log_output, "response_body"),
             "DEBUG log must contain a response_body key when DEBUG logging is enabled"
    end

    test "the response_body captured in the log is a decoded structure, not a raw JSON string" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(:get, "/_matrix/client/versions")
          end)
        end)

      json_line = extract_json_log_line(log_output)
      decoded = Jason.decode!(json_line)

      assert is_map(decoded["response_body"]),
             "response_body must be a decoded map inside the logged JSON structure, not a string"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — single JSON structure with the full field set
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: logged payload is a single JSON structure" do
    test "the DEBUG log line parses as JSON and contains all required top-level fields" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(:get, "/_matrix/client/versions")
          end)
        end)

      json_line = extract_json_log_line(log_output)

      decoded =
        Jason.decode!(json_line)

      for key <- ~w(method path status duration_ms request_id request_body response_body) do
        assert Map.has_key?(decoded, key),
               "logged JSON structure must contain key #{inspect(key)}, got: #{inspect(Map.keys(decoded))}"
      end

      assert decoded["method"] == "GET"
      assert decoded["path"] == "/_matrix/client/versions"
      assert decoded["status"] == 200
      assert is_integer(decoded["duration_ms"])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC10 — the RequestLogger plug uses PayloadRedactor internally: no
  # credentials or message content ever reach the log line, even though the
  # plug-level test never touches PayloadRedactor directly (that is AC9/AC10's
  # own isolation test, in payload_redactor_test.exs).
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4-AC7 wired end-to-end through the plug" do
    test "a password field in the request body never appears in plaintext in the DEBUG log" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(:post, "/_matrix/client/v3/login", %{
              "type" => "m.login.password",
              "user_id" => "@alice:localhost",
              "password" => "super-secret-plaintext-password"
            })
          end)
        end)

      refute String.contains?(log_output, "super-secret-plaintext-password"),
             "a plaintext password must never reach the DEBUG log, even end-to-end through the plug"

      assert String.contains?(log_output, "***REDACTED***"),
             "the redacted marker must appear in place of the password"
    end

    test "an Authorization Bearer header value never appears in plaintext in the DEBUG log" do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(:get, "/_matrix/client/v3/sync", nil, [
              {"authorization", "Bearer syt_super_secret_token_value_abc123"}
            ])
          end)
        end)

      refute String.contains?(log_output, "syt_super_secret_token_value_abc123"),
             "a plaintext bearer token must never reach the DEBUG log"

      # Positive evidence, not just absence-of-secret: the header must actually
      # have been captured (and then redacted) — a logger that never looks at
      # headers at all would vacuously pass the refute above. Assert the
      # redacted marker is present, proving header capture is wired in.
      assert String.contains?(log_output, "***REDACTED***"),
             "the Authorization header must be captured and show the redacted marker in the DEBUG log"
    end

    test "a deprecated ?access_token= query-param value never appears in plaintext in the DEBUG log (code-review M2)" do
      # code-review M2: PayloadRedactor.redact_string/1 has always had regex-
      # based `access_token=` redaction, but RequestLogger never actually
      # logged the query string anywhere, so that Oracle MUST was only
      # exercised in isolated unit tests — never end-to-end. This proves the
      # deprecated query-param auth style (still used by some legacy Matrix
      # clients) is captured AND redacted in the real request path.
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(
              :get,
              "/_matrix/client/v3/sync?access_token=leaked_query_param_secret_xyz&since=s1"
            )
          end)
        end)

      refute String.contains?(log_output, "leaked_query_param_secret_xyz"),
             "a plaintext ?access_token= query-param value must never reach the DEBUG log"

      # Positive evidence, not just absence-of-secret: a logger that never
      # looked at the query string at all would vacuously pass the refute
      # above. Assert the redacted marker is present, proving query-string
      # capture is actually wired in (same pattern as the Authorization-header
      # test above).
      assert String.contains?(log_output, "***REDACTED***"),
             "the query string must be captured and show the redacted marker in the DEBUG log"
    end

    test "F1 (security review 2026-07-05, CRITICAL): a send-event request body (no content wrapper) never leaks the message text" do
      # PUT /rooms/{roomId}/send/{eventType}/{txnId} sends the event content as
      # the RAW top-level request body (no {"content": {...}} wrapper) — the
      # single most common Matrix write operation. Unauthenticated here (no DB
      # needed): JsonBody decodes conn.body_params before OidcPlug rejects the
      # request, and RequestLogger's before_send callback still reads that
      # already-decoded body_params regardless of the eventual 401.
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(
              :put,
              "/_matrix/client/v3/rooms/!room:localhost/send/m.room.message/txn1",
              %{"body" => "distinctive-secret-message-text", "msgtype" => "m.text"}
            )
          end)
        end)

      refute String.contains?(log_output, "distinctive-secret-message-text"),
             "a plaintext top-level message body must never reach the DEBUG log on the write path"

      assert String.contains?(log_output, "***MESSAGE_CONTENT***"),
             "the message-content redaction marker must appear in place of the top-level body"
    end

    test "F1-R (security review 2026-07-05, cycle 6 re-verify, HIGH): m.location.geo_uri on the write path (not on the fixed field-name list) never leaks" do
      # PUT /rooms/{roomId}/send/m.room.message/{txnId} with an m.location
      # event: `geo_uri` is real plaintext GPS-coordinate PII, and is NOT one
      # of the fixed `@always_content_keys` (body/formatted_body/filename/
      # topic/name/displayname/reason) — cycle 5's field-name-list fix alone
      # does not catch it. This requires the write path to treat the whole
      # top-level body as a `content` object (route-aware `in_content?: true`).
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(
              :put,
              "/_matrix/client/v3/rooms/!room:localhost/send/m.room.message/txn-geo",
              %{
                "msgtype" => "m.location",
                "body" => "My location",
                "geo_uri" => "geo:52.5200-distinctive-13.4050"
              }
            )
          end)
        end)

      refute String.contains?(log_output, "geo:52.5200-distinctive-13.4050"),
             "a plaintext geo_uri (GPS PII) must never reach the DEBUG log on the write path"

      assert String.contains?(log_output, "***MESSAGE_CONTENT***"),
             "the message-content redaction marker must appear in place of geo_uri"
    end

    test "F1-R (security review 2026-07-05, cycle 6 re-verify, HIGH): an arbitrary custom/vendor event field on the write path never leaks" do
      # PUT /rooms/{roomId}/send/{eventType}/{txnId} with a custom/vendor
      # event type — Matrix's event schema is open/extensible, so a FIXED
      # field-name list can never be exhaustive. Any content field must be
      # masked on the write path, not just the known ones.
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(
              :put,
              "/_matrix/client/v3/rooms/!room:localhost/send/com.example.custom_event/txn-custom",
              %{"custom_field" => "distinctive-custom-vendor-payload-text"}
            )
          end)
        end)

      refute String.contains?(log_output, "distinctive-custom-vendor-payload-text"),
             "a plaintext custom/vendor content field must never reach the DEBUG log on the write path"

      assert String.contains?(log_output, "***MESSAGE_CONTENT***"),
             "the message-content redaction marker must appear in place of the custom field"
    end

    test "F1-R (security review 2026-07-05, cycle 6 re-verify, HIGH): a state-event write body (PUT .../state/{eventType}) with a non-fixed field never leaks" do
      # PUT /rooms/{roomId}/state/{eventType} also sends the raw content
      # object as the top-level request body, with no `content` wrapper.
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            call(
              :put,
              "/_matrix/client/v3/rooms/!room:localhost/state/com.example.custom_state",
              %{"custom_state_field" => "distinctive-custom-state-payload-text"}
            )
          end)
        end)

      refute String.contains?(log_output, "distinctive-custom-state-payload-text"),
             "a plaintext non-fixed state-event content field must never reach the DEBUG log on the write path"

      assert String.contains?(log_output, "***MESSAGE_CONTENT***"),
             "the message-content redaction marker must appear in place of the custom state field"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC10 — No payload logging when DEBUG is disabled (default level)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: no payload logging when DEBUG is disabled (default)" do
    test "with the default (non-DEBUG) log level, no request_body/response_body keys are logged" do
      # Do NOT call with_log_level/2 here — this test asserts the DEFAULT
      # behaviour. config/test.exs sets Logger level to :warning; INFO-level
      # request logs are therefore not even emitted by capture_log at :info by
      # default. Bump only to :info (never :debug) to observe the INFO line
      # while proving no payload keys leak in at that level.
      original_level = Logger.level()
      Logger.configure(level: :info)

      log_output =
        try do
          capture_log(fn ->
            call(:post, "/_matrix/client/v3/login", %{
              "user_id" => "@alice:localhost",
              "password" => "secret123"
            })
          end)
        after
          Logger.configure(level: original_level)
        end

      refute String.contains?(log_output, "request_body"),
             "request_body must NOT be logged when DEBUG logging is disabled"

      refute String.contains?(log_output, "response_body"),
             "response_body must NOT be logged when DEBUG logging is disabled"

      # Only INFO-level fields are present.
      assert String.contains?(log_output, "method")
      assert String.contains?(log_output, "path")
      assert String.contains?(log_output, "status")
      assert String.contains?(log_output, "duration_ms")
      assert String.contains?(log_output, "request_id")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4-AC7 combined — real login + sync round trip (DB-backed, :integration)
  # ══════════════════════════════════════════════════════════════════════════

  describe "combined redaction over a real authenticated login + sync round trip" do
    @describetag :integration

    @server_name "test.local"
    @issuer "https://idp.example.com/realms/nebu"
    @audience "nebu-client"
    @kid "payload-debug-logging-key-1"

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

      priv_jwk = Map.put(priv_map, "kid", @kid)

      Application.put_env(:nebu_http, :server_name, @server_name)
      Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

      on_exit(fn ->
        Application.delete_env(:nebu_http, :server_name)
        Nebu.Web.OidcTestSupport.clear()
        Application.delete_env(:nebu_http, :oidc_jwks)
      end)

      priv_jwk
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

    setup do
      prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      on_exit(fn ->
        case prev_rl do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end
      end)

      priv = setup_oidc_keys()
      sub = "payloaddebug" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      {uid, token} = bearer_for(sub, priv)

      if Process.whereis(Nebu.Repo) do
        _ =
          Nebu.Matrix.Session.TokenValidator.validate(
            uid,
            "user",
            "Payload Debug",
            "pd@example.com"
          )

        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Payload Debug", nil)

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            for table <- ["matrix_sessions", "profiles", "users"] do
              _ =
                Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM #{table} WHERE user_id = $1", [
                  uid
                ])
            end
          end
        end)
      end

      {:ok, token: token, user_id: uid}
    end

    test "login request (password-shaped body) + sync response (message content) are both redacted in DEBUG logs",
         %{token: token} do
      log_output =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            # 1. A login-shaped POST carrying a credential-looking field — proves
            #    request-side redaction (AC4/AC5) end-to-end.
            call(:post, "/_matrix/client/v3/login", %{
              "type" => "m.login.token",
              "token" => token,
              "password" => "must-not-leak-into-logs"
            })

            # 2. An authenticated sync — the RESPONSE contains a real
            #    Matrix-shaped body (rooms/timeline). Even if this particular
            #    fixture's sync returns no message events, the Authorization
            #    header used to reach it must never leak either.
            call(:get, "/_matrix/client/v3/sync", nil, [{"authorization", "Bearer " <> token}])
          end)
        end)

      refute String.contains?(log_output, "must-not-leak-into-logs"),
             "request-side password must be redacted in the combined round trip"

      refute String.contains?(log_output, token),
             "the raw bearer/login token must never appear in plaintext in the DEBUG log"

      assert String.contains?(log_output, "***REDACTED***"),
             "at least one credential redaction marker must appear in the combined log output"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4/AC5 — RED-phase ATDD for enhanced-logging/operational-log-store.
  #
  # Story: docs/stories/enhanced-logging/operational-log-store.md
  #
  # Why these MUST FAIL right now: `RequestLogger.call/2` (this file's SUT)
  # currently never calls `Logger.metadata(request_id: ...)` at all (verified
  # by reading server/lib/nebu/web/plugs/request_logger.ex — it only reads
  # `request_id` into a local variable for its own `base_fields` map), and
  # `base_fields` currently has no `route_template` key. Both AC4's test and
  # AC5's wiring test below assert on behaviour that literally does not exist
  # in the current implementation yet.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: request_id is propagated to Logger.metadata/1" do
    test "a downstream Logger call in the same process, after RequestLogger runs, carries request_id in its metadata" do
      test_pid = self()

      try do
        # A minimal downstream "plug" — a plain function called from inside
        # the SAME process the request runs in (mirrors how
        # Nebu.Repo.QueryTelemetry's Logger.debug/1 call, fired from within
        # the request-handling process, is the actual production motivation
        # for this AC per Dev Notes).
        capture_metadata = fn ->
          send(test_pid, {:observed_metadata, Logger.metadata()})
        end

        # We can't easily inject a downstream plug into the real pipeline
        # from here without modifying router config, so we drive this at the
        # Plug-call level directly: call RequestLogger, then (still in the
        # SAME process, before the request finishes) read Logger.metadata/0 —
        # AC4 requires Logger.metadata(request_id: ...) to have been called
        # EARLY in RequestLogger.call/2 itself (not just in the before_send
        # callback), so it must already be visible right after `call/2`
        # returns.
        conn =
          conn(:get, "/_matrix/client/v3/sync")
          |> put_req_header("x-request-id", "req-ac4-propagation-test")
          |> put_resp_header("x-request-id", "req-ac4-propagation-test")

        _conn = Nebu.Web.Plugs.RequestLogger.call(conn, [])

        capture_metadata.()

        assert_receive {:observed_metadata, metadata}, 500

        assert Keyword.get(metadata, :request_id) == "req-ac4-propagation-test",
               "Logger.metadata/1 must carry request_id after RequestLogger.call/2 runs in " <>
                 "this process, so ALL subsequent Logger.* calls (e.g. " <>
                 "Nebu.Repo.QueryTelemetry's Logger.debug/1) automatically carry it too — " <>
                 "got metadata: #{inspect(metadata)}"
      after
        Logger.reset_metadata()
      end
    end
  end

  describe "AC4: request_id is NOT inherited by Task.start/1 (documented limitation)" do
    test "a task spawned via Task.start/1 from a process with Logger.metadata(request_id: ...) set does not see it" do
      test_pid = self()

      try do
        Logger.metadata(request_id: "req-123-not-inherited")

        Task.start(fn ->
          send(test_pid, {:task_metadata, Logger.metadata()})
        end)

        assert_receive {:task_metadata, task_metadata}, 500

        refute Keyword.get(task_metadata, :request_id) == "req-123-not-inherited",
               "Logger.metadata/1 is per-process — a Task.start/1'd task must NOT " <>
                 "automatically inherit the parent process's request_id (AC4's documented " <>
                 "limitation). If this assertion ever starts failing because Elixir/OTP " <>
                 "changes this behavior, that is actually GOOD news and this test (and its " <>
                 "Dev Notes caveat) should be updated."
      after
        Logger.reset_metadata()
      end
    end
  end

  describe "AC5: route_template is computed and logged alongside the base request fields" do
    test "a room-scoped request path logs a route_template key with a normalized (non-raw) room ID" do
      log_output =
        with_log_level(:info, fn ->
          capture_log(fn ->
            call(:put, "/_matrix/client/v3/rooms/!room:localhost/send/m.room.message/txn-ac5")
          end)
        end)

      assert String.contains?(log_output, "route_template"),
             "the base INFO log line must include a route_template key (AC5), got: #{log_output}"

      refute String.contains?(log_output, "!room:localhost"),
             "route_template must be the NORMALIZED path, not the raw room ID, got: #{log_output}"
    end

    test "/sync's route_template is the literal, unchanged path (no path parameters to normalize)" do
      log_output =
        with_log_level(:info, fn ->
          capture_log(fn ->
            call(:get, "/_matrix/client/v3/sync")
          end)
        end)

      assert String.contains?(log_output, "/_matrix/client/v3/sync"),
             "route_template for /sync must be the literal path, unchanged, got: #{log_output}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # M2 (bug-fix cycle 5, code-review MAJOR finding): a direct regression test
  # for the `Logger.metadata(method:, status:, duration_ms:)` fix added in
  # `before_send` (see the comment at that call site in
  # `request_logger.ex`). Prior tests each proved only HALF of the chain:
  # `handler_test.exs` proves `Handler`'s parsing/redaction/persistence in
  # isolation (never asserting on method/status/duration_ms specifically),
  # and `logs_live_test.exs`'s fixtures hand-construct the `metadata` map
  # (proving `LogsLive` consumes the shape correctly, not that
  # `RequestLogger` + `Handler` actually PRODUCE it). This test drives a
  # real request through `RequestLogger` (via the full router, exactly like
  # every other test in this file) with the REAL `Nebu.Web.LogStore.Handler`
  # attached, and asserts on the metadata map the handler actually broadcasts
  # — proving the full plug -> Logger.metadata/1 -> Handler.parse_log_event/1
  # chain end-to-end, not just each half in isolation.
  # ══════════════════════════════════════════════════════════════════════════

  describe "M2: method/status/duration_ms reach Handler.parse_log_event/1's metadata map" do
    test "a real HTTP request through RequestLogger produces a broadcast entry whose metadata carries method/status/duration_ms with the correct types" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      conn =
        with_log_level(:info, fn ->
          call(:get, "/_matrix/client/v3/sync")
        end)

      # Identify the exact broadcast entry this request produced via its
      # `x-request-id` response header (set by the RequestId plug ahead of
      # RequestLogger — same technique `handler_test.exs`'s persisted-row
      # test uses). Matching on `request_id` + `route_template` pins down
      # the exact base INFO log line `RequestLogger`'s `before_send`
      # callback emits (as opposed to the separate DEBUG payload log line
      # the same request also produces, which shares the same
      # request_id/route_template but a different message shape).
      #
      # bug-fix cycle 6 (code-review follow-up to M2): this test previously
      # noted here that `Handler.source_from_meta/1` classifies "http" from
      # a bare `:module` metadata key that real `Logger.*` macro calls never
      # actually set (only `:mfa`, `{Module, Function, Arity}`) — meaning
      # `source` always resolved to "unknown", never "http", for every real
      # HTTP-sourced entry. That gap is now fixed (`source_from_meta/1`
      # derives the calling module from `:mfa`), so this test now also
      # asserts `source == "http"` below, in addition to the metadata
      # assertions M2 originally added.
      request_id =
        conn
        |> Plug.Conn.get_resp_header("x-request-id")
        |> List.first()

      refute is_nil(request_id),
             "expected the RequestId plug to have set an x-request-id response header"

      entries = drain_broadcasts()

      base_entry =
        Enum.find(entries, fn
          %{request_id: ^request_id, route_template: "/_matrix/client/v3/sync"} -> true
          _ -> false
        end)

      refute is_nil(base_entry),
             "expected a broadcast operational_logs entry for request_id " <>
               "#{inspect(request_id)} and route_template \"/_matrix/client/v3/sync\", got: " <>
               inspect(entries)

      metadata = Map.get(base_entry, :metadata, %{})

      assert Map.get(metadata, "method") == "GET",
             "expected metadata[\"method\"] == \"GET\", got: #{inspect(metadata)}"

      assert is_integer(Map.get(metadata, "status")),
             "expected metadata[\"status\"] to be an integer HTTP status code, got: " <>
               inspect(metadata)

      assert is_integer(Map.get(metadata, "duration_ms")),
             "expected metadata[\"duration_ms\"] to be an integer, got: #{inspect(metadata)}"

      # bug-fix cycle 6: now that Handler.source_from_meta/1 derives the
      # calling module from :mfa, a real HTTP request through RequestLogger
      # must classify as source "http" (previously always "unknown" — see
      # comment above).
      assert Map.get(base_entry, :source) == "http",
             "expected the broadcast entry's source to be \"http\", got: " <>
               inspect(base_entry)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review MAJOR-1 (war-room-mode, cycle 1): `conn.assigns.current_user`
  # is NOT always a bare Matrix user_id string. `RequestLogger` is mounted in
  # the TOP-LEVEL `Nebu.Web.Router`, which also serves `/admin/*` routes —
  # there, `Nebu.Admin.Auth.fetch_current_user/2` assigns a MAP (`"sub"`,
  # `"email"`, `"admin"`, `"matrix_user_id"`, session-timing fields), not a
  # bare string. `Handler.safe_metadata/1` recurses into maps, so passing that
  # raw map straight to `Logger.metadata/1` would leak the admin's EMAIL into
  # the persisted/broadcast `operational_logs.metadata["user_id"]` field.
  # `extract_user_id/1` (request_logger.ex) reduces `conn.assigns.current_user`
  # to a bare identifier string (or nil) BEFORE it ever reaches
  # `Logger.metadata/1`. Driven directly through `RequestLogger.call/2` (not
  # the full router) — mirrors the AC4 "propagation" test's direct-call
  # technique above and the SECURITY LAW describe-block pattern in
  # `handler_test.exs`: this only needs to prove RequestLogger's OWN handling
  # of whatever shape ends up in that assign, since the assign itself is
  # produced further down the SAME pipeline by OidcPlug (string) or
  # Nebu.Admin.Auth (map).
  # ══════════════════════════════════════════════════════════════════════════

  describe "code-review MAJOR-1: conn.assigns.current_user is reduced to a bare identifier before Logger.metadata/1" do
    test "a Matrix-route STRING current_user (regression) still flows through unchanged to the broadcast metadata" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      request_id = "req-major1-string-#{System.unique_integer([:positive])}"

      try do
        with_log_level(:info, fn ->
          conn(:get, "/_matrix/client/v3/sync")
          |> put_resp_header("x-request-id", request_id)
          |> assign(:current_user, "@alice:localhost")
          |> assign(:device_id, "DEVICE1")
          |> Nebu.Web.Plugs.RequestLogger.call([])
          |> send_resp(200, "{}")
        end)

        entries = drain_broadcasts()

        base_entry =
          Enum.find(entries, fn
            %{request_id: ^request_id} -> true
            _ -> false
          end)

        refute is_nil(base_entry),
               "expected a broadcast entry for request_id #{inspect(request_id)}, got: " <>
                 inspect(entries)

        metadata = Map.get(base_entry, :metadata, %{})

        assert Map.get(metadata, "user_id") == "@alice:localhost",
               "a bare string current_user (the Matrix-route shape) must flow through to " <>
                 "metadata[\"user_id\"] unchanged, got: #{inspect(metadata)}"
      after
        Logger.reset_metadata()
      end
    end

    test "an admin-route MAP current_user containing an \"email\" key NEVER leaks that email into the broadcast or its metadata" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      request_id = "req-major1-map-#{System.unique_integer([:positive])}"

      admin_user = %{
        "sub" => "admin-oidc-sub-xyz",
        "email" => "the-secret-email-value@example.com",
        "admin" => true,
        "matrix_user_id" => "@admin-bob:localhost",
        "session_exp" => System.system_time(:second) + 3600
      }

      try do
        with_log_level(:info, fn ->
          conn(:get, "/admin/logs")
          |> put_resp_header("x-request-id", request_id)
          |> assign(:current_user, admin_user)
          |> Nebu.Web.Plugs.RequestLogger.call([])
          |> send_resp(200, "ok")
        end)

        entries = drain_broadcasts()
        serialized = entries |> Enum.map(&inspect/1) |> Enum.join(" ")

        refute String.contains?(serialized, "the-secret-email-value"),
               "an admin's email must NEVER appear anywhere in a broadcast operational_logs " <>
                 "entry, even though conn.assigns.current_user is a MAP on admin routes — got: " <>
                 serialized

        base_entry =
          Enum.find(entries, fn
            %{request_id: ^request_id} -> true
            _ -> false
          end)

        refute is_nil(base_entry),
               "expected a broadcast entry for request_id #{inspect(request_id)}, got: " <>
                 inspect(entries)

        metadata = Map.get(base_entry, :metadata, %{})

        assert Map.get(metadata, "user_id") == "@admin-bob:localhost",
               "an admin-route MAP current_user must be reduced to its matrix_user_id (never " <>
                 "the whole map, never the email), got: #{inspect(metadata)}"
      after
        Logger.reset_metadata()
      end
    end

    test "an admin-route MAP current_user WITHOUT matrix_user_id falls back to \"sub\", still never the email" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      request_id = "req-major1-map-fallback-#{System.unique_integer([:positive])}"

      admin_user = %{
        "sub" => "admin-oidc-sub-fallback",
        "email" => "another-secret-email@example.com",
        "admin" => true
      }

      try do
        with_log_level(:info, fn ->
          conn(:get, "/admin/logs")
          |> put_resp_header("x-request-id", request_id)
          |> assign(:current_user, admin_user)
          |> Nebu.Web.Plugs.RequestLogger.call([])
          |> send_resp(200, "ok")
        end)

        entries = drain_broadcasts()
        serialized = entries |> Enum.map(&inspect/1) |> Enum.join(" ")

        refute String.contains?(serialized, "another-secret-email"),
               "an admin's email must NEVER appear anywhere in a broadcast operational_logs " <>
                 "entry, got: " <> serialized

        base_entry =
          Enum.find(entries, fn
            %{request_id: ^request_id} -> true
            _ -> false
          end)

        refute is_nil(base_entry),
               "expected a broadcast entry for request_id #{inspect(request_id)}, got: " <>
                 inspect(entries)

        metadata = Map.get(base_entry, :metadata, %{})

        assert Map.get(metadata, "user_id") == "admin-oidc-sub-fallback",
               "without matrix_user_id, the admin-route MAP current_user must fall back to " <>
                 "\"sub\" (still never the email), got: #{inspect(metadata)}"
      after
        Logger.reset_metadata()
      end
    end
  end

  # ── shared parsing helper ───────────────────────────────────────────────────

  # capture_log/1 may include ANSI/metadata prefix text before the actual
  # logged term. Find the JSON object substring (starts at the first "{" that
  # yields a balanced, parseable JSON document) so tests can Jason.decode!/1 it
  # directly rather than string-matching on fragile substrings.
  defp extract_json_log_line(log_output) do
    case Regex.run(~r/\{.*\}/s, log_output) do
      [json] -> json
      nil -> flunk("no JSON object found in log output: #{inspect(log_output)}")
    end
  end
end
