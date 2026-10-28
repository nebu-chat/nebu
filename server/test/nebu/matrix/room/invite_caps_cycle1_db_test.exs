defmodule Nebu.Matrix.Room.InviteCapsCycle1DbTest do
  @moduledoc """
  Real-database tests for story `rate-limits-join-invite-create-room`, review cycle 1 (Kassandra M-1): the victim cannot be locked out
  of invitations by one attacker, and the caps are HARD under concurrency. NO fakes: both rules are SQL / locking behaviour.

    * (M-1a) the per-invitee TOTAL of `InviteDB.pending_invite_counts/3` does not count the rows of a DEACTIVATED inviter (they count
      again when the account is reactivated) nor the rows of an inviter on the invitee's `m.ignored_user_list`; the PAIR count and the
      inviter count stay raw (they bound what ONE attacker writes). A malformed or non-object list ignores nobody and never fails
      the read.
    * (M-1b) there is exactly one deactivation path (`Admin.DB.set_is_active/2` behind `deactivate_user`); instead of rejecting the
      invitation rows (which would show the invitees a `rooms.leave` and could not be undone by a reactivation) the exclusion above
      frees the slots of a deactivated account.
    * (M-1c) `InviteDB.insert_invitation_capped/4` counts and inserts under the transaction advisory locks of the inviter and the
      invitee: N concurrent invitations can never exceed a cap (per invitee, per pair, per inviter), the refusal writes nothing, a
      re-arm of a decided row counts as new.
    * `InviteDB.first_cap_violation/3` (pure): inviter first, then the invitees in list order, the pair before the invitee total.

  `@moduletag :integration`, `async: false`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Room.InviteDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @server "test.local"
  @wide %{per_inviter: 1_000, per_invitee: 1_000, per_pair: 1_000}

  defp user!, do: T.provision_user!()

  defp room! do
    room = "!ic1#{T.rand(6)}:#{@server}"
    assert {:ok, _} = DB.insert_room(room)
    room
  end

  defp pending!(inviter, invitee) do
    room = room!()
    assert :ok = InviteDB.insert_invitation(room, inviter, invitee)
    room
  end

  defp counts(inviter, invitees), do: InviteDB.pending_invite_counts(inviter, invitees, 100)
  defp total(inviter, invitee), do: counts(inviter, [invitee]) |> elem(1) |> get_in([:invitees, invitee, :total])

  defp set_active(uid, active), do: T.sql!("UPDATE users SET is_active = $1 WHERE user_id = $2", [active, uid])

  defp ignore!(uid, ignored_uids),
    do: Nebu.Matrix.AccountDataStore.put(uid, "m.ignored_user_list", Jason.encode!(%{"ignored_users" => Map.new(ignored_uids, &{&1, %{}})}))

  defp pending_rows(where_sql, params), do: T.sql!("SELECT count(*) FROM room_invitations WHERE accepted_at IS NULL AND rejected_at IS NULL AND " <> where_sql, params).rows |> hd() |> hd()

  # ═══ (M-1a) the invitee total ═══════════════════════════════════════════════════

  describe "M-1a - the invitee total does not count deactivated inviters" do
    test "a deactivated inviter's rows leave the TOTAL, a reactivation brings them back; the pair count and the inviter count stay raw" do
      victim = user!()
      attacker = user!()
      friend = user!()

      for _ <- 1..4, do: pending!(attacker, victim)
      pending!(friend, victim)

      assert {:ok, %{inviter: 4, invitees: %{^victim => %{total: 5, from_inviter: 4}}}} = counts(attacker, [victim])

      set_active(attacker, false)
      assert {:ok, %{inviter: 4, invitees: %{^victim => %{total: 1, from_inviter: 4}}}} = counts(attacker, [victim])
      assert total(friend, victim) == 1, "seen from another inviter: only the friend's row is left"

      set_active(attacker, true)
      assert total(friend, victim) == 5
    end

    test "the deactivated inviter's rows are still PENDING rows (nothing is rejected: the invitees keep their invitations)" do
      victim = user!()
      attacker = user!()
      room = pending!(attacker, victim)

      set_active(attacker, false)
      assert pending_rows("room_id = $1 AND invitee_id = $2", [room, victim]) == 1
      assert {:ok, true} = InviteDB.pending_invite?(room, victim)
    end
  end

  describe "M-1a - the invitee total does not count inviters on the invitee's m.ignored_user_list" do
    test "an ignored inviter's rows leave the TOTAL (not the pair count), other inviters count, un-ignoring brings them back" do
      victim = user!()
      pest = user!()
      friend = user!()

      for _ <- 1..3, do: pending!(pest, victim)
      for _ <- 1..2, do: pending!(friend, victim)
      assert total(friend, victim) == 5

      ignore!(victim, [pest])
      assert {:ok, %{inviter: 3, invitees: %{^victim => %{total: 2, from_inviter: 3}}}} = counts(pest, [victim]), "the pest's own pair count is raw"
      assert total(friend, victim) == 2

      ignore!(victim, [])
      assert total(friend, victim) == 5
    end

    test "only the VICTIM's list counts: another user's ignore list changes nothing, and a list entry for someone else does not hide the pest" do
      victim = user!()
      bystander = user!()
      pest = user!()
      other = user!()
      pending!(pest, victim)
      pending!(pest, bystander)

      ignore!(bystander, [pest])
      ignore!(victim, [other])

      assert {:ok, %{invitees: invitees}} = counts(pest, [victim, bystander])
      assert invitees[victim].total == 1, "victim ignores someone else"
      assert invitees[bystander].total == 0, "the bystander ignores the pest"
    end

    test "a malformed, non-object or array-shaped list ignores nobody and the read does not fail" do
      victim = user!()
      pest = user!()
      pending!(pest, victim)

      for stored <- ["not json at all", "[]", "\"a string\"", "null", "{}", ~s({"ignored_users": null}), ~s({"ignored_users": "#{pest}"}), ~s({"ignored_users": ["#{pest}"]}), ~s({"other": {"#{pest}": {}}})] do
        Nebu.Matrix.AccountDataStore.put(victim, "m.ignored_user_list", stored)
        assert {:ok, %{invitees: %{^victim => %{total: 1}}}} = counts(pest, [victim]), "stored #{inspect(stored)} ignores nobody"
      end

      # positive control: the well-formed list DOES ignore
      ignore!(victim, [pest])
      assert total(pest, victim) == 0
    end

    test "ONE statement still answers 50 invitees, the ignore lookup included" do
      a = user!()
      invitees = for _ <- 1..50, do: user!()
      ignore!(hd(invitees), [a])
      pending!(a, hd(invitees))

      id = "ic1-" <> T.rand(6)
      :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

      result =
        try do
          counts(a, invitees)
        after
          :telemetry.detach(id)
        end

      assert {:ok, %{invitees: map}} = result
      assert map_size(map) == 50 and map[hd(invitees)].total == 0 and map[hd(invitees)].from_inviter == 1

      statements = Stream.repeatedly(fn -> receive do {:statement, q} -> q after 0 -> nil end end) |> Enum.take_while(& &1)
      assert length(statements) == 1
    end
  end

  def handle_query(_event, _measurements, %{query: query}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:statement, query})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  # ═══ the pure decision ═════════════════════════════════════════════════════════

  describe "first_cap_violation/3 (pure)" do
    @caps %{per_inviter: 5, per_invitee: 3, per_pair: 2}

    defp c(inviter, invitees), do: %{inviter: inviter, invitees: Map.new(invitees)}

    test "nil below every cap; inviter + k > per_inviter is :inviter (k = the number of invitees); the boundary passes" do
      assert InviteDB.first_cap_violation(c(3, [{"@b", %{total: 0, from_inviter: 0}}, {"@c", %{total: 0, from_inviter: 0}}]), ["@b", "@c"], @caps) == nil
      assert InviteDB.first_cap_violation(c(4, [{"@b", %{total: 0, from_inviter: 0}}, {"@c", %{total: 0, from_inviter: 0}}]), ["@b", "@c"], @caps) == :inviter
      assert InviteDB.first_cap_violation(c(4, []), ["@b"], @caps) == nil
      assert InviteDB.first_cap_violation(c(5, []), ["@b"], @caps) == :inviter
    end

    test "per invitee in list order, the pair before the invitee total, an absent invitee counts as zero" do
      counts = c(0, [{"@b", %{total: 3, from_inviter: 0}}, {"@c", %{total: 2, from_inviter: 2}}, {"@d", %{total: 3, from_inviter: 2}}])

      assert InviteDB.first_cap_violation(counts, ["@b", "@c"], @caps) == :invitee
      assert InviteDB.first_cap_violation(counts, ["@c", "@b"], @caps) == :pair
      assert InviteDB.first_cap_violation(counts, ["@d"], @caps) == :pair, "both broken: the pair text wins"
      assert InviteDB.first_cap_violation(counts, ["@nobody"], @caps) == nil
      assert InviteDB.first_cap_violation(c(5, []), ["@b", "@c"], @caps) == :inviter, "the inviter cap beats every invitee"
    end

    test "count_bound/1 is the largest cap + 1 and never above the largest bigint" do
      assert InviteDB.count_bound(@caps) == 6
      assert InviteDB.count_bound(%{per_inviter: 9_223_372_036_854_775_807, per_invitee: 1, per_pair: 1}) == 9_223_372_036_854_775_807
    end
  end

  # ═══ (M-1c) the hard caps ═══════════════════════════════════════════════════════

  describe "M-1c - insert_invitation_capped/4: decisions" do
    test "below the caps it writes the row; at a cap it answers {:error, {:cap, which}} and writes NOTHING" do
      a = user!()
      b = user!()
      room = room!()

      assert :ok = InviteDB.insert_invitation_capped(room, a, b, %{@wide | per_pair: 1})
      assert {:ok, true} = InviteDB.pending_invite?(room, b)

      room2 = room!()
      assert {:error, {:cap, :pair}} = InviteDB.insert_invitation_capped(room2, a, b, %{@wide | per_pair: 1})
      assert {:ok, false} = InviteDB.pending_invite?(room2, b)

      assert {:error, {:cap, :invitee}} = InviteDB.insert_invitation_capped(room2, user!(), b, %{@wide | per_invitee: 1})
      assert {:error, {:cap, :inviter}} = InviteDB.insert_invitation_capped(room2, a, user!(), %{@wide | per_inviter: 1})
      assert {:ok, false} = InviteDB.pending_invite?(room2, b)
      assert pending_rows("room_id = $1", [room2]) == 0
    end

    test "a re-arm of a DECLINED row adds a pending row and is counted; a row that is already pending is not a new row" do
      a = user!()
      b = user!()
      room = pending!(a, b)
      assert :ok = InviteDB.reject_invitation(room, b)

      caps = %{@wide | per_pair: 1}
      assert :ok = InviteDB.insert_invitation_capped(room, a, b, caps), "the declined row is not counted: the re-arm is the first pending row"
      assert {:error, {:cap, :pair}} = InviteDB.insert_invitation_capped(room!(), a, b, caps), "now the pair is at its cap"
    end

    test "a failing read is {:error, reason} and rolls the lock transaction back (no row)" do
      a = user!()
      b = user!()
      room = room!()

      assert {:error, {:result, result}} =
               Nebu.Repo.transaction(fn ->
                 Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL search_path TO pg_catalog", [])
                 Nebu.Repo.rollback({:result, InviteDB.insert_invitation_capped(room, a, b, @wide)})
               end)

      assert {:error, _} = result
      assert {:ok, false} = InviteDB.pending_invite?(room, b)
    end
  end

  describe "M-1c - insert_invitation_capped/4: N concurrent invitations never exceed a cap" do
    # `n` attempts, 8 at a time: the pool has 10 connections and every waiter of an advisory lock holds one, so more simultaneous
    # attempts would be dropped from the pool queue under load (DBConnection `queue_timeout`), which is a test artefact, not a cap fault
    defp race(n, fun), do: 1..n |> Task.async_stream(fun, max_concurrency: 8, ordered: false, timeout: 60_000) |> Enum.map(fn {:ok, r} -> r end)
    defp oks(results), do: Enum.count(results, &(&1 == :ok))
    defp cap_refusals(results, which), do: Enum.count(results, &(&1 == {:error, {:cap, which}}))

    test "per INVITEE: 24 inviters (8 at a time), cap 5 -> exactly 5 rows, 19 refusals (several rounds, a fresh victim each)" do
      for _round <- 1..4 do
        victim = user!()
        inviters = for _ <- 1..24, do: {user!(), room!()}
        caps = %{@wide | per_invitee: 5}

        results = race(24, fn i -> {inviter, room} = Enum.at(inviters, i - 1); InviteDB.insert_invitation_capped(room, inviter, victim, caps) end)

        assert oks(results) == 5 and cap_refusals(results, :invitee) == 19, inspect(results)
        assert pending_rows("invitee_id = $1", [victim]) == 5
      end
    end

    test "per PAIR: one inviter, 24 rooms (8 at a time) into one victim, cap 3 -> exactly 3 rows" do
      for _round <- 1..4 do
        inviter = user!()
        victim = user!()
        rooms = for _ <- 1..24, do: room!()
        caps = %{@wide | per_pair: 3}

        results = race(24, fn i -> InviteDB.insert_invitation_capped(Enum.at(rooms, i - 1), inviter, victim, caps) end)

        assert oks(results) == 3 and cap_refusals(results, :pair) == 21, inspect(results)
        assert pending_rows("inviter_id = $1 AND invitee_id = $2", [inviter, victim]) == 3
      end
    end

    test "per INVITER: one inviter, 24 invitations (8 at a time) to 24 users, cap 4 -> exactly 4 rows" do
      for _round <- 1..4 do
        inviter = user!()
        invitees = for _ <- 1..24, do: {user!(), room!()}
        caps = %{@wide | per_inviter: 4}

        results = race(24, fn i -> {invitee, room} = Enum.at(invitees, i - 1); InviteDB.insert_invitation_capped(room, inviter, invitee, caps) end)

        assert oks(results) == 4 and cap_refusals(results, :inviter) == 20, inspect(results)
        assert pending_rows("inviter_id = $1", [inviter]) == 4
      end
    end

    test "crossing locks do not deadlock: users invite each other concurrently (inviter and invitee roles swapped)" do
      users = for _ <- 1..8, do: user!()
      pairs = for a <- users, b <- users, a != b, do: {a, b, room!()}

      results = race(length(pairs), fn i -> {a, b, room} = Enum.at(pairs, i - 1); InviteDB.insert_invitation_capped(room, a, b, @wide) end)

      assert oks(results) == length(pairs), inspect(Enum.uniq(results))
    end
  end

  # ═══ (delta gate L-2) a bounded lock wait ═══════════════════════════════════════

  describe "L-2 - bounded lock wait (lock_timeout 2 s)" do
    # holds the invitee advisory lock of `invitee` in another process until it is told to stop (the key format is the one of
    # `insert_invitation_capped/4`: a drift would make the capped insert NOT wait, and the assertions below would fail)
    defp hold_invitee_lock(invitee) do
      parent = self()

      pid =
        spawn_link(fn ->
          Nebu.Repo.transaction(fn ->
            %{rows: [[key]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT hashtextextended($1, 0)", ["nebu:invite:invitee:" <> invitee])
            Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT pg_advisory_xact_lock($1)", [key])
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      pid
    end

    test "a held invitee lock: the capped insert gives up after about 2 s with :lock_timeout, writes nothing, works afterwards" do
      a = user!()
      b = user!()
      room = room!()
      holder = hold_invitee_lock(b)

      started = System.monotonic_time(:millisecond)
      assert {:error, :lock_timeout} = InviteDB.insert_invitation_capped(room, a, b, @wide)
      waited = System.monotonic_time(:millisecond) - started

      assert waited >= 1_500 and waited < 10_000, "waited #{waited} ms (lock_timeout 2 s)"
      assert {:ok, false} = InviteDB.pending_invite?(room, b)

      send(holder, :release)
      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 5_000

      assert :ok = InviteDB.insert_invitation_capped(room, a, b, @wide), "positive control: with the lock free the same call writes the row"
    end

    test "a lock on ANOTHER invitee does not delay the call" do
      a = user!()
      b = user!()
      c = user!()
      holder = hold_invitee_lock(c)

      started = System.monotonic_time(:millisecond)
      assert :ok = InviteDB.insert_invitation_capped(room!(), a, b, @wide)
      assert System.monotonic_time(:millisecond) - started < 1_500

      send(holder, :release)
    end
  end
end
