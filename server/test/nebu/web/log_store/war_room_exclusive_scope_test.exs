defmodule Nebu.Web.LogStore.WarRoomExclusiveScopeTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-dedicated-page`
  (AC9/AC10 — the "exclusive scope" convenience syntax: "capture everything
  EXCEPT these endpoints", primarily motivated by `/_matrix/client/v3/sync`
  dominating any endpoint-scoped capture).

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md
  Story Amendment 5 (2026-07-08): the default exclude-list SOURCE is
  `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` (reused, not
  hardcoded — see `war_room_manager_exclusive_scope_test.exs` for the
  validation half of that contract). This file only pins the pure
  scope-matching contract in `Nebu.Web.LogStore.WarRoom`.

  ## Why these MUST FAIL right now

  Neither the `war_room_sessions.exclusive_scope` column (Dev Notes' Option
  A: "add a separate `exclusive_scope JSONB` column, keep `scope` as a
  string — minimal-change, backward-compatible") nor
  `Nebu.Web.LogStore.WarRoom`'s exclusive-scope matching branch exist yet.

  Every test that inserts a session with an `exclusive_scope` override fails
  with a Postgres `column "exclusive_scope" of relation "war_room_sessions"
  does not exist` error (the migration does not exist yet — ATDD does not
  write implementation, including migrations, per this story's own
  instructions) — this IS the expected RED state, mirroring
  `war_room_manager_test.exs`'s own "AC1: war_room_sessions table exists"
  precedent (RED because the schema is missing, not because of a bug in
  this test file).

  The one schema-contract test below (mirroring `war_room_manager_test.exs`'s
  "has every column the story specifies" test) fails on a plain `refute`/
  `assert` (the column is simply absent from `information_schema.columns`),
  not a raised error — a cheap, fast signal for "the migration has not
  landed yet" independent of the raw-SQL insert helper below.

  ## Contract pinned by this file

    * `exclusive_scope` is `nil` or a JSON list of route-template strings.
    * `WarRoom.check/1`'s matching becomes: an entry whose `route_template`
      is a member of a NON-EMPTY `exclusive_scope` list is NEVER tagged and
      NEVER counted against the budget (AC10's literal "if yes, skip — do
      not tag, do not count"), REGARDLESS of what `scope`/`filter` would
      otherwise have matched.
    * `exclusive_scope: nil` or `exclusive_scope: []` is a pure no-op —
      100% backward compatible with every existing `scope_matches?/2` /
      `filter_matches?/2` test in `war_room_test.exs` (no existing test
      in that file passes an `exclusive_scope` key at all, so this is an
      purely ADDITIVE branch, never a replacement of the existing checks).
    * The exclusion check runs BEFORE (and independently of) `scope`/
      `filter` matching — an excluded route_template is skipped even when
      `scope: "all"` would otherwise match everything, and even when a
      `filter` would otherwise match the entry's metadata exactly.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    pid =
      case Process.whereis(Nebu.Web.LogStore.WarRoom) do
        nil -> start_supervised!(Nebu.Web.LogStore.WarRoom)
        existing -> existing
      end

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wr-excl-test-%'",
          []
        )
      end
    end)

    {:ok, war_room: pid}
  end

  # ── helpers (mirrors war_room_test.exs's own helpers exactly) ─────────────

  defp run_id, do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"

  defp insert_session(overrides) do
    defaults = %{
      started_by: "distinctive-wr-excl-test-#{run_id()}",
      reason: "exclusive scope test reason",
      scope: nil,
      filter: nil,
      exclusive_scope: nil,
      max_entries: 1000,
      max_duration_s: 300,
      started_at: DateTime.utc_now(),
      entries_collected: 0
    }

    attrs = Map.merge(defaults, Map.new(overrides))

    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO war_room_sessions
          (started_by, reason, scope, filter, exclusive_scope, max_entries, max_duration_s,
           started_at, entries_collected)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        RETURNING id
        """,
        [
          attrs.started_by,
          attrs.reason,
          attrs.scope,
          attrs.filter,
          attrs.exclusive_scope,
          attrs.max_entries,
          attrs.max_duration_s,
          attrs.started_at,
          attrs.entries_collected
        ]
      )

    [[id]] = result.rows
    id
  end

  defp session_row(id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "SELECT entries_collected FROM war_room_sessions WHERE id = $1",
        [id]
      )

    [[entries_collected]] = result.rows
    %{entries_collected: entries_collected}
  end

  defp log_entry(overrides) do
    Map.merge(
      %{
        level: "debug",
        source: "http",
        route_template: "/_matrix/client/v3/sync",
        request_id: "req-#{System.unique_integer([:positive])}",
        message: "distinctive-wr-excl-test-entry",
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  defp load!(war_room) do
    :ok = Nebu.Web.LogStore.WarRoom.load_active()
    :sys.get_state(war_room)
    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Schema contract (Dev Notes Option A)
  # ══════════════════════════════════════════════════════════════════════════

  describe "schema: war_room_sessions.exclusive_scope (Option A)" do
    test "the column exists, is nullable, and is JSONB-typed" do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT data_type, is_nullable FROM information_schema.columns
          WHERE table_name = 'war_room_sessions' AND column_name = 'exclusive_scope'
          """,
          []
        )

      assert result.rows == [["jsonb", "YES"]],
             "expected war_room_sessions.exclusive_scope to be a nullable jsonb column " <>
               "(Dev Notes Option A) — got: #{inspect(result.rows)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC10 — exclusive scope skips matching entries entirely
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC10: a route_template in a non-empty exclusive_scope is never tagged/counted" do
    test "an entry for the excluded route is NOT tagged, even though scope=\"all\" would otherwise match everything",
         %{war_room: wr} do
      id =
        insert_session(
          scope: "all",
          exclusive_scope: ["/_matrix/client/v3/sync"]
        )

      load!(wr)

      refute Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/sync")
             ),
             "AC10: an excluded route_template must never be tagged, regardless of scope"

      assert session_row(id).entries_collected == 0,
             "AC10: an excluded entry must never increment entries_collected either"
    end

    test "an entry for a DIFFERENT (non-excluded) route IS tagged and counted normally",
         %{war_room: wr} do
      id =
        insert_session(
          scope: "all",
          exclusive_scope: ["/_matrix/client/v3/sync"]
        )

      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/admin/users")
             ) == id

      assert session_row(id).entries_collected == 1
    end

    test "multiple excluded routes are all honored (not hardcoded to a single literal string)",
         %{war_room: wr} do
      id =
        insert_session(
          scope: "all",
          exclusive_scope: ["/_matrix/client/v3/sync", "/health", "/admin/keepalive"]
        )

      load!(wr)

      for route <- ["/_matrix/client/v3/sync", "/health", "/admin/keepalive"] do
        refute Nebu.Web.LogStore.WarRoom.check(log_entry(route_template: route)),
               "AC10: #{route} is in exclusive_scope and must never be tagged"
      end

      assert Nebu.Web.LogStore.WarRoom.check(log_entry(route_template: "/admin/rooms")) == id
      assert session_row(id).entries_collected == 1
    end

    test "exclusive_scope combines with an existing filter (AND semantics unaffected)", %{
      war_room: wr
    } do
      id =
        insert_session(
          scope: "all",
          filter: %{"user_id" => "@alice:localhost"},
          exclusive_scope: ["/_matrix/client/v3/sync"]
        )

      load!(wr)

      # excluded route -> never tagged, even with a matching filter.
      refute Nebu.Web.LogStore.WarRoom.check(
               log_entry(
                 route_template: "/_matrix/client/v3/sync",
                 metadata: %{"user_id" => "@alice:localhost"}
               )
             )

      # non-excluded route, filter matches -> tagged.
      assert Nebu.Web.LogStore.WarRoom.check(
               log_entry(
                 route_template: "/admin/users",
                 metadata: %{"user_id" => "@alice:localhost"}
               )
             ) == id

      # non-excluded route, filter does NOT match -> not tagged (unrelated
      # to exclusive_scope — the pre-existing AND-semantics contract).
      refute Nebu.Web.LogStore.WarRoom.check(
               log_entry(
                 route_template: "/admin/rooms",
                 metadata: %{"user_id" => "@bob:localhost"}
               )
             )
    end
  end

  describe "backward compatibility: exclusive_scope nil/empty is a pure no-op" do
    test "exclusive_scope: nil matches exactly like the pre-existing scope/filter contract",
         %{war_room: wr} do
      id = insert_session(scope: "all", exclusive_scope: nil)
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/sync")
             ) == id
    end

    test "exclusive_scope: [] (empty list) matches exactly like nil", %{war_room: wr} do
      id = insert_session(scope: "all", exclusive_scope: [])
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/sync")
             ) == id
    end
  end
end
