defmodule Nebu.Admin.LogsLive.TraceMapNodeControlsContractTest do
  @moduledoc """
  RED-phase ATDD contract tests for `enhanced-logging/trace-map-node-controls`
  — the PURE-LOGIC half (AC4, AC5, AC6, AC12, AC13): off-list resolution,
  capture-expiry comparison, cascade-set computation, the configurable
  capture duration, the route-aware persistence policy, and the audit-action
  vocabulary (AC12 Option B, per the story's ANSWERED design question 2).

  Story: docs/stories/enhanced-logging/trace-map-node-controls.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §4/§5

  The LiveView rendering/event half lives in
  `trace_map_node_controls_test.exs` (same directory); the DB-backed
  manager behavior in `temporary_capture_manager_test.exs`; the browser-only
  half in `e2e/features/admin/logs-trace-map-node-controls.feature`
  (@pending-feature). This file COMPOSES with the shipped
  `trace_map_leitstand_test.exs` — nothing here contradicts that file's
  pinned contract.

  ## Why these MUST FAIL right now

  None of the functions below exist yet:

    * `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0`,
      `off_endpoint?/1`, `cascade_targets/2` — the module exists but these
      functions are new -> `UndefinedFunctionError` (red, not a compile
      error: remote calls to missing functions only warn).
    * `Nebu.Admin.TemporaryCaptureManager` — module does not exist at all.
    * `Nebu.Web.LogStore.should_persist?/2` — only the `/1` arity exists.
    * `"enable_temporary_capture"` / `"disable_temporary_capture"` are not
      in `Nebu.Compliance.AuditWriter`'s `@known_actions` allowlist ->
      `{:error, :audit_unknown_action}` (red).

  ## Contract pinned by this file

    * AC4/AC13: `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` is
      the canonical, reusable off-by-default list (the superseded
      `noise-endpoint-bucketing` story's backend concept) — default members
      exactly `/_matrix/client/v3/sync`, `/admin/keepalive`, `/health`.
      `off_endpoint?/1` is the membership predicate.
    * AC1/AC2 cascade: `cascade_targets(node_key, endpoint_order)` is a PURE
      function (ADR-018/021 plain module style) computing which observed
      endpoint route templates a config change on `node_key` applies to:
      the endpoint itself for a satellite, every endpoint of the domain for
      a domain key (via `TraceMapTree.domain_for_endpoint/1`, never a
      duplicated heuristic), every observed endpoint for `"nebu"`.
    * AC5/AC6 (ANSWERED design question 1: DB-backed timer — "state is a
      row, expiry is a comparison against now()"):
      `Nebu.Admin.TemporaryCaptureManager.expired?(capture, now)` and
      `remaining_seconds(capture, now)` are pure comparisons over the
      capture row's `:expires_at` `DateTime` — no process timer owns
      correctness. `capture_duration_s/0` reads
      `Application.get_env(:nebu, :temporary_capture_duration_s, 300)`
      (ANSWERED design question 3, war_room_manager precedent).
      `active?/1` is guarded behind `Process.whereis(Nebu.Repo)` (the same
      DB-free-unit-test contract as `initial_war_room_status/0`) and
      answers `false` when no Repo is running.
    * AC4 enforcement: `Nebu.Web.LogStore.should_persist?/2`
      `(level, route_template)` — the route-aware policy check the ingest
      path needs. An off-list route with NO active capture suppresses
      DEBUG/INFO/WARN persistence, but **ERROR-level entries are ALWAYS
      persisted** (story amendment 2026-07-07, "AC4 errors-always-persist
      exception": "off" silences noise, never failures — a silently-red
      zone contradicts the leitstand mission). Any other route (or a nil
      route) delegates to the existing level-only `/1` policy. The
      capture-active branch needs the DB and is pinned in
      `temporary_capture_manager_test.exs`.
    * AC12 (Option B — ANSWERED design question 2): the audit-action
      vocabulary `enable_temporary_capture` / `disable_temporary_capture`
      must be accepted by `Nebu.Compliance.AuditWriter.log/6`'s
      `@known_actions` allowlist ("Adding a new audit action requires
      updating this list first" — audit_writer.ex's own doc).
  """

  # async: false — the duration/audit describe blocks mutate process-global
  # Application env keys ({:nebu, :temporary_capture_duration_s} and
  # {:compliance, :repo}), same reasoning as audit_writer_test.exs.
  use ExUnit.Case, async: false

  alias Nebu.Admin.LogsLive.TraceMap
  alias Nebu.Admin.TemporaryCaptureManager

  @off_defaults ["/_matrix/client/v3/sync", "/admin/keepalive", "/admin/live/longpoll", "/health"]

  # ══════════════════════════════════════════════════════════════════════
  # AC4/AC13: the canonical long-polling off-list
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4/AC13: long_polling_endpoints/0 is the canonical config-driven off-list" do
    test "the default list is exactly sync, keepalive, admin longpoll, and health" do
      assert Enum.sort(TraceMap.long_polling_endpoints()) == Enum.sort(@off_defaults)
    end

    test "off_endpoint?/1 resolves membership for every default member" do
      for route <- @off_defaults do
        assert TraceMap.off_endpoint?(route),
               "AC4: #{route} is in the default off-list and must resolve as off"
      end
    end

    test "off_endpoint?/1 is false for ordinary endpoints, domains, and nebu" do
      refute TraceMap.off_endpoint?("/admin/users")
      refute TraceMap.off_endpoint?("/_matrix/client/v3/login")
      refute TraceMap.off_endpoint?("/_matrix/client")
      refute TraceMap.off_endpoint?("nebu")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1/AC2: cascade-set computation (pure)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: cascade_targets/2 computes the descendant set for a config change" do
    @order [
      "/admin/users",
      "/admin/rooms",
      "/_matrix/client/v3/login",
      "/_matrix/media/v3/upload"
    ]

    test "a satellite key cascades only to itself ('Applies to this endpoint only')" do
      assert TraceMap.cascade_targets("/admin/users", @order) == ["/admin/users"]
    end

    test "a domain key cascades to every observed endpoint of that domain, and no others" do
      assert Enum.sort(TraceMap.cascade_targets("/admin", @order)) ==
               ["/admin/rooms", "/admin/users"]
    end

    test "nebu cascades to every observed endpoint on the map" do
      assert Enum.sort(TraceMap.cascade_targets("nebu", @order)) == Enum.sort(@order)
    end

    test "a single-segment route that is its own domain cascades to itself exactly once" do
      # /health is simultaneously a domain key AND a satellite key
      # (TraceMapTree.domain_for_endpoint("/health") == "/health") — the
      # cascade set must not contain it twice (the same dedupe class as
      # code-review M1 in trace_map_leitstand_test.exs).
      assert TraceMap.cascade_targets("/health", ["/health" | @order]) == ["/health"]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5/AC6: capture expiry is a pure comparison; duration is env-config
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5/AC6: TemporaryCaptureManager pure expiry comparison" do
    @capture %{
      endpoint: "/health",
      enabled_at: ~U[2026-07-07 10:00:00Z],
      expires_at: ~U[2026-07-07 10:05:00Z],
      started_by: "@admin:test.local"
    }

    test "expired?/2 is false strictly before expires_at" do
      refute TemporaryCaptureManager.expired?(@capture, ~U[2026-07-07 10:04:59Z])
    end

    test "expired?/2 is true at and after expires_at" do
      assert TemporaryCaptureManager.expired?(@capture, ~U[2026-07-07 10:05:00Z])
      assert TemporaryCaptureManager.expired?(@capture, ~U[2026-07-07 11:00:00Z])
    end

    test "remaining_seconds/2 counts down to the expiry" do
      assert TemporaryCaptureManager.remaining_seconds(@capture, ~U[2026-07-07 10:03:30Z]) == 90
    end

    test "remaining_seconds/2 clamps at zero after expiry (never negative)" do
      assert TemporaryCaptureManager.remaining_seconds(@capture, ~U[2026-07-07 10:06:00Z]) == 0
    end
  end

  describe "AC5: capture duration comes from Application env (war_room_manager precedent)" do
    test "capture_duration_s/0 defaults to 300 seconds (5 minutes)" do
      previous = Application.fetch_env(:nebu, :temporary_capture_duration_s)
      Application.delete_env(:nebu, :temporary_capture_duration_s)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:nebu, :temporary_capture_duration_s, value)
          :error -> :ok
        end
      end)

      assert TemporaryCaptureManager.capture_duration_s() == 300
    end

    test "capture_duration_s/0 honors the :temporary_capture_duration_s override" do
      Application.put_env(:nebu, :temporary_capture_duration_s, 7)
      on_exit(fn -> Application.delete_env(:nebu, :temporary_capture_duration_s) end)

      assert TemporaryCaptureManager.capture_duration_s() == 7
    end
  end

  describe "AC5: active?/1 is DB-guarded (unit-test contract, no Nebu.Repo running)" do
    @describetag :no_repo
    test "with no Repo, no endpoint has an active capture" do
      refute Process.whereis(Nebu.Repo),
             "precondition: this is the DB-free unit environment"

      refute TemporaryCaptureManager.active?("/health"),
             "AC5: without a reachable captures table there is no active capture — " <>
               "mirror initial_war_room_status/0's Process.whereis(Nebu.Repo) guard"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4: route-aware persistence policy (server-side enforcement)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: should_persist?/2 blocks off-list routes with no active capture" do
    @describetag :no_repo
    # Levels probed DB-free: "warning" (the /1 catch-all — unconditionally
    # true at level policy, so a `false` here can ONLY come from the
    # off-list branch) and "error" (same catch-all). "debug"/"info" read
    # the PolicyCache and are deliberately not probed in this DB-free file.
    test "an off-list route suppresses warnings without a capture" do
      for route <- @off_defaults do
        refute Nebu.Web.LogStore.should_persist?("warning", route),
               "AC4: WARN entries for off-list route #{route} must NOT be persisted " <>
                 "(no active capture)"
      end
    end

    test "ERROR always persists, even on an off-list route (amendment 2026-07-07)" do
      for route <- @off_defaults do
        assert Nebu.Web.LogStore.should_persist?("error", route),
               "AC4 errors-always-persist exception: 'off' silences noise, never " <>
                 "failures — ERROR on #{route} must be persisted even without a capture"
      end
    end

    test "a non-off route delegates to the level-only policy (error/warning always persist)" do
      assert Nebu.Web.LogStore.should_persist?("error", "/admin/users")
      assert Nebu.Web.LogStore.should_persist?("warning", "/_matrix/client/v3/login")
    end

    test "a nil route (no route_template) delegates to the level-only policy" do
      assert Nebu.Web.LogStore.should_persist?("error", nil)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC12 (Option B): audit-action vocabulary
  # ══════════════════════════════════════════════════════════════════════

  describe "AC12: enable/disable_temporary_capture are known audit actions" do
    # FakeRepo pattern copied from audit_writer_test.exs — the allowlist
    # check happens BEFORE any DB call, so a fake repo isolates exactly the
    # vocabulary contract: today these two actions are rejected with
    # {:error, :audit_unknown_action} (red); once added to @known_actions
    # the write goes through the fake and returns :ok (green).
    defmodule FakeRepo do
      def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
      def insert(struct, _opts \\ []), do: {:ok, struct}

      def insert!(struct, opts \\ []) do
        {:ok, s} = insert(struct, opts)
        s
      end
    end

    setup do
      Application.put_env(:compliance, :repo, FakeRepo)
      on_exit(fn -> Application.delete_env(:compliance, :repo) end)
      :ok
    end

    test "enable_temporary_capture is accepted by the AuditWriter allowlist" do
      assert Nebu.Compliance.AuditWriter.log(
               "@admin:test.local",
               "enable_temporary_capture",
               "endpoint",
               "/health",
               %{},
               "success"
             ) == :ok
    end

    test "disable_temporary_capture is accepted by the AuditWriter allowlist" do
      assert Nebu.Compliance.AuditWriter.log(
               "@admin:test.local",
               "disable_temporary_capture",
               "endpoint",
               "/health",
               %{},
               "success"
             ) == :ok
    end
  end
end
