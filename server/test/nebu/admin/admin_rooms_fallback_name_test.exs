defmodule Nebu.Admin.RoomsFallbackNameTest do
  @moduledoc """
  RED-phase ATDD acceptance tests for the `bugfix/admin-rooms-fallback-name` bug fix.

  ## Bug

  `Nebu.Admin.RoomsHTML.room_display_name/1` (server/lib/nebu/admin/rooms_html.ex) is
  called by BOTH `templates/rooms/index.html.heex` and `templates/rooms/show.html.heex`:

      defp room_display_name(%{name: name}) when is_binary(name) and name != "", do: name
      defp room_display_name(%{room_id: id}), do: id

  For a room with no `m.room.name` set, this falls back to the raw Matrix room_id
  (e.g. `!15a233d26eaa6557:localhost`), which is not meaningful to an admin operator
  scanning the rooms list (tmp/bugs.md: "Rooms: Die meisten Rooms haben keinen
  Namen... würde ich ein default Namen nach einem Pattern wie
  'participant1:username'-'participant2:username' verwenden").

  This is DISTINCT from the already-fixed client-facing issue (epic
  room-naming-and-default-rooms / story direct-room-heroes, Matrix `summary.m.heroes`)
  — that fix affects what real Matrix clients compute client-side. THIS bug is about
  what the Admin UI itself renders server-side in its own rooms list/detail pages.

  ## Design decisions taken for this test suite (none of these are implemented yet —
  the tests below assert against them and are expected to FAIL until a fix lands)

  - Separator for a name-based fallback: `" & "` (e.g. "Alice & Bob").
  - Threshold for the count-based fallback: rooms with MORE THAN 4 members (i.e. 5+)
    render "(N members)" instead of listing every member — avoids unbounded string
    growth in the rooms list per AC3. Rooms with 1-4 members get name-based fallback.
  - Missing `profiles.displayname` (no profiles row at all, OR a NULL displayname)
    falls back to the member's Matrix user_id localpart (the part before `:`).
  - Zero-member / one-member rooms (AC5) are asserted loosely — the exact fallback
    text is implementation judgement (e.g. "(empty room)" or the sole member's name)
    — what's asserted is: HTTP 200 (no crash) AND the display is no longer simply
    the raw room_id (today's implementation ALWAYS falls back to the raw room_id
    whenever `name` is blank, regardless of member count, so this remains a
    meaningful RED assertion).
  - AC4 (an explicitly named room is unaffected) is a REGRESSION test: it is
    expected to ALREADY PASS today (the current `room_display_name/1` first clause
    already returns `name` verbatim) — it is included to guard against the fix
    accidentally changing named-room behavior.

  ## Why these tests exercise the REAL rendered HTML, not `room_display_name/1` directly

  `room_display_name/1` is a private (`defp`) function of `Nebu.Admin.RoomsHTML` — it
  cannot be called directly from a test module. It is also unclear ahead of
  implementation exactly what shape of data (a `room` map enriched with a computed
  members list? a separately-assigned `:members_summary`?) the eventual fix will
  thread through to the template. So these are true acceptance tests: they seed real
  Postgres rows (rooms / room_members / profiles / users) and assert on the HTML
  the two controller actions (`RoomsController.index/2`, `RoomsController.show/2`)
  actually produce for a real admin session — a black-box, implementation-agnostic
  contract. This mirrors the `Nebu.Admin.AdminStaleRoomsTest` /
  `Nebu.Admin.ListRoomMembersWithoutPiiTest` convention of direct-SQL-seeded,
  `:integration`-tagged Postgres tests, combined with the
  `Nebu.Admin.HttpControllersTest` convention of driving `Nebu.Admin.Endpoint` via
  `Plug.Test` + a signed admin session cookie (no LiveView/WebSocket involved — both
  rooms pages are plain HTTP GET controller actions).

  ## INTEGRATION test — requires a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo and
  Nebu.Admin.Endpoint started). Excluded from the unit run (`make test-unit-elixir`);
  runs via `make test-integration` (or `mix test --include integration` against a
  live stack).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)
  @admin "@admin:test.local"

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    :ok
  end

  # ── Session helpers (mirrors Nebu.Admin.HttpControllersTest.build_admin_conn/1) ──

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-1",
      "matrix_user_id" => @admin
    })
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  # ── DB seeding helpers (mirrors Nebu.Admin.AdminStaleRoomsTest /
  #    Nebu.Admin.ListRoomMembersWithoutPiiTest raw-SQL seeding conventions) ──

  defp insert_room(room_id, name, now) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO rooms (room_id, name, visibility, created_at, status)
      VALUES ($1, $2, 'private', $3, 'active')
      ON CONFLICT (room_id) DO UPDATE SET name = EXCLUDED.name
      """,
      [room_id, name, now]
    )
  end

  defp insert_user(user_id, now) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO users (user_id, created_at) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING",
      [user_id, now]
    )
  end

  # Deliberately NOT called for members that should have NO profiles row (AC2).
  defp insert_profile(user_id, displayname, now) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO profiles (user_id, displayname, updated_at)
      VALUES ($1, $2, $3)
      ON CONFLICT (user_id) DO UPDATE SET displayname = EXCLUDED.displayname
      """,
      [user_id, displayname, now]
    )
  end

  defp insert_member(room_id, user_id, joined_at) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO room_members (room_id, user_id, joined_at, left_at)
      VALUES ($1, $2, $3, NULL)
      ON CONFLICT (room_id, user_id) DO UPDATE SET left_at = NULL, joined_at = $3
      """,
      [room_id, user_id, joined_at]
    )
  end

  defp cleanup(room_id, user_ids) do
    Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM room_members WHERE room_id = $1", [room_id])
    Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [room_id])

    Enum.each(user_ids, fn uid ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM profiles WHERE user_id = $1", [uid])
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [uid])
    end)
  end

  # ── HTML extraction helpers ──────────────────────────────────────────────────
  #
  # room_display_name/1 is private, so we extract the visible display text the
  # two templates actually rendered for a given room_id, straight out of the
  # HTTP response body.

  defp unescape_html(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  # index.html.heex: <tr data-room-id="X" ...><td><a href="...">DISPLAY</a></td>...
  defp index_display_name(resp_body, room_id) do
    case Regex.run(
           ~r/data-room-id="#{Regex.escape(room_id)}"[^>]*>.*?<a[^>]*>(.*?)<\/a>/s,
           resp_body
         ) do
      [_, captured] -> captured |> String.trim() |> unescape_html()
      nil -> nil
    end
  end

  # show.html.heex: <h1 ... data-room-id="X">DISPLAY<span ...>...
  defp show_display_name(resp_body, room_id) do
    case Regex.run(
           ~r/data-room-id="#{Regex.escape(room_id)}"[^>]*>(.*?)<span/s,
           resp_body
         ) do
      [_, captured] -> captured |> String.trim() |> unescape_html()
      nil -> nil
    end
  end

  defp assert_matches_either_order(actual, name_a, name_b) do
    expected_ab = "#{name_a} & #{name_b}"
    expected_ba = "#{name_b} & #{name_a}"

    assert actual in [expected_ab, expected_ba],
           "expected fallback name to be #{inspect(expected_ab)} or #{inspect(expected_ba)}, " <>
             "got: #{inspect(actual)}"
  end

  # ── AC1: 2 members, both with profiles.displayname → name-based fallback ─────

  describe "AC1 — two members, both with displaynames" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac1:test.local"
      alice = "@#{@run_id}_ac1_alice:test.local"
      bob = "@#{@run_id}_ac1_bob:test.local"

      insert_room(room_id, "", now)
      insert_user(alice, now)
      insert_user(bob, now)
      insert_profile(alice, "Alice", now)
      insert_profile(bob, "Bob", now)
      insert_member(room_id, alice, now)
      insert_member(room_id, bob, now + 1)

      on_exit(fn -> cleanup(room_id, [alice, bob]) end)

      %{room_id: room_id}
    end

    test "index page shows both display names instead of the raw room_id", %{room_id: room_id} do
      conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      assert conn.status == 200

      display = index_display_name(conn.resp_body, room_id)
      refute display == room_id, "expected a name-based fallback, got the raw room_id"
      assert_matches_either_order(display, "Alice", "Bob")
    end

    test "show page shows both display names instead of the raw room_id", %{room_id: room_id} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))
      conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()
      assert conn.status == 200

      display = show_display_name(conn.resp_body, room_id)
      refute display == room_id, "expected a name-based fallback, got the raw room_id"
      assert_matches_either_order(display, "Alice", "Bob")
    end
  end

  # ── AC2: a member with NO profiles row → falls back to their user_id localpart ─

  describe "AC2 — a member with no profiles.displayname falls back to their localpart" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac2:test.local"
      alice = "@#{@run_id}_ac2_alice:test.local"
      bob_localpart = "#{@run_id}_ac2_bob"
      bob = "@#{bob_localpart}:test.local"

      insert_room(room_id, "", now)
      insert_user(alice, now)
      insert_user(bob, now)
      insert_profile(alice, "Alice", now)
      # bob deliberately has NO profiles row at all.
      insert_member(room_id, alice, now)
      insert_member(room_id, bob, now + 1)

      on_exit(fn -> cleanup(room_id, [alice, bob]) end)

      %{room_id: room_id, bob_localpart: bob_localpart}
    end

    test "index page falls back to the localpart (not nil/blank) and does not crash",
         %{room_id: room_id, bob_localpart: bob_localpart} do
      conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      assert conn.status == 200

      display = index_display_name(conn.resp_body, room_id)
      refute display == nil
      refute display =~ "nil"
      assert_matches_either_order(display, "Alice", bob_localpart)
    end

    test "show page falls back to the localpart (not nil/blank) and does not crash",
         %{room_id: room_id, bob_localpart: bob_localpart} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))
      conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()
      assert conn.status == 200

      display = show_display_name(conn.resp_body, room_id)
      refute display == nil
      refute display =~ "nil"
      assert_matches_either_order(display, "Alice", bob_localpart)
    end
  end

  # ── AC3: more than 4 members → count-based fallback, not every member's name ──

  describe "AC3 — more than the name-listing threshold (4) members" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac3:test.local"
      members = for n <- 1..5, do: "@#{@run_id}_ac3_m#{n}:test.local"

      insert_room(room_id, "", now)

      members
      |> Enum.with_index()
      |> Enum.each(fn {uid, idx} ->
        insert_user(uid, now)
        insert_profile(uid, "Member#{idx + 1}", now)
        insert_member(room_id, uid, now + idx)
      end)

      on_exit(fn -> cleanup(room_id, members) end)

      %{room_id: room_id}
    end

    test "index page shows a member-count fallback, not every member's name", %{room_id: room_id} do
      conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      assert conn.status == 200

      display = index_display_name(conn.resp_body, room_id)

      assert display =~ ~r/\(\s*5\s+members?\s*\)/i,
             "expected a count-based fallback like \"(5 members)\", got: #{inspect(display)}"

      refute display =~ "Member1"
      refute display =~ "Member5"
    end

    test "show page shows a member-count fallback, not every member's name", %{room_id: room_id} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))
      conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()
      assert conn.status == 200

      display = show_display_name(conn.resp_body, room_id)

      assert display =~ ~r/\(\s*5\s+members?\s*\)/i,
             "expected a count-based fallback like \"(5 members)\", got: #{inspect(display)}"

      refute display =~ "Member1"
      refute display =~ "Member5"
    end
  end

  # ── AC4: a room WITH an explicit name is unaffected (REGRESSION — should ─────
  #    already pass today; guards the fix against changing named-room behavior) ─

  describe "AC4 — a room with an explicit name is unaffected (regression)" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac4:test.local"
      alice = "@#{@run_id}_ac4_alice:test.local"

      insert_room(room_id, "Team Standup", now)
      insert_user(alice, now)
      insert_member(room_id, alice, now)

      on_exit(fn -> cleanup(room_id, [alice]) end)

      %{room_id: room_id}
    end

    test "index page shows the explicit name verbatim", %{room_id: room_id} do
      conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      assert conn.status == 200
      assert index_display_name(conn.resp_body, room_id) == "Team Standup"
    end

    test "show page shows the explicit name verbatim", %{room_id: room_id} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))
      conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()
      assert conn.status == 200
      assert show_display_name(conn.resp_body, room_id) == "Team Standup"
    end
  end

  # ── AC5: edge cases — zero or one member, no name → no crash ──────────────────

  describe "AC5 — zero members, no name" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac5_empty:test.local"
      insert_room(room_id, "", now)
      # Deliberately zero room_members rows for this room.

      on_exit(fn -> cleanup(room_id, []) end)
      %{room_id: room_id}
    end

    test "index page does not crash and does not just repeat the raw room_id",
         %{room_id: room_id} do
      conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      assert conn.status == 200

      display = index_display_name(conn.resp_body, room_id)
      refute display == nil
      refute display == room_id,
             "expected a sensible empty-room fallback (e.g. \"(empty room)\"), got the raw room_id"
    end

    test "show page does not crash and does not just repeat the raw room_id",
         %{room_id: room_id} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))
      conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()
      assert conn.status == 200

      display = show_display_name(conn.resp_body, room_id)
      refute display == nil
      refute display == room_id,
             "expected a sensible empty-room fallback (e.g. \"(empty room)\"), got the raw room_id"
    end
  end

  describe "AC5 — exactly one member, no name" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac5_solo:test.local"
      solo = "@#{@run_id}_ac5_solo:test.local"

      insert_room(room_id, "", now)
      insert_user(solo, now)
      insert_profile(solo, "Solo", now)
      insert_member(room_id, solo, now)

      on_exit(fn -> cleanup(room_id, [solo]) end)
      %{room_id: room_id}
    end

    test "index page does not crash and does not just repeat the raw room_id",
         %{room_id: room_id} do
      conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      assert conn.status == 200

      display = index_display_name(conn.resp_body, room_id)
      refute display == nil
      refute display == room_id,
             "expected a sensible single-member fallback (e.g. the member's own name/localpart), " <>
               "got the raw room_id"
    end

    test "show page does not crash and does not just repeat the raw room_id",
         %{room_id: room_id} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))
      conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()
      assert conn.status == 200

      display = show_display_name(conn.resp_body, room_id)
      refute display == nil
      refute display == room_id,
             "expected a sensible single-member fallback (e.g. the member's own name/localpart), " <>
               "got the raw room_id"
    end
  end

  # ── AC6: index and detail pages share identical fallback logic ────────────────

  describe "AC6 — index and detail pages share identical fallback logic" do
    setup do
      now = System.system_time(:millisecond)
      room_id = "!#{@run_id}_ac6:test.local"
      alice = "@#{@run_id}_ac6_alice:test.local"
      bob = "@#{@run_id}_ac6_bob:test.local"

      insert_room(room_id, "", now)
      insert_user(alice, now)
      insert_user(bob, now)
      insert_profile(alice, "Alice", now)
      insert_profile(bob, "Bob", now)
      insert_member(room_id, alice, now)
      insert_member(room_id, bob, now + 1)

      on_exit(fn -> cleanup(room_id, [alice, bob]) end)

      %{room_id: room_id}
    end

    test "both pages render the identical name-based fallback for the same room",
         %{room_id: room_id} do
      encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

      index_conn = build_admin_conn(:get, "/admin/rooms") |> endpoint_call()
      show_conn = build_admin_conn(:get, "/admin/rooms/#{encoded}") |> endpoint_call()

      assert index_conn.status == 200
      assert show_conn.status == 200

      index_display = index_display_name(index_conn.resp_body, room_id)
      show_display = show_display_name(show_conn.resp_body, room_id)

      assert_matches_either_order(index_display, "Alice", "Bob")

      assert index_display == show_display,
             "expected the SAME fallback text on both pages (both call room_display_name/1), " <>
               "but index=#{inspect(index_display)} show=#{inspect(show_display)}"
    end
  end
end
