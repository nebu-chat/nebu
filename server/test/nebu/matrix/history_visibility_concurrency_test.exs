defmodule Nebu.Matrix.HistoryVisibilityConcurrencyTest do
  @moduledoc """
  Story `history-visibility-enforcement`, AC17: A's history-visibility change `shared -> joined` races the join of a later joiner H, A's messages and H's 10 concurrent `/messages`
  calls, for 30 rounds (`Task.async` behind a barrier, `ModerationTestSupport.race/1`), real stack (`Nebu.Web.Router`, the real `Nebu.Repo`, `Room.Server` under Horde). `async: false`, tag
  `:concurrency`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The story's wording ("each message written BEFORE the change's reply is visible to H, each message written after the change's reply and before H's join is invisible") cannot be
      checked literally in a race: H has to be a MEMBER to read, and a message stamped in the millisecond of the change or of H's join is judged most restrictively (D2 (c)). The test
      therefore checks the invariant that holds for EVERY interleaving, against the STORED rows: after the round the rule is re-computed from the stored hv / member events and message
      timestamps (`HistoryVisibilityTestSupport.model_visible?/2`, an independent re-implementation); then
      - SAFETY: every `/messages` answer is a `200` and never contains a message the model hides (no leak, in any interleaving);
      - LIVENESS: every message whose send reply arrived BEFORE the request started and that the model shows IS in the answer (a concurrent write never hides what is visible).
    * The literal story sentence is checked in the sequential control round (clock-separated writes), which also guards against vacuity (the rule is in force, the race is not a no-op).
    * H's join races the change and the posts; whether H joined before or after the change differs per round and is not required to be a mix (the counts are printed).
    * A failure prints the sequence of the round (`{kind, timestamp}` pairs sorted by time: no content, no ids).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.HistoryVisibilityTestSupport
  import Nebu.Matrix.MembershipStateTestSupport, only: [setup_env!: 0]

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag :concurrency
  @moduletag timeout: 600_000

  @rounds 30
  @readers 10

  setup do
    setup_env!()
    :ok
  end

  defp mono, do: System.monotonic_time(:microsecond)

  test "control (no race): the story's sentence holds with clock-separated writes: messages before the change are visible to the later joiner, after it and before his join are not" do
    a = user!("HCA")
    h = user!("HCH")
    room = public_room(a)
    pre = for i <- 1..3, do: say_m!(a, room, "pre#{i}x")
    set_hv!(a, room, "joined")
    post = for i <- 1..3, do: say_m!(a, room, "post#{i}x")
    join_ev!(h, room)
    after_join = say_m!(a, room, "afterx")

    {chunk, _body, raw} = msgs!(h, room)
    assert_shown!(chunk, raw, pre ++ [after_join])
    for p <- post, do: refute_leak!(raw, p)
  end

  test "30 rounds: the change shared -> joined races H's join, A's three posts and 10 concurrent /messages of H: every answer 200, no leak, no spuriously hidden message" do
    a = user!("HCA")
    h = user!("HCH")
    summary = for round <- 1..@rounds, do: one_round(a, h, round)

    joined_before = Enum.count(summary, & &1.joined_before_change)
    IO.puts("history_visibility_concurrency: #{@rounds} rounds, H joined before the change in #{joined_before}, after it in #{@rounds - joined_before}; #{Enum.sum(Enum.map(summary, & &1.reads))} reads")
    assert Enum.all?(summary, &(&1.reads == @readers))
    if joined_before == 0 or joined_before == @rounds, do: IO.puts("WARNING history_visibility_concurrency: the race was one-sided (joined before the change in #{joined_before} of #{@rounds} rounds)")
  end

  defp one_round(a, h, round) do
    room = public_room(a)
    pre = for i <- 1..3, do: %{id: say!(a, room, word("pre#{i}")), sent: mono()}
    tick()

    parent = self()

    # the jitter (a busy loop, no sleep) moves the change relative to H's join: some rounds H joins first, some rounds after the change
    jitter = Enum.at([0, 20_000, 80_000, 200_000, 500_000, 1_200_000], rem(round, 6))

    change_and_posts = fn ->
      busy(jitter)
      conn = put_hv(a, room, "joined")
      send(parent, {:change_reply, conn.status, mono()})
      for i <- 1..3, do: %{id: say!(a, room, word("post#{i}")), sent: mono()}
    end

    join_and_read = fn ->
      join_conn = join(h, room)
      joined_at = mono()

      reads =
        for _ <- 1..@readers do
          Task.async(fn ->
            started = mono()
            {started, messages_req(h, room, "dir=b&limit=100")}
          end)
        end
        |> Enum.map(&Task.await(&1, 30_000))

      {join_conn.status, joined_at, reads}
    end

    [posts, {join_status, _joined_at, reads}] = race([change_and_posts, join_and_read])

    change_status =
      receive do
        {:change_reply, status, _at} -> status
      after
        0 -> :missing
      end

    sequence = round_sequence(room, h)
    context = "round #{round}: #{inspect(sequence)}"

    assert change_status == 200, "#{context}: the change answered #{inspect(change_status)}"
    assert join_status == 200, "#{context}: the join answered #{inspect(join_status)}"

    rows = model_rows(room, h)
    sent = pre ++ posts
    ts_by_id = Map.new(sent, fn m -> {m.id, ts_of(m.id)} end)
    expected = for {id, ts} <- ts_by_id, model_visible?(rows, ts), into: MapSet.new(), do: id

    for {started, conn} <- reads do
      assert conn.status == 200, "#{context}: a read answered #{conn.status}"
      got = conn |> T.json() |> Map.fetch!("chunk") |> ids() |> MapSet.new()
      got_msgs = MapSet.intersection(got, MapSet.new(Map.keys(ts_by_id)))

      leaked = MapSet.difference(got_msgs, expected)
      assert MapSet.size(leaked) == 0, "#{context}: #{MapSet.size(leaked)} message(s) in an answer that the rule hides"

      required = for m <- sent, m.sent < started, MapSet.member?(expected, m.id), do: m.id
      missing = Enum.reject(required, &MapSet.member?(got_msgs, &1))
      assert missing == [], "#{context}: #{length(missing)} visible message(s) missing from an answer that started after their send reply"
    end

    {hv_rows, member_rows} = rows
    hv_ts = hv_rows |> Enum.map(& &1.ts) |> Enum.max(fn -> 0 end)
    join_ts = member_rows |> Enum.filter(&(&1.m == "join")) |> Enum.map(& &1.ts) |> Enum.min(fn -> 0 end)
    %{joined_before_change: join_ts < hv_ts, reads: length(reads)}
  end

  defp busy(n), do: Enum.reduce(1..n//1, 0, fn i, acc -> rem(acc + i, 7) end)

  # the ordered kinds and stored timestamps of the round: no content, no ids
  defp round_sequence(room, h) do
    {hv, mem} = model_rows(room, h)
    msgs = T.sql!("SELECT origin_server_ts FROM events WHERE room_id = $1 AND event_type = 'm.room.message'", [room]).rows |> Enum.map(fn [ts] -> {:msg, ts} end)
    (Enum.map(hv, &{:hv, &1.ts}) ++ Enum.map(mem, &{:join_or_other, &1.ts}) ++ msgs) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(fn {kind, ts} -> {kind, rem(ts, 100_000)} end)
  end
end
