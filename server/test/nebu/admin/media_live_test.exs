defmodule Nebu.Admin.MediaLiveTest do
  @moduledoc """
  Acceptance tests for `Nebu.Admin.MediaLive` (media-security-admin-control/5a-admin-media-table,
  extended by 6a-routine-state-actions with the Block/Unblock/Delete/Rescan row actions —
  see the "6a: routine admin actions" describe block below — and by 6c-infected-override with
  the Override row action, see the "6c: infected override" describe block near the end of this
  file).

  Story: docs/stories/media-security-admin-control/5a-admin-media-table.md
  Story: docs/stories/media-security-admin-control/6a-routine-state-actions.md
  Story: docs/stories/media-security-admin-control/6c-infected-override.md

  ## 6c's own RED-phase note (2026-07-19)

  Unlike 6a's own describe block (which only needed the session's `current_user` shape already
  established by 5a), 6c's tests gate on a DISTINCT `media_admin_override` grant read from the
  real `users` table (AC6 — "not the standard `on_mount(:require_admin)` gate alone"), via a
  migration that has not landed yet on this branch. So 6c's tests below fail for TWO overlapping,
  both-legitimate RED reasons until dev-story lands the migration + LiveView changes: (a) a
  genuine Postgrex "column media_admin_override does not exist" error from the seeding helpers
  below, and/or (b) the override trigger/modal markup (`open_override_confirm`/
  `media-override-confirm-modal`/`confirm_override`, this file's own chosen contract — see the
  "6c: infected override" describe block) simply not existing in `Nebu.Admin.MediaLive`'s current
  render/1 output. Both are expected, not a compile error.

  ## Why every test here is `@moduletag :integration`, router-mounted, real Postgres

  Unlike most admin LiveViews, `Nebu.Admin.MediaLive` has no injectable fake DB seam — ADR-018
  puts every query inline in the LiveView itself, directly against `media_files`. There is
  therefore no DB-free unit-test path available at all: every single test needs a live `Nebu.Repo`
  connection with real seeded rows (mirrors `state_machine_test.exs`'s own "requires a live
  Nebu.Repo" convention). This module also HARD-REQUIRES `handle_params/3` (AC3/AC4's URL-driven
  filter/pagination state), so `live_isolated/3` cannot mount it at all (same constraint documented
  on `Nebu.Admin.LogsLive.TraceMap`'s own moduledoc) — every test mounts through the REAL router,
  reusing `logs_live_test.exs`'s own `admin_conn_for_live/1` + `@endpoint.call/2` + `Nebu.Release.
  migrate/0` pattern (see that file's "AC12: mount/3's war_room_id param" describe block for the
  precedent this file follows).

  ## Schema-reality corrections baked into these tests (see the story's own Summary section)

    * `filename` (nullable) was added by Story 2b's migration 000025 — the identity column shows
      it when present, falling back to Media-ID (`<code>`) when `NULL`.
    * `uploader_user_id` is nullable since Story 2e's migration 000027 (nulled on
      `:reserved -> :hard_deleted`) — rendered as `"—"` when `NULL`.
    * The ClamAV signature column reads `scan_metadata["clamav_signature"]`, matching the actual
      key `Nebu.Workers.MediaScanWorker.infect/2` (Story 4b, landed) persists — not a plain
      `"signature"` key an earlier draft of this story assumed.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
          |> String.replace(["-", "_"], "a")

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
          "e.g. `make test-integration`"
      )
    end

    Nebu.Release.migrate()
    Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})

    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Seeding / cleanup helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp media_id(suffix), do: "medialive_#{@run_id}_#{suffix}"

  # Zero-padded numeric suffix — plain unpadded integers (1, 10, 11, ...) create
  # false-positive substring matches with Elixir's `=~` (e.g. "page60_1" is a
  # substring of "page60_10"/"page60_11"/...), which would make a `refute html
  # =~ id` assertion pass even when that exact row IS present. Padding to a
  # fixed width makes every generated id's numeric segment collision-free.
  defp pad2(i), do: i |> Integer.to_string() |> String.pad_leading(2, "0")

  defp insert_media_file!(media_id, attrs) do
    defaults = %{
      server_name: "test.local",
      content_type: "application/octet-stream",
      file_size: 1024,
      aes_key_hex: "aeskeyhex",
      nonce_hex: "noncehex",
      uploader_user_id: "@uploader:test.local",
      uploaded_at: System.system_time(:millisecond),
      deleted: false,
      state: "released",
      filename: nil,
      scan_metadata: nil
    }

    fields = Map.merge(defaults, Map.new(attrs))

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state, filename, scan_metadata)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
      """,
      [
        media_id,
        fields.server_name,
        fields.content_type,
        fields.file_size,
        fields.aes_key_hex,
        fields.nonce_hex,
        fields.uploader_user_id,
        fields.uploaded_at,
        fields.deleted,
        fields.state,
        fields.filename,
        fields.scan_metadata
      ]
    )

    media_id
  end

  # Every test's media_ids share this run's prefix, so cleanup is a single LIKE
  # delete registered once per test via on_exit — no per-row bookkeeping needed.
  defp cleanup_on_exit! do
    on_exit(fn ->
      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_files WHERE media_id LIKE $1", [
        "medialive_#{@run_id}_%"
      ])
    end)
  end

  defp admin_conn_for_live(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-media-live-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp sent_admin_conn(path) do
    path
    |> admin_conn_for_live()
    |> @endpoint.call(@endpoint.init([]))
  end

  defp non_admin_conn(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> @endpoint.call(@endpoint.init([]))
  end

  # media-security-admin-control/6c-infected-override: a parameterized variant
  # of admin_conn_for_live/1 — 6c's tests need DISTINCT admin identities per
  # test (one WITH the media_admin_override grant, one WITHOUT), rather than
  # reusing the single shared "@admin:test.local" identity every other test in
  # this file uses, so granting/revoking the grant on one test can never leak
  # into another test's (or another test FILE's) session.
  defp admin_conn_for_live_as(path, matrix_user_id) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session("current_user", %{
      "admin" => true,
      "sub" => matrix_user_id,
      "matrix_user_id" => matrix_user_id
    })
  end

  defp sent_admin_conn_as(path, matrix_user_id) do
    path
    |> admin_conn_for_live_as(matrix_user_id)
    |> @endpoint.call(@endpoint.init([]))
  end

  # Seeds/grants the media_admin_override role on a real `users` row (see
  # this module's own moduledoc RED-phase note — the column does not exist
  # yet on this branch).
  defp grant_override_role!(admin_id) do
    now_ms = System.system_time(:millisecond)

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO users (user_id, system_role, is_active, created_at, media_admin_override)
      VALUES ($1, 'instance_admin', true, $2, true)
      ON CONFLICT (user_id) DO UPDATE SET media_admin_override = true
      """,
      [admin_id, now_ms]
    )
  end

  # Explicitly sets media_admin_override = false (rather than omitting the
  # column) — see media_admin_actions_test.exs's identical helper for why:
  # a genuine, explicit "no grant" row fails the same documented RED way
  # (Postgrex "column does not exist") as its granted sibling, instead of
  # trivially succeeding against today's schema and producing a vacuous pass
  # on the paired "-without grant" LiveView test below (there is no override
  # markup for ANYONE yet — an absence assertion alone would not prove this
  # AC6 guard is real without this seeding step also being a genuine RED).
  defp insert_admin_without_grant!(admin_id) do
    now_ms = System.system_time(:millisecond)

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO users (user_id, system_role, is_active, created_at, media_admin_override)
      VALUES ($1, 'instance_admin', true, $2, false)
      ON CONFLICT (user_id) DO UPDATE SET media_admin_override = false
      """,
      [admin_id, now_ms]
    )
  end

  defp cleanup_admin_user!(admin_id) do
    Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [admin_id])
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT1: empty state
  # ══════════════════════════════════════════════════════════════════════════

  test "mount renders the empty state when media_files has no rows" do
    # The real media_files table is shared across the whole test run, so a
    # literal "zero rows in the WHOLE table" scenario isn't reproducible here.
    # This test instead scopes to an uploader value THIS run never seeds,
    # proving the "genuinely zero rows for the active (filtered) view"
    # empty-state copy renders — the filtered-empty-state branch is exercised
    # separately (and distinctly worded) by the "no filter matches" test below.
    conn = sent_admin_conn("/admin/media?uploader=medialive_#{@run_id}_never_seeded")
    {:ok, _view, html} = live(conn)

    assert html =~ "Keine Treffer" or html =~ "Noch keine Medien hochgeladen."
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT2: renders a row with all 8 columns
  # ══════════════════════════════════════════════════════════════════════════

  test "mount renders a row per seeded media_files entry with all 8 columns" do
    cleanup_on_exit!()
    id = media_id("cols")
    uploader = "@cols_#{@run_id}:test.local"

    insert_media_file!(id,
      content_type: "application/pdf",
      file_size: 2_400_000,
      uploader_user_id: uploader,
      state: "released",
      filename: "Jahresbericht_#{@run_id}.pdf",
      scan_metadata: %{"scanned_at" => "2026-07-01T10:00:00Z", "clamav_signature" => "OK"}
    )

    conn = sent_admin_conn("/admin/media?uploader=cols_#{@run_id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "Jahresbericht_#{@run_id}.pdf"
    assert html =~ uploader
    assert html =~ "application/pdf"
    assert html =~ "2.4 MB"
    assert html =~ "OK"
    assert html =~ "Freigegeben"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT3/AT4: state filters
  # ══════════════════════════════════════════════════════════════════════════

  test "state filter: selecting :infected via state[]=infected shows only infected rows" do
    cleanup_on_exit!()
    infected_id = media_id("infected")
    released_id = media_id("released_a")

    insert_media_file!(infected_id, state: "infected", filename: "evil_#{@run_id}.exe")
    insert_media_file!(released_id, state: "released", filename: "clean_#{@run_id}.txt")

    conn = sent_admin_conn("/admin/media?state%5B%5D=infected&uploader=@uploader")
    {:ok, _view, html} = live(conn)

    assert html =~ "evil_#{@run_id}.exe"
    refute html =~ "clean_#{@run_id}.txt"
  end

  test "state filter: multiple states via state[]=infected&state[]=admin_blocked shows the union" do
    cleanup_on_exit!()
    infected_id = media_id("union_infected")
    blocked_id = media_id("union_blocked")
    released_id = media_id("union_released")

    insert_media_file!(infected_id, state: "infected", filename: "u_infected_#{@run_id}.bin")
    insert_media_file!(blocked_id, state: "admin_blocked", filename: "u_blocked_#{@run_id}.bin")
    insert_media_file!(released_id, state: "released", filename: "u_released_#{@run_id}.bin")

    conn =
      sent_admin_conn(
        "/admin/media?state%5B%5D=infected&state%5B%5D=admin_blocked&uploader=@uploader"
      )

    {:ok, _view, html} = live(conn)

    assert html =~ "u_infected_#{@run_id}.bin"
    assert html =~ "u_blocked_#{@run_id}.bin"
    refute html =~ "u_released_#{@run_id}.bin"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT5: mime filter
  # ══════════════════════════════════════════════════════════════════════════

  test "mime filter: content_type prefix match narrows results (e.g. application/pdf)" do
    cleanup_on_exit!()
    pdf_id = media_id("mime_pdf")
    png_id = media_id("mime_png")

    insert_media_file!(pdf_id, content_type: "application/pdf", filename: "mime_pdf_#{@run_id}.pdf")
    insert_media_file!(png_id, content_type: "image/png", filename: "mime_png_#{@run_id}.png")

    conn = sent_admin_conn("/admin/media?mime_prefix=application%2Fpdf&uploader=@uploader")
    {:ok, _view, html} = live(conn)

    assert html =~ "mime_pdf_#{@run_id}.pdf"
    refute html =~ "mime_png_#{@run_id}.png"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT6: uploader filter
  # ══════════════════════════════════════════════════════════════════════════

  test "uploader filter: substring match on uploader_user_id narrows results" do
    cleanup_on_exit!()
    a_id = media_id("uploader_a")
    b_id = media_id("uploader_b")

    insert_media_file!(a_id, uploader_user_id: "@distinctive_uploader:test.local", filename: "ua_#{@run_id}.bin")
    insert_media_file!(b_id, uploader_user_id: "@someone_else:test.local", filename: "ub_#{@run_id}.bin")

    conn = sent_admin_conn("/admin/media?uploader=distinctive_uploader")
    {:ok, _view, html} = live(conn)

    assert html =~ "ua_#{@run_id}.bin"
    refute html =~ "ub_#{@run_id}.bin"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT7: date-range filter
  # ══════════════════════════════════════════════════════════════════════════

  test "date-range filter: uploaded_at between from/to excludes rows outside the range" do
    cleanup_on_exit!()
    in_range_id = media_id("date_in_range")
    out_of_range_id = media_id("date_out_of_range")

    # Fixed anchor timestamps (ms epoch) rather than "now" to keep the range
    # assertion deterministic regardless of test wall-clock time.
    anchor = 1_750_000_000_000

    insert_media_file!(in_range_id,
      uploaded_at: anchor,
      uploader_user_id: "@daterange_#{@run_id}:test.local",
      filename: "in_range_#{@run_id}.bin"
    )

    insert_media_file!(out_of_range_id,
      uploaded_at: anchor - 100 * 24 * 60 * 60 * 1000,
      uploader_user_id: "@daterange_#{@run_id}:test.local",
      filename: "out_of_range_#{@run_id}.bin"
    )

    from_ms = anchor - 24 * 60 * 60 * 1000
    to_ms = anchor + 24 * 60 * 60 * 1000

    conn =
      sent_admin_conn(
        "/admin/media?uploader=daterange_#{@run_id}&uploaded_from=#{from_ms}&uploaded_to=#{to_ms}"
      )

    {:ok, _view, html} = live(conn)

    assert html =~ "in_range_#{@run_id}.bin"
    refute html =~ "out_of_range_#{@run_id}.bin"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT8: combined filters
  # ══════════════════════════════════════════════════════════════════════════

  test "combined filters (state + mime + uploader + date range) compose with AND semantics" do
    cleanup_on_exit!()
    match_id = media_id("combined_match")
    wrong_state_id = media_id("combined_wrong_state")
    wrong_mime_id = media_id("combined_wrong_mime")

    anchor = 1_750_000_000_000

    insert_media_file!(match_id,
      state: "infected",
      content_type: "application/pdf",
      uploader_user_id: "@combined_#{@run_id}:test.local",
      uploaded_at: anchor,
      filename: "combined_match_#{@run_id}.bin"
    )

    insert_media_file!(wrong_state_id,
      state: "released",
      content_type: "application/pdf",
      uploader_user_id: "@combined_#{@run_id}:test.local",
      uploaded_at: anchor,
      filename: "combined_wrong_state_#{@run_id}.bin"
    )

    insert_media_file!(wrong_mime_id,
      state: "infected",
      content_type: "image/png",
      uploader_user_id: "@combined_#{@run_id}:test.local",
      uploaded_at: anchor,
      filename: "combined_wrong_mime_#{@run_id}.bin"
    )

    from_ms = anchor - 1000
    to_ms = anchor + 1000

    conn =
      sent_admin_conn(
        "/admin/media?state%5B%5D=infected&mime_prefix=application%2Fpdf" <>
          "&uploader=combined_#{@run_id}&uploaded_from=#{from_ms}&uploaded_to=#{to_ms}"
      )

    {:ok, _view, html} = live(conn)

    assert html =~ "combined_match_#{@run_id}.bin"
    refute html =~ "combined_wrong_state_#{@run_id}.bin"
    refute html =~ "combined_wrong_mime_#{@run_id}.bin"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT9: no filter matches
  # ══════════════════════════════════════════════════════════════════════════

  test "no filter matches → renders 'Keine Treffer — Filter anpassen', not an empty table" do
    conn = sent_admin_conn("/admin/media?uploader=medialive_#{@run_id}_definitely_nothing_matches_this")
    {:ok, _view, html} = live(conn)

    assert html =~ "Keine Treffer"
    refute html =~ "<table"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT10: URL round-trip
  # ══════════════════════════════════════════════════════════════════════════

  test "filter changes round-trip through the URL: push_patch followed by a fresh mount " <>
         "with the same query string reproduces the identical filtered result set" do
    cleanup_on_exit!()
    uploader_scope = "roundtrip_#{@run_id}"
    infected_id = media_id("roundtrip_infected")
    released_id = media_id("roundtrip_released")

    insert_media_file!(infected_id, state: "infected", uploader_user_id: "@#{uploader_scope}:test.local")
    insert_media_file!(released_id, state: "released", uploader_user_id: "@#{uploader_scope}:test.local")

    conn1 = sent_admin_conn("/admin/media?uploader=#{uploader_scope}")
    {:ok, view1, html1} = live(conn1)
    assert html1 =~ infected_id
    assert html1 =~ released_id

    # Clicking the (currently inactive) "infected" pill push_patches to a NEW
    # URL that adds state[]=infected on top of the existing uploader filter.
    html1_after_click =
      view1
      |> element("button[phx-value-state=infected]")
      |> render_click()

    expected_path = "/admin/media?state%5B%5D=infected&uploader=#{uploader_scope}"
    assert_patch(view1, expected_path)
    assert html1_after_click =~ infected_id
    refute html1_after_click =~ released_id

    # A completely fresh, SEPARATE mount with the SAME resulting query string
    # must reproduce the identical filtered result set (the TraceMap filter-
    # state contract — trace-map-filter-reset-bugfix is the cautionary
    # precedent this guards against regressing here too).
    conn2 = sent_admin_conn(expected_path)
    {:ok, _view2, html2} = live(conn2)

    assert html2 =~ infected_id
    refute html2 =~ released_id
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT11-14: keyset pagination
  # ══════════════════════════════════════════════════════════════════════════

  test "pagination: with 60 seeded rows (uploaded_at strictly descending), page 1 " <>
         "returns exactly the 50 most recent rows in uploaded_at DESC order" do
    cleanup_on_exit!()
    base_ts = 1_760_000_000_000
    uploader = "@pagination60_#{@run_id}:test.local"

    ids =
      for i <- 1..60 do
        id = media_id("page60_#{pad2(i)}")
        insert_media_file!(id, uploaded_at: base_ts + i, uploader_user_id: uploader)
        id
      end

    conn = sent_admin_conn("/admin/media?uploader=pagination60_#{@run_id}")
    {:ok, _view, html} = live(conn)

    # Exactly the 50 most recent rows (highest i, i.e. i in 11..60) must be
    # present; the oldest 10 (i in 1..10) must NOT be on page 1.
    Enum.each(11..60, fn i -> assert html =~ Enum.at(ids, i - 1) end)
    Enum.each(1..10, fn i -> refute html =~ Enum.at(ids, i - 1) end)
  end

  test "pagination: 'Weitere laden' with the returned cursor returns exactly the " <>
         "remaining 10 rows, no duplicate and no skipped media_id" do
    cleanup_on_exit!()
    base_ts = 1_761_000_000_000
    uploader = "@pagination_lm_#{@run_id}:test.local"

    ids =
      for i <- 1..60 do
        id = media_id("lm60_#{pad2(i)}")
        insert_media_file!(id, uploaded_at: base_ts + i, uploader_user_id: uploader)
        id
      end

    conn = sent_admin_conn("/admin/media?uploader=pagination_lm_#{@run_id}")
    {:ok, view, html} = live(conn)

    assert html =~ "Weitere laden"

    html2 =
      view
      |> element("#load-more-btn")
      |> render_click()

    # All 60 rows now present (50 original + 10 appended), no duplicates possible
    # since each media_id is unique and stream_insert is keyed by dom_id.
    Enum.each(1..60, fn i -> assert html2 =~ Enum.at(ids, i - 1) end)

    refute has_element?(view, "#load-more-btn")
  end

  test "pagination cursor boundary: a row inserted between page 1 and the Load More " <>
         "fetch, with a uploaded_at newer than the cursor, does not appear on page 2 " <>
         "and does not shift any already-seen row" do
    cleanup_on_exit!()
    base_ts = 1_762_000_000_000
    uploader = "@pagination_boundary_#{@run_id}:test.local"

    ids =
      for i <- 1..55 do
        id = media_id("boundary_#{pad2(i)}")
        insert_media_file!(id, uploaded_at: base_ts + i, uploader_user_id: uploader)
        id
      end

    conn = sent_admin_conn("/admin/media?uploader=pagination_boundary_#{@run_id}")
    {:ok, view, _html} = live(conn)

    # Simulate a NEW row landing (a fresh upload) with uploaded_at newer than
    # anything seen so far — the classic "OFFSET phantom row" trap.
    late_id = media_id("boundary_late")
    insert_media_file!(late_id, uploaded_at: base_ts + 1000, uploader_user_id: uploader)

    html2 =
      view
      |> element("#load-more-btn")
      |> render_click()

    # The late-inserted row must NOT appear on page 2 (it sorts before the
    # cursor, i.e. it belongs on page 1, which this LiveView instance never
    # re-fetches) and none of the original remaining 5 rows may be skipped.
    refute html2 =~ late_id
    Enum.each(1..5, fn i -> assert html2 =~ Enum.at(ids, i - 1) end)
  end

  test "pagination cursor boundary: two rows share the exact same uploaded_at value " <>
         "— the media_id tiebreaker in the keyset still produces a stable, " <>
         "non-overlapping split across pages" do
    cleanup_on_exit!()
    base_ts = 1_763_000_000_000
    uploader = "@pagination_tie_#{@run_id}:test.local"

    # 49 rows with STRICTLY NEWER timestamps than the tied pair occupy
    # positions 1-49 (DESC order); the two tied rows (same, OLDEST,
    # timestamp) occupy positions 50-51, split by the media_id DESC
    # tiebreaker — "tie_b_shared" > "tie_a_shared" lexicographically, so
    # tie_b lands at position 50 (page 1's last row) and tie_a at position
    # 51 (page 2's only row). This deterministically forces the tied pair
    # to straddle the page-1/page-2 cut (51 rows total, LIMIT 50).
    for i <- 1..49 do
      id = media_id("tie_#{pad2(i)}")
      insert_media_file!(id, uploaded_at: base_ts + i, uploader_user_id: uploader)
    end

    tie_a = media_id("tie_a_shared")
    tie_b = media_id("tie_b_shared")
    insert_media_file!(tie_a, uploaded_at: base_ts, uploader_user_id: uploader)
    insert_media_file!(tie_b, uploaded_at: base_ts, uploader_user_id: uploader)

    conn = sent_admin_conn("/admin/media?uploader=pagination_tie_#{@run_id}")
    {:ok, view, html} = live(conn)

    page1_has_a = html =~ tie_a
    page1_has_b = html =~ tie_b

    # Exactly one of the tied pair lands on page 1 (the other must be the very
    # first row of page 2) — never both, never neither.
    assert page1_has_a != page1_has_b

    html2 =
      view
      |> element("#load-more-btn")
      |> render_click()

    page2_has_a = html2 =~ tie_a
    page2_has_b = html2 =~ tie_b

    assert (page1_has_a and page2_has_b) or (page1_has_b and page2_has_a)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT15/16: scan_metadata rendering
  # ══════════════════════════════════════════════════════════════════════════

  test "scanned_at and ClamAV signature columns render '—' when scan_metadata is NULL" do
    cleanup_on_exit!()
    id = media_id("scan_null")

    insert_media_file!(id,
      state: "quarantined",
      uploader_user_id: "@scannull_#{@run_id}:test.local",
      scan_metadata: nil
    )

    conn = sent_admin_conn("/admin/media?uploader=scannull_#{@run_id}")
    {:ok, view, _html} = live(conn)

    assert view |> element("tr[data-media-id='#{id}']") |> render() =~ "—"
  end

  test "scanned_at and ClamAV signature columns render the scan_metadata JSONB values " <>
         "when present" do
    cleanup_on_exit!()
    id = media_id("scan_present")

    insert_media_file!(id,
      state: "infected",
      uploader_user_id: "@scanpresent_#{@run_id}:test.local",
      scan_metadata: %{
        "scanned_at" => "2026-07-10T08:00:00Z",
        "clamav_signature" => "Eicar-Test-Signature"
      }
    )

    conn = sent_admin_conn("/admin/media?uploader=scanpresent_#{@run_id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "2026-07-10T08:00:00Z"
    assert html =~ "Eicar-Test-Signature"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT17/18: multi-select
  # ══════════════════════════════════════════════════════════════════════════

  test "multi-select: checking two rows then toggling a third filter-independent row " <>
         "keeps all three selected" do
    cleanup_on_exit!()
    uploader = "@multiselect_#{@run_id}:test.local"
    a = media_id("ms_a")
    b = media_id("ms_b")
    c = media_id("ms_c")

    insert_media_file!(a, uploader_user_id: uploader, state: "released")
    insert_media_file!(b, uploader_user_id: uploader, state: "infected")
    insert_media_file!(c, uploader_user_id: uploader, state: "admin_blocked")

    conn = sent_admin_conn("/admin/media?uploader=multiselect_#{@run_id}")
    {:ok, view, _html} = live(conn)

    view |> element("tr[data-media-id='#{a}'] input[type=checkbox]") |> render_click()
    view |> element("tr[data-media-id='#{b}'] input[type=checkbox]") |> render_click()
    html = view |> element("tr[data-media-id='#{c}'] input[type=checkbox]") |> render_click()

    assert html =~ "3 ausgewählt"
  end

  test "multi-select: 'select all matching current filter' selects only the rows " <>
         "visible under the active filter, not the full table, with a visible " <>
         "selection count" do
    cleanup_on_exit!()
    uploader = "@selectall_#{@run_id}:test.local"
    other_uploader = "@selectall_other_#{@run_id}:test.local"

    for i <- 1..3 do
      insert_media_file!(media_id("sa_match_#{i}"), uploader_user_id: uploader, state: "released")
    end

    insert_media_file!(media_id("sa_nomatch"), uploader_user_id: other_uploader, state: "released")

    conn = sent_admin_conn("/admin/media?uploader=selectall_#{@run_id}&state%5B%5D=released")
    {:ok, view, _html} = live(conn)

    html =
      view
      |> element("thead input[type=checkbox]")
      |> render_click()

    assert html =~ "3 ausgewählt"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT19: access control
  # ══════════════════════════════════════════════════════════════════════════

  test "non-admin access control: a session without the admin role is redirected " <>
         "away from /admin/media, never rendering the table" do
    conn = non_admin_conn("/admin/media")

    # setup/0 always seeds bootstrap_completed => true, so the on_mount
    # :require_admin gate's unauthenticated branch redirects to /admin/login
    # specifically (not /admin/bootstrap — see Nebu.Admin.Auth.on_mount/4).
    #
    # media-security-admin-control/6a-routine-state-actions (Acceptance Test
    # 25): this SAME on_mount halt+redirect is what makes 6a's four new
    # handle_event clauses (block/unblock/rescan/confirm_delete) unreachable
    # too — a rejected mount means no LiveView process the client could ever
    # send those events to. 6a inherits this gate rather than adding a new
    # authorization mechanism, so no separate test duplicates this one; it
    # already proves the inheritance for every handle_event clause in this
    # module, 5a's and 6a's alike.
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT20: HEEx auto-escaping
  # ══════════════════════════════════════════════════════════════════════════

  test "HEEx auto-escaping: a media_id, filename, or uploader value containing " <>
         "'<script>' renders as escaped text, never executed markup" do
    cleanup_on_exit!()
    id = media_id("xss")

    insert_media_file!(id,
      uploader_user_id: "<script>window.__xss_uploader=1</script>",
      filename: "<script>window.__xss_filename=1</script>",
      state: "released"
    )

    conn = sent_admin_conn("/admin/media?uploader=<script>window.__xss_uploader")
    {:ok, _view, html} = live(conn)

    refute html =~ "<script>window.__xss_uploader=1</script>"
    refute html =~ "<script>window.__xss_filename=1</script>"
    assert html =~ "&lt;script&gt;"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT21-23: schema-reality correction tests (filename/uploader nullability)
  # ══════════════════════════════════════════════════════════════════════════

  test "identity column: renders the real filename in plain text when " <>
         "media_files.filename is not null" do
    cleanup_on_exit!()
    id = media_id("filename_present")

    insert_media_file!(id,
      uploader_user_id: "@filenamepresent_#{@run_id}:test.local",
      filename: "Quartalsbericht_#{@run_id}.docx"
    )

    conn = sent_admin_conn("/admin/media?uploader=filenamepresent_#{@run_id}")
    {:ok, view, _html} = live(conn)

    row_html = view |> element("tr[data-media-id='#{id}']") |> render()
    assert row_html =~ "Quartalsbericht_#{@run_id}.docx"
    refute row_html =~ "<code>#{id}</code>"
  end

  test "identity column: falls back to Media-ID in <code> styling when filename is NULL" do
    cleanup_on_exit!()
    id = media_id("filename_null")

    insert_media_file!(id,
      uploader_user_id: "@filenamenull_#{@run_id}:test.local",
      filename: nil,
      state: "reserved"
    )

    conn = sent_admin_conn("/admin/media?uploader=filenamenull_#{@run_id}")
    {:ok, view, _html} = live(conn)

    row_html = view |> element("tr[data-media-id='#{id}']") |> render()
    assert row_html =~ "<code>#{id}</code>"
  end

  test "uploader column renders '—' when uploader_user_id is NULL" do
    cleanup_on_exit!()
    id = media_id("uploader_null")

    insert_media_file!(id,
      uploader_user_id: nil,
      filename: "hard_deleted_#{@run_id}.bin",
      state: "hard_deleted"
    )

    conn = sent_admin_conn("/admin/media?state%5B%5D=hard_deleted&mime_prefix=application%2Foctet")
    {:ok, view, _html} = live(conn)

    assert has_element?(view, "tr[data-media-id='#{id}']")
    row_html = view |> element("tr[data-media-id='#{id}']") |> render()
    assert row_html =~ "—"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/5b-live-updates-nav-badges
  # Acceptance Tests 1-3, 8 — PubSub-driven live row updates on "media:admin"
  #
  # ## Test 8 adaptation (documented, not a silent deviation)
  #
  # The story's own AT8 proposes asserting "exactly one Phoenix.PubSub
  # subscription was made" via registry introspection. `Phoenix.PubSub` has no
  # public API to enumerate a given pid's subscriptions (the registry backing
  # a subscription is adapter-private), so this suite instead pins the
  # regression guard BEHAVIORALLY: broadcasting directly on a per-media_id
  # topic (`"media:\#{media_id}"`, Story 2d/4b's existing topic) must have NO
  # effect on this LiveView's rendered row — proving `Nebu.Admin.MediaLive`
  # does not subscribe to it. Combined with every other test in this section
  # (which broadcast on `"media:admin"` and DO see an effect), this pins down
  # "reacts to media:admin only" exactly as precisely as a subscription count
  # would, without depending on PubSub internals.
  # ══════════════════════════════════════════════════════════════════════════

  describe "5b: live row updates via \"media:admin\" broadcasts" do
    defp broadcast_admin(media_id, old_state, new_state) do
      Phoenix.PubSub.broadcast(
        Nebu.PubSub,
        "media:admin",
        {:media_state_transition, media_id, old_state, new_state}
      )
    end

    # `Nebu.Admin.MediaLive`'s row-patch handler re-fetches the row FRESH by
    # media_id (the broadcast payload carries only media_id/old_state/new_state,
    # not the row's other columns — see media_live.ex's own moduledoc). In real
    # production this is always correct: `Nebu.Media.StateMachine.transition/4`
    # only broadcasts AFTER its DB transaction commits, so the row is already
    # updated by broadcast time. This helper mirrors that "DB write already
    # committed" precondition directly (a raw UPDATE, not the full state
    # machine/ClamAV pipeline — matching this codebase's established
    # broadcast-only-in-tests convention, see this file's moduledoc) before
    # broadcasting, rather than leaving the row's actual DB state stale.
    defp set_db_state!(media_id, new_state) do
      Ecto.Adapters.SQL.query!(Nebu.Repo, "UPDATE media_files SET state = $2 WHERE media_id = $1", [
        media_id,
        Atom.to_string(new_state)
      ])
    end

    test "a media_id visible in the current page gets its row patched in place on a media:admin broadcast" do
      cleanup_on_exit!()
      uploader = "@rowpatch_#{@run_id}:test.local"
      id = media_id("rowpatch_target")

      insert_media_file!(id, uploader_user_id: uploader, state: "scanning", filename: "rp_#{@run_id}.bin")

      conn = sent_admin_conn("/admin/media?uploader=rowpatch_#{@run_id}")
      {:ok, view, html} = live(conn)

      assert html =~ "Wird geprüft"

      set_db_state!(id, :released)
      broadcast_admin(id, :scanning, :released)
      # Synchronize with the LiveView process before rendering: a round-trip
      # render/1 call blocks until all prior messages (incl. our broadcast)
      # have been processed by the LiveView, avoiding a race/sleep.
      row_html = view |> element("tr[data-media-id='#{id}']") |> render()

      assert row_html =~ "Freigegeben"
      refute row_html =~ "Wird geprüft"
    end

    test "a broadcast for a media_id not in the current page/filter is ignored, no phantom row appears" do
      cleanup_on_exit!()
      uploader = "@rowpatch_excl_#{@run_id}:test.local"
      visible_id = media_id("rowpatch_visible")
      excluded_id = media_id("rowpatch_excluded_x")

      insert_media_file!(visible_id, uploader_user_id: uploader, state: "released")

      conn = sent_admin_conn("/admin/media?uploader=rowpatch_excl_#{@run_id}")
      {:ok, view, html} = live(conn)
      count_before = view |> render() |> count_media_rows()

      refute html =~ excluded_id

      broadcast_admin(excluded_id, :scanning, :infected)
      html_after = view |> render()

      refute html_after =~ excluded_id
      assert count_media_rows(html_after) == count_before
    end

    test "multi-select selection survives a live row update for an unrelated row" do
      cleanup_on_exit!()
      uploader = "@rowpatch_ms_#{@run_id}:test.local"
      a = media_id("rowpatch_ms_a")
      b = media_id("rowpatch_ms_b")
      c = media_id("rowpatch_ms_c")

      insert_media_file!(a, uploader_user_id: uploader, state: "released")
      insert_media_file!(b, uploader_user_id: uploader, state: "released")
      insert_media_file!(c, uploader_user_id: uploader, state: "scanning")

      conn = sent_admin_conn("/admin/media?uploader=rowpatch_ms_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view |> element("tr[data-media-id='#{a}'] input[type=checkbox]") |> render_click()
      view |> element("tr[data-media-id='#{b}'] input[type=checkbox]") |> render_click()

      set_db_state!(c, :infected)
      broadcast_admin(c, :scanning, :infected)
      html = view |> element("tr[data-media-id='#{c}']") |> render()
      assert html =~ "Infiziert"

      # "N ausgewählt" is 5a's own established, reliable selection-count
      # assertion (see media_live_test.exs's pre-existing multi-select tests)
      # — it lives OUTSIDE the `phx-update="stream"` tbody, so it always
      # reflects @selected_ids fresh on every render, unlike an individual
      # stream row's OWN attributes (Phoenix LiveView's stream diffing only
      # re-sends attributes for rows explicitly touched by a stream
      # operation in that render cycle — a row's other, non-stream-driven
      # attributes are not guaranteed to be re-diffed just because an
      # unrelated assign changed elsewhere in the same render). Since only
      # A and B were ever toggled in this test (nothing else can add to
      # @selected_ids), "2 ausgewählt" here can only mean {A, B} — a fully
      # sufficient proof of AC1's "A and B remain checked after the patch".
      assert render(view) =~ "2 ausgewählt"
    end

    test "a broadcast on the per-media_id topic (story 2d/4b's own topic, NOT media:admin) does " <>
           "NOT patch the row — regression guard: this LiveView must not subscribe per-row (AT8)" do
      cleanup_on_exit!()
      uploader = "@rowpatch_at8_#{@run_id}:test.local"
      id = media_id("rowpatch_at8")

      insert_media_file!(id, uploader_user_id: uploader, state: "scanning")

      conn = sent_admin_conn("/admin/media?uploader=rowpatch_at8_#{@run_id}")
      {:ok, view, _html} = live(conn)

      Phoenix.PubSub.broadcast(Nebu.PubSub, "media:#{id}", {:media_state_transition, id, :released})

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Wird geprüft",
             "AT8 regression: Nebu.Admin.MediaLive must react ONLY to \"media:admin\" broadcasts, " <>
               "never to a per-media_id \"media:<id>\" topic (that topic belongs to " <>
               "Story 2d's DownloadStall consumer) — a per-row subscription here does not scale " <>
               "past a handful of visible rows (see story Summary/Guardrails)."
    end

    defp count_media_rows(html) do
      html |> Floki.parse_document!() |> Floki.find("tr[data-role='media-row']") |> length()
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/6a-routine-state-actions
  # Acceptance Tests 19-24 — Block/Unblock/Rescan/Delete row actions
  #
  # Every state-changing action here goes through the REAL Nebu.Media.admin_*
  # functions and the REAL Nebu.Media.StateMachine.transition/4 — no fakes.
  # The row's own badge update after Block/Unblock/Delete is NOT driven by
  # anything in this test file: it arrives for free via the SAME 5b
  # "media:admin" broadcast + handle_info/2 row-patch mechanism the tests
  # above already exercise (Nebu.Media.StateMachine broadcasts after its own
  # commit; this LiveView is already subscribed via mount/3). Rescan (AC4)
  # never transitions state at all, so its row is asserted to stay unchanged.
  # ══════════════════════════════════════════════════════════════════════════

  describe "6a: routine admin actions" do
    test "clicking Block on a :released row fires immediately (no modal) and the row's " <>
           "badge updates to :admin_blocked via the live socket" do
      cleanup_on_exit!()
      uploader = "@block_#{@run_id}:test.local"
      id = media_id("block_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "released")

      conn = sent_admin_conn("/admin/media?uploader=block_#{@run_id}")
      {:ok, view, html} = live(conn)

      assert html =~ "Freigegeben"
      refute has_element?(view, "#media-delete-confirm-modal")

      row_html =
        view
        |> form("tr[data-media-id='#{id}'] form", %{"reason" => ""})
        |> render_submit()

      refute row_html =~ "#media-delete-confirm-modal"
      assert render(view) =~ "Gesperrt"
      assert render(view) =~ "gesperrt"
    end

    test "clicking Unblock on an :admin_blocked row fires immediately and the row's " <>
           "badge updates to :released" do
      cleanup_on_exit!()
      uploader = "@unblock_#{@run_id}:test.local"
      id = media_id("unblock_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "admin_blocked")

      conn = sent_admin_conn("/admin/media?uploader=unblock_#{@run_id}")
      {:ok, view, html} = live(conn)

      assert html =~ "Gesperrt"

      view
      |> element("tr[data-media-id='#{id}'] button[phx-click=unblock]")
      |> render_click()

      assert render(view) =~ "Freigegeben"
      assert render(view) =~ "entsperrt"
    end

    test "clicking Rescan on a :quarantined row fires immediately and an info flash " <>
           "confirms the rescan was queued" do
      cleanup_on_exit!()
      uploader = "@rescan_#{@run_id}:test.local"
      id = media_id("rescan_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "quarantined")

      conn = sent_admin_conn("/admin/media?uploader=rescan_#{@run_id}")
      {:ok, view, html} = live(conn)

      assert html =~ "In Quarantäne"

      view
      |> element("tr[data-media-id='#{id}'] button[phx-click=rescan]")
      |> render_click()

      html_after = render(view)
      assert html_after =~ "eingeplant"
      # AC4: Rescan never itself transitions state — the row stays :quarantined
      # until the (not exercised in this LiveView test) worker picks the job up.
      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "In Quarantäne"
    end

    test "clicking Delete opens a confirm modal; the row is unchanged until the modal " <>
           "is confirmed" do
      cleanup_on_exit!()
      uploader = "@delete_open_#{@run_id}:test.local"
      id = media_id("delete_open")

      insert_media_file!(id, uploader_user_id: uploader, state: "released")

      conn = sent_admin_conn("/admin/media?uploader=delete_open_#{@run_id}")
      {:ok, view, _html} = live(conn)

      refute has_element?(view, "#media-delete-confirm-modal")

      html =
        view
        |> element("#delete-trigger-#{id}")
        |> render_click()

      assert html =~ "media-delete-confirm-modal"
      assert html =~ "Datei löschen?"

      # Row is unchanged — no transition has happened yet, only the confirm
      # dialog opened.
      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Freigegeben"
    end

    test "confirming the Delete modal transitions the row to :deleted and closes the modal" do
      cleanup_on_exit!()
      uploader = "@delete_confirm_#{@run_id}:test.local"
      id = media_id("delete_confirm")

      insert_media_file!(id, uploader_user_id: uploader, state: "released")

      conn = sent_admin_conn("/admin/media?uploader=delete_confirm_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view |> element("#delete-trigger-#{id}") |> render_click()
      assert has_element?(view, "#media-delete-confirm-modal")

      html = view |> element("#media-delete-confirm-submit") |> render_click()

      refute html =~ "media-delete-confirm-modal"
      refute has_element?(view, "#media-delete-confirm-modal")

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Gelöscht"

      # NOTE (AC10 "focus returns to the trigger element on close"): real
      # focus movement is a client-side DOM effect performed by the
      # MediaDeleteConfirmModal JS hook's `destroyed/0` callback
      # (priv/static/assets/app.js) — Phoenix.LiveViewTest has no real
      # browser/DOM and cannot observe actual focus state, only the
      # server-rendered HTML diff (which the assertions above already
      # cover: the modal markup is gone). Verified by code inspection, not
      # by this test.
    end

    test "pressing Escape while the Delete modal is open cancels without transitioning the row" do
      cleanup_on_exit!()
      uploader = "@delete_escape_#{@run_id}:test.local"
      id = media_id("delete_escape")

      insert_media_file!(id, uploader_user_id: uploader, state: "released")

      conn = sent_admin_conn("/admin/media?uploader=delete_escape_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view |> element("#delete-trigger-#{id}") |> render_click()
      assert has_element?(view, "#media-delete-confirm-modal")

      view
      |> element("#media-delete-confirm-modal")
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#media-delete-confirm-modal")

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Freigegeben"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/6c-infected-override
  # Acceptance Tests 13-18 — the Override row action, gated by the distinct
  # media_admin_override grant (AC6), with its own escalated-warning confirm
  # modal (AC7).
  #
  # ## Markup/event contract this test file establishes (dev-story must match)
  #
  # None of the following exist in `Nebu.Admin.MediaLive` yet — chosen here to
  # mirror 6a's own Delete-confirm naming exactly, substituting "override" for
  # "delete":
  #   * trigger:      `phx-click="open_override_confirm"` /
  #                    `phx-value-media_id={row.media_id}` on an `:infected` row,
  #                    only when `socket.assigns.media_admin_override?` is true
  #                    (per the story's own Technical Requirements)
  #   * modal:         `#media-override-confirm-modal` (role="dialog"), containing
  #                    the literal AC7 warning text and a `<form phx-submit=
  #                    "confirm_override">` with a hidden `media_id` field and a
  #                    `name="reason"` input/textarea
  #   * cancel:        `phx-click="cancel_override_confirm"` / Escape via
  #                    `phx-window-keydown`/`phx-key="Escape"` on the modal,
  #                    mirroring `#media-delete-confirm-modal` exactly
  # ══════════════════════════════════════════════════════════════════════════

  describe "6c: infected override (media_admin_override)" do
    test "the override action/button is not rendered on an :infected row for an admin session " <>
           "without the media_admin_override grant" do
      cleanup_on_exit!()
      uploader = "@override_norole_#{@run_id}:test.local"
      id = media_id("override_norole")
      admin_uid = "@override_norole_admin_#{@run_id}:test.local"

      insert_media_file!(id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "no_role_#{@run_id}.bin"
      )

      insert_admin_without_grant!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      conn = sent_admin_conn_as("/admin/media?uploader=override_norole_#{@run_id}", admin_uid)
      {:ok, view, html} = live(conn)

      assert html =~ "Infiziert"

      refute has_element?(
               view,
               "[phx-click=open_override_confirm][phx-value-media_id='#{id}']"
             )
    end

    test "the override action/button is rendered on an :infected row for an admin session with " <>
           "the media_admin_override grant, and is absent on non-:infected rows" do
      cleanup_on_exit!()
      uploader = "@override_role_#{@run_id}:test.local"
      infected_id = media_id("override_role_infected")
      released_id = media_id("override_role_released")
      admin_uid = "@override_role_admin_#{@run_id}:test.local"

      insert_media_file!(infected_id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "role_infected_#{@run_id}.bin"
      )

      insert_media_file!(released_id,
        uploader_user_id: uploader,
        state: "released",
        filename: "role_released_#{@run_id}.bin"
      )

      grant_override_role!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      conn = sent_admin_conn_as("/admin/media?uploader=override_role_#{@run_id}", admin_uid)
      {:ok, view, _html} = live(conn)

      assert has_element?(
               view,
               "[phx-click=open_override_confirm][phx-value-media_id='#{infected_id}']"
             )

      refute has_element?(
               view,
               "tr[data-media-id='#{released_id}'] [phx-click=open_override_confirm]"
             )
    end

    test "clicking the override action opens the confirm modal with the literal escalated " <>
           "warning text and a reason input; the row is unchanged until confirmed" do
      cleanup_on_exit!()
      uploader = "@override_open_#{@run_id}:test.local"
      id = media_id("override_open")
      admin_uid = "@override_open_admin_#{@run_id}:test.local"

      insert_media_file!(id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "open_#{@run_id}.bin"
      )

      grant_override_role!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      conn = sent_admin_conn_as("/admin/media?uploader=override_open_#{@run_id}", admin_uid)
      {:ok, view, _html} = live(conn)

      refute has_element?(view, "#media-override-confirm-modal")

      html =
        view
        |> element("[phx-click=open_override_confirm][phx-value-media_id='#{id}']")
        |> render_click()

      assert html =~ "media-override-confirm-modal"

      assert html =~
               "Diese Datei wurde als Malware erkannt. Freigabe erfolgt auf eigene Verantwortung."

      assert has_element?(
               view,
               "#media-override-confirm-modal input[name=reason], " <>
                 "#media-override-confirm-modal textarea[name=reason]"
             )

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Infiziert"
    end

    test "confirming the override modal with a non-empty reason transitions the row to " <>
           ":released via the live socket and closes the modal, returning focus to the row's " <>
           "trigger" do
      cleanup_on_exit!()
      uploader = "@override_confirm_#{@run_id}:test.local"
      id = media_id("override_confirm")
      admin_uid = "@override_confirm_admin_#{@run_id}:test.local"

      insert_media_file!(id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "confirm_#{@run_id}.bin",
        scan_metadata: %{"clamav_signature" => "Eicar-Test-Signature"}
      )

      grant_override_role!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      conn = sent_admin_conn_as("/admin/media?uploader=override_confirm_#{@run_id}", admin_uid)
      {:ok, view, _html} = live(conn)

      view
      |> element("[phx-click=open_override_confirm][phx-value-media_id='#{id}']")
      |> render_click()

      assert has_element?(view, "#media-override-confirm-modal")

      html =
        view
        |> form("#media-override-confirm-modal form", %{"reason" => "confirmed false positive"})
        |> render_submit()

      refute html =~ "media-override-confirm-modal"
      refute has_element?(view, "#media-override-confirm-modal")

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Freigegeben"

      # NOTE (AC7 "focus returns to the row's trigger element on close"): real
      # focus movement is a client-side DOM effect (a JS hook's destroyed/0
      # callback, mirroring 6a's own MediaDeleteConfirmModal convention) —
      # Phoenix.LiveViewTest has no real browser/DOM and cannot observe actual
      # focus state, only the server-rendered HTML diff (already asserted
      # above: the modal markup is gone). Verified by code inspection, not by
      # this test — same documented limitation as 6a's own Delete-confirm test.
    end

    test "attempting to confirm the override modal with an empty reason keeps the modal open " <>
           "and surfaces a validation error, without firing admin_override_infected/3" do
      cleanup_on_exit!()
      uploader = "@override_empty_#{@run_id}:test.local"
      id = media_id("override_empty")
      admin_uid = "@override_empty_admin_#{@run_id}:test.local"

      insert_media_file!(id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "empty_#{@run_id}.bin"
      )

      grant_override_role!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      conn = sent_admin_conn_as("/admin/media?uploader=override_empty_#{@run_id}", admin_uid)
      {:ok, view, _html} = live(conn)

      view
      |> element("[phx-click=open_override_confirm][phx-value-media_id='#{id}']")
      |> render_click()

      assert has_element?(view, "#media-override-confirm-modal")

      view
      |> form("#media-override-confirm-modal form", %{"reason" => ""})
      |> render_submit()

      # The modal must still be open (no {:ok, :released} branch reached) and
      # the file must still genuinely be :infected — admin_override_infected/3's
      # own AC2 validation never lets an empty/whitespace reason drive a real
      # transition, regardless of what the LiveView's own client-side "disabled
      # while blank" affordance does or doesn't intercept first.
      assert has_element?(view, "#media-override-confirm-modal")

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Infiziert"
    end

    test "pressing Escape while the override modal is open cancels without transitioning the row" do
      cleanup_on_exit!()
      uploader = "@override_escape_#{@run_id}:test.local"
      id = media_id("override_escape")
      admin_uid = "@override_escape_admin_#{@run_id}:test.local"

      insert_media_file!(id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "escape_#{@run_id}.bin"
      )

      grant_override_role!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      conn = sent_admin_conn_as("/admin/media?uploader=override_escape_#{@run_id}", admin_uid)
      {:ok, view, _html} = live(conn)

      view
      |> element("[phx-click=open_override_confirm][phx-value-media_id='#{id}']")
      |> render_click()

      assert has_element?(view, "#media-override-confirm-modal")

      view
      |> element("#media-override-confirm-modal")
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#media-override-confirm-modal")

      row_html = view |> element("tr[data-media-id='#{id}']") |> render()
      assert row_html =~ "Infiziert"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10e-trace-map-war-room-integration (AC3):
  # every routine admin action (Block/Unblock/Delete/Rescan, 6a) and the
  # Infected-Override action (6c) must ADDITIONALLY log an operational entry
  # (route_template: "/admin/media", request_id: media_id) alongside — NEVER
  # instead of — the pre-existing `Nebu.Compliance.AuditWriter.log/6` call
  # `Nebu.Media`'s own `admin_block/3`/`admin_unblock/2`/`admin_delete/2`/
  # `admin_rescan/2`/`admin_override_infected/3` already perform (see
  # `lib/nebu/media.ex`'s own `write_admin_audit/4` private helper — the
  # AuditWriter call lives in `Nebu.Media`, not in this LiveView itself; the
  # NEW `Logger.info/2` call this AC adds belongs directly in
  # `Nebu.Admin.MediaLive`'s own `handle_event/3` clauses, per the story's
  # Technical Requirements).
  #
  # Observed the same way clamav_test.exs's/media_scan_worker_test.exs's own
  # 10e additions do: attach the REAL `Nebu.Web.LogStore.Handler`, subscribe
  # to the "operational_logs" PubSub topic, and inspect the broadcast entry's
  # top-level `:route_template`/`:request_id` fields.
  #
  # ## Why these MUST FAIL right now
  #
  # `Nebu.Admin.MediaLive`'s handle_event/3 clauses for these five actions
  # currently call ONLY into `Nebu.Media.admin_*` — none of them additionally
  # calls `Logger.info/2` with this metadata, so every
  # `assert_operational_entry_for!/2` assertion below fails today (no
  # matching broadcast entry is ever received), while the audit_log-row
  # assertions in the SAME tests already PASS (that half is pre-existing,
  # landed 6a/6c behavior — kept here as the "in addition to, never instead
  # of" half of this AC).
  # ══════════════════════════════════════════════════════════════════════════

  describe "10e AC3: admin actions carry Trace-Map metadata alongside AuditWriter" do
    # code-review cycle 2 (MAJOR-2): log_admin_media_action/2 now logs via
    # Logger.info/2 (per AC3's exact spec), not Logger.warning/2 — this level
    # bump is required so this describe block's tests can actually observe
    # it; config/test.exs's primary Logger level (:warning) would otherwise
    # silently drop it before it ever reaches Nebu.Web.LogStore.Handler.
    # Mirrors request_logger_test.exs's own Logger.configure(level:
    # :info)/on_exit restore idiom, scoped narrowly to just this describe
    # block.
    setup do
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    defp ensure_pubsub_started! do
      case Process.whereis(Nebu.PubSub) do
        nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
        _pid -> :ok
      end
    end

    defp attach_log_capture! do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")
    end

    defp drain_log_entries(acc \\ []) do
      receive do
        msg -> drain_log_entries([msg | acc])
      after
        500 -> Enum.reverse(acc)
      end
    end

    defp assert_operational_entry_for!(media_id, entries) do
      entry =
        Enum.find(entries, fn
          %{route_template: "/admin/media", request_id: ^media_id} -> true
          _ -> false
        end)

      refute is_nil(entry),
             "expected an operational_logs entry with route_template \"/admin/media\" and " <>
               "request_id == #{inspect(media_id)}, got: #{inspect(entries)}"
    end

    defp audit_row_actor(media_id, action) do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT actor_user_id FROM audit_log WHERE target_id = $1 AND action = $2",
          [media_id, action]
        )

      case result.rows do
        [[actor_user_id] | _] -> actor_user_id
        [] -> nil
      end
    end

    test "Block fires both the AuditWriter media_blocked entry and an operational log entry" do
      cleanup_on_exit!()
      uploader = "@block_10e_#{@run_id}:test.local"
      id = media_id("block_10e_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "released")

      attach_log_capture!()

      conn = sent_admin_conn("/admin/media?uploader=block_10e_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view
      |> form("tr[data-media-id='#{id}'] form", %{"reason" => ""})
      |> render_submit()

      refute is_nil(audit_row_actor(id, "media_blocked")),
             "expected the pre-existing AuditWriter.log/6 media_blocked entry to still fire"

      assert_operational_entry_for!(id, drain_log_entries())
    end

    test "Unblock fires both the AuditWriter media_unblocked entry and an operational log entry" do
      cleanup_on_exit!()
      uploader = "@unblock_10e_#{@run_id}:test.local"
      id = media_id("unblock_10e_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "admin_blocked")

      attach_log_capture!()

      conn = sent_admin_conn("/admin/media?uploader=unblock_10e_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view
      |> element("tr[data-media-id='#{id}'] button[phx-click=unblock]")
      |> render_click()

      refute is_nil(audit_row_actor(id, "media_unblocked")),
             "expected the pre-existing AuditWriter.log/6 media_unblocked entry to still fire"

      assert_operational_entry_for!(id, drain_log_entries())
    end

    test "confirming Delete fires both the AuditWriter media_deleted entry and an operational log entry" do
      cleanup_on_exit!()
      uploader = "@delete_10e_#{@run_id}:test.local"
      id = media_id("delete_10e_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "released")

      attach_log_capture!()

      conn = sent_admin_conn("/admin/media?uploader=delete_10e_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view |> element("#delete-trigger-#{id}") |> render_click()
      view |> element("#media-delete-confirm-submit") |> render_click()

      refute is_nil(audit_row_actor(id, "media_deleted")),
             "expected the pre-existing AuditWriter.log/6 media_deleted entry to still fire"

      assert_operational_entry_for!(id, drain_log_entries())
    end

    test "Rescan fires both the AuditWriter media_rescanned entry and an operational log entry" do
      cleanup_on_exit!()
      uploader = "@rescan_10e_#{@run_id}:test.local"
      id = media_id("rescan_10e_action")

      insert_media_file!(id, uploader_user_id: uploader, state: "quarantined")

      attach_log_capture!()

      conn = sent_admin_conn("/admin/media?uploader=rescan_10e_#{@run_id}")
      {:ok, view, _html} = live(conn)

      view
      |> element("tr[data-media-id='#{id}'] button[phx-click=rescan]")
      |> render_click()

      refute is_nil(audit_row_actor(id, "media_rescanned")),
             "expected the pre-existing AuditWriter.log/6 media_rescanned entry to still fire"

      assert_operational_entry_for!(id, drain_log_entries())
    end

    test "confirming Infected-Override fires both the AuditWriter media_infected_override entry and an operational log entry" do
      cleanup_on_exit!()
      uploader = "@override_10e_#{@run_id}:test.local"
      id = media_id("override_10e_action")
      admin_uid = "@override_10e_admin_#{@run_id}:test.local"

      insert_media_file!(id,
        uploader_user_id: uploader,
        state: "infected",
        filename: "override_10e_#{@run_id}.bin"
      )

      grant_override_role!(admin_uid)
      on_exit(fn -> cleanup_admin_user!(admin_uid) end)

      attach_log_capture!()

      conn = sent_admin_conn_as("/admin/media?uploader=override_10e_#{@run_id}", admin_uid)
      {:ok, view, _html} = live(conn)

      view
      |> element("[phx-click=open_override_confirm][phx-value-media_id='#{id}']")
      |> render_click()

      view
      |> form("#media-override-confirm-modal form", %{"reason" => "false positive, confirmed clean"})
      |> render_submit()

      refute is_nil(audit_row_actor(id, "media_infected_override")),
             "expected the pre-existing AuditWriter.log/6 media_infected_override entry to " <>
               "still fire"

      assert_operational_entry_for!(id, drain_log_entries())
    end
  end
end
