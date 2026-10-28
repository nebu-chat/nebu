defmodule Nebu.Matrix.HistoryVisibilityUpgradeHttpTest do
  @moduledoc """
  Story `history-visibility-enforcement`, AC22 (11) and D3 / D15: the room upgrade carries the `joined` setting into the replacement room, which starts its own history. Real stack
  (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`, real `Room.Server` under Horde). `async: false`. (A file of its own, the ATDD agent's choice named in the Change Log.)

  ## Decisions of the ATDD step

    * The upgrader A writes the replacement room's events in the order create, join, levels, state copy (the hv event among it), then the invitations of the old members: so B (an old member,
      invited by the upgrade) holds an invitation that lies AFTER the copied `joined` event: hidden to him (his own invite under `joined`, D5 (b)), like everything A writes before B joins.
    * "only the create chain before the copied hv event and the events after his join" is asserted as the exact set difference to A's page in the new room: A's page minus {B's invite, n1}.
    * The old room: a tombstoned, archived room has no running process; every read is `404 Room not found` for a former member (`gi` (e), unchanged by this story).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.HistoryVisibilityTestSupport
  import Nebu.Matrix.MembershipStateTestSupport, only: [setup_env!: 0]

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    setup_env!()
    :ok
  end

  defp upgrade!(user, room) do
    conn = T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})
    assert conn.status == 200, "upgrade: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["replacement_room"]
  end

  defp stored_hv(room) do
    [[content]] = T.sql!("SELECT content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = '' ORDER BY origin_server_ts DESC, event_id DESC LIMIT 1", [room, hv_type()]).rows
    content_of(content)
  end

  test "(11) a joined room is upgraded: the copied setting restricts the replacement room for a later joiner (create chain + events after his join); the old room is unserved" do
    a = user!("HVA")
    b = user!("HVB")
    {old, _} = hv_room!(a, "joined")
    old_msg = say_m!(a, old, "oldx")
    invite_ev!(a, old, b)
    join_ev!(b, old)
    say_m!(a, old, "old2x")

    tick()
    new = upgrade!(a, old)
    tick()
    assert stored_hv(new) == %{"history_visibility" => "joined"}, "fixture: the setting was carried into the replacement room"

    n1 = say_m!(a, new, "n1x")
    b_invite = latest_member_event_id!(new, b)
    assert member_events(new, b.uid) |> List.last() |> Map.fetch!(:content) |> Map.fetch!("membership") == "invite", "fixture: B holds the invitation the upgrade wrote"
    join = join_ev!(b, new)
    n2 = say_m!(a, new, "n2x")

    {a_chunk, _, a_raw} = msgs!(a, new)
    assert_shown!(a_chunk, a_raw, [n1, n2])
    {b_chunk, b_body, b_raw} = msgs!(b, new)

    # hv-type events are visible by D5 (a) and never listed as hidden; the events the upgrade wrote at or after the millisecond of the copied hv event (the join rules, the invitations ...; an event of the SAME millisecond is judged most
    # restrictively, D2 (c): the upgrade stamps several events within one millisecond) and before B's join are invisible to B; the hv event itself and the create chain
    # strictly before it are visible (D3, D5 (a))
    {a_forward, _, _} = msgs!(a, new, "dir=f&limit=100")
    hv_new = a_forward |> Enum.filter(&(&1["type"] == hv_type())) |> List.last()
    join_index = Enum.find_index(a_forward, &(&1["event_id"] == join))

    hidden_ids =
      for {e, i} <- Enum.with_index(a_forward),
          i < join_index,
          e["type"] != hv_type(),
          e["origin_server_ts"] >= hv_new["origin_server_ts"],
          do: e["event_id"]

    assert b_invite in hidden_ids and n1.id in hidden_ids, "fixture: B's invitation and n1 lie between the copied hv event and B's join"

    assert ids(b_chunk) == ids(a_chunk) -- hidden_ids, "B sees the create chain up to the copied hv event, his join and what follows; nothing in between"
    assert hv_new["event_id"] in ids(b_chunk)
    # the create event is shared (D3) unless the upgrade stamped it in the SAME millisecond as the copied hv event (D2 (c): hidden, most restrictive)
    create = Enum.find(a_forward, &(&1["type"] == "m.room.create"))
    assert (create["event_id"] in ids(b_chunk)) == (create["origin_server_ts"] < hv_new["origin_server_ts"]), "the create event follows the same-ms rule"
    assert join in ids(b_chunk)
    assert_shown!(b_chunk, b_raw, [n2])
    assert end_absent?(b_body)
    refute_leak!(b_raw, [n1, b_invite])

    # the replacement room's own history only: nothing of the OLD room's messages is in it, for anyone
    refute_leak!(a_raw, old_msg)

    # the old room is archived and unserved
    for u <- [a, b], do: assert_room_404!(messages_req(u, old))
  end

  test "control: the same upgrade of a shared room: the later joiner sees n1 too" do
    a = user!("HVA")
    b = user!("HVB")
    {old, _} = hv_room!(a, "shared")
    invite_ev!(a, old, b)
    join_ev!(b, old)
    tick()
    new = upgrade!(a, old)
    tick()
    n1 = say_m!(a, new, "n1x")
    join_ev!(b, new)

    {b_chunk, _, b_raw} = msgs!(b, new)
    assert_shown!(b_chunk, b_raw, [n1])
    assert ids(b_chunk) == all_ids_of(a, new)
  end

  defp all_ids_of(user, room) do
    {chunk, _, _} = msgs!(user, room)
    ids(chunk)
  end
end
