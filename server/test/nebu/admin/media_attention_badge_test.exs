defmodule Nebu.Admin.MediaAttentionBadgeTest do
  @moduledoc """
  Acceptance tests for `Nebu.Admin.MediaAttentionBadge`
  (media-security-admin-control/5b-live-updates-nav-badges, Acceptance Tests 4-7, 9).

  Story: docs/stories/media-security-admin-control/5b-live-updates-nav-badges.md

  ## Why every test here is `@moduletag :integration`

  `initial_count/0` runs a live `SELECT count(*) FROM media_files ...` (ADR-018 inline SQL,
  no injectable fake DB seam, mirrors `Nebu.Admin.MediaLiveTest`'s own justification) and
  `subscribe/0` + the six LiveViews' wiring need a running `Nebu.PubSub`. `classify/1` and
  `apply_transition/3` are pure and DB-free, but are kept in the same `:integration`-tagged
  module for simplicity — they do not need `Nebu.Repo` and would pass under `mix test` alone,
  but are grouped here since the module they exercise is otherwise DB-bound.

  ## Six LiveViews, corrected from the story's original "4" (see story's own Summary
  correction, 2026-07-18): `Nebu.Admin.DashboardLive`, `Nebu.Admin.AuditLogLive`,
  `Nebu.Admin.LogsLive`, `Nebu.Admin.LogsLive.TraceMap`, `Nebu.Admin.LogsLive.WarRoom`, and
  `Nebu.Admin.MediaLive` — verified directly against `server/lib/nebu/admin/router.ex`'s
  `live_session :admin` block, all six already carrying the identical
  `Nebu.Admin.WarRoomIndicator` wiring precedent this story's badge mirrors.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias Nebu.Admin.MediaAttentionBadge

  @endpoint Nebu.Admin.Endpoint

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
          |> String.replace(["-", "_"], "a")

  @attention_pages [
    {"/admin/dashboard", "Nebu.Admin.DashboardLive"},
    {"/admin/audit-log", "Nebu.Admin.AuditLogLive"},
    {"/admin/logs", "Nebu.Admin.LogsLive"},
    {"/admin/logs/trace-map", "Nebu.Admin.LogsLive.TraceMap"},
    {"/admin/logs/war-room", "Nebu.Admin.LogsLive.WarRoom"},
    {"/admin/media", "Nebu.Admin.MediaLive"}
  ]

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
  # Seeding / cleanup / conn helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp media_id(suffix), do: "attnbadge_#{@run_id}_#{suffix}"

  defp insert_media_file!(media_id, state) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state)
      VALUES ($1, 'test.local', 'application/octet-stream', 1024, 'aeskeyhex', 'noncehex',
              '@attnbadge:test.local', $2, false, $3)
      """,
      [media_id, System.system_time(:millisecond), state]
    )

    media_id
  end

  defp cleanup_on_exit! do
    on_exit(fn ->
      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_files WHERE media_id LIKE $1", [
        "attnbadge_#{@run_id}_%"
      ])
    end)
  end

  defp admin_conn_for_live(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-attn-badge-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-attn-badge-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp sent_admin_conn(path) do
    path
    |> admin_conn_for_live()
    |> @endpoint.call(@endpoint.init([]))
  end

  # UX gate (2026-07-18): the badge span now carries BOTH an aria-hidden visible
  # number and an sr-only accessible-name span (mirrors the existing
  # war-room-dot precedent) — `Floki.text/1` on the outer badge concatenates
  # both descendants' text, so the numeric value is extracted specifically
  # from the `aria-hidden="true"` inner span, not the whole badge's text.
  defp badge_count(html) do
    [visible] =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='nav-media-attention-badge'] span[aria-hidden='true']")

    visible |> Floki.text() |> String.trim() |> String.to_integer()
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT4: badge count reflects DB state on initial mount (fresh COUNT, not cached)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT4: initial_count/0 — fresh DB-derived COUNT over exactly the AC2 state set" do
    test "counts exactly :quarantined, :scan_failed, :infected — excludes reserved/scanning/admin_blocked/terminal" do
      cleanup_on_exit!()

      # The real media_files table is shared across the whole test run, so this
      # asserts the DELTA `initial_count/0` itself reports before vs. after
      # seeding — exercising the actual function, not a re-derived query —
      # rather than an absolute value.
      before_seed = MediaAttentionBadge.initial_count()

      insert_media_file!(media_id("q1"), "quarantined")
      insert_media_file!(media_id("q2"), "quarantined")
      insert_media_file!(media_id("sf1"), "scan_failed")
      insert_media_file!(media_id("inf1"), "infected")

      # Explicitly excluded states — must NOT be counted (AC2).
      insert_media_file!(media_id("released1"), "released")
      insert_media_file!(media_id("reserved1"), "reserved")
      insert_media_file!(media_id("scanning1"), "scanning")
      insert_media_file!(media_id("blocked1"), "admin_blocked")
      insert_media_file!(media_id("deleted1"), "deleted")

      after_seed = MediaAttentionBadge.initial_count()

      assert after_seed - before_seed == 4
    end

    test "each of the 6 admin LiveViews assigns the badge count fresh at mount, not an inherited value" do
      cleanup_on_exit!()

      insert_media_file!(media_id("mount_q"), "quarantined")
      insert_media_file!(media_id("mount_sf"), "scan_failed")

      # This run's own attention-count contribution is exactly 2. Since the
      # shared table may carry other rows from concurrent/prior runs, every
      # page's badge is asserted to be present and numeric (>= 2), and — the
      # actual AC2 regression guard — identical across all 6 pages for the
      # SAME moment in time (proving every LiveView independently derives the
      # same fresh COUNT, not a cached/hardcoded value).
      counts =
        for {path, _module} <- @attention_pages do
          conn = sent_admin_conn(path)
          {:ok, _view, html} = live(conn)

          badge_count(html)
        end

      assert Enum.all?(counts, &(&1 >= 2))
      assert Enum.uniq(counts) == [hd(counts)],
             "all 6 LiveViews must show the identical badge count at the same moment: #{inspect(counts)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT5/AT6/AT7: classify/1 + apply_transition/3 delta arithmetic (pure, no DB)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT5/6/7: apply_transition/3 delta arithmetic" do
    defp socket_with_count(n) do
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, media_attention_count: n}}
    end

    defp count(socket), do: socket.assigns.media_attention_count

    test "AT5: entering the attention set increments the count by 1" do
      for {old, new} <- [{:scanning, :infected}, {:scanning, :scan_failed}, {:reserved, :quarantined}] do
        result = MediaAttentionBadge.apply_transition(socket_with_count(3), old, new)
        assert count(result) == 4, "#{old} -> #{new} must increment (+1)"
      end
    end

    test "AT6: leaving the attention set decrements the count by 1" do
      for {old, new} <- [{:quarantined, :released}, {:infected, :deleted}] do
        result = MediaAttentionBadge.apply_transition(socket_with_count(3), old, new)
        assert count(result) == 2, "#{old} -> #{new} must decrement (-1)"
      end
    end

    test "AT6 (no double count): scan_failed -> scanning does NOT decrement further than the " <>
           "single exit it represents — :scanning is not in the attention set either" do
      result = MediaAttentionBadge.apply_transition(socket_with_count(3), :scan_failed, :scanning)
      assert count(result) == 2
    end

    test "AT7: transitions entirely outside the attention set never move the badge" do
      for {old, new} <- [{:released, :deleted}, {:admin_blocked, :released}, {:reserved, :hard_deleted}] do
        result = MediaAttentionBadge.apply_transition(socket_with_count(5), old, new)
        assert count(result) == 5, "#{old} -> #{new} must not move the badge"
      end
    end

    test "AT7 (chain): reserved -> quarantined -> scanning ends outside the set relative to " <>
           "where the chain started counted (each individual broadcast still applied correctly)" do
      socket =
        socket_with_count(0)
        |> MediaAttentionBadge.apply_transition(:reserved, :quarantined)

      assert count(socket) == 1

      socket = MediaAttentionBadge.apply_transition(socket, :quarantined, :scanning)
      assert count(socket) == 0
    end

    test "classify/1: exactly the 3-state attention set returns 1, everything else returns 0" do
      assert MediaAttentionBadge.classify(:quarantined) == 1
      assert MediaAttentionBadge.classify(:scan_failed) == 1
      assert MediaAttentionBadge.classify(:infected) == 1

      for state <- [:reserved, :scanning, :admin_blocked, :released, :deleted, :hard_deleted] do
        assert MediaAttentionBadge.classify(state) == 0, "#{state} must classify as 0 (not counted)"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT9: two independently mounted sessions converge on the same count
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT9: two independent LiveView sessions converge on the same badge count" do
    test "the same broadcast sequence, published once, is seen identically by both sessions" do
      cleanup_on_exit!()
      id_a = media_id("converge_a")
      id_b = media_id("converge_b")

      # A guaranteed-nonzero floor: the badge only renders when count > 0 (AC3
      # "no badge" when nothing needs attention), so this keeps the count
      # observable throughout the test regardless of what else is/isn't in
      # the attention set from concurrent test runs.
      insert_media_file!(media_id("converge_floor"), "quarantined")

      insert_media_file!(id_a, "scanning")
      insert_media_file!(id_b, "scanning")

      conn1 = sent_admin_conn("/admin/media")
      conn2 = sent_admin_conn("/admin/media")

      {:ok, view1, html1} = live(conn1)
      {:ok, view2, html2} = live(conn2)

      start1 = badge_count(html1)
      start2 = badge_count(html2)
      assert start1 == start2

      # A single broadcast call reaches both subscribed sessions.
      Phoenix.PubSub.broadcast(
        Nebu.PubSub,
        "media:admin",
        {:media_state_transition, id_a, :scanning, :infected}
      )

      Phoenix.PubSub.broadcast(
        Nebu.PubSub,
        "media:admin",
        {:media_state_transition, id_b, :scanning, :quarantined}
      )

      Phoenix.PubSub.broadcast(
        Nebu.PubSub,
        "media:admin",
        {:media_state_transition, id_a, :infected, :deleted}
      )

      final1 = view1 |> render() |> badge_count()
      final2 = view2 |> render() |> badge_count()

      assert final1 == final2
      # Net effect of the 3 broadcasts relative to start: +1 (infected) -1 (deleted) +1 (quarantined) = +1
      assert final1 == start1 + 1
    end
  end
end
