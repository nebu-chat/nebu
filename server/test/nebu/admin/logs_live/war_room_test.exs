defmodule Nebu.Admin.LogsLive.WarRoomTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-dedicated-page`
  (AC1-AC14, as corrected by the story's "Story Amendments (2026-07-08)"
  section — the amendments are the source of truth wherever they conflict
  with the story's original literal text).

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md

  ## Architecture this file pins down (amendment 1)

  A SINGLE new LiveView module, `Nebu.Admin.LogsLive.WarRoom`, mirroring the
  sibling `Nebu.Admin.LogsLive.TraceMap`'s own "one module, two router
  actions" shape (see that module's moduledoc for why this is a SEPARATE
  module from the existing `Nebu.Admin.LogsLive`, not a bolted-on action —
  the identical `live_isolated/3` + `handle_params/3` incompatibility
  reasoning would apply here too if this module needed `handle_params/3`;
  it does NOT — see below):

      live "/logs/war-room",           LogsLive.WarRoom, :index
      live "/logs/war-room/:room_id",  LogsLive.WarRoom, :show

  `@active_nav` is `"logs-war-room"` (matching the ALREADY-SHIPPED sidebar
  child key from `admin-sidebar-nesting` — see `layouts.ex`'s
  `@logs_nav_children`) in BOTH actions.

  ## Why `handle_params/3` is NOT needed here (unlike TraceMap)

  `:show`'s `room_id` is a static PATH segment, available directly in
  `mount/3`'s own `params` argument (`%{"room_id" => id}`) — no
  `push_patch/2`-driven URL round-trip is needed the way TraceMap's
  bracket-array endpoint filters need one. The exclusive-scope checkbox
  toggling (AC9) and scope-mode switching (AC8) are ordinary
  `phx-change`/assigns state, not URL-driven. This means `mount/3` can
  branch on `params["room_id"]` (present -> detail mode, absent/
  `:not_mounted_at_router` -> list mode) directly, exactly like the
  EXISTING `Nebu.Admin.LogsLive`'s own `war_room_id_param/1` precedent —
  and therefore `live_isolated/3` CAN mount this module for every list-mode
  test below (no `handle_params/3` export to trip the
  `live_isolated/3`-breaks-on-`handle_params/3` incompatibility TraceMap's
  moduledoc documents). Only the DETAIL view (`:show`, needs a real path
  param) and the AC12 route-repoint proof need the real router.

  ## Why these MUST FAIL right now

  `Nebu.Admin.LogsLive.WarRoom` does not exist at all — every
  `live_isolated/3`/`live/1` call below fails with `UndefinedFunctionError`
  (list-mode tests) or the real router still dispatches
  `/admin/logs/war-room` to the OLD stub (`LogsLive, :index` — literally the
  Live Stream page, mislabeled per amendment 1) for the router-mounted
  tests, which therefore render the WRONG page entirely (asserted against
  below, not merely "the new module doesn't exist").

  ## Data-attribute contract this file pins down for the dev agent

    * List page: `<h1>War Room</h1>`; one `[data-testid="war-room-session-row"]
      [data-room-id={id}]` `<.link navigate="/admin/logs/war-room/{id}">`
      per session (a native, clickable element — AC13), containing:
      `[data-testid="war-room-session-status"]` (badge text pairs an emoji
      with a word, never color alone — AC13), `-started-by`, `-reason`,
      `-scope`, `-filter`, `-time-range`, `-entries`, `-duration`.
    * Empty state: `[data-testid="war-room-empty-state"]`.
    * Start form: `[data-testid="war-room-start-form"]` — same flat field
      names as the retired embedded panel (reason/scope/user_id/device_id/
      max_entries/max_duration_s), PLUS (AC9) an
      `[data-testid="war-room-exclusive-options"]` block (shown only when
      `scope` is `"exclusive"`) containing one
      `input[type=checkbox][name="exclusive_scope[]"]` per
      `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` member
      (amendment 5 — reused, not hardcoded) plus a free-text
      `input[name="exclusive_other"]` (AC9's "other" option).
    * Warnings (AC7/AC8, re-displayed from the retired panel):
      `[data-testid="war-room-warning-all"]` / `[data-testid=
      "war-room-warning-sync"]`.
    * Trace Map preview (AC8, amendment 3 — LEVEL/SOURCE dimensions only,
      `:readonly` `TraceMapBubble`): `[data-testid="war-room-trace-preview"]`
      containing `[data-testid="trace-map-bubble"]` instances.
    * Detail page: `[data-testid="war-room-detail-meta"]`,
      `[data-testid="war-room-detail-back-link"]` (navigate to
      `/admin/logs/war-room`), reused `[data-testid="request-row"]` entries
      (`Nebu.Admin.LogsLive`'s own existing row testid — Dev Notes:
      "reusing `Nebu.Admin.LogsLive`'s list ... components").
    * 404: `[data-testid="war-room-not-found"]`.
    * Copy-to-markdown (AC14, amendment 6): `[data-testid=
      "war-room-copy-markdown-button"]`, `data-copy-text={...}`,
      `phx-click={JS.dispatch("nebu:copy-thread") |> JS.push("copy_to_markdown")}`
      — REUSES the existing `nebu:copy-thread` CSP-safe clipboard event
      `Nebu.Admin.LogsLive.DetailPanel`'s own copy-thread button already
      dispatches (`priv/static/assets/app.js`'s existing generic
      `document.addEventListener("nebu:copy-thread", ...)` listener needs no
      changes at all for this reuse). The "Copied to clipboard" toast is a
      DEDICATED assign (`@copy_toast`), NOT Phoenix's built-in `@flash` —
      mirrors `Nebu.Admin.LogsLive.TraceMap`'s own `@cascade_flash` precedent
      (that module's comment: "this LiveView's shared admin layout does not
      render `@flash` today"): `[data-testid="war-room-copy-toast"]
      role="status"`.
  """
  use ExUnit.Case, async: false

  # NOTE on tagging: unlike `war_room_test.exs`/`war_room_manager_test.exs`
  # (GenServer-level, genuinely DB-only), THIS file mixes DB-free LiveView
  # rendering tests (form/UI/PubSub-live-update contracts — run under plain
  # `make test-unit-elixir`, mirroring `Nebu.Admin.LogsLive.TraceMap`'s own
  # "MOST tests below still run under plain mix test" precedent, since
  # `Nebu.Repo` is only started when `Application.get_env(:nebu, Nebu.Repo)`
  # is configured — see `Nebu.Application.repo_children/0`) with genuinely
  # DB-backed tests (real session rows — `@describetag :integration` per
  # describe block, run only under `make test-integration`). Tagging the
  # WHOLE file `:integration` would hide the DB-free half from
  # `make test-unit-elixir`'s red-phase signal entirely.

  import Phoenix.LiveViewTest
  import Plug.Test
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-wr-dedicated-page-test-key", 2)
  @admin_session %{"current_user" => %{"admin" => true, "sub" => "admin-wr-dedicated-tests"}}

  # ── helpers ──────────────────────────────────────────────────────────────

  defp run_id, do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
  defp new_started_by, do: "distinctive-wr-page-test-#{run_id()}"

  defp mount_list(session \\ @admin_session) do
    live_isolated(Plug.Test.conn(:get, "/admin/logs/war-room"), Nebu.Admin.LogsLive.WarRoom,
      session: session
    )
  end

  defp admin_conn(path) do
    %{conn(:get, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-wr-dedicated-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp mount_via_router(path) do
    sent_conn = path |> admin_conn() |> @endpoint.call(@endpoint.init([]))
    live(sent_conn)
  end

  defp parsed(html), do: Floki.parse_document!(html)
  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  # AC2 of war-room-mode guarantees at most ONE row with ended_at IS NULL
  # exists at all (a partial unique index) — defensively ends whatever might
  # currently be "active" (leakage from another integration test file in the
  # same `mix test --include integration` run) before a test inserts its own
  # active session, mirroring `war_room_manager_test.exs`'s own
  # `end_all_active!/0` precedent exactly.
  defp end_all_active! do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
      []
    )
  end

  defp insert_session(overrides) do
    defaults = %{
      started_by: new_started_by(),
      reason: "dedicated page test reason",
      scope: nil,
      filter: nil,
      max_entries: 100,
      max_duration_s: 300,
      started_at: DateTime.utc_now(),
      ended_at: nil,
      ended_reason: nil,
      entries_collected: 0
    }

    attrs = Map.merge(defaults, Map.new(overrides))

    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO war_room_sessions
          (started_by, reason, scope, filter, max_entries, max_duration_s,
           started_at, ended_at, ended_reason, entries_collected)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        RETURNING id
        """,
        [
          attrs.started_by,
          attrs.reason,
          attrs.scope,
          attrs.filter,
          attrs.max_entries,
          attrs.max_duration_s,
          attrs.started_at,
          attrs.ended_at,
          attrs.ended_reason,
          attrs.entries_collected
        ]
      )

    [[id]] = result.rows
    # dev-story fix: `id` is a native Postgres `uuid` column — a raw
    # `Ecto.Adapters.SQL.query!/3` `RETURNING id` (confirmed against the live
    # stack) returns it as a 16-byte BINARY, not the canonical hex-dash
    # STRING. Every caller of this helper either renders the id into HTML
    # (`data-room-id`/`href`) or interpolates it directly into a URL path
    # (`mount_via_router("/admin/logs/war-room/#{target}")`, AC5) — both
    # require the canonical STRING form, mirroring
    # `Nebu.Web.LogStore.get_logs/1`'s own `normalize_filter_value/2`
    # precedent for the identical `war_room_id` concern. Converted once
    # here; `insert_operational_log/2` below dumps it back to binary for
    # its own `war_room_id` INSERT parameter.
    Ecto.UUID.load!(id)
  end

  # test-review MINOR-2 (fixed): `inserted_at` is now overridable (defaults
  # to `now()`, i.e. omit the column and let Postgres fill it, exactly as
  # before) — needed by the AC5 chronological-ordering test below, which
  # must seed entries with DELIBERATELY SHUFFLED (non-insertion-order)
  # timestamps to genuinely prove the detail view SORTS by timestamp rather
  # than merely reflecting whatever order they happened to be inserted/
  # queried in.
  # No default on `overrides` — every call site below always passes it
  # explicitly (a default value here is never exercised and trips
  # `--warnings-as-errors`).
  defp insert_operational_log(war_room_id, overrides) do
    defaults = %{
      level: "info",
      source: "http",
      route_template: "/admin/users",
      request_id: "req-#{System.unique_integer([:positive])}",
      message: "distinctive-wr-page-detail-entry",
      metadata: %{},
      inserted_at: nil
    }

    attrs = Map.merge(defaults, Map.new(overrides))
    # `war_room_id` arrives as the canonical STRING form (insert_session/1's
    # own return value) — dumped back to the raw 16-byte binary Postgrex's
    # `uuid` extension requires for a bound query parameter (see
    # insert_session/1's own comment for the full rationale).
    war_room_id_binary = Ecto.UUID.dump!(war_room_id)

    if attrs.inserted_at do
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs
          (level, source, route_template, request_id, message, metadata, war_room_id, inserted_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        """,
        [
          attrs.level,
          attrs.source,
          attrs.route_template,
          attrs.request_id,
          attrs.message,
          attrs.metadata,
          war_room_id_binary,
          attrs.inserted_at
        ]
      )
    else
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, route_template, request_id, message, metadata, war_room_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        """,
        [
          attrs.level,
          attrs.source,
          attrs.route_template,
          attrs.request_id,
          attrs.message,
          attrs.metadata,
          war_room_id_binary
        ]
      )
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Amendment 1 / AC12 — the stub route is REPLACED, active_nav corrected
  # ══════════════════════════════════════════════════════════════════════

  describe "amendment 1 (AC12): /admin/logs/war-room dispatches the NEW dedicated page" do
    test "renders the War Room page, not the old Live Stream stub" do
      {:ok, _view, html} = mount_via_router("/admin/logs/war-room")
      doc = parsed(html)

      assert Floki.text(find(doc, "h1")) =~ "War Room",
             "amendment 1: /admin/logs/war-room must render the NEW dedicated War Room page, " <>
               "not the stub route (`LogsLive, :index` — literally the Live Stream page, " <>
               "mislabeled) it currently repoints to"

      refute html =~ "Sammlung konfigurieren",
             "amendment 1: this must NOT be the Live Stream page (that page's own " <>
               "'Sammlung konfigurieren →' link must not appear here)"
    end

    test "the sidebar's active nav key becomes \"logs-war-room\", not the old Live Stream mislabel" do
      {:ok, _view, html} = mount_via_router("/admin/logs/war-room")
      doc = parsed(html)

      war_room_link = find(doc, ~s(a[data-navkey="logs-war-room"]))
      assert war_room_link, "expected the sidebar's War Room child link to exist"

      assert attr(war_room_link, "aria-current") == "page",
             "amendment 1/AC12: the SAME class of bug the sidebar-nesting UX gate flagged as " <>
               "INFO-1/A2 — active_nav must genuinely become \"logs-war-room\" here, not " <>
               "silently stay on \"logs-monitoring\" (the old stub's mislabel)"

      monitoring_link = find(doc, ~s(a[data-navkey="logs-monitoring"]))
      refute attr(monitoring_link, "aria-current") == "page",
             "amendment 1: \"Live Stream\" must NOT be highlighted while on the War Room page"
    end

    test "/admin/logs/war-room/:room_id also dispatches the SAME module (:show action)" do
      {:ok, _view, html} = mount_via_router("/admin/logs/war-room/00000000-0000-0000-0000-000000000000")
      doc = parsed(html)

      war_room_link = find(doc, ~s(a[data-navkey="logs-war-room"]))
      assert attr(war_room_link, "aria-current") == "page",
             "amendment 1: the detail route must ALSO highlight the War Room nav item " <>
               "(same module, mirrors LogsLive.TraceMap's single-module, multi-action pattern)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1/AC2 — session list
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: the list displays all sessions, active first, then most-recent-first" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wr-page-test-%' OR started_by = '@bob:localhost'",
          []
        )
      end)

      :ok
    end

    test "3 sessions (1 active, 2 ended) render with the active session first" do
      end_all_active!()

      old_ended =
        insert_session(
          started_by: new_started_by(),
          started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          ended_at: DateTime.add(DateTime.utc_now(), -3500, :second),
          ended_reason: "manual_stop"
        )

      recent_ended =
        insert_session(
          started_by: new_started_by(),
          started_at: DateTime.add(DateTime.utc_now(), -600, :second),
          ended_at: DateTime.add(DateTime.utc_now(), -500, :second),
          ended_reason: "budget_exhausted"
        )

      active =
        insert_session(
          started_by: new_started_by(),
          started_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      {:ok, _view, html} = mount_list()
      doc = parsed(html)

      rows = find_all(doc, ~s([data-testid="war-room-session-row"]))
      ids = Enum.map(rows, &attr(&1, "data-room-id"))

      assert Enum.take(ids, 1) == [active],
             "AC1: the active session must be listed FIRST, regardless of start time"

      # The two ended sessions must both appear, ordered most-recent-start first.
      ended_ids = ids -- [active]
      assert ended_ids == [recent_ended, old_ended],
             "AC1: ended sessions must be ordered by most recent start_at first"
    end

    test "each row shows the expected fields (AC2)" do
      end_all_active!()

      id =
        insert_session(
          started_by: "@bob:localhost",
          reason: "investigating slow sync",
          scope: "/_matrix/client/v3/sync",
          filter: %{"user_id" => "@alice:localhost"},
          max_entries: 100,
          entries_collected: 42
        )

      {:ok, _view, html} = mount_list()
      row = find(parsed(html), ~s([data-testid="war-room-session-row"][data-room-id="#{id}"]))
      assert row, "expected a row for the inserted session"

      assert Floki.text(find(row, ~s([data-testid="war-room-session-started-by"]))) =~
               "@bob:localhost"

      assert Floki.text(find(row, ~s([data-testid="war-room-session-reason"]))) =~
               "investigating slow sync"

      assert Floki.text(find(row, ~s([data-testid="war-room-session-scope"]))) =~
               "/_matrix/client/v3/sync"

      assert Floki.text(find(row, ~s([data-testid="war-room-session-filter"]))) =~
               "@alice:localhost"

      assert Floki.text(find(row, ~s([data-testid="war-room-session-entries"]))) =~ "42"
      assert Floki.text(find(row, ~s([data-testid="war-room-session-entries"]))) =~ "100"

      assert find(row, ~s([data-testid="war-room-session-time-range"]))
      assert find(row, ~s([data-testid="war-room-session-duration"]))
    end
  end

  describe "AC2: status badge pairs an emoji with text — never color alone (AC13)" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wr-page-test-%'",
          []
        )
      end)

      :ok
    end

    test "an active session (ended_at IS NULL) shows a 🟢 Active badge" do
      end_all_active!()
      id = insert_session(ended_at: nil, ended_reason: nil)

      {:ok, _view, html} = mount_list()
      row = find(parsed(html), ~s([data-testid="war-room-session-row"][data-room-id="#{id}"]))
      badge = find(row, ~s([data-testid="war-room-session-status"]))

      text = Floki.text(badge)
      assert text =~ "🟢"
      assert text =~ ~r/active/i
    end

    test "an ended session with ended_reason=\"budget_exhausted\" shows a 🔴 Ended (budget exhausted) badge" do
      id =
        insert_session(
          ended_at: DateTime.utc_now(),
          ended_reason: "budget_exhausted"
        )

      {:ok, _view, html} = mount_list()
      row = find(parsed(html), ~s([data-testid="war-room-session-row"][data-room-id="#{id}"]))
      badge = find(row, ~s([data-testid="war-room-session-status"]))

      text = Floki.text(badge)
      assert text =~ "🔴"
      assert text =~ ~r/ended/i
      assert text =~ ~r/budget.exhausted/i
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 — row navigation
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: each session row is a native, clickable link to its detail view" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wr-page-test-%'",
          []
        )
      end)

      :ok
    end

    test "the row navigates to /admin/logs/war-room/{room_id}" do
      end_all_active!()
      id = insert_session([])

      {:ok, _view, html} = mount_list()
      row = find(parsed(html), ~s([data-testid="war-room-session-row"][data-room-id="#{id}"]))

      assert attr(row, "href") == "/admin/logs/war-room/#{id}",
             "AC3/AC13: the row itself must be a native <a>/<.link navigate> element whose " <>
               "href points at the session's own detail route"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 — empty state
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: an empty session list shows the placeholder message" do
    test "with zero sessions (DB-free unit-test contract — no Nebu.Repo running), the empty-state message is shown" do
      refute Process.whereis(Nebu.Repo),
             "precondition: this is the DB-free unit environment (mirrors " <>
               "Nebu.Admin.LogsLive.TraceMap's own initial_entries/0 guard) — with no Repo " <>
               "reachable, the session list is necessarily empty"

      {:ok, _view, html} = mount_list()
      doc = parsed(html)

      empty = find(doc, ~s([data-testid="war-room-empty-state"]))
      assert empty, "AC4: expected an empty-state element when no sessions exist"
      assert Floki.text(empty) =~ "No War Room sessions yet"

      refute find(doc, ~s([data-testid="war-room-session-row"]))
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5/AC6 — detail view
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: the detail view shows session metadata and ONLY that session's captured logs" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by IN " <>
            "('@target:localhost', '@other:localhost', '@chrono:localhost')",
          []
        )
      end)

      :ok
    end

    test "metadata panel + filtered, sorted logs; entries from a DIFFERENT session are excluded" do
      end_all_active!()
      target = insert_session(started_by: "@target:localhost", reason: "target session")

      # AC2 of war-room-mode: at most ONE row may have ended_at IS NULL at
      # any time — `other` must be a DIFFERENT (ended) session, not a second
      # simultaneously-active one, or this raw INSERT itself would violate
      # the partial unique index.
      other =
        insert_session(
          started_by: "@other:localhost",
          reason: "other session",
          ended_at: DateTime.utc_now(),
          ended_reason: "manual_stop"
        )

      for n <- 1..5 do
        insert_operational_log(target, message: "distinctive-wr-page-target-entry-#{n}")
      end

      insert_operational_log(other, message: "distinctive-wr-page-OTHER-entry-should-not-appear")

      {:ok, _view, html} = mount_via_router("/admin/logs/war-room/#{target}")
      doc = parsed(html)

      meta = find(doc, ~s([data-testid="war-room-detail-meta"]))
      assert meta, "AC5: expected a session metadata panel"
      assert Floki.text(meta) =~ "@target:localhost"
      assert Floki.text(meta) =~ "target session"

      rows = find_all(doc, ~s([data-testid="request-row"]))
      assert length(rows) == 5,
             "AC5: expected exactly the 5 entries tagged with this session's war_room_id"

      refute html =~ "distinctive-wr-page-OTHER-entry-should-not-appear",
             "AC5: an entry from a DIFFERENT war_room_id must never appear on this session's " <>
               "detail page"

      back_link = find(doc, ~s([data-testid="war-room-detail-back-link"]))
      assert back_link, "AC5: expected a breadcrumb/back link to the list view"
      assert attr(back_link, "href") == "/admin/logs/war-room"
    end

    # test-review MINOR-1 (fixed): the test above only pinned COUNT + the
    # cross-session EXCLUSION contract, not AC5's own "sorted by timestamp"
    # requirement. Entries are seeded with DELIBERATELY SHUFFLED
    # `inserted_at` values (out of insertion order) so a pass here can only
    # come from a genuine ORDER BY inserted_at in the detail view's query —
    # never from accidentally-already-sorted insertion/PK order.
    test "captured logs render in ascending chronological order, regardless of insertion order" do
      end_all_active!()
      target = insert_session(started_by: "@chrono:localhost", reason: "chronological order probe")

      base = DateTime.utc_now()

      # Deliberately shuffled: the 3rd-oldest entry is inserted FIRST, etc.
      shuffled = [
        {"req-chrono-3", DateTime.add(base, 30, :second)},
        {"req-chrono-1", DateTime.add(base, 10, :second)},
        {"req-chrono-5", DateTime.add(base, 50, :second)},
        {"req-chrono-2", DateTime.add(base, 20, :second)},
        {"req-chrono-4", DateTime.add(base, 40, :second)}
      ]

      for {request_id, inserted_at} <- shuffled do
        insert_operational_log(target,
          request_id: request_id,
          inserted_at: inserted_at,
          message: "distinctive-wr-page-chrono-#{request_id}"
        )
      end

      {:ok, _view, html} = mount_via_router("/admin/logs/war-room/#{target}")
      doc = parsed(html)

      rendered_request_ids =
        doc
        |> find_all(~s([data-testid="request-row"]))
        |> Enum.map(&attr(&1, "data-request-id"))

      assert rendered_request_ids == ["req-chrono-1", "req-chrono-2", "req-chrono-3", "req-chrono-4", "req-chrono-5"],
             "AC5: the detail view's captured-logs section must render entries sorted by " <>
               "timestamp ASCENDING, independent of insertion order — got: " <>
               inspect(rendered_request_ids)
    end
  end

  describe "AC6: the detail view 404s for a non-existent session id" do
    test "an invalid room_id shows a 404 message with a link back to the list" do
      {:ok, _view, html} =
        mount_via_router("/admin/logs/war-room/00000000-0000-0000-0000-000000000000")

      doc = parsed(html)
      not_found = find(doc, ~s([data-testid="war-room-not-found"]))

      assert not_found, "AC6: expected a 404/not-found element for an unknown room_id"
      assert Floki.text(not_found) =~ ~r/not found/i

      back_link = find(doc, ~s([data-testid="war-room-detail-back-link"]))
      assert back_link, "AC6: expected an offer to return to the list"
      assert attr(back_link, "href") == "/admin/logs/war-room"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7/AC8 — pre-session scoping form + read-only Trace Map preview
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7/AC8: the pre-session scoping form renders with every required field" do
    test "the form contains reason/scope/user_id/device_id/max_entries/max_duration_s + Start button" do
      {:ok, _view, html} = mount_list()
      doc = parsed(html)

      form = find(doc, ~s([data-testid="war-room-start-form"]))
      assert form, "AC7: expected the 'Start a new War Room session' form section"

      assert find(form, ~s(input[name="reason"]))
      assert find(form, ~s(select[name="scope"]))
      assert find(form, ~s(input[name="user_id"]))
      assert find(form, ~s(input[name="device_id"]))
      assert find(form, ~s(input[name="max_entries"]))
      assert find(form, ~s(input[name="max_duration_s"]))

      start_button = find(form, ~s(button[type="submit"]))
      assert start_button
      assert Floki.text(start_button) =~ "Start War Room"
    end
  end

  describe "amendment 3: AC8's live-activity preview reuses TraceMapBubble for level+source (:readonly), not a second radial map" do
    test "the preview renders level and source dimension bubbles in :readonly mode" do
      {:ok, _view, html} = mount_list()
      doc = parsed(html)

      preview = find(doc, ~s([data-testid="war-room-trace-preview"]))
      assert preview, "amendment 3: expected a live-activity preview section on the form"

      refute find(preview, ~s([data-testid="trace-map-svg"])),
             "amendment 3: this must NOT be a second radial Leitstand map instance — that " <>
               "would be out of proportion to the need (the exclusive-scope checkboxes " <>
               "already solve the actual 'sync is noisy' motivation)"

      level_bubbles = find_all(preview, ~s([data-testid="trace-map-bubble"][data-bubble-dimension="level"]))
      assert level_bubbles != [], "amendment 3: expected level-dimension bubbles in the preview"

      source_bubbles = find_all(preview, ~s([data-testid="trace-map-bubble"][data-bubble-dimension="source"]))
      assert source_bubbles != [], "amendment 3: expected source-dimension bubbles in the preview"

      for bubble <- level_bubbles ++ source_bubbles do
        refute attr(bubble, "phx-click"),
               "amendment 3/AC8: the preview's bubbles must be READ-ONLY (mode: :readonly) — " <>
                 "not clickable filters, just a live-count preview"
      end
    end

    test "the preview updates live as new operational_logs entries arrive via PubSub (AC8)" do
      {:ok, view, _html} = mount_list()

      Phoenix.PubSub.broadcast(Nebu.PubSub, "operational_logs", %{
        level: "error",
        source: "ecto",
        route_template: "/admin/rooms",
        request_id: "req-wr-page-live-#{System.unique_integer([:positive])}",
        message: "distinctive-wr-page-live-preview-entry",
        metadata: %{}
      })

      html = render(view) |> parsed()
      preview = find(html, ~s([data-testid="war-room-trace-preview"]))

      error_bubble = find(preview, ~s([data-testid="trace-map-bubble"][data-bubble-value="error"]))
      assert attr(error_bubble, "data-bubble-count") != "0",
             "AC8: the live-activity preview must update in real time as new entries arrive, " <>
               "with no page reload"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC9/AC10/amendment 5 — exclusive scope UI
  # ══════════════════════════════════════════════════════════════════════

  describe "AC9: exclusive scope mode shows an exclude-list selector sourced from long_polling_endpoints/0" do
    test "selecting scope=\"exclusive\" reveals checkboxes for every canonical off-list endpoint" do
      {:ok, view, _html} = mount_list()

      html =
        view
        |> element(~s([data-testid="war-room-start-form"] select[name="scope"]))
        |> render_change(%{"scope" => "exclusive"})
        |> parsed()

      options = find(html, ~s([data-testid="war-room-exclusive-options"]))
      assert options, "AC9: expected the exclude-list selector once scope=\"exclusive\" is chosen"

      for route <- Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints() do
        checkbox =
          find(options, ~s(input[type="checkbox"][value="#{route}"]))

        assert checkbox,
               "amendment 5: expected a checkbox for #{route} (from the CANONICAL, REUSED " <>
                 "long_polling_endpoints/0 — not a hardcoded parallel list)"
      end

      assert find(options, ~s(input[name="exclusive_other"])),
             "AC9: expected an 'other' free-text input for a custom excluded route"
    end

    test "with scope != \"exclusive\", the exclude-list selector is not shown" do
      {:ok, _view, html} = mount_list()
      refute find(parsed(html), ~s([data-testid="war-room-exclusive-options"])),
             "AC9: the exclude-list selector must only appear once exclusive mode is chosen"
    end
  end

  describe "AC10: submitting the form with exclusive scope starts a session tagged accordingly" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wr-page-test-%'",
          []
        )
      end)

      :ok
    end

    test "submitting scope=exclusive with /sync checked persists exclusive_scope=[\"/_matrix/client/v3/sync\"]" do
      end_all_active!()

      {:ok, view, _html} = mount_list()
      reason = new_started_by()

      view
      |> element(~s([data-testid="war-room-start-form"]))
      |> render_submit(%{
        "reason" => reason,
        "scope" => "exclusive",
        "exclusive_scope" => ["/_matrix/client/v3/sync"],
        "user_id" => "",
        "device_id" => "",
        "max_entries" => "100",
        "max_duration_s" => "300"
      })

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT exclusive_scope FROM war_room_sessions WHERE reason = $1",
          [reason]
        )

      assert result.rows == [[["/_matrix/client/v3/sync"]]],
             "AC10: expected the started session to persist exclusive_scope exactly as chosen"
    end

    # test-review MINOR-3 (fixed): the test above only proves
    # `Nebu.Admin.WarRoomManager.start_session/1` persists a
    # pre-shaped `exclusive_scope` list when called directly — it never
    # exercises the LIVEVIEW'S OWN merging of the checkbox list with AC9's
    # free-text "other" input. This test submits the REAL form (checkbox +
    # `exclusive_other` filled in together) and asserts the LiveView itself
    # merges them into one list before calling into the manager.
    test "the LiveView merges the checked checkboxes AND the free-text 'other' input into one exclusive_scope list" do
      end_all_active!()

      {:ok, view, _html} = mount_list()
      reason = new_started_by()

      view
      |> element(~s([data-testid="war-room-start-form"]))
      |> render_submit(%{
        "reason" => reason,
        "scope" => "exclusive",
        "exclusive_scope" => ["/_matrix/client/v3/sync"],
        "exclusive_other" => "/admin/very/custom/noisy-route",
        "user_id" => "",
        "device_id" => "",
        "max_entries" => "100",
        "max_duration_s" => "300"
      })

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT exclusive_scope FROM war_room_sessions WHERE reason = $1",
          [reason]
        )

      assert [[persisted]] = result.rows

      assert Enum.sort(persisted) ==
               Enum.sort(["/_matrix/client/v3/sync", "/admin/very/custom/noisy-route"]),
             "AC9/AC10: the LiveView itself (not just WarRoomManager.start_session/1 called " <>
               "directly) must merge the checked canonical checkboxes with the free-text " <>
               "'other' input into ONE exclusive_scope list before starting the session — " <>
               "got: #{inspect(persisted)}"
    end

    # code-review MINOR (war-room-dedicated-page, cycle 3): scope="exclusive"
    # submitted with ZERO checkboxes checked AND a blank "other" field must
    # NOT silently collapse to scope:"all", exclusive_scope:nil (i.e.
    # capture-everything — the exact noisy full capture the operator picked
    # "all except..." to avoid). The submission must be rejected with a
    # visible @start_error, and no session may be started.
    test "submitting scope=exclusive with zero exclusions is rejected with a form error, not a silent capture-all" do
      end_all_active!()

      {:ok, view, _html} = mount_list()
      reason = new_started_by()

      html =
        view
        |> element(~s([data-testid="war-room-start-form"]))
        |> render_submit(%{
          "reason" => reason,
          "scope" => "exclusive",
          "exclusive_scope" => [],
          "exclusive_other" => "",
          "user_id" => "",
          "device_id" => "",
          "max_entries" => "100",
          "max_duration_s" => "300"
        })

      error = find(parsed(html), ~s([data-testid="war-room-start-error"]))

      assert error,
             "expected a visible form error when 'exclusive' scope is submitted with no " <>
               "exclusions, instead of silently degrading to scope:\"all\""

      assert html =~ "Select at least one endpoint to exclude, or choose a different scope"

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT id FROM war_room_sessions WHERE reason = $1",
          [reason]
        )

      assert result.rows == [],
             "no session should be started when the exclusive-scope submission is rejected"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC11 — warnings (re-displayed from the retired embedded panel)
  # ══════════════════════════════════════════════════════════════════════

  # test-review MINOR-4 (fixed): this block was mislabeled "AC7/AC11" — the
  # broad/noisy-scope warnings are AC7 (the warning CONTENT/CONDITIONS) and
  # AC8 (re-displaying them on THIS page's form), not AC11 (which is the
  # nav_item sidebar entry, covered by amendment 1's own describe block
  # above).
  describe "AC7/AC8: broad/noisy-scope warnings are shown on the dedicated page" do
    test "scope=\"all\" shows the broad-scope warning" do
      {:ok, _view, html} = mount_list()
      assert find(parsed(html), ~s([data-testid="war-room-warning-all"]))
      assert html =~ "collecting all endpoints"
    end

    test "scope=\"/_matrix/client/v3/sync\" shows the stronger sync-specific warning" do
      {:ok, _view, html} = mount_list()
      assert find(parsed(html), ~s([data-testid="war-room-warning-sync"]))
      assert html =~ "is called continuously by every client"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC13 — accessibility
  # ══════════════════════════════════════════════════════════════════════

  describe "AC13: accessibility contract" do
    test "the page uses semantic h1/h2 headings" do
      {:ok, _view, html} = mount_list()
      doc = parsed(html)

      assert find(doc, "h1"), "AC13: expected a page-level <h1>"
      assert find_all(doc, "h2") != [], "AC13: expected at least one <h2> section heading"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC14 — copy-to-markdown (amendment 6: CSP-safe clipboard reuse)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC14/amendment 6: the detail view's copy-to-markdown button is CSP-safe and toasts" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE '@copy-%test:localhost'",
          []
        )
      end)

      :ok
    end

    # test-review MINOR-5 (fixed): strengthened to match the story's own Dev
    # Notes "Copy-to-Markdown (AC14)" template STRUCTURE, not just substring
    # presence of the seeded values — a naive implementation that dumps the
    # right values in the WRONG shape (e.g. no "## Captured Logs" heading, or
    # a different bullet format) would have passed the old, weaker version
    # of this test.
    test "the button carries a data-copy-text markdown blob matching the Dev Notes template exactly, and dispatches the reused nebu:copy-thread event" do
      end_all_active!()

      id =
        insert_session(
          started_by: "@copy-test:localhost",
          reason: "copy to markdown test",
          scope: "all",
          max_entries: 100,
          entries_collected: 1
        )

      insert_operational_log(id,
        level: "warning",
        source: "ecto",
        message: "distinctive-wr-page-copy-entry"
      )

      {:ok, _view, html} = mount_via_router("/admin/logs/war-room/#{id}")
      doc = parsed(html)

      button = find(doc, ~s([data-testid="war-room-copy-markdown-button"]))
      assert button, "AC14: expected a copy-to-markdown button on the detail view"

      copy_text = attr(button, "data-copy-text")

      assert copy_text =~ ~r/^#\s+War Room Session #{Regex.escape(id)}/m,
             "Dev Notes template: expected a top-level '# War Room Session {room_id}' heading"

      assert copy_text =~ "**Started by:** @copy-test:localhost",
             "Dev Notes template: expected a '**Started by:**' line, not just the value " <>
               "appearing somewhere in the text"

      assert copy_text =~ "**Reason:** copy to markdown test"
      assert copy_text =~ ~r/\*\*Scope:\*\*\s*all/
      assert copy_text =~ ~r/\*\*Entries collected:\*\*\s*1\s*\/\s*100/

      assert copy_text =~ "## Captured Logs",
             "Dev Notes template: expected a '## Captured Logs' section heading"

      assert copy_text =~ ~r/-\s*`[^`]+`\s*\[warning\]\s*\[ecto\]\s*distinctive-wr-page-copy-entry/,
             "Dev Notes template: expected each entry as '- `{timestamp}` [{level}] " <>
               "[{source}] {message}' — got: #{inspect(copy_text)}"

      assert attr(button, "phx-click") =~ "nebu:copy-thread",
             "amendment 6: must reuse the EXISTING CSP-safe nebu:copy-thread client event " <>
               "(no inline onclick/JS) — no new app.js listener should be needed"
    end

    test "clicking the button round-trips to the server and shows a 'Copied to clipboard' toast" do
      end_all_active!()
      id = insert_session(started_by: "@copy-toast-test:localhost", reason: "copy toast test")
      {:ok, view, _html} = mount_via_router("/admin/logs/war-room/#{id}")

      html =
        view
        |> element(~s([data-testid="war-room-copy-markdown-button"]))
        |> render_click()

      assert html =~ "Copied to clipboard",
             "AC14: expected a 'Copied to clipboard' confirmation after the copy action " <>
               "round-trips through handle_event (a dedicated assign, not Phoenix's built-in " <>
               "@flash — this admin layout does not render @flash today, mirroring " <>
               "LogsLive.TraceMap's own @cascade_flash precedent)"

      assert find(parsed(html), ~s([data-testid="war-room-copy-toast"][role="status"]))
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Security (test-review finding 9, security_review: required) — an
  # admin-supplied exclusive_scope/exclusive_other value is UNTRUSTED input
  # (Dev Notes item 7's own "do not trust the form's UI validation alone").
  # Shape validation (Dev Notes item 7 / war_room_manager_exclusive_scope_test.exs)
  # only rejects values that do NOT start with "/" — it does NOT reject
  # HTML-special characters (a route-shaped value like
  # "/admin/<b>xss-probe</b>" legitimately starts with "/" and would pass
  # that check), so RENDERING-time escaping is the real defense against a
  # stored-XSS class finding here, not input validation alone.
  # ══════════════════════════════════════════════════════════════════════

  describe "security: an admin-supplied exclusive_other value with HTML-special characters is escaped on render" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wr-page-test-%'",
          []
        )
      end)

      :ok
    end

    test "a route-shaped exclusive_other value containing raw HTML tags is never emitted unescaped on the detail page" do
      end_all_active!()

      {:ok, view, _html} = mount_list()
      reason = new_started_by()
      malicious = "/admin/<b>xss-probe</b>"

      view
      |> element(~s([data-testid="war-room-start-form"]))
      |> render_submit(%{
        "reason" => reason,
        "scope" => "exclusive",
        "exclusive_scope" => [],
        "exclusive_other" => malicious,
        "user_id" => "",
        "device_id" => "",
        "max_entries" => "100",
        "max_duration_s" => "300"
      })

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT id FROM war_room_sessions WHERE reason = $1",
          [reason]
        )

      assert [[id]] = result.rows,
             "precondition: the route-shaped value must pass shape validation and persist " <>
               "(this test is about RENDER-time escaping, not input rejection)"

      {:ok, _detail_view, detail_html} = mount_via_router("/admin/logs/war-room/#{id}")

      refute detail_html =~ malicious,
             "security (security_review: required — Kassandra focus area): the raw, " <>
               "unescaped exclusive_other value must never appear verbatim in the detail " <>
               "page's HTML. An admin-supplied route string is untrusted input; shape " <>
               "validation alone (must start with \"/\") does not exclude HTML-special " <>
               "characters, so escaping at RENDER time is the real defense here"

      assert detail_html =~ "&lt;b&gt;xss-probe&lt;/b&gt;" or
               (parsed(detail_html)
                |> find(~s([data-testid="war-room-detail-meta"]))
                |> Floki.text() =~ "xss-probe"),
             "expected the value to still be DISPLAYED, as inert escaped text (not silently " <>
               "stripped) — proves the fix is escaping, not merely deleting the field: " <>
               "got #{inspect(detail_html)}"
    end
  end
end
