defmodule Nebu.Matrix.Room.InviteCapsDbTest do
  @moduledoc """
  Real-database tests for story `rate-limits-join-invite-create-room` (epic oauth-broker, follow-up `ey`), AC4 and the SQL half of D8: the
  count read the pending-invitation caps are decided on, `Nebu.Matrix.Room.InviteDB.pending_invite_counts/3`, and the migration
  `000050_room_invitations_pending_inviter_idx` it needs. NO fakes: a fake that returns ready counts proves nothing about the SQL (a fake
  hid a real defect in two earlier stories), so the pending predicate, the re-arm, the per-pair / per-invitee / per-inviter split, the
  LIMIT bound, the one-statement property, the failing read and the index usage are pinned here against `Nebu.Repo`, with rows written
  through the real writers (`InviteDB.insert_invitation/3`, `accept_invitation/2`, `reject_invitation/2`, `Room.DB.insert_room/1`) and
  random users from the real `TokenValidator` (`room_invitations` has FKs to `rooms` and `users`).

  ## The read under test (D8; the name and shape are pinned by the story)

      InviteDB.pending_invite_counts(inviter_id, invitee_ids, limit)
        -> {:ok, %{inviter: n, invitees: %{invitee_id => %{total: t, from_inviter: p}}}} | {:error, reason}

    * a PENDING invitation is a `room_invitations` row with `accepted_at IS NULL AND rejected_at IS NULL`;
    * `inviter` = the pending rows of `inviter_id` over ALL rooms; `total` = every inviter's pending rows to that invitee;
      `from_inviter` = the pending rows of `inviter_id` to that invitee; an invitee without rows is present with zeros; `[]` invitees
      answers the inviter count only (`invitees: %{}`);
    * every count is BOUNDED by `limit` (= max cap + 1 at the call site): a user with 100 000 rows costs at most `limit` index entries;
    * ONE statement however many invitees (one round trip for a createRoom of 50 invitees);
    * the plan, with sequential scans disabled, uses the new partial index AND `room_invitations_invitee_idx` and has no Seq Scan of
      `room_invitations`. A Seq Scan with the switch off means no index can serve a predicate.

  `@moduletag :integration`, `async: false` (statement counting uses the telemetry event of the repo, filtered to the calling process; the
  failing-read test revokes a privilege for a moment).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Room.InviteDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @server "test.local"
  @idx "room_invitations_pending_inviter_idx"
  @invitee_idx "room_invitations_invitee_idx"

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp counts(inviter, invitees, limit), do: apply(InviteDB, String.to_atom("pending_invite_counts"), [inviter, invitees, limit])

  defp user!, do: T.provision_user!()

  defp room! do
    room = "!ic#{T.rand(6)}:#{@server}"
    assert {:ok, _} = DB.insert_room(room)
    room
  end

  # a PENDING invitation of `invitee` by `inviter` in a fresh room; returns the room
  defp pending!(inviter, invitee) do
    room = room!()
    assert :ok = InviteDB.insert_invitation(room, inviter, invitee)
    room
  end

  defp zero, do: %{total: 0, from_inviter: 0}

  # ─── statement counting / plan capture (telemetry of the repo, only the calling process) ───

  def handle_query(_event, _measurements, %{query: query, params: params}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:statement, query, params})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp capture_statements(fun) do
    id = "invite-caps-db-#{T.rand(6)}"
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

    try do
      result = fun.()
      {result, drain_statements([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:statement, query, params} -> drain_statements([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # the plan nodes (JSON) of a captured statement with sequential scans DISABLED
  defp plan_nodes(sql, params) do
    {:ok, plan} =
      Nebu.Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL enable_seqscan = off", [])
        %{rows: [[json]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "EXPLAIN (FORMAT JSON) " <> sql, params)
        json
      end)

    plan = if is_binary(plan), do: Jason.decode!(plan), else: plan
    collect_nodes(plan)
  end

  defp collect_nodes(list) when is_list(list), do: Enum.flat_map(list, &collect_nodes/1)

  defp collect_nodes(%{} = map) do
    own = if Map.has_key?(map, "Node Type"), do: [map], else: []
    own ++ Enum.flat_map(Map.values(map), &collect_nodes/1)
  end

  defp collect_nodes(_other), do: []

  # ═══ the counted predicate ═══════════════════════════════════════════════════════

  describe "AC4 - only PENDING rows are counted" do
    test "an accepted row and a rejected row of the same pair are not counted; a pending row is; a re-armed row counts ONCE" do
      a = user!()
      b = user!()

      pending = pending!(a, b)
      accepted = pending!(a, b)
      rejected = pending!(a, b)
      rearmed = pending!(a, b)

      assert :ok = InviteDB.accept_invitation(accepted, b)
      assert :ok = InviteDB.reject_invitation(rejected, b)
      # a decline followed by a NEW invitation re-arms the SAME row (one row per (room, invitee)): pending again, counted once
      assert :ok = InviteDB.reject_invitation(rearmed, b)
      assert :ok = InviteDB.insert_invitation(rearmed, a, b)

      assert {:ok, %{inviter: 2, invitees: %{^b => %{total: 2, from_inviter: 2}}}} = counts(a, [b], 100)

      # positive control: the declined / accepted ones were real rows (the SQL filters them, it does not miss them)
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1 AND invitee_id = $2", [a, b]).rows == [[4]]
      assert pending not in [accepted, rejected, rearmed]
    end

    test "the inviter count spans rooms and invitees; another inviter's rows and another invitee's rows are not mixed in" do
      a = user!()
      b = user!()
      c = user!()
      other = user!()

      for invitee <- [b, b, c], do: pending!(a, invitee)
      pending!(other, b)
      pending!(other, c)

      assert {:ok, %{inviter: 3, invitees: invitees}} = counts(a, [b, c], 100)
      assert invitees == %{b => %{total: 3, from_inviter: 2}, c => %{total: 2, from_inviter: 1}}

      assert {:ok, %{inviter: 2}} = counts(other, [b, c], 100)
    end

    test "from_inviter counts only the given inviter's rows to that invitee, total counts EVERY inviter's pending rows to that invitee" do
      a = user!()
      x = user!()
      y = user!()
      b = user!()

      pending!(a, b)
      pending!(x, b)
      pending!(x, b)
      pending!(y, b)

      assert {:ok, %{invitees: %{^b => %{total: 4, from_inviter: 1}}}} = counts(a, [b], 100)
      assert {:ok, %{invitees: %{^b => %{total: 4, from_inviter: 2}}}} = counts(x, [b], 100)
      assert {:ok, %{inviter: 0, invitees: %{^b => %{total: 4, from_inviter: 0}}}} = counts(user!(), [b], 100)
    end

    test "a re-arm by ANOTHER inviter moves the row: the first inviter's count drops, the second one's rises (the row has ONE current inviter)" do
      a = user!()
      c = user!()
      b = user!()

      room = pending!(a, b)
      assert {:ok, %{inviter: 1}} = counts(a, [b], 100)

      assert :ok = InviteDB.insert_invitation(room, c, b)

      assert {:ok, %{inviter: 0, invitees: %{^b => %{total: 1, from_inviter: 0}}}} = counts(a, [b], 100)
      assert {:ok, %{inviter: 1, invitees: %{^b => %{total: 1, from_inviter: 1}}}} = counts(c, [b], 100)
    end

    test "an invitee without any row is present with zeros; unknown ids are fine; an empty list answers the inviter count only" do
      a = user!()
      b = user!()
      nobody = user!()
      ghost = "@ghost#{T.rand(5)}:#{@server}"

      pending!(a, b)

      assert {:ok, %{inviter: 1, invitees: invitees}} = counts(a, [b, nobody, ghost], 100)
      assert invitees == %{b => %{total: 1, from_inviter: 1}, nobody => zero(), ghost => zero()}

      assert {:ok, %{inviter: 1, invitees: empty}} = counts(a, [], 100)
      assert empty == %{}

      assert {:ok, %{inviter: 0, invitees: %{^nobody => %{total: 0, from_inviter: 0}}}} = counts(user!(), [nobody], 100)
    end

    test "duplicates in the invitee list are answered once (a map has one entry per invitee)" do
      a = user!()
      b = user!()
      pending!(a, b)

      assert {:ok, %{invitees: invitees}} = counts(a, [b, b, b], 100)
      assert invitees == %{b => %{total: 1, from_inviter: 1}}
    end
  end

  # ═══ the LIMIT bound ═══════════════════════════════════════════════════════════════

  describe "AC4 - counts stop at the limit" do
    test "with limit + 5 rows every count is the LIMIT; below the limit the count is exact" do
      a = user!()
      b = user!()
      limit = 7

      for _ <- 1..(limit + 5), do: pending!(a, b)

      assert {:ok, %{inviter: ^limit, invitees: %{^b => %{total: ^limit, from_inviter: ^limit}}}} = counts(a, [b], limit)
      assert {:ok, %{inviter: 12, invitees: %{^b => %{total: 12, from_inviter: 12}}}} = counts(a, [b], 100)
      assert {:ok, %{inviter: 12}} = counts(a, [b], 13), "limit above the count: exact"
      assert {:ok, %{inviter: 12}} = counts(a, [b], 12), "limit equal to the count: exact"
    end

    test "the three counts are bounded independently (total of the invitee, pair of the inviter, rows of the inviter in other rooms)" do
      a = user!()
      b = user!()
      c = user!()
      x = user!()
      limit = 4

      # a -> b: 2 rows (pair 2); x -> b: 6 rows (b's total 8 > limit); a -> c: 5 rows (a's total 7 > limit)
      for _ <- 1..2, do: pending!(a, b)
      for _ <- 1..6, do: pending!(x, b)
      for _ <- 1..5, do: pending!(a, c)

      assert {:ok, %{inviter: ^limit, invitees: invitees}} = counts(a, [b, c], limit)
      assert invitees == %{b => %{total: limit, from_inviter: 2}, c => %{total: limit, from_inviter: limit}}
    end
  end

  # ═══ ONE statement ═════════════════════════════════════════════════════════════════

  describe "AC4 - ONE statement" do
    test "50 invitees (and 1, and none) are answered by exactly ONE statement through Nebu.Repo" do
      a = user!()
      invitees = for _ <- 1..50, do: user!()
      pending!(a, hd(invitees))

      {result, statements} = capture_statements(fn -> counts(a, invitees, 101) end)

      assert {:ok, %{inviter: 1, invitees: map}} = result
      assert map_size(map) == 50
      assert length(statements) == 1, "ONE statement for the whole call, got #{length(statements)}"

      {_, one} = capture_statements(fn -> assert {:ok, _} = counts(a, [hd(invitees)], 101) end)
      assert length(one) == 1

      {_, none} = capture_statements(fn -> assert {:ok, _} = counts(a, [], 101) end)
      assert length(none) <= 1, "an empty list needs at most the inviter count"
    end
  end

  # ═══ the index (migration 000050) ═════════════════════════════════════════════════

  describe "AC4 - migration 000050 and the plan" do
    test "the migration created #{@idx}: a partial index on (inviter_id, invitee_id) WHERE accepted_at IS NULL AND rejected_at IS NULL" do
      assert %{rows: [[def_]]} =
               T.sql!("SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'room_invitations' AND indexname = $1", [@idx])

      normalised = def_ |> String.replace(~r/[\s()]+/, " ") |> String.downcase()
      assert normalised =~ "using btree inviter_id, invitee_id"
      assert normalised =~ "where accepted_at is null and rejected_at is null"
    end

    test "with sequential scans disabled the plan uses the partial index and has no Seq Scan of room_invitations (small tables: the other index is not pinned)" do
      a = user!()
      b = user!()
      c = user!()
      pending!(a, b)
      pending!(c, b)

      {result, statements} = capture_statements(fn -> counts(a, [b, c], 101) end)
      assert {:ok, %{inviter: 1}} = result
      assert [{sql, params}] = statements

      nodes = plan_nodes(sql, params)
      index_names = for node <- nodes, name = node["Index Name"], uniq: true, do: name

      assert @idx in index_names, "the inviter / pair counts are served by #{@idx}, plan uses #{inspect(index_names)}"

      seq = Enum.filter(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "room_invitations"))
      assert seq == [], "a Seq Scan of room_invitations even with enable_seqscan off: no index can serve the predicate\n#{sql}"
    end

    test "on a seeded 20 000-row table (analysed, rolled back) the plan has no Seq Scan and uses both indexes, with the planner's own choice and with seqscan off" do
      a = user!()
      b = user!()
      pending!(a, b)
      {_, [{sql, _params}]} = capture_statements(fn -> assert {:ok, _} = counts(a, [b], 101) end)

      marker = "xp" <> T.rand(4)
      user_of = fn n -> "@#{marker}u#{n}:#{@server}" end
      invitees = for n <- 1..20, do: user_of.(1000 + n)

      for {label, enable_seqscan} <- [{"the planner's own choice", "on"}, {"enable_seqscan = off", "off"}] do
        # selective fixture: 1 000 inviters x 20 rows, 2 000 invitees x 10 rows (a planner may legitimately stop a ~400-row inviter early with a
        # Seq Scan under LIMIT 101; with 20 rows per inviter an index is the only sensible plan)
        # the fixture lives in ONE privileged transaction that is rolled back (no row survives, nothing leaks into another test)
        result =
          T.with_privileged_conn(fn conn ->
            Postgrex.transaction(conn, fn tx ->
              Postgrex.query!(tx, "INSERT INTO users (user_id, created_at) SELECT '@#{marker}u' || g || ':#{@server}', 0 FROM generate_series(1, 2100) g", [])
              Postgrex.query!(tx, "INSERT INTO rooms (room_id, created_at) SELECT '!#{marker}r' || g || ':#{@server}', 0 FROM generate_series(1, 20000) g", [])

              Postgrex.query!(
                tx,
                "INSERT INTO room_invitations (room_id, inviter_id, invitee_id, invited_at) " <>
                  "SELECT '!#{marker}r' || g || ':#{@server}', '@#{marker}u' || (g % 1000 + 1) || ':#{@server}', '@#{marker}u' || (g % 2000 + 1) || ':#{@server}', 0 FROM generate_series(1, 20000) g",
                []
              )

              Postgrex.query!(tx, "ANALYZE room_invitations", [])
              Postgrex.query!(tx, "SET LOCAL enable_seqscan = #{enable_seqscan}", [])

              %{rows: [[json]]} = Postgrex.query!(tx, "EXPLAIN (FORMAT JSON) " <> sql, ["@#{marker}u7:#{@server}", Enum.map(invitees, & &1), 101])
              Postgrex.rollback(tx, {:plan, json})
            end)
          end)

        assert {:error, {:plan, json}} = result
        nodes = collect_nodes(if is_binary(json), do: Jason.decode!(json), else: json)
        index_names = for node <- nodes, name = node["Index Name"], uniq: true, do: name

        assert @idx in index_names, "#{label}: the inviter / pair counts use #{@idx}, plan uses #{inspect(index_names)}"
        assert @invitee_idx in index_names, "#{label}: the invitee total uses #{@invitee_idx}, plan uses #{inspect(index_names)}"

        seq = Enum.filter(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "room_invitations"))
        assert seq == [], "#{label}: a Seq Scan of room_invitations on a 20 000-row table\n#{sql}"
      end

      assert T.sql!("SELECT count(*) FROM rooms WHERE room_id LIKE $1", ["!" <> marker <> "%"]).rows == [[0]], "the fixture was rolled back"
    end
  end

  # ═══ a DB error ═══════════════════════════════════════════════════════════════════

  describe "AC4 - a failing read" do
    test "a database error answers {:error, _}: with the search_path emptied (transaction-local, no privilege change, nothing to restore) the unqualified table is not found" do
      a = user!()
      b = user!()
      pending!(a, b)

      # `SET LOCAL` ends with the transaction (a rollback here): there is no state a killed test could leave behind in the database
      # (an earlier variant revoked SELECT from nebu_app: a hard kill between REVOKE and GRANT would have left a long-lived DB broken)
      assert {:error, {:counts, result}} =
               Nebu.Repo.transaction(fn ->
                 Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL search_path TO pg_catalog", [])
                 Nebu.Repo.rollback({:counts, counts(a, [b], 101)})
               end)

      assert {:error, _reason} = result

      # positive control: outside the transaction the same call answers
      assert {:ok, %{inviter: 1}} = counts(a, [b], 101)
    end
  end
end
