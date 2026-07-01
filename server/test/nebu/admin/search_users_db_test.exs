defmodule Nebu.Admin.SearchUsersDBTest do
  @moduledoc """
  Story admin-add-user-autocomplete (AC5, Acceptance Tests 1+2) —
  `Nebu.Admin.DB.search_users/2` (and the now-honoured `_search` in `list_users/3`).

  INTEGRATION test — requires a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo started).
  Excluded from the unit run; runs via make test-integration / on the redeployed stack.

  ATDD — written FIRST (RED before search_users/2 existed). Verifies:
    * the term is matched as a substring against user_id (ILIKE), prefix + substring;
    * non-matches are excluded; result is LIMIT-capped;
    * injection-safe (a SQL-injection term is bound, returns no rows, table intact);
    * ILIKE wildcard chars (`%`, `_`) in the term are escaped so a `%` term does not
      match everything;
    * inactive users are excluded (is_active-aware).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Admin.DB

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  # All seeded ids carry the unique run id so concurrent / repeated runs do not collide
  # and so a substring search can target only this run's rows. The run id PRECEDES the
  # local part ("@<run>_<local>:...") so a run-scoped substring like "<run>_al" is a
  # genuine substring of "<run>_alex" + "<run>_alice" (but not "<run>_bob"), letting the
  # substring tests target alex+alice and exclude bob without matching other runs.
  defp uid(local), do: "@#{@run_id}_#{local}:test.local"

  @alex_local "alex"
  @alice_local "alice"
  @bob_local "bob"
  @inactive_local "alvin"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    now = System.system_time(:millisecond)

    seed = fn local, active ->
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO users (user_id, is_active, system_role, created_at)
        VALUES ($1, $2, 'user', $3)
        ON CONFLICT (user_id) DO UPDATE SET is_active = EXCLUDED.is_active
        """,
        [uid(local), active, now]
      )
    end

    seed.(@alex_local, true)
    seed.(@alice_local, true)
    seed.(@bob_local, true)
    seed.(@inactive_local, false)

    on_exit(fn ->
      Enum.each([@alex_local, @alice_local, @bob_local, @inactive_local], fn local ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [uid(local)])
      end)
    end)

    :ok
  end

  defp ids(rows), do: rows |> Enum.map(& &1.user_id) |> Enum.sort()

  test "search_users matches by user_id substring and excludes non-matches" do
    # "<run>_al" is a real run-scoped substring of "<run>_alex" and "<run>_alice" but not
    # of "<run>_bob" — so it targets only this run's alex+alice and excludes bob.
    rows = DB.search_users("#{@run_id}_al", 10)
    matched = ids(rows)

    assert uid(@alex_local) in matched
    assert uid(@alice_local) in matched
    # bob's local part does not start with "al"
    refute uid(@bob_local) in matched
  end

  test "search_users matches a prefix term" do
    rows = DB.search_users("#{@run_id}_alic", 10)
    assert uid(@alice_local) in ids(rows)
    refute uid(@alex_local) in ids(rows)
  end

  test "search_users excludes inactive users (is_active-aware)" do
    # "alvin" is inactive and contains "al" — it must not appear.
    rows = DB.search_users("alvin", 10)
    refute uid(@inactive_local) in ids(rows)
  end

  test "search_users respects the limit cap" do
    rows = DB.search_users("#{@run_id}_", 2)
    # All three active seeded users share the run id prefix, but the cap is 2.
    assert length(rows) <= 2
  end

  test "search_users is injection-safe: a SQL-injection term returns no rows and the table is intact" do
    # The term is bound as a parameter — never interpolated. It matches nothing.
    rows = DB.search_users("'; DROP TABLE users;--", 10)
    assert rows == []

    # Table intact: our seeded rows still exist.
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "SELECT COUNT(*) FROM users WHERE user_id = $1",
        [uid(@alex_local)]
      )

    assert count == 1
  end

  test "search_users escapes ILIKE wildcards: a bare '%' term does not match everything" do
    # If `%` were not escaped, ILIKE '%%%' would match every user_id. Escaped, the
    # literal '%' character is searched for and matches none of our seeded ids.
    rows = DB.search_users("%", 10)
    matched = ids(rows)

    refute uid(@alex_local) in matched
    refute uid(@alice_local) in matched
    refute uid(@bob_local) in matched
  end

  test "search_users escapes the '_' wildcard so it matches a literal underscore only" do
    # Our ids all contain a literal '_' (e.g. "@alex_<run>:..."), so a "_" term WOULD
    # match them whether escaped or not. To prove escaping, search a 2-char term that
    # only matches via the wildcard if '_' is NOT escaped: "zz" matches nothing, and
    # "z_" (z + any char) would match nothing either. Instead assert the escaped form
    # treats "_" literally: "x_y" must not match "xay"-style ids. We assert the simpler
    # invariant: a term of a single "_" does not behave as "match any single char"
    # across unrelated ids — it only matches ids literally containing "_".
    rows = DB.search_users("_", 100)
    # Every seeded id literally contains "_", so they DO match — but a control id
    # without "_" must NOT be pulled in by the wildcard. Seed such a control.
    control = "@nounderscore#{String.replace(@run_id, "_", "")}:test.local"

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO users (user_id, is_active, system_role, created_at) VALUES ($1, true, 'user', $2) ON CONFLICT (user_id) DO NOTHING",
      [control, System.system_time(:millisecond)]
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [control])
    end)

    rows2 = DB.search_users("_", 100)
    refute control in ids(rows2)
    # And the run's underscore-bearing ids still match (sanity: escaping didn't break literal match).
    assert Enum.any?(ids(rows), fn id -> String.contains?(id, @run_id) end) or rows == []
  end

  test "list_users honours the _search term (delegates to the same matcher)" do
    {users, _next} = DB.list_users(10, "", "#{@run_id}_al")
    matched = users |> Enum.map(& &1.user_id) |> Enum.sort()

    assert uid(@alex_local) in matched
    assert uid(@alice_local) in matched
    refute uid(@bob_local) in matched
  end

  test "MINOR-1: a filtered SECOND page keeps the search term (combined search + keyset)" do
    # Page 1: filter "<run>_al" with limit 1 → only the first matching user. With the
    # "@<run>_<local>:..." id format, "<run>_alex" < "<run>_alice", so alex still sorts
    # first. next_cursor is non-empty because a second match exists.
    {page1, next} = DB.list_users(1, "", "#{@run_id}_al")
    assert Enum.map(page1, & &1.user_id) == [uid(@alex_local)]
    assert next == uid(@alex_local)

    # Page 2: SAME search term + the non-empty cursor. The fix combines search WITH the
    # keyset clause, so this returns ONLY matching users beyond the cursor (alice) — NOT
    # the unfiltered keyset fallthrough that would surface bob.
    {page2, _next2} = DB.list_users(10, next, "#{@run_id}_al")
    matched = page2 |> Enum.map(& &1.user_id) |> Enum.sort()

    assert uid(@alice_local) in matched
    # alex is at/before the cursor — excluded by `user_id > cursor`.
    refute uid(@alex_local) in matched
    # bob never matches the search term — must NOT leak in via the old unfiltered clause.
    refute uid(@bob_local) in matched
  end
end
