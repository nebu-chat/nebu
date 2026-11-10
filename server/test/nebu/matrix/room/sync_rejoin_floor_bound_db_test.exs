defmodule Nebu.Matrix.Room.SyncRejoinFloorBoundDbTest do
  @moduledoc """
  Real-database test for the bugfix `sync-rejoin-floor-window-point-lookups` (follow-up `I` of the oauth-pages-redesign flake triage). The time floor of
  `Room.DB.fetch_visible_events_in_range_segmented/5` (the gated rejoin `/sync` range read) is a `min(origin_server_ts)` over the position window
  `base - 63 .. base`. As a position RANGE it could be served by a bitmap scan of the whole room (`events_room_id_ts_idx`, `room_id` as the only index
  condition) when the global `room_pos` statistics inflate the estimate for a low base and the timestamp index is much smaller than the position index.
  Migration 000063 adds the covering index `events_room_pos_ts_idx (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL`.

  ## What is proven here

  In ONE rolled-back privileged transaction the skew of a full test run is rebuilt (many small rooms, one large room whose rows share ONE timestamp, so the
  real `events_room_id_ts_idx` stays small). The floor statement of the real call (the statement text is captured from the repo telemetry and cut down
  to `SELECT ts FROM rj_floor`) reads at most 64 rows of `events` in the STALE-statistics regime (the room is unknown to the statistics) in the custom and in the generic plan mode, and with
  index-only scans or bitmap scans switched off; after a fresh `ANALYZE` it reads at most the rows of the room (the known residual, below). The rows are counted by the transaction's own
  statistics counters (`seq_tup_read + idx_tup_fetch`: heap rows fetched, i.e. rows that are not all-visible yet fall back to a heap fetch and are counted).
  KNOWN RESIDUAL (accepted by the owner; the fresh-statistics rows of this test only assert "at most the room's rows"): on a CHURNED table (most pages not all-visible, so the
  covering index costs like a plain index) with a fresh `ANALYZE` and the inflated global `room_pos` estimate, the planner can still choose a room-only bitmap scan: 500 rows read once
  per floor (targeted suites, seed 1), the behaviour before migration 000063; also measured with an additional, even smaller `room_id`-only index and index-only scans switched off.
  The migration makes the floor an index-only scan, it does not make the planner unable to pick another path. Removing the planner choice (a per-room floor structure) is a possible later story.
  That the floor read the WHOLE room before the migration is planner dependent (it depends on what the run left in the table), so it is not asserted here: the
  end-to-end failure is `SyncRejoinRangeScanBoundHttpTest` and the deterministic pins are the plan-shape tests of `SyncRejoinRangeScanBoundDbTest`.
  Nothing is left behind (rollback; the in-transaction `ANALYZE` updates `pg_class` in place and the rolled-back rows are dead tuples, so a `VACUUM ANALYZE events`
  runs afterwards: otherwise later plan tests would plan with those statistics).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.HistoryVisibilityTestSupport, only: [raw_room!: 0, put_message!: 4, put_hv_event!: 4, word: 1]
  import Nebu.Matrix.MembershipStateTestSupport, only: [put_member_id!: 7]

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 600_000

  setup do
    Nebu.Matrix.MembershipStateTestSupport.setup_env!()
    :ok
  end

  @final_select ~r/SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key\s+FROM rj_page.*\z/s

  defp uid(label), do: "@#{label}#{T.rand(4)}:#{T.server_name()}"

  # the statement of the real call, captured from the repo telemetry, cut down to the floor: `SELECT ts FROM rj_floor` (same parameters: $1 room, $2 viewer, $3 base, $4 head, $5 limit + 1)
  defp floor_statement! do
    room = raw_room!()
    {a, b} = {uid("rfa"), uid("rfb")}
    put_hv_event!(room, a, "shared", 100)
    put_member_id!(room, a, "join", a, 105, "$" <> T.rand(12), %{})
    put_member_id!(room, b, "join", b, 110, "$" <> T.rand(12), %{})
    for i <- 1..40, do: put_message!(room, a, word("m"), 1_000 + i)
    head = T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

    parent = self()
    id = "rj-floor-#{T.rand(6)}"

    :ok =
      :telemetry.attach(id, [:nebu, :repo, :query], fn _e, _m, %{query: q}, _c -> if String.contains?(q, "/* history_visibility */") and q =~ "rj_floor", do: send(parent, {:stmt, q}) end, nil)

    try do
      assert {:ok, _} = DB.fetch_visible_events_in_range_segmented(room, b, 20, head, 20)
    after
      :telemetry.detach(id)
    end

    assert_received {:stmt, query}
    assert query =~ "OFFSET 0", "the statement carries the floor"
    assert Regex.match?(@final_select, query), "the statement ends with the final select over rj_page"
    Regex.replace(@final_select, query, "SELECT ts FROM rj_floor WHERE $5::bigint > 0")
  end

  @big_rows 500

  # small rooms (positions 1 .. 3), a large room of ONE timestamp (so the real events_room_id_ts_idx deduplicates it and stays small, as after the earlier bulk tests) and NO ANALYZE: the room is
  # unknown to the statistics (stale regime)
  defp skewed_world!(tx) do
    tag = T.rand(6)
    big = "!rfbig#{tag}:#{T.server_name()}"
    Postgrex.query!(tx, "INSERT INTO rooms (room_id, created_at) VALUES ($1, 1)", [big])

    Postgrex.query!(
      tx,
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts)
      SELECT '$rfbig' || $2::text || g, $1, '@o:t', 'm.room.message', '{"body":"x"}'::jsonb, 5000000000000 FROM generate_series(1, $3::int) g
      """,
      [big, tag, @big_rows]
    )

    Postgrex.query!(tx, "INSERT INTO rooms (room_id, created_at) SELECT '!rfsm' || $1::text || g || ':t', 1 FROM generate_series(1, 400) g", [tag])

    Postgrex.query!(
      tx,
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts)
      SELECT '$rfsm' || $1::text || g || '-' || k, '!rfsm' || $1::text || g || ':t', '@o:t', 'm.room.message', '{"body":"x"}'::jsonb, 1000000 + g * 10 + k
      FROM generate_series(1, 400) g CROSS JOIN generate_series(1, 3) k
      """,
      [tag]
    )

    Postgrex.query!(tx, "SET LOCAL enable_seqscan = off", [])
    big
  end

  defp tx_rows_read(tx), do: Postgrex.query!(tx, "SELECT COALESCE(sum(seq_tup_read + idx_tup_fetch), 0)::bigint FROM pg_stat_xact_user_tables WHERE relname = 'events'", []).rows |> hd() |> hd()

  defp rows_of(tx, sql, params) do
    before = tx_rows_read(tx)
    %{rows: [[floor]]} = Postgrex.query!(tx, sql, params)
    {floor, tx_rows_read(tx) - before}
  end

  # planner regimes: the default, no index-only scan (the covering index then serves as a plain index), no bitmap scan
  @regimes [{"default", []}, {"no index-only scan", ["enable_indexonlyscan = off"]}, {"no bitmap scan", ["enable_bitmapscan = off"]}]
  @planner_switches ~w(enable_bitmapscan enable_indexscan enable_indexonlyscan)

  @tag ac: "the-bound-test-is-green-deterministically"
  test "the floor reads at most 64 rows with stale statistics (and at most the room with fresh ones: known residual), in both plan modes and three planner regimes" do
    floor_sql = floor_statement!()

    measure = fn ->
      T.with_privileged_conn(fn conn ->
        Postgrex.transaction(conn, fn tx ->
          big = skewed_world!(tx)
          params = [big, "@v:t", 7, @big_rows, 21]

          measurements =
            for stats <- ["stale", "fresh"], mode <- ["force_custom_plan", "force_generic_plan"], {regime, settings} <- @regimes do
              if stats == "fresh" and mode == "force_custom_plan" and regime == "default", do: Postgrex.query!(tx, "ANALYZE events", [])
              Postgrex.query!(tx, "SET LOCAL plan_cache_mode = #{mode}", [])
              for sw <- @planner_switches, do: Postgrex.query!(tx, "SET LOCAL #{sw} = on", [])
              for setting <- settings, do: Postgrex.query!(tx, "SET LOCAL #{setting}", [])
              {stats, "#{stats} statistics, #{mode}, #{regime}", rows_of(tx, floor_sql, params)}
            end

          Postgrex.rollback(tx, measurements)
        end)
      end)
    end

    # The rollback removes the rows, but NOT the side effects of the in-transaction ANALYZE on `pg_class` (reltuples / relpages are updated in place) nor the dead tuples
    # of the rolled-back rows: they would skew the statistics the NEXT tests plan with (measured). A VACUUM ANALYZE outside the transaction refreshes both (later tests plan with fresh statistics of the real rows).
    result =
      try do
        measure.()
      after
        T.privileged_sql!("VACUUM ANALYZE events")
      end

    assert {:error, measurements} = result

    for {stats, label, {floor, rows}} <- measurements do
      assert floor == 5_000_000_000_000, "#{label}: the floor is the ONE timestamp of the large room"

      case stats do
        # STRICT where the covering index is stable: the room is unknown to the statistics (the skew of a full run), in every plan mode and planner regime
        "stale" ->
          assert rows <= 64, "#{label}: the floor read #{rows} rows of events (the window has 7 events; a read of the whole #{@big_rows}-row room would be #{@big_rows})"

        # KNOWN RESIDUAL (accepted by the owner, bugfix sync-rejoin-floor-window-point-lookups): with a fresh ANALYZE on a CHURNED table (most pages not all-visible, so the covering index
        # costs like a plain index) and the inflated global room_pos estimate, the planner can still pick a room-only bitmap scan of the whole room: ONE read of the room per floor, the
        # behaviour before migration 000063 (measured: 500 rows, targeted suites, seed 1). Only "at most the room's rows" is asserted here; the removal of the planner choice is a possible
        # later story (a per-room floor structure).
        "fresh" ->
          assert rows <= @big_rows, "#{label}: the floor read #{rows} rows of events (more than the #{@big_rows} rows of the room)"
      end
    end

    # nothing leaked out of the transaction
    assert T.sql!("SELECT count(*) FROM rooms WHERE room_id LIKE '!rfbig%' OR room_id LIKE '!rfsm%'", []).rows == [[0]]
  end
end
