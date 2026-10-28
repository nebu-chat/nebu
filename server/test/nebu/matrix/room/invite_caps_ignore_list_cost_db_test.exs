defmodule Nebu.Matrix.Room.InviteCapsIgnoreListCostDbTest do
  @moduledoc """
  Real-database regression tests for the delta gate of review cycle 1 of story `rate-limits-join-invite-create-room` (Kassandra H-1,
  HIGH): the per-invitee total of `InviteDB.pending_invite_counts/3` excludes the rows of inviters on the invitee's
  `m.ignored_user_list`. The list is global account data the invitee can make up to 1 000 000 bytes large. The first cut parsed and
  cast it (`content_json::jsonb`, plus `pg_input_is_valid`) TWICE PER PENDING ROW inside the counted subquery, memory was not freed
  between rows, and rows the exclusion removes do not count towards `LIMIT`: a 664 KB list x 100 rows took 1.9 s for ONE count, a
  964 KB list x 60 rows got the PostgreSQL backend OOM-killed (crash recovery of the whole database). Two accounts were enough (A stores
  the list, B gives A pending rows, any `POST /invite` of A runs the count; the same count runs again under the advisory lock).

  The fix parses the list ONCE PER INVITEE (a lateral join on the unnest), never per row. Pinned here for BOTH callers of the statement:
  the pre-check read (`pending_invite_counts/3`) and the capped insert (`insert_invitation_capped/4`, which counts under the lock), with
  a generous time bound (a regression to per-row parsing needs seconds and gigabytes on these sizes; the sizes are chosen so that the
  CORRECT statement uses a few megabytes).

  Fixtures are written in bulk with `generate_series` (random marker, no cleanup needed). `@moduletag :integration`, `async: false`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.InviteDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @server "test.local"
  @wide %{per_inviter: 100_000, per_invitee: 100_000, per_pair: 100_000}
  # ~ 920 KB of JSON: 20 000 filler keys of ~45 bytes plus the ignored inviters
  @filler_keys 20_000
  @rows 200
  @bound_ms 1_000

  # `@rows` pending rows to `victim`, the first half from inviters in `ignored_ids`, the other half from inviters that are not
  defp fixture!(victim) do
    marker = "ilc" <> T.rand(5)
    user = fn n -> "@#{marker}u#{n}:#{@server}" end

    T.sql!("INSERT INTO users (user_id, created_at) SELECT '@#{marker}u' || g || ':#{@server}', 0 FROM generate_series(1, $1::int) g", [@rows])
    T.sql!("INSERT INTO rooms (room_id, created_at) SELECT '!#{marker}r' || g || ':#{@server}', 0 FROM generate_series(1, $1::int) g", [@rows])

    T.sql!(
      "INSERT INTO room_invitations (room_id, inviter_id, invitee_id, invited_at) " <>
        "SELECT '!#{marker}r' || g || ':#{@server}', '@#{marker}u' || g || ':#{@server}', $2, 0 FROM generate_series(1, $1::int) g",
      [@rows, victim]
    )

    ignored = for n <- 1..div(@rows, 2), do: user.(n)
    {marker, ignored, for(n <- (div(@rows, 2) + 1)..@rows, do: user.(n))}
  end

  defp big_ignore_list(ignored_ids, marker) do
    filler = for n <- 1..@filler_keys, into: %{}, do: {"@filler#{marker}#{String.pad_leading(Integer.to_string(n), 12, "0")}:#{@server}", %{}}
    Jason.encode!(%{"ignored_users" => Map.merge(filler, Map.new(ignored_ids, &{&1, %{}}))})
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  describe "a ~1 MB m.ignored_user_list with 200 pending rows (half of them ignored)" do
    test "the pre-check count answers in under a second and counts exactly the rows of the inviters that are not ignored" do
      victim = T.provision_user!()
      {marker, ignored, others} = fixture!(victim)
      body = big_ignore_list(ignored, marker)
      assert byte_size(body) > 800_000
      Nebu.Matrix.AccountDataStore.put(victim, "m.ignored_user_list", body)

      {ms, result} = timed(fn -> InviteDB.pending_invite_counts(hd(others), [victim], 101) end)

      assert {:ok, %{invitees: %{^victim => %{total: 100, from_inviter: 1}}}} = result, "the 100 rows of the ignored half are not counted (the limit 101 is not reached)"
      assert ms < @bound_ms, "the count took #{ms} ms: the ignore list must be parsed once per invitee, not once per pending row"
    end

    test "a count over SEVERAL invitees with a big list each (one parse per invitee) is fast as well" do
      victims = for _ <- 1..3, do: T.provision_user!()

      fixtures =
        for victim <- victims do
          {marker, ignored, others} = fixture!(victim)
          Nebu.Matrix.AccountDataStore.put(victim, "m.ignored_user_list", big_ignore_list(ignored, marker))
          hd(others)
        end

      {ms, result} = timed(fn -> InviteDB.pending_invite_counts(hd(fixtures), victims, 101) end)

      assert {:ok, %{invitees: invitees}} = result
      assert Enum.all?(victims, &(invitees[&1].total == 100))
      assert ms < @bound_ms * 2, "3 invitees x ~1 MB x 200 rows took #{ms} ms"
    end

    test "the capped insert (which counts again under the advisory locks) is fast too, and still refuses at the cap" do
      victim = T.provision_user!()
      {marker, ignored, _others} = fixture!(victim)
      Nebu.Matrix.AccountDataStore.put(victim, "m.ignored_user_list", big_ignore_list(ignored, marker))

      inviter = T.provision_user!()
      room = "!ilcnew#{T.rand(5)}:#{@server}"
      assert {:ok, _} = Nebu.Matrix.Room.DB.insert_room(room)

      # 100 counted rows: a cap of 101 passes, a cap of 100 refuses (the 100 ignored rows are not what decides)
      {ms, result} = timed(fn -> InviteDB.insert_invitation_capped(room, inviter, victim, %{@wide | per_invitee: 101}) end)
      assert result == :ok
      assert ms < @bound_ms, "the capped insert took #{ms} ms"

      room2 = "!ilcnew#{T.rand(5)}:#{@server}"
      assert {:ok, _} = Nebu.Matrix.Room.DB.insert_room(room2)
      {ms2, result2} = timed(fn -> InviteDB.insert_invitation_capped(room2, T.provision_user!(), victim, %{@wide | per_invitee: 101}) end)
      assert result2 == {:error, {:cap, :invitee}}, "101 counted rows now"
      assert ms2 < @bound_ms
    end
  end

  describe "an ignore list that is not usable ignores nobody and costs nothing" do
    for {label, body} <- [
          {"a 1 MB blob that is not JSON", {:blob, 1_000_000}},
          {"a 1 MB JSON array (not an object)", {:array, 40_000}},
          {"a 1 MB object whose ignored_users is a string", {:string, 1_000_000}},
          {"a 1 MB object whose ignored_users is an array", {:ignored_array, 20_000}}
        ] do
      test "#{label}: all 200 rows count, in under a second" do
        victim = T.provision_user!()
        {_marker, ignored, others} = fixture!(victim)

        stored =
          case unquote(Macro.escape(body)) do
            {:blob, n} -> String.duplicate("x", n)
            {:array, n} -> Jason.encode!(for(i <- 1..n, do: "@filler#{i}:test.local"))
            {:string, n} -> Jason.encode!(%{"ignored_users" => String.duplicate("y", n)})
            # an ARRAY of ids that contains the ignored inviters: the sync reads the KEYS of an object only, so nobody is ignored
            {:ignored_array, n} -> Jason.encode!(%{"ignored_users" => ignored ++ for(i <- 1..n, do: "@filler#{i}:test.local")})
          end

        Nebu.Matrix.AccountDataStore.put(victim, "m.ignored_user_list", stored)

        {ms, result} = timed(fn -> InviteDB.pending_invite_counts(hd(others), [victim], 1_000) end)

        assert {:ok, %{invitees: %{^victim => %{total: @rows}}}} = result
        assert ms < @bound_ms, "#{ms} ms"
      end
    end
  end
end
