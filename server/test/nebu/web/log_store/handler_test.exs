defmodule Nebu.Web.LogStore.HandlerTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/operational-log-store` (AC2
  handler-callback detail, plus the redaction LAW carried over from
  `matrix-payload-debug-logging`).

  Story: docs/stories/enhanced-logging/operational-log-store.md

  ## Why these MUST FAIL right now

  `Nebu.Web.LogStore.Handler` (server/lib/nebu/web/log_store/handler.ex) does
  not exist yet, and `Nebu.Web.LogStore.attach_handler/0` does not exist
  either. Every test here fails at runtime with `UndefinedFunctionError`.

  ## The most important test in this file (security-review LAW)

  Per the "No Sensitive Data in Logs" LAW (already enforced end-to-end for
  `Nebu.Web.Plugs.RequestLogger`'s own DEBUG payload logging in
  `matrix-payload-debug-logging`), this new central `:logger` handler MUST NOT
  become a second, unredacted leak path for the same content class
  (credentials + chat message content). The design intent (per the story's
  Background section) is that `PayloadRedactor` already runs BEFORE the
  `Logger.debug(fn -> ... end)` call inside `RequestLogger`, so by the time
  the handler's `log/2` callback receives the rendered event, the message text
  is ALREADY the redacted JSON string — the handler itself does no redaction
  and needs none. The test below does NOT assume this — it drives a REAL
  request through `Nebu.Web.Router` (using `RequestLogger`'s own
  instrumentation, not a hand-redacted call) with the central handler
  attached, and inspects what the handler actually broadcasts.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirrors request_logger_test.exs) ───────────────────────

  defp call(method, path, body), do: call(method, path, body, [])

  defp call(method, path, body, headers) do
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

  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  # Drains every message currently sitting in this test process's mailbox
  # (broadcast entries), up to a short quiet-period timeout, so a test can
  # inspect ALL entries emitted by one request (a request typically emits at
  # least two Logger calls: the base INFO line and the DEBUG payload line).
  defp drain_broadcasts(acc \\ []) do
    receive do
      msg -> drain_broadcasts([msg | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — handler callback contract (direct unit test of Handler.log/2)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: Handler.log/2 callback contract" do
    test "broadcasts a synthetic :logger log_event to \"operational_logs\" and returns :ok" do
      ensure_pubsub_started!()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      log_event = %{
        level: :warning,
        msg: {:string, "distinctive-handler-unit-test-message"},
        meta: %{time: System.system_time(:microsecond)}
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})

      assert_receive entry,
                     1_000,
                     "Handler.log/2 must broadcast the parsed entry to \"operational_logs\""

      serialized = inspect(entry)

      assert String.contains?(serialized, "distinctive-handler-unit-test-message"),
             "the broadcast entry must carry the original log message through"
    end

    test "does not raise for a :report-shaped msg (e.g. base_fields map logged via Logger.info(map))" do
      log_event = %{
        level: :info,
        msg: {:report, %{method: "GET", path: "/sync", status: 200, duration_ms: 3}},
        meta: %{time: System.system_time(:microsecond)}
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # bug-fix cycle 6 (admin-logs-monitoring-view, code-review follow-up to M2):
  # `source_from_meta/1` classifies "http"/"ecto" from the CALLING module —
  # which real `Logger.*` macro calls surface ONLY via the auto-injected
  # `:mfa` metadata key (`{module, function, arity}`), never a bare `:module`
  # key. These tests drive `Handler.log/2` directly with synthetic
  # `:logger` events shaped exactly like what `:mfa` actually looks like
  # (mirroring the "AC2: Handler.log/2 callback contract" tests above), so
  # they pin down `source_from_meta/1`'s contract without depending on a full
  # HTTP request or a live Ecto/Postgres connection. The end-to-end paths
  # (a real request through `RequestLogger`, a real query through
  # `Nebu.Repo.QueryTelemetry`) are covered separately, in
  # `request_logger_test.exs`'s M2 test and in the `:integration`-tagged test
  # below.
  # ══════════════════════════════════════════════════════════════════════════

  describe "bug-fix cycle 6: source_from_meta/1 classifies via :mfa (not a nonexistent bare :module key)" do
    test "an :mfa naming Nebu.Web.Plugs.RequestLogger classifies as source \"http\"" do
      ensure_pubsub_started!()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      log_event = %{
        level: :info,
        msg: {:string, "distinctive-mfa-http-classification-test"},
        meta: %{
          time: System.system_time(:microsecond),
          mfa: {Nebu.Web.Plugs.RequestLogger, :call, 2}
        }
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})

      assert_receive %{source: "http"} = entry, 1_000,
        "expected an :mfa naming Nebu.Web.Plugs.RequestLogger to classify as source \"http\""

      assert String.contains?(inspect(entry), "distinctive-mfa-http-classification-test")
    end

    test "an :mfa naming Nebu.Repo.QueryTelemetry classifies as source \"ecto\"" do
      ensure_pubsub_started!()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      log_event = %{
        level: :debug,
        msg: {:string, "distinctive-mfa-ecto-classification-test"},
        meta: %{
          time: System.system_time(:microsecond),
          mfa: {Nebu.Repo.QueryTelemetry, :handle_event, 4}
        }
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})

      assert_receive %{source: "ecto"}, 1_000,
        "expected an :mfa naming Nebu.Repo.QueryTelemetry to classify as source \"ecto\""
    end

    test "an :mfa naming an unrecognised module falls back to that module's own name as source" do
      ensure_pubsub_started!()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      log_event = %{
        level: :info,
        msg: {:string, "distinctive-mfa-unrecognised-module-test"},
        meta: %{
          time: System.system_time(:microsecond),
          mfa: {SomeOther.Unrecognised.Module, :some_fun, 1}
        }
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})

      assert_receive %{source: "Elixir.SomeOther.Unrecognised.Module"}, 1_000,
        "expected an unrecognised :mfa module to fall back to its own Atom.to_string/1 name"
    end

    test "meta with neither :mfa nor :module classifies as source \"unknown\"" do
      ensure_pubsub_started!()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      log_event = %{
        level: :info,
        msg: {:string, "distinctive-mfa-missing-test"},
        meta: %{time: System.system_time(:microsecond)}
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})

      assert_receive %{source: "unknown"}, 1_000,
        "expected meta with no :mfa/:module key to classify as source \"unknown\""
    end

    test "a bare :module key (never set by real Logger macro calls, but kept as a harmless fallback) still classifies as \"http\"" do
      ensure_pubsub_started!()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      log_event = %{
        level: :info,
        msg: {:string, "distinctive-bare-module-fallback-test"},
        meta: %{
          time: System.system_time(:microsecond),
          module: Nebu.Web.Plugs.RequestLogger
        }
      }

      assert :ok = Nebu.Web.LogStore.Handler.log(log_event, %{})

      assert_receive %{source: "http"}, 1_000,
        "expected the bare :module fallback to still classify as \"http\" when :mfa is absent"
    end

    # ────────────────────────────────────────────────────────────────────────
    # End-to-end proof that Nebu.Repo.QueryTelemetry's REAL Logger.debug/1
    # call (report/anonymous-function style, `Logger.debug(fn -> ... end)`)
    # actually carries an :mfa naming Nebu.Repo.QueryTelemetry, and that the
    # Handler classifies the resulting broadcast entry as source "ecto" —
    # not just the synthetic-event unit tests above. Requires a live
    # Nebu.Repo/Postgres connection (`make test-integration` /
    # `--include integration`), mirroring this file's other DB-backed test.
    # ────────────────────────────────────────────────────────────────────────
    @tag :integration
    test "a real query through Nebu.Repo.QueryTelemetry broadcasts source \"ecto\" end-to-end" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      original_config = Application.get_env(:nebu, Nebu.Repo.QueryTelemetry, [])
      Application.put_env(:nebu, Nebu.Repo.QueryTelemetry, enabled: true)

      on_exit(fn ->
        Application.put_env(:nebu, Nebu.Repo.QueryTelemetry, original_config)
      end)

      with_log_level(:debug, fn ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1", [])
      end)

      entries = drain_broadcasts()

      ecto_entry =
        Enum.find(entries, fn
          %{source: "ecto"} -> true
          _ -> false
        end)

      refute is_nil(ecto_entry),
             "expected at least one broadcast operational_logs entry with source \"ecto\" " <>
               "from a real query through Nebu.Repo.QueryTelemetry, got: #{inspect(entries)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # SECURITY LAW — the central handler must never become a new, unredacted
  # leak path for credentials or chat message content (No Sensitive Data in
  # Logs LAW). This is the single most important test in this story.
  # ══════════════════════════════════════════════════════════════════════════

  describe "SECURITY LAW: redaction passthrough end-to-end through RequestLogger" do
    test "a send-event request with a real message body, driven through RequestLogger, never broadcasts the raw secret/content" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      with_log_level(:debug, fn ->
        call(
          :put,
          "/_matrix/client/v3/rooms/!room:localhost/send/m.room.message/txn-logstore-security",
          %{
            "body" => "distinctive-secret-message-text-for-logstore-handler",
            "msgtype" => "m.text"
          }
        )
      end)

      entries = drain_broadcasts()
      serialized = entries |> Enum.map(&inspect/1) |> Enum.join(" ")

      refute String.contains?(serialized, "distinctive-secret-message-text-for-logstore-handler"),
             "a plaintext message body must NEVER reach an operational_logs broadcast entry, " <>
               "even though this handler is a GENERIC :logger handler (not payload-specific) — " <>
               "RequestLogger's own PayloadRedactor pass must have already run before the " <>
               "Logger.debug/1 call this handler observes"

      assert String.contains?(serialized, "***MESSAGE_CONTENT***"),
             "the redaction marker must be present in at least one broadcast entry, proving " <>
               "this assertion is not vacuously true because nothing was captured at all"
    end

    test "a login request with a plaintext password, driven through RequestLogger, never broadcasts the raw credential" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      with_log_level(:debug, fn ->
        call(:post, "/_matrix/client/v3/login", %{
          "user_id" => "@alice:localhost",
          "password" => "distinctive-plaintext-password-for-logstore-handler"
        })
      end)

      entries = drain_broadcasts()
      serialized = entries |> Enum.map(&inspect/1) |> Enum.join(" ")

      refute String.contains?(serialized, "distinctive-plaintext-password-for-logstore-handler"),
             "a plaintext password must NEVER reach an operational_logs broadcast entry via the " <>
               "central :logger handler"

      assert String.contains?(serialized, "***REDACTED***"),
             "the credential-redaction marker must be present in at least one broadcast entry"
    end

    test "an Authorization Bearer token, driven through RequestLogger, never broadcasts the raw token" do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      with_log_level(:debug, fn ->
        call(:get, "/_matrix/client/v3/sync", nil, [
          {"authorization", "Bearer distinctive-secret-bearer-token-for-logstore-handler"}
        ])
      end)

      entries = drain_broadcasts()
      serialized = entries |> Enum.map(&inspect/1) |> Enum.join(" ")

      refute String.contains?(serialized, "distinctive-secret-bearer-token-for-logstore-handler"),
             "a plaintext bearer token must NEVER reach an operational_logs broadcast entry via " <>
               "the central :logger handler"
    end

    # ────────────────────────────────────────────────────────────────────────
    # The three tests above only inspect the PubSub broadcast side of AC2
    # ("always: broadcast... conditionally: write to DB"). The Writer's
    # batching/serialization (JSON-encoding metadata, building the INSERT
    # parameter list) is a DISTINCT code path from the broadcast and could
    # reintroduce or fail to carry forward redaction even if the broadcast
    # is clean — e.g. if a future change has the Writer re-derive fields
    # instead of reusing the already-redacted `entry.message`. This test
    # closes that gap by asserting on the ACTUAL PERSISTED ROW, not just the
    # in-memory broadcast — this is the story's own Compliance Note made
    # concrete ("whether PayloadRedactor's redaction interacts with this new
    # store is an open question for security review").
    # ────────────────────────────────────────────────────────────────────────
    @tag :integration
    test "a send-event request with a real message body is persisted to operational_logs WITHOUT the raw secret" do
      Nebu.Release.migrate()

      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_info" => "true",
        "log_collect_debug" => "true"
      })

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key IN ($1, $2)", [
            "log_collect_info",
            "log_collect_debug"
          ])
        end
      end)

      case Process.whereis(Nebu.Web.LogStore.Writer) do
        nil -> start_supervised!(Nebu.Web.LogStore.Writer)
        _existing -> :ok
      end

      :ok = Nebu.Web.LogStore.attach_handler()

      # NOTE: we can't find this request's persisted row(s) by searching for
      # the secret substring — if redaction works correctly, that substring
      # is BY DEFINITION never present in the DB. Instead we capture the
      # actual `x-request-id` response header (set by the RequestId plug
      # ahead of RequestLogger in the pipeline) and query the dedicated
      # `request_id` column, which `RequestLogger` propagates into
      # `Logger.metadata/1` early in `call/2` — so it's already attached to
      # every Logger call (base INFO line + DEBUG payload line) this one
      # request produces, independent of whatever redaction did to the
      # message body itself.
      conn =
        with_log_level(:debug, fn ->
          call(
            :put,
            "/_matrix/client/v3/rooms/!room:localhost/send/m.room.message/txn-logstore-persisted-row",
            %{
              "body" => "distinctive-secret-message-text-for-persisted-row",
              "msgtype" => "m.text"
            }
          )
        end)

      request_id =
        conn
        |> Plug.Conn.get_resp_header("x-request-id")
        |> List.first()

      refute is_nil(request_id),
             "expected the RequestId plug to have set an x-request-id response header"

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE request_id = $1",
            [request_id]
          )
        end
      end)

      result =
        wait_until_persisted_rows(
          "SELECT message, metadata::text FROM operational_logs WHERE request_id = $1",
          [request_id]
        )

      serialized =
        result.rows
        |> Enum.map(fn row -> Enum.join(row, " ") end)
        |> Enum.join(" ")

      refute String.contains?(serialized, "distinctive-secret-message-text-for-persisted-row"),
             "the raw message body must NEVER be written into an operational_logs row's " <>
               "message/metadata columns — the Writer's DB-persistence path must carry " <>
               "forward the same redaction the broadcast path already has, got: " <>
               inspect(result.rows)

      assert String.contains?(serialized, "***MESSAGE_CONTENT***"),
             "the redaction marker must appear in the persisted row, proving this assertion " <>
               "is not vacuously true because no matching row was ever written"

      # code-review M1: `route_template` was computed by `RequestLogger` and
      # embedded in the rendered log MESSAGE, but never actually attached to
      # the `:logger` event's `meta` via `Logger.metadata/1` — the only place
      # `Handler.parse_log_event/1` ever reads `route_template`/`request_id`
      # from. This left the persisted `operational_logs.route_template`
      # COLUMN permanently NULL for every HTTP-sourced entry, even though a
      # substring check on the raw log TEXT (the old, insufficient AC5 test
      # coverage) could not detect it. Assert on the actual persisted COLUMN
      # here, not just message/metadata text.
      route_template_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT route_template FROM operational_logs WHERE request_id = $1 AND route_template IS NOT NULL",
          [request_id]
        )

      assert route_template_result.num_rows > 0,
             "expected at least one operational_logs row for this request to have a " <>
               "non-NULL route_template column, got 0 matching rows for request_id " <>
               "#{inspect(request_id)}"

      # This one request produces (at least) two operational_logs rows — the
      # base INFO line and the DEBUG payload line — both carrying the SAME
      # `Logger.metadata/1`-propagated route_template.
      persisted_route_templates = Enum.map(route_template_result.rows, fn [rt] -> rt end)

      assert Enum.all?(
               persisted_route_templates,
               &(&1 == "/_matrix/client/v3/rooms/:room_id/send/:event_type/:txn_id")
             ),
             "expected every persisted route_template column for this request to be the " <>
               "fully-normalized template (room ID, event type, and txn_id all replaced " <>
               "with placeholders), got: #{inspect(persisted_route_templates)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # enhanced-logging/war-room-mode (AC4) — an active, MATCHING war room
  # session overrides the ambient per-level retention policy AND the
  # redaction LAW above still holds for every entry it collects.
  #
  # Design decisions (war-room-mode/design-decisions.md #3): the match/tag/
  # budget-check happens SYNCHRONOUSLY in Handler.log/2, BEFORE the
  # should_persist?/1 gate — via Nebu.Web.LogStore.WarRoom.check/1 — not
  # deferred into Writer.flush_buffer/1 (the story's own moduledoc suggestion
  # is wrong for correctness: Writer never even sees an entry
  # should_persist?/1 already discarded). These tests drive REAL requests
  # through Nebu.Web.Router (same as the SECURITY LAW tests above), with a
  # REAL war_room_sessions row created through
  # Nebu.Admin.WarRoomManager.start_session/1 (the same "front door" the
  # admin LiveView calls), so a passing test here proves the full
  # Handler -> WarRoom -> Writer chain end-to-end, not just an isolated unit.
  #
  # Why these MUST FAIL right now: neither Nebu.Web.LogStore.WarRoom nor
  # Nebu.Admin.WarRoomManager nor the war_room_sessions table exist yet.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4 (war-room-mode): active matching war room overrides ambient retention policy" do
    @describetag :integration

    test "a DEBUG entry is persisted and tagged with war_room_id even though log_collect_debug=false" do
      Nebu.Release.migrate()
      ensure_war_room_deps_started!()

      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_info" => "false",
        "log_collect_debug" => "false"
      })

      end_all_active_war_rooms!()

      run_id = war_room_run_id()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "distinctive-war-room-override-test-#{run_id}",
          reason: "AC4 ambient-policy-override test",
          scope: "all",
          max_entries: 1000,
          max_duration_s: 300
        })

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM war_room_sessions WHERE id = $1", [
            session.id
          ])

          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM server_config WHERE key IN ($1, $2)",
            ["log_collect_info", "log_collect_debug"]
          )
        end
      end)

      conn =
        with_log_level(:debug, fn ->
          call(:get, "/_matrix/client/v3/sync", nil)
        end)

      request_id = conn |> Plug.Conn.get_resp_header("x-request-id") |> List.first()
      refute is_nil(request_id)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE request_id = $1",
            [request_id]
          )
        end
      end)

      result =
        wait_until_persisted_rows(
          "SELECT level, war_room_id FROM operational_logs WHERE request_id = $1 AND level = 'debug'",
          [request_id]
        )

      assert result.num_rows > 0,
             "expected the DEBUG payload line for this request to be persisted DESPITE " <>
               "log_collect_debug=false, because an active, matching war room session must " <>
               "override the ambient per-level retention policy (AC4)"

      war_room_ids = Enum.map(result.rows, fn [_level, wr_id] -> wr_id end)

      assert session.id in war_room_ids,
             "expected at least one persisted DEBUG row for this request to be tagged with " <>
               "the active war room session's id, got: #{inspect(war_room_ids)}"

      updated =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT entries_collected FROM war_room_sessions WHERE id = $1",
          [session.id]
        )

      assert [[collected]] = updated.rows
      assert collected > 0,
             "expected entries_collected to have incremented for the matching, tagged entry"
    end

    test "an entry NOT matching the war room's scope is not tagged and does not increment entries_collected" do
      Nebu.Release.migrate()
      ensure_war_room_deps_started!()

      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_info" => "true",
        "log_collect_debug" => "false"
      })

      end_all_active_war_rooms!()

      run_id = war_room_run_id()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "distinctive-war-room-scope-test-#{run_id}",
          reason: "AC4 scope-mismatch test",
          scope: "/_matrix/client/v3/sync",
          max_entries: 1000,
          max_duration_s: 300
        })

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM war_room_sessions WHERE id = $1", [
            session.id
          ])

          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM server_config WHERE key IN ($1, $2)",
            ["log_collect_info", "log_collect_debug"]
          )
        end
      end)

      # test-quality fix (dev-story, not a design decision): this test
      # asserts on the request's INFO base line (`Logger.info(base_fields)`
      # in `RequestLogger`'s `before_send` callback), which — like every
      # `Logger.*` call — is a complete NO-OP whenever the ambient
      # `Logger.level()` is above `:info` (this project's `config/test.exs`
      # sets the default to `:warning`). Every OTHER test in this describe
      # block wraps its own request in `with_log_level(:debug, fn -> ...
      # end)` (needed there for the DEBUG payload line); this one, needing
      # only the INFO line, was missing an equivalent wrap entirely —
      # happened to still pass most of the time only because some OTHER,
      # concurrently-running async test elsewhere in the full suite
      # transiently keeps the GLOBAL Logger level elevated, which is not a
      # reliable precondition (confirmed flaky/failing when this file runs
      # in isolation, or whenever no such concurrent test overlaps).
      conn =
        with_log_level(:info, fn ->
          call(
            :get,
            "/_matrix/client/v3/profile/@alice-war-room-scope-test-#{run_id}:localhost",
            nil
          )
        end)

      request_id = conn |> Plug.Conn.get_resp_header("x-request-id") |> List.first()
      refute is_nil(request_id)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE request_id = $1",
            [request_id]
          )
        end
      end)

      # This request's INFO base line persists via the ambient policy
      # (log_collect_info=true) regardless of the war room — that's what
      # makes "war_room_id IS NULL" a meaningful assertion below, rather
      # than trivially true because nothing was persisted at all.
      result =
        wait_until_persisted_rows(
          "SELECT war_room_id FROM operational_logs WHERE request_id = $1 AND level = 'info'",
          [request_id]
        )

      assert Enum.all?(result.rows, fn [wr_id] -> is_nil(wr_id) end),
             "a request to a route that does NOT match the war room's scope must never be " <>
               "tagged with war_room_id, got: #{inspect(result.rows)}"

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT entries_collected FROM war_room_sessions WHERE id = $1",
          [session.id]
        )

      assert [[0]] = count_result.rows,
             "entries_collected must remain 0 when no entry has matched this session's scope"
    end

    test "a send-event request during an active, matching war room session still never leaks the raw message body" do
      Nebu.Release.migrate()
      ensure_war_room_deps_started!()

      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_info" => "false",
        "log_collect_debug" => "false"
      })

      end_all_active_war_rooms!()

      run_id = war_room_run_id()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "distinctive-war-room-redaction-test-#{run_id}",
          reason: "AC4 + redaction LAW regression",
          scope: "all",
          max_entries: 1000,
          max_duration_s: 300
        })

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM war_room_sessions WHERE id = $1", [
            session.id
          ])

          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM server_config WHERE key IN ($1, $2)",
            ["log_collect_info", "log_collect_debug"]
          )
        end
      end)

      conn =
        with_log_level(:debug, fn ->
          call(
            :put,
            "/_matrix/client/v3/rooms/!room:localhost/send/m.room.message/txn-war-room-redaction-#{run_id}",
            %{
              "body" => "distinctive-secret-message-text-war-room-#{run_id}",
              "msgtype" => "m.text"
            }
          )
        end)

      request_id = conn |> Plug.Conn.get_resp_header("x-request-id") |> List.first()
      refute is_nil(request_id)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE request_id = $1",
            [request_id]
          )
        end
      end)

      result =
        wait_until_persisted_rows(
          "SELECT message, metadata::text, war_room_id FROM operational_logs " <>
            "WHERE request_id = $1 AND war_room_id IS NOT NULL",
          [request_id]
        )

      assert result.num_rows > 0,
             "expected at least one war-room-tagged row for this request (log_collect_debug " <>
               "is FALSE, so persistence here can ONLY come from the active, matching war " <>
               "room session — proving AC4's override actually fired)"

      serialized =
        result.rows
        |> Enum.map(fn [message, metadata_text, _wr_id] -> "#{message} #{metadata_text}" end)
        |> Enum.join(" ")

      refute String.contains?(
               serialized,
               "distinctive-secret-message-text-war-room-#{run_id}"
             ),
             "the raw message body must NEVER appear in a war-room-collected " <>
               "operational_logs row — bypassing the ambient retention policy (AC4) must " <>
               "NEVER bypass redaction"

      assert String.contains?(serialized, "***MESSAGE_CONTENT***"),
             "the redaction marker must be present in the war-room-tagged row, proving this " <>
               "assertion is not vacuously true"
    end
  end

  defp war_room_run_id, do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"

  defp ensure_war_room_deps_started! do
    case Process.whereis(Nebu.Web.LogStore.Writer) do
      nil -> start_supervised!(Nebu.Web.LogStore.Writer)
      _existing -> :ok
    end

    case Process.whereis(Nebu.Web.LogStore.WarRoom) do
      nil -> start_supervised!(Nebu.Web.LogStore.WarRoom)
      _existing -> :ok
    end

    :ok = Nebu.Web.LogStore.attach_handler()
  end

  defp end_all_active_war_rooms! do
    if Process.whereis(Nebu.Repo) do
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
        []
      )
    end
  end

  # Polls the DB every 200ms (up to `timeout_ms`) until `sql` returns a
  # non-empty result, or fails the test. Mirrors writer_test.exs's helper —
  # duplicated locally to keep this file's DB-dependent test self-contained
  # (this is the only test in this file that touches Nebu.Repo).
  defp wait_until_persisted_rows(sql, params, timeout_ms \\ 7_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_persisted_rows(sql, params, deadline)
  end

  defp do_wait_until_persisted_rows(sql, params, deadline) do
    result = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params)

    cond do
      result.num_rows > 0 ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for rows matching #{sql} #{inspect(params)}")

      true ->
        Process.sleep(200)
        do_wait_until_persisted_rows(sql, params, deadline)
    end
  end
end
