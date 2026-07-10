defmodule Nebu.Admin.LogsLiveTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/admin-logs-monitoring-view`
  (Acceptance Tests 1-10 and 12 from the story's "Acceptance Tests" section;
  Acceptance Test 11 — `trace_map_bubble/1` component reusability — lives in
  `test/nebu/admin/logs_live/trace_map_bubble_test.exs`).

  Story: docs/stories/enhanced-logging/admin-logs-monitoring-view.md

  ## Why these MUST FAIL right now

  None of `Nebu.Admin.LogsLive` (server/lib/nebu/admin/logs_live.ex),
  `Nebu.Admin.LogsLive.TraceMapBubble`
  (server/lib/nebu/admin/logs_live/trace_map_bubble.ex), or
  `Nebu.Admin.LogsLive.DetailPanel`
  (server/lib/nebu/admin/logs_live/detail_panel.ex) exist yet. `router.ex` has
  no `/admin/logs` route either. Every test below fails when `live_isolated/3`
  tries to mount `Nebu.Admin.LogsLive` — expect
  `** (UndefinedFunctionError) function Nebu.Admin.LogsLive.__live__/0 is
  undefined` (or an equivalent "module is not available" error from
  `Phoenix.LiveView.Utils`/`Phoenix.LiveViewTest`), NOT a compile error in
  this file.

  ## Contract this file pins down for the dev agent

  ### PubSub message shape — VERIFIED against the already-merged
  `operational-log-store` sibling story's actual code, NOT the
  `{:operational_log_entry, entry_map}` tuple the STORY'S OWN Dev Notes
  describe (that tuple shape does not exist anywhere in the merged code):

  `server/lib/nebu/web/log_store/handler.ex`, `safe_broadcast/1`
  (around line 139):

      defp safe_broadcast(entry) do
        if Process.whereis(Nebu.PubSub) do
          Phoenix.PubSub.broadcast(Nebu.PubSub, "operational_logs", entry)
        end
        :ok
      end

  `entry` is the bare map built by `parse_log_event/1` (handler.ex, around
  line 53):

      %{level: "error", source: "http", route_template: "/login",
        request_id: "req-1", message: "boom", metadata: %{}}

  i.e. `handle_info/2` in `Nebu.Admin.LogsLive` MUST match the bare map
  directly (e.g. `def handle_info(%{level: _, source: _, request_id: _} =
  entry, socket)`), NOT a 2-tuple. The `entry/1` / `http_entry/1` helpers
  below construct exactly this shape — no `id`, no `inserted_at`, no
  `war_room_id` (those three only exist on the persisted DB row returned by
  `Nebu.Web.LogStore.get_logs/1`, never on the broadcast message).

  ### Fixture assumption re: HTTP entries' `metadata` (see the ATDD handoff
  report for full rationale — flagging here too since it affects every
  method/status/duration_ms assertion below):

  The REAL `Nebu.Web.Plugs.RequestLogger` plug logs HTTP request/response
  fields via `Logger.info(base_fields)` where `base_fields` is a plain map
  (method/path/status/duration_ms/request_id/route_template) — Elixir's
  `Logger` treats that as a "report", and `Handler.render_msg/1`'s
  `{:report, report}` clause (handler.ex, around line 122) renders the WHOLE
  map into the entry's `message` field via `inspect/1`. None of
  method/status/duration_ms survive into the `metadata` column for real HTTP
  entries today — only `Logger.metadata/1`-set keys do, and
  `route_template`/`request_id` are stripped back out by `@drop_meta_keys`
  since they are already their own top-level fields.

  This is a genuine mismatch with the story's own Dev Notes ("Architecture &
  Implementation Hints" item 2: "look for an operational_logs entry with
  `source=\"http\"` and extract the status from `metadata.status`"). Rather
  than asserting against `inspect/1`-rendered text (which `LogsLive` would
  have to regex-parse — fragile, and not what the Dev Notes describe), this
  file follows the Dev Notes' documented target contract: fixture HTTP
  entries place `method`/`status`/`duration_ms` directly under `metadata` as
  the shape `Nebu.Admin.LogsLive` is expected to read. Reconciling this with
  `RequestLogger`'s actual current behavior (likely: a follow-up fix so
  `RequestLogger` also calls `Logger.metadata/1` with these fields before
  logging, or `LogsLive` learns to parse `message`) is OUT OF SCOPE for this
  ATDD pass and is called out explicitly in the handoff report.

  ## Auth / mounting

  `{Nebu.Admin.Auth, :require_admin}` is wired via the ROUTER's
  `live_session :admin` block (see `router.ex`), not declared inside the
  LiveView module itself — mirrors every existing LiveView in this codebase
  (`AuditLogLive`, `BootstrapLive`, `RoomsLive`, none of which declare their
  own `on_mount`). Per the established precedent in
  `test/nebu/web/admin_bootstrap_live_test.exs` (`live_isolated/3` with a
  `session: %{"current_user" => %{"admin" => true, ...}}` map), these tests
  mount `LogsLive` directly via `live_isolated/3`, bypassing the router (and
  therefore the on_mount hook) entirely.

  ## Data-attribute contract (proposed, for the dev agent to implement)

  Since none of the markup exists yet, this file also pins down the
  `data-*`/`aria-*` test hooks the implementation must render (mirrors the
  existing `data-step`/`data-progress-step` convention used by
  `bootstrap_live_test.exs`):

    * Trace Map bubble: `<button data-testid="trace-map-bubble"
      data-bubble-dimension={dimension} data-bubble-value={value}
      data-bubble-count={count} aria-pressed={...} aria-label={...}
      phx-click={a Phoenix.LiveView.JS command list, e.g.
      JS.toggle_attribute({"aria-pressed", "true", "false"})}>`. CORRECTION
      (test-review finding #3, superseding this paragraph's original
      `phx-click="toggle_filter"` proposal): AC3 requires the filter toggle to
      be CLIENT-SIDE ONLY (no server round-trip), so `phx-click` MUST be bound
      to a `Phoenix.LiveView.JS` command list, NEVER a bare `handle_event`
      event-name string — a rendered `phx-click` attribute value that does
      NOT start with `[` (i.e. looks like a bare event name) fails
      Acceptance Test 1/1b/2's static contract checks. Uncollected/"off"
      bubbles additionally carry `data-bubble-off="true"` and visible text
      containing "off".
    * Active-filter chip row: `data-testid="active-filter-chips"` container;
      each chip `data-testid="filter-chip" data-chip-dimension={..}
      data-chip-value={..}` (pre-rendered for every bubble, client-side
      shown/hidden in lockstep with that bubble's `aria-pressed` — there is no
      server-held `@active_filters` assign to read from) containing a remove
      ("×") control `data-testid="filter-chip-remove"` whose `phx-click` is,
      like the bubble's, a `Phoenix.LiveView.JS` command list — NOT
      `phx-click="toggle_filter"` as this paragraph originally proposed
      before the AC3/AC5 reconciliation (test-review finding #3/#4).
    * Request-stream row: `data-testid="request-row"
      data-request-id={request_id} data-highest-level={level}`, clickable
      via `phx-click="open_detail" phx-value-request_id={request_id}`.
    * Detail panel: `data-testid="detail-panel" data-request-id={id}`;
      each entry `data-testid="detail-entry"`; close button
      `phx-click="close_detail"`; copy button
      `data-testid="copy-thread-button"`.
    * New-entries banner: `data-testid="new-entries-banner"
      aria-live="polite"`; resume control
      `phx-click="resume_live_updates"`. This file also assumes (proposed,
      undocumented-elsewhere seam) a `handle_event("pause_live_updates", ...)`
      the client would push on scroll — flagged as an assumption in the
      handoff report since the story's Dev Notes do not name this event.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  # enhanced-logging/war-room-mode (AC12): `Phoenix.LiveViewTest.live/1`'s
  # `defmacro live(conn, path \\ nil, opts \\ [])` embeds a reference to an
  # unqualified `get(conn, path)` call in its `quote` block for the
  # `is_binary(path)` branch — even when called as `live(conn)` (single
  # arg, `path` defaulting to `nil`, which takes the OTHER branch at
  # runtime), the compiler still resolves `get/2` at COMPILE time for the
  # whole macro expansion, so `Phoenix.ConnTest.get/2` must be imported
  # regardless of which branch actually executes. Needed only by the
  # router-based mount in the "AC12: mount/3's war_room_id param..."
  # describe block below (which needs a REAL router-dispatched conn, via
  # `@endpoint.call/2`, so `mount/3`'s `params` argument is an actual
  # query-param map — not the `:not_mounted_at_router` atom
  # `live_isolated/3` always passes); every other test in this file uses
  # `live_isolated/3` instead, which does not need this import.
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint
  @topic "operational_logs"

  @admin_session %{"current_user" => %{"admin" => true, "sub" => "admin-logs-tests"}}

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp mount_logs_live(session \\ @admin_session) do
    live_isolated(Plug.Test.conn(:get, "/admin/logs"), Nebu.Admin.LogsLive, session: session)
  end

  # Builds a broadcast entry in the EXACT shape `Nebu.Web.LogStore.Handler`
  # actually sends (see moduledoc) — a bare map, no tuple wrapper, no
  # id/inserted_at/war_room_id.
  #
  # bug-fix cycle 6: `source: "http"`/`source: "ecto"` fixtures below (and in
  # `http_entry/1`) hand-set the field directly rather than deriving it
  # through the real `Nebu.Web.LogStore.Handler.source_from_meta/1`
  # classification path — this was already the CORRECT/intended contract
  # (`LogsLive` consuming a correctly-classified entry), it just didn't match
  # what `source_from_meta/1` actually produced for real Logger calls until
  # this cycle's fix (it always classified as "unknown", keying off a bare
  # `:module` metadata key Elixir's Logger macros never set). These fixtures
  # remain accurate and unchanged; see `handler_test.exs` and
  # `request_logger_test.exs`'s M2 test for coverage of the classification
  # itself now matching this contract end-to-end.
  defp entry(overrides) do
    Map.merge(
      %{
        level: "info",
        source: "other",
        route_template: nil,
        request_id: "req-#{System.unique_integer([:positive, :monotonic])}",
        message: "distinctive test log entry",
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  # HTTP-entry convenience wrapper — see moduledoc's fixture-assumption note.
  # `method`/`status`/`duration_ms` are placed under `metadata` (string keys,
  # matching `Handler.safe_metadata/1`'s string-key coercion).
  defp http_entry(overrides) do
    overrides = Map.new(overrides)
    {meta_overrides, top_overrides} = Map.split(overrides, [:method, :status, :duration_ms])

    metadata =
      meta_overrides
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    entry(Map.merge(%{source: "http", metadata: metadata}, top_overrides))
  end

  defp broadcast_entry(overrides) do
    e = entry(overrides)
    Phoenix.PubSub.broadcast(Nebu.PubSub, @topic, e)
    e
  end

  defp broadcast_http_entry(overrides) do
    e = http_entry(overrides)
    Phoenix.PubSub.broadcast(Nebu.PubSub, @topic, e)
    e
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 1 [AC1-AC5] — Trace Map renders with live counts
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 1 [AC1-AC5]: Trace Map renders with live counts" do
    # ── AC3 vs AC5 reconciliation (test-review finding #3) ──────────────────
    # AC3 mandates the Trace Map's filter toggle is CLIENT-SIDE ONLY — no
    # server round-trip per bubble click. AC5/Dev Notes describe the bubble as
    # wiring "phx-click", which reconciles with AC3 via the standard Phoenix
    # idiom: `phx-click` is bound to a `Phoenix.LiveView.JS` command list
    # (e.g. `JS.toggle_attribute/JS.toggle_class`), NOT a bare
    # `handle_event`-push event name. `Phoenix.LiveViewTest`'s `render_click/1`
    # always performs a REAL server round-trip — using it to assert the
    # filter-toggle behavior would therefore test something the real, AC3-
    # compliant implementation must NOT do (and, against a genuine JS-command
    # `phx-click`, `render_click/1` has no matching `handle_event` to hit
    # anyway). This test is corrected to assert only the STATIC HTML CONTRACT
    # the client-side JS command needs to function (aria-pressed defaults to
    # "false", `data-bubble-dimension`/`data-bubble-value` present, and
    # `phx-click`'s value is shaped like a JS command list, never a bare event
    # name). The actual runtime click-to-filter behavior (rows filtering, no
    # network round-trip) is authoritatively verified by
    # `e2e/features/admin/logs-monitoring.feature` (Playwright, real browser)
    # — Phoenix.LiveViewTest cannot execute real browser JS.
    # enhanced-logging/trace-map-leitstand (AC13): the endpoint-bubble half of
    # this test was retired together with the Endpoints dimension itself —
    # endpoint filtering now lives on /admin/logs/trace-map (see
    # trace_map_retirement_test.exs for the removal contract; the Levels and
    # Sources bubbles asserted here are unchanged).
    test "an ERROR/http broadcast increments the ERROR and http bubbles; both stay clickable via a client-side-only phx-click contract; the chip row renders" do
      {:ok, view, _html} = mount_logs_live()

      # Under `make test-integration` (full docker-compose stack), LogsLive is
      # mounted against the REAL, suite-wide `Nebu.PubSub` — hundreds of OTHER
      # concurrently-running test files make real HTTP requests that flow
      # through the real `RequestLogger` plug and broadcast real entries onto
      # this same "operational_logs" topic. A bare `== 1` count assertion is
      # therefore not robust: capture a baseline BEFORE this test's own
      # broadcast and assert the count increased by exactly 1 relative to it —
      # immune to background noise while still meaningfully proving
      # "broadcasting this entry increments the bubble".
      baseline_html = parsed(render(view))
      baseline_error = bubble_count(find_bubble(baseline_html, "level", "error")) || 0
      baseline_http = bubble_count(find_bubble(baseline_html, "source", "http")) || 0

      broadcast_entry(level: "error", source: "http", route_template: "/login")

      html = parsed(render(view))

      error_bubble = find_bubble(html, "level", "error")
      http_bubble = find_bubble(html, "source", "http")

      assert error_bubble, "expected a Trace Map bubble for level=error"
      assert http_bubble, "expected a Trace Map bubble for source=http"

      assert bubble_count(error_bubble) == baseline_error + 1
      assert bubble_count(http_bubble) == baseline_http + 1

      # Still clickable: aria-pressed is present and false (default: all filters
      # inactive = everything visible, AC1).
      assert bubble_attr(error_bubble, "aria-pressed") == "false"
      assert bubble_attr(http_bubble, "aria-pressed") == "false"

      # Static client-side-only contract (see comment block above): every
      # bubble's `phx-click` must be a Phoenix.LiveView.JS command list — a
      # serialized JSON array, e.g. `[["attr", ...]]` — never a bare
      # `handle_event` event-name string like `"toggle_filter"`.
      for bubble <- [error_bubble, http_bubble] do
        phx_click = bubble_attr(bubble, "phx-click")
        assert phx_click, "expected the bubble to carry a phx-click attribute"

        assert String.starts_with?(phx_click, "["),
               "phx-click=#{inspect(phx_click)} looks like a bare handle_event push, not a " <>
                 "Phoenix.LiveView.JS command list — violates AC3 (client-side-only filter toggle)"
      end

      # AC4: the active-filter chip row container is part of the static
      # markup (its content/visibility toggles client-side in lockstep with
      # the bubbles' aria-pressed state — see Acceptance Test 1b for the
      # chip-removal contract). This assertion is unrelated to the
      # click-toggle mechanism above and stays as originally generated.
      assert Floki.find(html, ~s([data-testid="active-filter-chips"])) != [],
             "expected the active-filter chip row container to render"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 1b [AC4] — Active-filter chip removal is a distinct,
  # client-side-only interaction (test-review finding #4/#5 in the epic's
  # test-review-findings.md; numbered "5" there — chip-removal coverage gap)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 1b [AC4]: chip removal is a distinct client-side interaction" do
    # Same AC3 reasoning as Acceptance Test 1's comment block: removing a
    # filter via a chip's "×" must ALSO be client-side-only (there is no
    # server-held `@active_filters` assign to push a `handle_event` against —
    # see Test 1's reconciliation comment). Because a chip only becomes
    # VISIBLE once its filter is active — an outcome only real client-side JS
    # can produce, not `Phoenix.LiveViewTest` — its markup (including the
    # remove control) must already exist in the server-rendered DOM,
    # client-side-toggled between hidden/visible in lockstep with the
    # bubble's own aria-pressed state. This test pins down that static
    # contract: a chip paired to the level=error bubble exists in the initial
    # render, is a DISTINCT DOM node from the bubble itself (proving "click a
    # chip's ×" is a different interaction from "re-click the bubble", not an
    # alias for the same element — the gap test-review flagged), and its own
    # remove control carries a client-side JS-command `phx-click`, never a
    # bare event name. The actual visible show/hide behavior driven by a real
    # click is NOT verifiable here (no browser JS in ExUnit) — authoritatively
    # verified by `e2e/features/admin/logs-monitoring.feature`.
    test "the active-filter chip paired to a bubble carries its own remove (\"×\") control, distinct from the bubble, bound to a client-side command" do
      {:ok, view, _html} = mount_logs_live()

      broadcast_entry(level: "error", source: "http", route_template: "/login")

      html = parsed(render(view))

      bubble = find_bubble(html, "level", "error")
      assert bubble, "expected the level=error bubble to render"

      chip =
        html
        |> Floki.find(
          ~s([data-testid="filter-chip"][data-chip-dimension="level"][data-chip-value="error"])
        )
        |> List.first()

      assert chip, "expected a filter-chip element paired to the level=error bubble"
      refute chip == bubble, "the chip must be a distinct DOM element from the bubble it mirrors"

      remove_control =
        chip
        |> List.wrap()
        |> Floki.find(~s(button[data-testid="filter-chip-remove"]))
        |> List.first()

      assert remove_control, "expected the chip to carry a dedicated remove (\"×\") button"

      phx_click = remove_control |> List.wrap() |> Floki.attribute("phx-click") |> List.first()
      assert phx_click, "expected the chip's remove control to carry a phx-click attribute"

      assert String.starts_with?(phx_click, "["),
             "chip remove phx-click=#{inspect(phx_click)} looks like a bare handle_event push, " <>
               "not a Phoenix.LiveView.JS command list — must be client-side per AC3, mirroring the bubble"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 2 [AC1-AC5] — Trace Map bubble toggle filters rows
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 2 [AC1-AC5]: Trace Map bubble toggle filters rows" do
    # AC3 vs AC5 reconciliation (see Acceptance Test 1's comment block for the
    # full reasoning). The ORIGINAL version of this test called
    # `render_click/1` on the ERROR bubble and asserted the SERVER-rendered
    # row count dropped from 5 to 2 — i.e. it asserted a `handle_event`-driven
    # LiveView state change. That is exactly what AC3 forbids (filter-toggle
    # must be CLIENT-SIDE ONLY, no server round-trip), and it does not match
    # the real implementation either: `phx-click` is bound to a
    # `Phoenix.LiveView.JS` command list, not a bare event name, so there is
    # no `handle_event("toggle_filter", ...)` clause for `render_click/1` to
    # hit. This test is corrected to assert what ExUnit CAN legitimately
    # verify:
    #   1. All 5 rows are present, UNFILTERED, by default (AC1: "Default
    #      state: all filters inactive = everything visible").
    #   2. Each row carries the `data-highest-level` attribute the real
    #      client-side JS filtering logic depends on to decide visibility.
    #   3. The ERROR bubble itself starts with `aria-pressed="false"` (no
    #      filter active by default).
    # The actual click-to-filter runtime behavior (clicking ERROR hides the
    # INFO rows; clicking again restores them) is authoritatively verified by
    # `e2e/features/admin/logs-monitoring.feature` (Playwright, real browser)
    # — Phoenix.LiveViewTest cannot execute real browser JS.
    test "by default all rows are visible (unfiltered), each carrying the data-highest-level attribute client-side filtering depends on" do
      {:ok, view, _html} = mount_logs_live()

      # Under `make test-integration`, LogsLive's request-stream also picks up
      # real background traffic from hundreds of OTHER concurrently-running
      # test files (real HTTP requests flowing through the real
      # RequestLogger plug onto the shared "operational_logs" topic). Scope
      # the row-count/level assertions down to THIS test's own request_ids
      # (mirroring how Acceptance Tests 4/5/6 key their assertions off
      # distinctive request_ids) so the assertions are immune to that noise
      # while still proving these 5 broadcasts produced exactly 5 rows with
      # the right levels.
      error_ids = for _ <- 1..2, do: broadcast_entry(level: "error", source: "http").request_id
      info_ids = for _ <- 1..3, do: broadcast_entry(level: "info", source: "http").request_id
      own_ids = error_ids ++ info_ids

      html = parsed(render(view))
      own_rows = rows(html) |> Enum.filter(&(row_attr(&1, "data-request-id") in own_ids))
      assert length(own_rows) == 5

      levels = own_rows |> Enum.map(&row_attr(&1, "data-highest-level"))
      assert Enum.count(levels, &(&1 == "error")) == 2
      assert Enum.count(levels, &(&1 == "info")) == 3

      error_bubble = find_bubble(html, "level", "error")

      assert bubble_attr(error_bubble, "aria-pressed") == "false",
             "no filter should be active by default (AC1)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 3 [AC2] — Uncollected level renders as "off"
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 3 [AC2]: uncollected level renders as \"off\"" do
    test "the DEBUG bubble renders a visual off indicator when DEBUG collection is disabled" do
      # `Nebu.Web.LogStore.get_policy/0` (log_store.ex) defaults
      # `log_collect_debug: false` whenever no `server_config` row exists for
      # that key yet — but under `make test-integration`'s full-suite run,
      # `server_config` is a live, mutable, suite-wide singleton table, NOT
      # per-test-isolated: `test/nebu/web/log_store/handler_test.exs` and
      # `test/nebu/web/log_store/writer_test.exs` both write the
      # `log_collect_debug` key via `Nebu.Admin.DB.upsert_server_config/1`
      # (no reliable cleanup relative to non-deterministic test-run
      # ordering/parallelism across `mix test` files). A prior version of
      # this test asserted the DEFAULT value directly (`assert
      # policy.log_collect_debug == false`) under the now-falsified
      # assumption that nothing else in the suite ever touches that key —
      # this was flaky under the full live-DB run (CI-gate finding,
      # bug-fix cycle 4). Fixed by controlling our OWN precondition
      # explicitly, mirroring `writer_test.exs`'s "AC7: level filtering
      # respects server_config" describe block (explicit
      # `Nebu.Admin.DB.upsert_server_config/1` call + `on_exit` cleanup),
      # rather than assuming a global default. Guarded by
      # `Process.whereis(Nebu.Repo)` (this file's existing convention for
      # distinguishing "plain unit run, no live Repo" from "full
      # `make test-integration` run") since `upsert_server_config/1` performs
      # a real DB write and would raise if `Nebu.Repo` is not running; in the
      # no-Repo mode, `read_server_config/0`'s own `Process.whereis(Nebu.Repo)`
      # guard already short-circuits to `%{}` (log_collect_debug defaults to
      # `false`), so no DB write is needed there anyway.
      if Process.whereis(Nebu.Repo) do
        :ok = Nebu.Admin.DB.upsert_server_config(%{"log_collect_debug" => "false"})

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            Ecto.Adapters.SQL.query(
              Nebu.Repo,
              "DELETE FROM server_config WHERE key = 'log_collect_debug'",
              []
            )
          end
        end)
      end

      # `get_policy/0` always performs a LIVE DB read (see log_store.ex's own
      # moduledoc — it is never routed through `PolicyCache`, which only
      # backs `Handler.log/2`'s hot path), so no cache-staleness window
      # exists here: the explicit write above is guaranteed visible on this
      # very next read.
      {:ok, policy} = Nebu.Web.LogStore.get_policy()
      assert policy.log_collect_debug == false

      {:ok, view, _html} = mount_logs_live()
      html = parsed(render(view))

      debug_bubble = find_bubble(html, "level", "debug")
      assert debug_bubble, "expected a Trace Map bubble for level=debug even with 0 events"

      assert bubble_attr(debug_bubble, "data-bubble-off") == "true"
      assert Floki.text(debug_bubble) =~ ~r/off/i

      # Clicking the OFF bubble must not silently claim an active ERROR-style
      # filter that then hides everything with no explanation — either it does
      # not toggle aria-pressed at all, or it does but the rendered result
      # still communicates the "not collected" reason (tooltip/title text).
      #
      # AC3-compliance side effect (discovered empirically against
      # phoenix_live_view 1.2.3 — see mix.lock): every Trace Map bubble's
      # `phx-click` is a `Phoenix.LiveView.JS` command list containing NO
      # `push`/`patch`/`navigate` op (client-side-only, per AC3 — see Test 1's
      # comment block). `Phoenix.LiveViewTest.ClientProxy.maybe_js_commands/6`
      # only recognizes `push`/`patch`/`navigate` ops; for any OTHER op set
      # (e.g. our `dispatch`-only list) on a plain (non-`<a>`) `:click`
      # element, it returns `[]`, and — since there is no `href`-based
      # fallback for a `<button>` — `render_click/1` then unconditionally
      # raises `ArgumentError, "no push or navigation command found within JS
      # commands: ..."`. That raise IS the real, AC3-compliant runtime
      # behavior for a genuinely client-side-only bubble (there is truly no
      # server-side event to dispatch) — equivalent in spirit to "does not
      # toggle aria-pressed at all" from this test's own comment above, just
      # surfaced as an exception rather than a no-op because
      # `Phoenix.LiveViewTest` (unlike a real browser) has no JS runtime to
      # execute `dispatch`/`toggle_attribute` commands. Treated as an
      # acceptable outcome here for that reason; the actual click-to-filter
      # behavior in a real browser is verified by
      # `e2e/features/admin/logs-monitoring.feature`.
      try do
        view
        |> element(~s([data-bubble-dimension="level"][data-bubble-value="debug"]))
        |> render_click()
      rescue
        ArgumentError -> :ok
      end

      html2 = parsed(render(view))
      debug_bubble2 = find_bubble(html2, "level", "debug")

      if bubble_attr(debug_bubble2, "aria-pressed") == "true" do
        assert Floki.text(debug_bubble2) =~ ~r/off|not collected/i or
                 bubble_attr(debug_bubble2, "title") =~ ~r/not collected/i
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 4 [AC6-AC9] — Request-stream rows display correct metadata
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 4 [AC6-AC9]: request-stream rows display correct metadata" do
    test "an HTTP entry with method/path/status/duration renders a row with the right badges and micro-summary" do
      {:ok, view, _html} = mount_logs_live()

      %{request_id: request_id} =
        broadcast_http_entry(
          request_id: "req-sync-1",
          route_template: "/sync",
          method: "POST",
          status: 200,
          duration_ms: 45
        )

      for _ <- 1..5 do
        broadcast_entry(level: "info", source: "ecto", request_id: request_id)
      end

      html = parsed(render(view))
      row = find_row(html, request_id)

      assert row, "expected a request-stream row for request_id=#{request_id}"

      row_text = Floki.text(row)
      assert row_text =~ "POST"
      assert row_text =~ "/sync"
      # test-review finding #1 (MINOR): the status badge must pair the icon
      # AND the text (AC13: "never color-only") — two separate `=~` checks
      # (AND logic), matching Test 8's level-badge pattern, not the weaker
      # `~r/🟢|2xx/` OR-regex this previously used (which passed with just
      # one of the two present).
      assert row_text =~ "🟢"
      assert row_text =~ ~r/2xx/i
      assert row_text =~ "45ms"

      assert row_attr(row, "data-count-debug") == "0"
      assert row_attr(row, "data-count-info") == "5"
      assert row_attr(row, "data-count-warn") == "0"
      assert row_attr(row, "data-count-error") == "0"
    end

    test "a non-HTTP request shows \"—\" for method+path" do
      {:ok, view, _html} = mount_logs_live()
      %{request_id: request_id} = broadcast_entry(level: "warning", source: "ecto")

      row = find_row(parsed(render(view)), request_id)
      assert row, "expected a request-stream row for a non-HTTP request"
      assert Floki.text(row) =~ "—"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 5 [AC7] — Rows sorted with errors surfaced first
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 5 [AC7]: rows sorted with errors surfaced first" do
    test "ERROR first, then WARNING, then INFO; a new WARN inserts after ERROR and before INFO" do
      {:ok, view, _html} = mount_logs_live()

      # Arrival order deliberately scrambled (B, C, A) to prove the sort is by
      # severity, not insertion order.
      broadcast_entry(level: "info", source: "http", request_id: "req-b")
      broadcast_entry(level: "warning", source: "http", request_id: "req-c")
      broadcast_entry(level: "error", source: "http", request_id: "req-a")

      # Under `make test-integration`, the request-stream also picks up real
      # background traffic from hundreds of OTHER concurrently-running test
      # files, interleaving unrelated request_ids into the observed order.
      # Filter the observed order down to only the request_ids THIS test
      # created before asserting exact relative order — proving their
      # relative order is correct without requiring the full list to contain
      # nothing else.
      own_ids = ["req-a", "req-b", "req-c"]

      order =
        parsed(render(view)) |> row_request_ids() |> Enum.filter(&(&1 in own_ids))

      assert order == ["req-a", "req-c", "req-b"]

      broadcast_entry(level: "warning", source: "http", request_id: "req-d")
      own_ids_with_d = own_ids ++ ["req-d"]

      order2 =
        parsed(render(view))
        |> row_request_ids()
        |> Enum.filter(&(&1 in own_ids_with_d))

      assert Enum.find_index(order2, &(&1 == "req-a")) <
               Enum.find_index(order2, &(&1 == "req-d")),
             "ERROR row must stay before the new WARN row"

      assert Enum.find_index(order2, &(&1 == "req-d")) <
               Enum.find_index(order2, &(&1 == "req-b")),
             "the new WARN row must sort before the INFO row"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 6 [AC8] — Detail panel shows full chronological thread
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 6 [AC8]: detail panel shows full chronological thread" do
    test "clicking a request row opens a detail panel with all entries in order, and closing it does not disturb other rows" do
      {:ok, view, _html} = mount_logs_live()

      request_id = "req-123"
      broadcast_entry(level: "info", source: "http", request_id: request_id, message: "m1")
      broadcast_entry(level: "info", source: "ecto", request_id: request_id, message: "m2")
      broadcast_entry(level: "info", source: "ecto", request_id: request_id, message: "m3")
      broadcast_entry(level: "info", source: "ecto", request_id: request_id, message: "m4")
      broadcast_entry(level: "warning", source: "http", request_id: request_id, message: "m5")

      other_request_id = "req-999"
      broadcast_entry(level: "info", source: "http", request_id: other_request_id)

      view
      |> element(~s([data-testid="request-row"][data-request-id="#{request_id}"]))
      |> render_click()

      html = parsed(render(view))
      panel = Floki.find(html, ~s([data-testid="detail-panel"][data-request-id="#{request_id}"]))
      assert panel != [], "expected the detail panel to open for #{request_id}"

      detail_entries = Floki.find(panel, ~s([data-testid="detail-entry"]))
      assert length(detail_entries) == 5

      messages = Enum.map(detail_entries, &Floki.text/1)
      assert messages == ["m1", "m2", "m3", "m4", "m5"]

      close = Floki.find(panel, ~s(button[phx-click="close_detail"]))
      assert close != [], "expected a close button wired to phx-click=\"close_detail\""

      view |> element(~s(button[phx-click="close_detail"])) |> render_click()

      html2 = parsed(render(view))

      assert Floki.find(html2, ~s([data-testid="detail-panel"][data-request-id="#{request_id}"])) ==
               []

      # Other rows must still be present, unaffected by opening/closing the panel.
      assert find_row(html2, other_request_id), "closing the panel must not drop other rows"

      assert find_row(html2, request_id),
             "closing the panel must not drop the row it was opened from"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 7 [AC10] — New entries appear without autoscroll
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 7 [AC10]: new entries appear without autoscroll" do
    @moduletag :proposed_contract

    test "while paused, new rows prepend silently and a resumable banner appears; resuming clears it" do
      {:ok, view, _html} = mount_logs_live()

      for i <- 1..10 do
        broadcast_entry(level: "info", source: "http", request_id: "req-seed-#{i}")
      end

      # PROPOSED CONTRACT (see moduledoc): a client-side scroll listener would
      # push this event once the operator has scrolled away from the top.
      # Named here so the dev agent has a concrete seam to implement against;
      # flagged as an assumption in the ATDD handoff report.
      render_click(view, "pause_live_updates", %{})

      for i <- 1..3 do
        broadcast_entry(level: "info", source: "http", request_id: "req-new-#{i}")
      end

      html = parsed(render(view))

      banner = Floki.find(html, ~s([data-testid="new-entries-banner"]))
      assert banner != [], "expected a new-entries banner while updates are paused"
      assert Floki.text(banner) =~ ~r/3.*new entries/i

      resume = Floki.find(banner, ~s(button[phx-click="resume_live_updates"]))
      assert resume != [], "expected a resume-live-updates control on the banner"

      # The 3 new rows are already in the stream (silently prepended) even
      # while paused — they are simply not what triggered an autoscroll.
      order = row_request_ids(html)
      assert "req-new-1" in order
      assert "req-new-2" in order
      assert "req-new-3" in order

      view |> element(~s(button[phx-click="resume_live_updates"])) |> render_click()

      html2 = parsed(render(view))

      assert Floki.find(html2, ~s([data-testid="new-entries-banner"])) == [],
             "the banner must clear once the operator resumes live updates"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 8 [AC13-AC15] — Accessibility: level badges (automated slice)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 8 [AC13-AC15]: level badges pair color with icon + text" do
    test "a WARN row's level badge has both an icon/color AND the word WARN, plus an aria-label" do
      {:ok, view, _html} = mount_logs_live()
      %{request_id: request_id} = broadcast_entry(level: "warning", source: "http")

      row = find_row(parsed(render(view)), request_id)
      badge = Floki.find(row, ~s([data-testid="level-badge"]))
      assert badge != [], "expected a dedicated level-badge element on the row"

      badge_text = Floki.text(badge)
      assert badge_text =~ ~r/WARN/i

      assert badge_text =~ ~r/🟠|\p{So}/u,
             "level badge must pair color with an icon, not color alone"

      aria_label = Floki.attribute(badge, "aria-label") |> List.first()
      assert aria_label, "level badge must carry an aria-label"
      assert aria_label =~ ~r/warn/i

      # Manual-verification gap (explicitly out of scope for ExUnit, per the
      # story's own Acceptance Test 8): actually listening with a screen
      # reader (NVDA/JAWS) to confirm each level is announced clearly. This
      # automated test only pins down the markup contract a screen reader
      # would read from.
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 9 [AC14] — Trace Map bubbles are keyboard-navigable
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 9 [AC14]: Trace Map bubbles are keyboard-navigable" do
    test "every bubble is a native <button> (natural Tab order + Space/Enter activation), with aria-pressed and aria-label" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "error", source: "http", route_template: "/login")

      html = parsed(render(view))
      bubbles = Floki.find(html, ~s([data-testid="trace-map-bubble"]))
      assert bubbles != [], "expected at least one Trace Map bubble to be rendered"

      for bubble <- bubbles do
        # Real Tab-order and Space/Enter keypress simulation requires a JS
        # runtime and is NOT automatable via Phoenix.LiveViewTest/Plug.Test —
        # out of scope for ExUnit (manual keyboard-navigation audit, per the
        # story's own Acceptance Test 9). What IS automatable: the markup
        # must use native, focusable, keyboard-operable <button> elements
        # (never a <div onclick>, which would need a hand-rolled keydown
        # handler and break native Space/Enter semantics), must not be
        # explicitly removed from the tab order, and must expose
        # aria-pressed/aria-label for the same assistive-tech contract AC14
        # requires.
        {tag, attrs, _children} = bubble
        assert tag == "button", "Trace Map bubbles must be <button> elements, got <#{tag}>"

        attrs_map = Map.new(attrs)
        refute attrs_map["tabindex"] == "-1", "bubble must not be excluded from the tab order"
        assert Map.has_key?(attrs_map, "aria-pressed")
        assert Map.has_key?(attrs_map, "aria-label")
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 10 [AC15] — New-entries banner uses aria-live="polite"
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 10 [AC15]: new-entries banner uses aria-live=\"polite\"" do
    test "the new-entries banner container carries aria-live=\"polite\" (never \"assertive\")" do
      {:ok, view, _html} = mount_logs_live()

      for i <- 1..10, do: broadcast_entry(request_id: "req-seed-#{i}")
      render_click(view, "pause_live_updates", %{})
      broadcast_entry(request_id: "req-new-1")

      html = parsed(render(view))
      banner = Floki.find(html, ~s([data-testid="new-entries-banner"]))
      assert banner != []

      assert Floki.attribute(banner, "aria-live") == ["polite"]

      # Manual-verification gap (explicitly out of scope for ExUnit, per the
      # story's own Acceptance Test 10): confirming with an actual screen
      # reader that the announcement does not steal focus/interrupt reading
      # flow. This automated test only pins down that the correct
      # aria-live politeness level is present in the markup, which is the
      # necessary (but not sufficient, absent a real AT) precondition.
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 12 [AC11-AC12] — Live subscription and filter integration
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 12 [AC11-AC12]: live subscription and filter integration" do
    @describetag :integration

    test "a real Logger call, routed through the live operational-log-store handler, updates LogsLive's counts and stream" do
      :ok = Nebu.Web.LogStore.attach_handler()
      {:ok, view, _html} = mount_logs_live()

      require Logger

      original_level = Logger.level()
      Logger.configure(level: :info)

      try do
        Logger.metadata(request_id: "req-integration-1", route_template: "/rooms")
        Logger.info("distinctive-admin-logs-monitoring-view-integration-probe")
      after
        Logger.configure(level: original_level)
        Logger.metadata(request_id: nil, route_template: nil)
      end

      # `Handler.log/2` runs synchronously in the Logger.info/1 caller's
      # process (this test process), but the PubSub broadcast + the LiveView
      # process's own handling of that message are each async relative to
      # this assertion, so poll briefly rather than asserting on the very
      # next render/1 call.
      html =
        eventually(fn ->
          html = parsed(render(view))

          if find_row(html, "req-integration-1") do
            html
          end
        end)

      row = find_row(html, "req-integration-1")
      assert row, "expected LogsLive to have streamed a row for the live-logged request_id"

      info_bubble = find_bubble(html, "level", "info")
      assert info_bubble, "expected the INFO bubble to reflect the live-logged entry"
      assert bubble_count(info_bubble) >= 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bug-fix cycle 4 regression [AC1/AC6] — an entry with `request_id: nil`
  # must not crash the mount/ingest path and must not produce a request row
  # ══════════════════════════════════════════════════════════════════════════
  #
  # CI-gate finding (full `make test-integration` run against a real,
  # already-populated Postgres): `Nebu.Web.LogStore.get_logs/1` (called by
  # `initial_entries/0` at mount) can legitimately return real
  # `operational_logs` rows whose `request_id` column is `nil` — system/
  # background log lines not tied to any HTTP request. Previously,
  # `ingest_entry/2` unconditionally grouped by `entry.request_id` and called
  # `upsert_row/2` for every entry, and `row_dom_id/1`'s
  # `Base.url_encode64(row.request_id, padding: false)` raised
  # `FunctionClauseError` the moment `row.request_id` was `nil` — crashing
  # `mount/3` and therefore every test in this file under live-DB conditions.
  # This never surfaced in isolated `mix test` runs because every fixture
  # here always supplies a real (synthetic) `request_id`.
  describe "Bug-fix cycle 4 regression [AC1/AC6]: request_id: nil entries" do
    test "a broadcast entry with request_id: nil increments bubble counts, does not crash mount, and produces no request row" do
      {:ok, view, _html} = mount_logs_live()

      baseline_html = parsed(render(view))
      baseline_error = bubble_count(find_bubble(baseline_html, "level", "error")) || 0
      baseline_other = bubble_count(find_bubble(baseline_html, "source", "other")) || 0
      baseline_row_count = length(rows(baseline_html))

      # Must not raise (the historical bug crashed the LiveView process via
      # row_dom_id/1's Base.url_encode64(nil, ...) FunctionClauseError).
      broadcast_entry(level: "error", source: "other", route_template: nil, request_id: nil)

      html = parsed(render(view))

      error_bubble = find_bubble(html, "level", "error")
      other_bubble = find_bubble(html, "source", "other")

      assert error_bubble,
             "expected the ERROR bubble to still render after a nil-request_id entry"

      assert other_bubble, "expected the \"other\" source bubble to still render"

      # Trace Map bubble counts (AC1) are NOT request-scoped — they count all
      # ingested events overall, per Acceptance Test 1's own baseline+delta
      # pattern, so a nil-request_id entry still increments them.
      assert bubble_count(error_bubble) == baseline_error + 1
      assert bubble_count(other_bubble) == baseline_other + 1

      # No request row (AC6: "one row per request" — an entry with no
      # request_id belongs to no request thread) was added.
      assert length(rows(html)) == baseline_row_count,
             "expected no new request-stream row for a request_id: nil entry"

      # The view process is still alive and mounted correctly (no crash).
      assert Process.alive?(view.pid)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bug-fix cycle 5 regression [M3, story Dev Notes "Performance
  # Considerations"] — the live-ingest path must cap the number of distinct
  # `request_id` rows kept in memory/DOM, evicting the OLDEST (by arrival
  # order, i.e. lowest `first_seq`) row once the cap is exceeded — NOT the
  # lowest-severity one (that would perversely discard a freshly-arrived
  # ERROR row before an ancient DEBUG one).
  #
  # `initial_entries/0` caps the DB seed at 200 (`Enum.take(200)`), so the
  # number of ALREADY-PRESENT rows at mount (`B`) is always `0 <= B <= 200` —
  # entirely independent of this test (it may run against a real, shared,
  # already-populated Postgres under `make test-integration`, or against no
  # DB at all in a plain `mix test` run). This test broadcasts 205 of its
  # OWN distinctly-tagged entries (deliberately more than the cap, 200,
  # regardless of `B`) and asserts on the resulting invariant that holds for
  # ANY `B` in that range:
  #   - total evictions needed = (B + 205) - 200 = B + 5
  #   - since every pre-existing (baseline) row is OLDER (lower `first_seq`,
  #     assigned by this LiveView's own monotonic `@next_seq` counter at
  #     mount, before any of this test's broadcasts) than every one of this
  #     test's own 205 entries, eviction consumes ALL B baseline rows first,
  #     then evicts exactly 5 MORE — always this test's OWN 5 earliest
  #     broadcasts (`req-m3-evict-1` .. `req-m3-evict-5`), regardless of `B`.
  #   - the remaining 200 of this test's own entries
  #     (`req-m3-evict-6` .. `req-m3-evict-205`) therefore ALWAYS survive,
  #     and the final row count is always exactly 200 (the cap).
  # ══════════════════════════════════════════════════════════════════════════
  describe "Bug-fix cycle 5 regression [M3]: unbounded row growth is capped with oldest-arrival eviction" do
    test "broadcasting more distinct request_ids than the cap evicts the oldest arrivals, keeps the row count at the cap, and does not crash" do
      {:ok, view, _html} = mount_logs_live()

      for i <- 1..205 do
        broadcast_entry(
          level: "info",
          source: "other",
          request_id: "req-m3-evict-#{i}"
        )
      end

      html = parsed(render(view))
      ids = row_request_ids(html)
      own_ids = Enum.filter(ids, &String.starts_with?(&1, "req-m3-evict-"))

      # The row-count cap (matching `initial_entries/0`'s own 200-row DB seed
      # cap) is respected overall, not just for this test's own entries.
      assert length(ids) <= 200,
             "expected the total row count to never exceed the cap, got #{length(ids)} rows"

      # Regardless of how many pre-existing (baseline) rows were already
      # loaded at mount, this test's 5 EARLIEST broadcasts are always the
      # ones evicted (see the describe block's derivation above) — they were
      # always the globally oldest-by-arrival rows once eviction needed to
      # free more slots than the baseline alone provided.
      for i <- 1..5 do
        refute "req-m3-evict-#{i}" in own_ids,
               "expected the oldest-arrived row req-m3-evict-#{i} to have been evicted " <>
                 "once the row-count cap was exceeded, got: #{inspect(own_ids)}"
      end

      # This test's 200 MOST RECENT broadcasts always survive.
      for i <- 6..205 do
        assert "req-m3-evict-#{i}" in own_ids,
               "expected the more-recently-arrived row req-m3-evict-#{i} to have survived " <>
                 "eviction, got: #{inspect(own_ids)}"
      end

      # The view process is still alive (no crash from the eviction path).
      assert Process.alive?(view.pid)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Security review finding [F-1, MEDIUM, admin-logs-monitoring-view security
  # review 2026-07-05] — Kassandra noted the live PubSub ingest path does not
  # gate on the retention policy, so an "off"-tier entry (e.g. DEBUG when
  # `log_collect_debug` is false) still streams live into counts/rows/detail
  # panel even though Acceptance Test 3 [AC2]'s bubble shows "⚫ off". An
  # attempted fix (bug-fix cycle 7) added an ingest-time policy gate here, but
  # `Nebu.Web.LogStore.get_policy/0`'s documented default is
  # `log_collect_info: false` whenever `server_config` is unset or
  # `Nebu.Repo` isn't running (plain `make test-unit-elixir` runs) — so the
  # gate silently dropped ALL "info"-level entries (this file's default test
  # fixture level) under that mode, regressing ~7 tests. REVERTED (see
  # `logs_live.ex`'s `ingest_entry/2` comment) — this directly conflicts with
  # the already-shipped, deliberate "broadcast is independent of persistence"
  # design (`Nebu.Web.LogStore`'s own moduledoc). Kassandra's finding was
  # explicitly MEDIUM/non-blocking (APPROVED) — accepted as a follow-up for a
  # future story to address deliberately (e.g. a distinct live-visibility
  # policy dimension), not chased further here to avoid destabilizing
  # existing, correct behavior this late in the pipeline.
  # ══════════════════════════════════════════════════════════════════════════

  # ══════════════════════════════════════════════════════════════════════════
  # enhanced-logging/war-room-dedicated-page, amendment 2 — the embedded War
  # Room start/stop panel that used to live here (AC11 of war-room-mode) was
  # RETIRED from `/admin/logs` once the dedicated `/admin/logs/war-room`
  # page shipped. The two describe blocks that used to assert its PRESENCE
  # here were removed (mirrors exactly how `trace-map-leitstand` retired the
  # Endpoints dimension from this same page, AC13) — see
  # `test/nebu/admin/logs_live/war_room_panel_retirement_test.exs` for the
  # mirror-image "must be ABSENT" contract, and
  # `test/nebu/admin/logs_live/war_room_test.exs` for the full "start a new
  # session" form's new home on the dedicated page.
  # ══════════════════════════════════════════════════════════════════════════

  # ══════════════════════════════════════════════════════════════════════════
  # AC12 (war-room-mode) — mount/3's war_room_id query-param branch.
  #
  # GENUINE ARCHITECTURAL GAP discovered while writing this test — NOT
  # already flagged in design-decisions.md #7: every OTHER test in this file
  # mounts LogsLive via `live_isolated/3`, which never sets `socket.router`.
  # `Phoenix.LiveView.Static.call_mount_and_handle_params!/4` hard-codes
  # `mount_params = if socket.router, do: params, else: :not_mounted_at_router`
  # — so `live_isolated/3` ALWAYS passes the literal atom
  # `:not_mounted_at_router` as `mount/3`'s first argument, NEVER a query-param
  # map, regardless of the conn's query string. AC12's `params["war_room_id"]`
  # branch is therefore structurally UNREACHABLE through every OTHER test's
  # usual convention. This test instead dispatches through the REAL router
  # (`Phoenix.ConnTest.get/3` + `Phoenix.LiveViewTest.live/2`, which DOES set
  # `socket.router`), reusing `logs_controller_test.exs`'s proven
  # admin-session-cookie pattern (`@endpoint.admin_session/2` +
  # `put_session/3`) since this LiveView's `:require_admin` on_mount hook
  # reads the session the exact same way the sibling LogsController does.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC12: mount/3's war_room_id param filters the initial log stream to one session" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      # test-quality fix (dev-story, not a design decision): this describe
      # block is the ONLY one in this file that mounts through the REAL
      # router (every other test uses `live_isolated/3`, which bypasses the
      # router — and therefore the `{Nebu.Admin.Auth, :require_admin}`
      # `on_mount` hook — entirely, per this section's own header comment).
      # `on_mount(:require_admin, ...)` redirects to `/admin/bootstrap`
      # whenever `Nebu.Admin.Auth.bootstrap_completed?/0` is false — which
      # it genuinely IS on a freshly-migrated database that has never run
      # the bootstrap wizard (confirmed: `bootstrap_completed?/0` returns
      # `false`, by design, for "no `bootstrap_completed` row at all", not
      # merely when `Nebu.Repo` isn't running). Seeded here (once, true,
      # never unset) rather than per-test, mirroring production semantics —
      # an instance never un-completes bootstrap.
      if Process.whereis(Nebu.Repo) do
        Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})
      end

      :ok
    end

    defp admin_conn_for_live(path) do
      %{
        Plug.Test.conn(:get, path)
        | secret_key_base: String.duplicate("nebu-war-room-live-test-key", 2)
      }
      |> Nebu.Admin.Endpoint.admin_session([])
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session("current_user", %{
        "admin" => true,
        "sub" => "admin-war-room-live-tests",
        "matrix_user_id" => "@admin:test.local"
      })
    end

    test "a war_room_id query param seeds the initial stream from get_logs(%{war_room_id: id}) " <>
           "instead of the default unfiltered load" do
      session_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO war_room_sessions
            (started_by, reason, max_entries, max_duration_s, ended_at, ended_reason)
          VALUES ($1, $2, $3, $4, now(), 'manual_stop')
          RETURNING id
          """,
          ["distinctive-war-room-live-mount-test", "AC12 mount param test", 100, 300]
        )

      [[war_room_id]] = session_result.rows

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE war_room_id = $1",
            [war_room_id]
          )

          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM war_room_sessions WHERE id = $1", [
            war_room_id
          ])
        end
      end)

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, message, request_id, war_room_id, inserted_at)
        VALUES ($1, $2, $3, $4, $5, now())
        """,
        [
          "debug",
          "http",
          "distinctive-war-room-live-mount-tagged-entry",
          "req-war-room-live-mount-tagged",
          war_room_id
        ]
      )

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, message, request_id, inserted_at)
        VALUES ($1, $2, $3, $4, now())
        """,
        [
          "info",
          "http",
          "distinctive-war-room-live-mount-UNTAGGED-entry",
          "req-war-room-live-mount-untagged"
        ]
      )

      # test-quality fixes (dev-story, not design decisions — see this
      # describe block's own header comment):
      #
      # 1. `war_room_id` here is the RAW value `Ecto.Adapters.SQL.query!/3`
      #    returns for a native `uuid` column — Postgrex decodes/encodes
      #    `uuid` as a 16-byte BINARY (see `Postgrex.Extensions.UUID`), not
      #    the canonical hex-dash STRING every other identifier in this
      #    codebase uses. Interpolating it directly into a URL query string
      #    embeds raw, non-UTF-8-safe bytes — exactly what a REAL browser
      #    navigating to a bookmarked `?war_room_id=<uuid>` link would never
      #    do (a real URL always carries the canonical string form).
      #    `Ecto.UUID.load!/1` converts the raw binary to that canonical
      #    string for the URL; the raw `war_room_id` binary above is kept
      #    unchanged for the DB assertions/cleanup, which bind it back
      #    against the same `uuid` column.
      #
      # 2. `Phoenix.LiveViewTest.live/1` requires a conn with a SENT
      #    response. `Phoenix.ConnTest.get/2`'s automatic cookie-recycling
      #    (`ensure_recycled/1` -> `recycle/1`) rebuilds a FRESH conn from
      #    `Plug.Test.recycle_cookies/2`, which only carries forward
      #    RESPONSE cookies from a conn that was actually sent — since
      #    `admin_conn_for_live/1`'s session was set via `put_session/3` on
      #    a conn that was NEVER sent (no Set-Cookie response existed to
      #    recycle), that recycling step silently drops the admin session,
      #    redirecting to /admin/login instead of mounting LogsLive.
      #    `@endpoint.call/2` (this file's `@endpoint Nebu.Admin.Endpoint`)
      #    dispatches through the SAME conn directly — no recycling — which
      #    is exactly `logs_controller_test.exs`'s own proven
      #    admin-session-cookie pattern this describe block's header comment
      #    references, and still produces a `state: :sent` conn `live/1`
      #    accepts.
      war_room_id_str = Ecto.UUID.load!(war_room_id)
      war_room_path = "/admin/logs?war_room_id=#{war_room_id_str}"

      sent_conn =
        war_room_path
        |> admin_conn_for_live()
        |> @endpoint.call(@endpoint.init([]))

      {:ok, _view, html} = live(sent_conn)

      assert html =~ "distinctive-war-room-live-mount-tagged-entry" or
               html =~ war_room_id_str,
             "expected the war-room-tagged entry (or at least a banner naming the session) " <>
               "to appear in the initial render when war_room_id is present in the URL (AC12)"

      refute html =~ "distinctive-war-room-live-mount-UNTAGGED-entry",
             "an untagged entry must NOT appear when viewing a single war room session's " <>
               "bookmarked slice (AC12) — the point is a filtered, historical view, not the " <>
               "default unfiltered/live-only window"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # BUG FIX — "Trace Map filter silently clears itself while new log entries
  # keep streaming in" — see
  # docs/stories/enhanced-logging/trace-map-filter-reset-bugfix.md for the
  # full story, acceptance criteria, and root-cause analysis.
  #
  # Root cause (confirmed via Playwright against the running dev stack): none
  # of the three `:for={... <- @endpoint_order | @levels | @sources}`
  # comprehensions in `render/1` above (the `TraceMapBubble.trace_map_bubble/1`
  # calls in the "Endpoints"/"Levels"/"Sources" sections) ever pass an
  # `active:` attribute. `TraceMapBubble.trace_map_bubble/1` defaults
  # `active: false` (trace_map_bubble.ex:48), and BOTH `aria-pressed=
  # {to_string(@active)}` and the `btn-active`/`btn-outline` class list
  # (trace_map_bubble.ex lines ~80/84-89) are derived directly from it. The
  # actual "pressed" state today lives ONLY in the browser DOM (app.js's
  # `wireTraceMapFilters`, via the `Phoenix.LiveView.JS.dispatch/2` command
  # from `bubble_js/0` above) — the SERVER never learns a filter was
  # clicked. Any subsequent `handle_info/2` ingest (literally any incoming
  # log entry, since it touches `@level_counts`/`@source_counts`/
  # `@endpoint_counts`, which the SAME `:for` comprehensions read for their
  # `count` attr) causes LiveView to re-diff and re-patch every bubble in
  # that list — including the one the operator activated — and since the
  # server still thinks `active: false`, the patch reasserts
  # `aria-pressed="false"` / `btn-outline`, silently overwriting the
  # client-side click.
  #
  # Fix direction (per the bug report's Dev Notes): filter state becomes
  # SERVER-TRACKED via URL query params (`push_patch` + `handle_params/3`),
  # so `render/1` can finally pass a real `active:` value derived from
  # `socket.assigns` that survives any later re-render — while the CLICK's
  # visual feedback stays immediate/client-side (AC2) by keeping the
  # existing `JS.dispatch/2` toggle and ADDING a `JS.patch/2` op to the same
  # command list (`phx-click` stays a JS command list — the existing
  # "phx-click must look like a command list, not a bare event name" static
  # contract, e.g. Acceptance Test 1 above and
  # `assertPhxClickIsJsCommand` in logs-monitoring.steps.ts, keeps holding
  # per AC4).
  #
  # WHY THESE MUST FAIL RIGHT NOW: `mount/3` above only ever reads
  # `params["war_room_id"]` (see `war_room_id_param/1`) — it never looks at
  # `endpoint`/`level`/`source` query params at all, and no `handle_params/3`
  # callback exists in this module. Every bubble is therefore rendered with
  # `active: false` unconditionally, regardless of the URL. The click-time
  # `phx-click` value is `JS.dispatch("nebu:trace-bubble-click")` only (see
  # `bubble_js/0`) — no `patch`/`push`/`navigate` op — so `render_click/1`
  # against it raises `ArgumentError, "no push or navigation command found
  # within JS commands: ..."` (the same empirically-confirmed behavior
  # already documented on Acceptance Test 3's `render_click` call above),
  # NOT a compile error.
  #
  # The real-browser click-then-wait reproduction of the bug itself (rows
  # actually re-hiding after the click, over 60+ real seconds of live
  # traffic) is NOT verifiable via `Phoenix.LiveViewTest` (no browser JS
  # runtime) — that is the scope of
  # `e2e/features/admin/logs-trace-map-filter-persistence.feature`
  # (Playwright, real browser, no mocks). The describe blocks below pin down
  # the SERVER-SIDE half of the contract: URL query params must seed the
  # initial `active` state, and that state must be resilient to any later
  # re-render.
  # ══════════════════════════════════════════════════════════════════════════

  describe "Bug fix [AC1]: a URL-derived active filter must survive a later, unrelated re-render" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      if Process.whereis(Nebu.Repo) do
        Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})
      end

      :ok
    end

    test "?level=error pre-activates the level=error bubble, and a broadcast to an UNRELATED " <>
           "dimension (source=http) does not clear it" do
      sent_conn =
        "/admin/logs?level=error"
        |> admin_conn_for_live()
        |> @endpoint.call(@endpoint.init([]))

      {:ok, view, html} = live(sent_conn)

      error_bubble = find_bubble(parsed(html), "level", "error")
      assert error_bubble, "expected the level=error bubble to render"

      assert bubble_attr(error_bubble, "aria-pressed") == "true",
             "expected the ?level=error URL query param to pre-activate the bubble on initial " <>
               "mount (this is the root-cause fix: LogsLive must read filter state from the " <>
               "URL via handle_params/3, not always render active: false)"

      assert bubble_class_includes?(error_bubble, "btn-active")
      refute bubble_class_includes?(error_bubble, "btn-outline")

      # Reproduces the reported bug's mechanism directly: broadcasting an
      # entry for a COMPLETELY UNRELATED dimension value still re-renders
      # the whole `:for={lvl <- @levels}` comprehension (every sibling
      # bubble's `count` attr is read off `@level_counts`, which this
      # broadcast updates) — exactly the patch that, with `active` hardcoded
      # to `false` today, silently resets `aria-pressed` to "false".
      broadcast_entry(level: "info", source: "http")

      html2 = parsed(render(view))
      error_bubble2 = find_bubble(html2, "level", "error")

      assert bubble_attr(error_bubble2, "aria-pressed") == "true",
             "BUG: an unrelated incoming log entry silently cleared the operator's active " <>
               "level=error filter"

      assert bubble_class_includes?(error_bubble2, "btn-active")
    end
  end

  describe "Bug fix [AC3]: URL query params seed the initial active-filter state (shareable link)" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      if Process.whereis(Nebu.Repo) do
        Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})
      end

      :ok
    end

    # enhanced-logging/trace-map-leitstand (AC13): originally exercised
    # `?endpoint=%2Fsync&level=error` — the endpoint dimension was retired
    # from this page (its URL-seeded selection contract now lives on
    # /admin/logs/trace-map, pinned by trace_map_leitstand_test.exs's AC5
    # bookmarkable-URL tests). Rewritten to the two dimensions this page
    # still owns, preserving the original intent: a bookmarked URL carrying
    # MULTIPLE dimensions pre-activates every named bubble on mount.
    test "?source=http&level=error pre-activates BOTH the source and level bubbles " <>
           "(AND-across-dimensions state, reproducible from a bookmarked/shared URL)" do
      sent_conn =
        "/admin/logs?source=http&level=error"
        |> admin_conn_for_live()
        |> @endpoint.call(@endpoint.init([]))

      {:ok, _view, html} = live(sent_conn)
      parsed_html = parsed(html)

      source_bubble = find_bubble(parsed_html, "source", "http")
      level_bubble = find_bubble(parsed_html, "level", "error")

      assert source_bubble, "expected the source=http bubble to render"
      assert level_bubble, "expected the level=error bubble to render"

      assert bubble_attr(source_bubble, "aria-pressed") == "true",
             "expected ?source=http to pre-activate the source=http bubble on load " <>
               "(AC3: a shareable URL must reproduce the same filtered view)"

      assert bubble_attr(level_bubble, "aria-pressed") == "true",
             "expected ?level=error to pre-activate the level=error bubble on load (AC3)"

      assert bubble_class_includes?(source_bubble, "btn-active")
      assert bubble_class_includes?(level_bubble, "btn-active")
    end
  end

  # test-quality fix (dev-story, not a design decision): the two describe
  # blocks below originally asserted on a `Phoenix.LiveView.JS.patch/2` +
  # `handle_params/3` mechanism (per this bug's Dev Notes' PRIMARY proposal).
  # That mechanism was evaluated FIRST and rejected after empirically
  # confirming — against the real, installed `phoenix_live_view 1.2.3`
  # dependency, not merely assumed — that simply EXPORTING a
  # `handle_params/3` callback on `Nebu.Admin.LogsLive` makes EVERY
  # `live_isolated/3`-mounted test in this LiveView's own, large, pre-
  # existing suite (`mount_logs_live/1`, used by ~20 OTHER describe blocks
  # in this very file) fail at mount: `live_isolated/3` is documented as
  # NOT "mounted... with the live/3 macro", a precondition `handle_params/3`
  # unconditionally requires — the raise (or, once a router option is
  # injected to bypass the FIRST of two internal checks, a `{:error,
  # {:redirect, ...}}}` from the SECOND, connect-phase check) fires
  # regardless of whether a patch is ever attempted, purely from the
  # callback's mere presence on the module. Breaking that pre-existing
  # suite would itself violate this story's own AC4 ("all existing
  # admin-logs-monitoring-view tests continue to pass unmodified"). The
  # actual, shipped fix instead adds a `JS.push/2` op (a real, ordinary
  # `handle_event/3`, unaffected by the router/live_isolated distinction)
  # alongside the pre-existing `JS.dispatch/2` — see `bubble_js/2`'s own
  # comment in `logs_live.ex` for the full rationale, including why AC3's
  # URL-reflects-filters requirement is satisfied client-side instead
  # (`app.js`'s `history.pushState`/`popstate`) rather than via native
  # LiveView patch/params. These two describe blocks are updated to assert
  # on the mechanism actually shipped, while preserving each test's intent
  # (a bubble click's phx-click list informs the server, and that
  # server-side round trip actually activates the bubble).
  describe "Bug fix [AC1/AC5]: clicking a bubble informs the server, not just dispatch client-side" do
    test "the phx-click JS command list includes a \"push\" op targeting \"toggle_filter\" " <>
           "(Phoenix.LiveView.JS.push/2), not a dispatch-only command list" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "info", source: "http", route_template: "/login")

      # trace-map-leitstand (AC13): asserted against the level=error bubble —
      # the endpoint dimension this test originally used was retired from
      # this page; the phx-click contract under test is dimension-agnostic.
      html = parsed(render(view))
      bubble = find_bubble(html, "level", "error")
      assert bubble, "expected the level=error bubble to render"

      phx_click = bubble_attr(bubble, "phx-click")
      assert phx_click, "expected a phx-click attribute"

      assert String.contains?(phx_click, "\"push\"") and
               String.contains?(phx_click, "toggle_filter"),
             "AC1/AC5's root-cause fix requires the filter-toggle's phx-click JS command " <>
               "list to ALSO include a \"push\" op targeting \"toggle_filter\" " <>
               "(Phoenix.LiveView.JS.push/2) so the server learns which filter is now " <>
               "active and can keep rendering it as such across later, unrelated " <>
               "re-renders — got #{inspect(phx_click)}. Today it is dispatch-only " <>
               "(bubble_js/0: JS.dispatch(\"nebu:trace-bubble-click\")), so the server never " <>
               "learns a filter was clicked at all."

      assert String.contains?(phx_click, "\"dispatch\""),
             "the fix must ADD the \"push\" op to the existing JS command list, not REPLACE " <>
               "it — AC2's instant, no-server-round-trip visual toggle depends on the " <>
               "pre-existing JS.dispatch(\"nebu:trace-bubble-click\") command staying present " <>
               "alongside the new push op, got #{inspect(phx_click)}"
    end
  end

  describe "Bug fix [AC1/AC5]: clicking a bubble round-trips through handle_event(\"toggle_filter\", ...)" do
    # trace-map-leitstand (AC13): originally clicked the endpoint=/login
    # bubble — the endpoint dimension was retired from this page; the
    # round-trip-persistence contract under test is dimension-agnostic, so
    # the source=http bubble stands in.
    test "clicking the source bubble activates it server-side, and it stays active across " <>
           "a subsequent unrelated broadcast" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "info", source: "http", route_template: "/login")

      view
      |> element(~s([data-bubble-dimension="source"][data-bubble-value="http"]))
      |> render_click()

      html = parsed(render(view))
      bubble = find_bubble(html, "source", "http")

      assert bubble_attr(bubble, "aria-pressed") == "true",
             "expected the click-triggered handle_event(\"toggle_filter\", ...) round trip to " <>
               "activate the source=http bubble server-side, so it stays consistent even " <>
               "after the client-side-only JS toggle this component also performs"

      # Reproduces the original bug's mechanism directly (AC1): a further,
      # UNRELATED broadcast must not silently clear the click.
      broadcast_entry(level: "error", source: "ecto")

      html2 = parsed(render(view))
      bubble2 = find_bubble(html2, "source", "http")

      assert bubble_attr(bubble2, "aria-pressed") == "true",
             "BUG: an unrelated incoming log entry silently cleared the operator's active " <>
               "source=http filter"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bug fix (trace-map-filter-reset-bugfix, dev-story cycle 1, code-review
  # MAJOR finding M1) — multi-select WITHIN a dimension must survive live
  # traffic exactly like the single-select case above.
  #
  # Repro (per the reviewer's finding): the pre-existing CLIENT-side filter
  # (`app.js`'s `activeTraceMapFilters`/`traceMapRowMatches`) already
  # OR-combines multiple active values within the SAME dimension — the
  # click handler toggles each bubble independently, with no mutual
  # exclusion. Before this fix, `@active_filters` stored only ONE value per
  # dimension, so clicking `level=error` then `level=warning` overwrote the
  # server's own record of `level` to just `"warning"` — the next unrelated
  # broadcast re-rendered the `level=error` bubble from that now-stale
  # server assign, silently deactivating it. This mirrors Acceptance Test
  # "Bug fix [AC1]"'s own single-select scenario above, but for two values
  # in the SAME dimension.
  # ══════════════════════════════════════════════════════════════════════════

  describe "Bug fix [AC1, M1]: multi-select WITHIN a dimension survives live traffic" do
    test "clicking level=error then level=warning activates BOTH server-side, and a later " <>
           "unrelated broadcast does not silently deactivate either one" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "info", source: "http", route_template: "/login")

      view
      |> element(~s([data-bubble-dimension="level"][data-bubble-value="error"]))
      |> render_click()

      view
      |> element(~s([data-bubble-dimension="level"][data-bubble-value="warning"]))
      |> render_click()

      html = parsed(render(view))

      assert bubble_attr(find_bubble(html, "level", "error"), "aria-pressed") == "true",
             "expected the first click to activate level=error server-side"

      assert bubble_attr(find_bubble(html, "level", "warning"), "aria-pressed") == "true",
             "expected the SECOND click to ALSO activate level=warning server-side, WITHOUT " <>
               "deactivating level=error — a dimension must be able to hold multiple active " <>
               "values at once, mirroring the client-side OR-within-a-dimension filter"

      # Reproduces the original bug's mechanism directly (AC1), for the
      # multi-select case: a further, UNRELATED broadcast (a different
      # dimension entirely) re-renders every level bubble's `:for`
      # comprehension item (it changes `@level_counts`) — must not silently
      # clear either active value.
      broadcast_entry(level: "info", source: "ecto")

      html2 = parsed(render(view))

      assert bubble_attr(find_bubble(html2, "level", "error"), "aria-pressed") == "true",
             "BUG (M1): an unrelated incoming log entry silently cleared the operator's " <>
               "active level=error filter once a SECOND value (level=warning) was also active " <>
               "in the same dimension"

      assert bubble_attr(find_bubble(html2, "level", "warning"), "aria-pressed") == "true",
             "BUG (M1): an unrelated incoming log entry silently cleared the operator's " <>
               "active level=warning filter"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bug fix (trace-map-filter-reset-bugfix, AC3, code-review finding): a
  # browser back/forward navigation is handled ENTIRELY client-side by
  # `app.js` (DOM/URL only, via `applyTraceMapFiltersFromUrl`) — it must ALSO
  # inform the server (`handle_event("sync_filters", ...)`) so
  # `@active_filters` doesn't stay stale. The scenario below reproduces the
  # EXACT desync the reviewer found: click endpoint (server tracks it),
  # click level:error (server now tracks BOTH), simulate the browser "back"
  # navigation's `sync_filters` push (server should now track ONLY
  # endpoint), then broadcast an UNRELATED entry to force a re-render — the
  # bug this test guards against is that re-render silently reactivating the
  # level=error filter the operator had already navigated away from.
  # ══════════════════════════════════════════════════════════════════════════

  describe "Bug fix [AC3]: popstate-driven \"sync_filters\" must survive a later, unrelated re-render" do
    # trace-map-leitstand (AC13): this test's original two dimensions were
    # endpoint + level — the endpoint dimension was retired from this page,
    # so the same cross-dimension desync scenario now runs on source + level
    # (the two dimensions this page still owns). The mechanism under test is
    # unchanged: a browser "back" that undoes only ONE of two clicks must
    # wholesale-replace the server's state, and a later unrelated broadcast
    # must not resurrect the cleared value.
    test "sync_filters restoring only source (simulating browser back) is not later " <>
           "overwritten by an unrelated broadcast reactivating level" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "info", source: "http", route_template: "/login")

      # Real click #1 (source) and #2 (level) — both round-trip through
      # `handle_event("toggle_filter", ...)`, exactly like a real operator
      # clicking two different Trace Map bubbles in sequence.
      view
      |> element(~s([data-bubble-dimension="source"][data-bubble-value="http"]))
      |> render_click()

      view
      |> element(~s([data-bubble-dimension="level"][data-bubble-value="error"]))
      |> render_click()

      html = parsed(render(view))

      assert bubble_attr(find_bubble(html, "source", "http"), "aria-pressed") == "true",
             "expected the first click to activate source=http server-side"

      assert bubble_attr(find_bubble(html, "level", "error"), "aria-pressed") == "true",
             "expected the second click to ALSO activate level=error server-side (the server " <>
               "now tracks BOTH filters as active, mirroring the reviewer's reproduction)"

      # Simulate the browser "back" navigation: `app.js`'s `popstate`
      # listener re-derives the DOM from the URL (only `source` survives
      # a "back" that undoes the second click) AND pushes this event to
      # inform the server of the restored state — the fix this test
      # guards. `render_click/3` on the bare `view` (no element selector)
      # sends an arbitrary event exactly like `liveSocket.main.pushEvent`
      # does for a non-click-originated push (see `app.js`'s
      # `pushFilterSyncToServer/0`).
      render_click(view, "sync_filters", %{
        "filters" => %{"level" => nil, "source" => "http"}
      })

      html2 = parsed(render(view))

      assert bubble_attr(find_bubble(html2, "source", "http"), "aria-pressed") == "true",
             "expected \"sync_filters\" to keep source=http active (present in the pushed " <>
               "filter map)"

      assert bubble_attr(find_bubble(html2, "level", "error"), "aria-pressed") == "false",
             "expected \"sync_filters\" to clear the server's stale level=error state (absent " <>
               "from the pushed filter map, simulating a browser \"back\" that undid that click)"

      # THE ACTUAL BUG REPRODUCTION: without the fix (no `sync_filters`
      # handler, or a handler that doesn't fully replace `@active_filters`),
      # this later, UNRELATED broadcast — which re-renders every level
      # bubble's `:for` comprehension item because it changes
      # `@level_counts` — must not resurrect the level=error filter that
      # was just correctly cleared above.
      broadcast_entry(level: "warning", source: "ecto")

      html3 = parsed(render(view))

      assert bubble_attr(find_bubble(html3, "source", "http"), "aria-pressed") == "true",
             "source=http should still be active after the unrelated broadcast"

      assert bubble_attr(find_bubble(html3, "level", "error"), "aria-pressed") == "false",
             "BUG: an unrelated broadcast resurrected the level=error filter that the " <>
               "popstate-driven \"sync_filters\" push had already correctly cleared — " <>
               "@active_filters was never actually updated by \"sync_filters\", or reverted " <>
               "to a stale value on the next re-render"
    end

    test "sync_filters replaces @active_filters wholesale, clearing dimensions absent from " <>
           "the pushed map" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "info", source: "http", route_template: "/login")

      view
      |> element(~s([data-bubble-dimension="source"][data-bubble-value="http"]))
      |> render_click()

      render_click(view, "sync_filters", %{
        "filters" => %{"level" => "warning", "source" => nil}
      })

      html = parsed(render(view))

      assert bubble_attr(find_bubble(html, "source", "http"), "aria-pressed") == "false",
             "expected \"sync_filters\" to CLEAR source=http (absent — nil — from the " <>
               "pushed filter map), not merely add level=warning on top of it"

      assert bubble_attr(find_bubble(html, "level", "warning"), "aria-pressed") == "true",
             "expected \"sync_filters\" to activate level=warning (present in the pushed " <>
               "filter map)"
    end

    # dev-story cycle 2, code-review MINOR follow-up (residual half-fix of a
    # cycle-1 MINOR): `active_filters_from_params/2` (the mount-time
    # URL-seed path) already drops an "off"-tier `level` value (e.g.
    # `?level=debug` while `log_collect_debug` is false) before it reaches
    # `@active_filters` — but `sync_filters` (the `popstate`-driven path)
    # did not apply the same guard. A hand-crafted/bookmarked `?level=debug`
    # URL followed by any browser back/forward would push `"debug"` into
    # `sync_filters`, and the server's own `@active_filters` would end up
    # holding it, even though the bubble is rendered/styled as "off"
    # (`btn-outline`) and no real click could ever have activated it.
    test "sync_filters rejects an off-tier level value, mirroring the mount-time URL-seed " <>
           "guard (level_off?/2)" do
      # `Nebu.Web.LogStore.get_policy/0` defaults `log_collect_debug: false`
      # whenever no `server_config` row exists yet — but under
      # `make test-integration`'s full-suite run, `server_config` is a live,
      # mutable, suite-wide singleton table (see Acceptance Test 3's own
      # comment above for the precedent). Control the precondition
      # explicitly rather than assume the default survives other tests'
      # writes.
      if Process.whereis(Nebu.Repo) do
        :ok = Nebu.Admin.DB.upsert_server_config(%{"log_collect_debug" => "false"})

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            Ecto.Adapters.SQL.query(
              Nebu.Repo,
              "DELETE FROM server_config WHERE key = 'log_collect_debug'",
              []
            )
          end
        end)
      end

      {:ok, view, _html} = mount_logs_live()

      render_click(view, "sync_filters", %{
        "filters" => %{"level" => "debug", "source" => nil}
      })

      html = parsed(render(view))
      debug_bubble = find_bubble(html, "level", "debug")

      assert bubble_attr(debug_bubble, "aria-pressed") == "false",
             "BUG: \"sync_filters\" stored an off-tier level=debug value as active in " <>
               "@active_filters, bypassing the same off-bubble guard the mount-time " <>
               "URL-seed path (active_filters_from_params/2) already applies"

      # Reproduces the residual bug's actual downstream symptom: a later,
      # UNRELATED broadcast (which re-renders every level bubble's `:for`
      # comprehension item) must not surface the rejected value either —
      # proving it was never stored, not merely cosmetically suppressed by
      # this one render.
      broadcast_entry(level: "info", source: "http")

      html2 = parsed(render(view))
      debug_bubble2 = find_bubble(html2, "level", "debug")

      assert bubble_attr(debug_bubble2, "aria-pressed") == "false",
             "BUG: the off-tier level=debug value pushed via \"sync_filters\" resurfaced as " <>
               "active after an unrelated broadcast, proving it WAS stored in @active_filters"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bug fix (trace-map-filter-reset-bugfix, dev-story cycle 2 reverify,
  # MINOR): `toggle_filter` — the plain click path, the MOST directly
  # reachable of the three `@active_filters` write paths (no URL-crafting
  # or back/forward navigation needed) — was found missing the same
  # off-tier `level` guard `active_filters_from_params/2` (mount) and
  # `sync_filters` (popstate) already applied, across 2 earlier cycles. A
  # crafted `toggle_filter` push (e.g. `liveSocket.main.pushEvent("toggle_
  # filter", {dimension: "level", value: "debug"})` from devtools) could
  # still mark an off-tier level as active server-side. Mirrors the
  # `sync_filters` off-tier regression test above exactly, but drives the
  # bug through `toggle_filter` (a bare event push with no element
  # selector, exactly like a crafted devtools push — no real click could
  # ever reach this, since `app.js`'s own `bubbleOff === "true"` guard
  # would short-circuit first).
  # ══════════════════════════════════════════════════════════════════════════

  describe "Bug fix [AC1, cycle-2-reverify MINOR]: toggle_filter rejects an off-tier level value" do
    test "toggle_filter does not store an off-tier level value as active, mirroring the " <>
           "mount-time (active_filters_from_params/2) and popstate (sync_filters) guards" do
      # See the `sync_filters` off-tier test above for why this precondition
      # is set explicitly rather than assumed.
      if Process.whereis(Nebu.Repo) do
        :ok = Nebu.Admin.DB.upsert_server_config(%{"log_collect_debug" => "false"})

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            Ecto.Adapters.SQL.query(
              Nebu.Repo,
              "DELETE FROM server_config WHERE key = 'log_collect_debug'",
              []
            )
          end
        end)
      end

      {:ok, view, _html} = mount_logs_live()

      render_click(view, "toggle_filter", %{"dimension" => "level", "value" => "debug"})

      html = parsed(render(view))
      debug_bubble = find_bubble(html, "level", "debug")

      assert bubble_attr(debug_bubble, "aria-pressed") == "false",
             "BUG: \"toggle_filter\" stored an off-tier level=debug value as active in " <>
               "@active_filters, bypassing the same off-bubble guard the mount-time " <>
               "URL-seed path (active_filters_from_params/2) and the popstate path " <>
               "(sync_filters) already apply"

      # Same downstream-symptom proof as the sync_filters test above: an
      # unrelated broadcast must not surface the rejected value either,
      # proving it was never stored.
      broadcast_entry(level: "info", source: "http")

      html2 = parsed(render(view))
      debug_bubble2 = find_bubble(html2, "level", "debug")

      assert bubble_attr(debug_bubble2, "aria-pressed") == "false",
             "BUG: the off-tier level=debug value pushed via \"toggle_filter\" resurfaced as " <>
               "active after an unrelated broadcast, proving it WAS stored in @active_filters"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # enhanced-logging/trace-map-leitstand (AC13) — the trace-map-hierarchy
  # tree tests that used to live here (Acceptance Tests 6/8 + the
  # code-review MINOR-3 expand-then-click flow) asserted the domain-grouped
  # disclosure tree embedded in this page's "Endpoints" section. That
  # section (and the endpoint dimension with it) was RETIRED from
  # /admin/logs — endpoint filtering now lives on the dedicated
  # /admin/logs/trace-map Leitstand page (`trace_map_leitstand_test.exs`
  # owns its URL-seeding/selection coverage; `trace_map_retirement_test.exs`
  # pins the removal itself). The three tests below preserve this file's
  # coverage of the SAME underlying server contracts (URL multi-select
  # seeding, zero regression for the surviving dimensions, chip-remove
  # round trip) against the dimensions this page still owns.
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 6 [AC6, AC8]: comma-joined URL param seeds multi-select within a dimension" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      if Process.whereis(Nebu.Repo) do
        Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})
      end

      :ok
    end

    test "comma-joined ?level=error,warning (this page's unchanged URL format) pre-activates " <>
           "BOTH level bubbles on mount" do
      sent_conn =
        "/admin/logs?level=error,warning"
        |> admin_conn_for_live()
        |> @endpoint.call(@endpoint.init([]))

      {:ok, _view, html} = live(sent_conn)
      parsed_html = parsed(html)

      error_bubble = find_bubble(parsed_html, "level", "error")
      warning_bubble = find_bubble(parsed_html, "level", "warning")

      assert error_bubble, "expected the level=error bubble to render"
      assert warning_bubble, "expected the level=warning bubble to render"

      assert bubble_attr(error_bubble, "aria-pressed") == "true",
             "AC6/AC7: a comma-joined ?level=... URL param must pre-activate BOTH values " <>
               "on initial mount — the comma-joined storage format is UNCHANGED from " <>
               "trace-map-filter-reset-bugfix"

      assert bubble_attr(warning_bubble, "aria-pressed") == "true"
    end
  end

  describe "Acceptance Test 8 [AC8]: zero regression — Levels/Sources bubbles survive the Endpoints retirement" do
    test "level and source bubbles still render flat (never inside a domain group), and click-to-filter still works" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "info", source: "http", route_template: "/admin/users")

      html = parsed(render(view))

      # AC13: no leftover domain-group / tree markup may remain anywhere on
      # this page (the tree moved to /admin/logs/trace-map).
      assert Floki.find(html, ~s([data-testid="trace-map-domain-group"])) == [],
             "AC13: no trace-map-domain-group markup may remain on /admin/logs"

      assert Floki.find(html, ~s([data-testid="trace-map-tree"])) == [],
             "AC13: no trace-map-tree markup may remain on /admin/logs"

      # `find_bubble/3` is the pre-existing helper EVERY prior story's tests
      # use — proving it keeps finding the surviving dimensions' bubbles is
      # the crux of AC8's "zero regression" claim for this page.
      assert find_bubble(html, "level", "error"),
             "the level=error bubble must keep rendering after the Endpoints retirement"

      assert find_bubble(html, "source", "http"),
             "the source=http bubble must keep rendering after the Endpoints retirement"

      view
      |> element(~s([data-bubble-dimension="level"][data-bubble-value="error"]))
      |> render_click()

      html2 = parsed(render(view))
      bubble2 = find_bubble(html2, "level", "error")

      assert bubble_attr(bubble2, "aria-pressed") == "true",
             "AC8: clicking a surviving bubble must still round-trip through " <>
               "handle_event(\"toggle_filter\", ...) exactly as it did before the retirement"

      assert bubble_class_includes?(bubble2, "btn-active")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # trace-map-leitstand AC13 follow-through: the chip "×" remove control's
  # SERVER round trip (`handle_event("remove_filter", ...)`) was previously
  # only covered indirectly (via sync_filters/toggle_filter). This replaces
  # the retired MINOR-3 expand-domain-then-click-leaf flow (the disclosure
  # tree it exercised no longer exists on this page) with the realistic
  # "activate via bubble, deactivate via chip ×" flow for a surviving
  # dimension.
  # ══════════════════════════════════════════════════════════════════════════

  describe "chip removal round-trips through handle_event(\"remove_filter\", ...)" do
    test "clicking a chip's × deactivates exactly that value server-side, and it stays inactive across a later unrelated broadcast" do
      {:ok, view, _html} = mount_logs_live()
      broadcast_entry(level: "error", source: "http", route_template: "/admin/users")

      view
      |> element(~s([data-bubble-dimension="level"][data-bubble-value="error"]))
      |> render_click()

      html = parsed(render(view))

      assert bubble_attr(find_bubble(html, "level", "error"), "aria-pressed") == "true",
             "precondition: the bubble click must activate level=error server-side"

      view
      |> element(
        ~s(button[data-testid="filter-chip-remove"][data-chip-dimension="level"][data-chip-value="error"])
      )
      |> render_click()

      html2 = parsed(render(view))

      assert bubble_attr(find_bubble(html2, "level", "error"), "aria-pressed") == "false",
             "expected the chip's × to clear level=error via handle_event(\"remove_filter\", ...)"

      # The reset-bug's own mechanism, inverted: a later, unrelated broadcast
      # (bumps @level_counts, re-rendering every level bubble) must not
      # resurrect the removed filter.
      broadcast_entry(level: "info", source: "ecto")

      html3 = parsed(render(view))

      assert bubble_attr(find_bubble(html3, "level", "error"), "aria-pressed") == "false",
             "BUG: an unrelated broadcast resurrected the level=error filter after its chip " <>
               "was removed — remove_filter never actually updated @active_filters"
    end
  end

  # ── Floki-based assertion helpers (shared data-attribute contract) ─────────

  # `Phoenix.LiveViewTest.render/1` (and `render_click/1`) return a raw HTML
  # STRING. `Floki.find/2` (floki ~> 0.36, pinned to 0.38.4 — see mix.lock)
  # does NOT implicitly parse a binary argument: `Floki.Finder.find/2` has an
  # explicit `def find(html_as_string, _) when is_binary(html_as_string), do:
  # []` clause, by design (a raw string is treated as an opaque text leaf,
  # not a document to auto-parse). Every top-level `render(view)` call in this
  # file is therefore routed through this helper first — idempotent (a
  # value that is already a parsed tree/node passes through unchanged), so
  # it is also safe to apply defensively inside `find_bubble/3`, `rows/1`,
  # and `find_row/2` below.
  defp parsed(html) when is_binary(html), do: Floki.parse_fragment!(html)
  defp parsed(html), do: html

  defp eventually(fun, attempts \\ 20) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      nil ->
        flunk("condition never became true")

      result ->
        result
    end
  end

  defp find_bubble(html, dimension, value) do
    html
    |> parsed()
    |> Floki.find(
      ~s([data-testid="trace-map-bubble"][data-bubble-dimension="#{dimension}"][data-bubble-value="#{value}"])
    )
    |> List.first()
  end

  defp bubble_count(bubble) do
    bubble
    |> List.wrap()
    |> Floki.attribute("data-bubble-count")
    |> List.first()
    |> case do
      nil -> nil
      count -> String.to_integer(count)
    end
  end

  defp bubble_attr(bubble, attr) do
    bubble |> List.wrap() |> Floki.attribute(attr) |> List.first()
  end

  # Used by the "Bug fix [AC1]"/"[AC3]" describe blocks above to assert on
  # `trace_map_bubble.ex`'s `btn-active`/`btn-outline` class toggle without
  # depending on the exact class-list ordering/whitespace Phoenix renders.
  defp bubble_class_includes?(bubble, class_name) do
    case bubble_attr(bubble, "class") do
      nil -> false
      class -> class |> String.split() |> Enum.member?(class_name)
    end
  end

  defp rows(html), do: html |> parsed() |> Floki.find(~s([data-testid="request-row"]))

  defp find_row(html, request_id) do
    html
    |> parsed()
    |> Floki.find(~s([data-testid="request-row"][data-request-id="#{request_id}"]))
    |> List.first()
  end

  defp row_attr(row, attr), do: row |> List.wrap() |> Floki.attribute(attr) |> List.first()

  defp row_request_ids(html) do
    html |> rows() |> Enum.map(&row_attr(&1, "data-request-id"))
  end
end
