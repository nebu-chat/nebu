defmodule Nebu.Matrix.MembershipStateGateHttpTest do
  @moduledoc """
  Story `membership-state-model`, security cycle 3 (Kassandra M-3, the wait justification of D19): ONE initial `/sync` reads the member
  state of up to 5 joined rooms in parallel, while the node-wide gate admits 3 slice reads at a time (the default). Each slice read is
  slowed to 300 ms here (a delegating db module), so the 4th and 5th read must WAIT for a slot: the response carries every room complete
  (no room degraded to the joined slice, no "served joined-only" warning). Real stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.MembershipStateTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport, only: [install_env!: 3]

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  defmodule SlowSliceDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :member_state_slice do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    # every slice read takes at least 300 ms: five parallel reads cannot all hold one of the three slots at once
    def member_state_slice(room, opts \\ []) do
      Process.sleep(300)
      apply(DB, :member_state_slice, [room, opts])
    end
  end

  setup do
    setup_env!()
    # the DEFAULT gate (setup_env! lifted it for the other suites)
    Application.delete_env(:nebu, :member_slice_max_concurrency)
    :ok
  end

  test "a 5-room parallel initial /sync at the default limit 3 returns every room complete (the 4th and 5th slice read wait for a slot)" do
    b = user!("MGB")

    rooms =
      for _ <- 1..5 do
        a = user!("MGA")
        c = user!("MGC")
        room = public_room(a)
        join!(b, room)
        invite!(a, room, c)
        for _ <- 1..25, do: say!(a, room, marker("fill"))
        {room, a, c}
      end

    install_env!(:event_dispatcher, :messages_db_module, SlowSliceDB)
    assert Nebu.Matrix.MemberSliceGate.max_concurrency() == 3

    {conn, log} = with_log(fn -> sync_conn(b, since: nil, timeout: 0) end)

    assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)

    for {room, a, c} <- rooms do
      assert membership_pairs(join_state(body, room)) == pairs([{a, "join"}, {b, "join"}, {c, "invite"}]), "every room has its full member state"
    end

    refute log =~ "served joined-only", "no room was degraded: #{log}"
  end

  # security cycle 3 (Kassandra L-3'): `full_state_rooms` reads the rooms of a `full_state=true` /sync one after the other in ONE process;
  # with a full gate each room would wait its own second and 12 rooms would pass the 10 s task timeout (a 500): the wait is ONE budget per
  # response, so after the first overflow the other rooms are degraded at once
  @tag timeout: 120_000
  test "a full_state /sync of 12 joined rooms while the gate (limit 1) is held answers 200 within the wait budget, the rooms degraded, no 500" do
    b = user!("MGB")
    holder_user = user!("MGH")
    held = public_room(holder_user)

    rooms =
      for _ <- 1..12 do
        a = user!("MGA")
        c = user!("MGC")
        room = public_room(a)
        join!(b, room)
        invite!(a, room, c)
        {room, a}
      end

    token = next(sync(b))
    Application.put_env(:nebu, :member_slice_max_concurrency, 1)
    install_env!(:event_dispatcher, :messages_db_module, Nebu.Matrix.MembershipStateTestSupport.Hooks.SliceDB)
    Nebu.Matrix.MembershipStateTestSupport.Hooks.arm(:atdd_ms_slice, %{room: held, block: self()})
    on_exit(&Nebu.Matrix.MembershipStateTestSupport.Hooks.disarm_all/0)

    holder = Task.async(fn -> members_conn(holder_user, held) end)
    assert_receive {:ms_gap, blocked, :slice_read}, 10_000

    started = System.monotonic_time(:millisecond)
    {conn, log} = with_log(fn -> sync_conn(b, since: token, full_state: true, timeout: 0) end)
    elapsed = System.monotonic_time(:millisecond) - started

    send(blocked, :go)
    assert Task.await(holder, 20_000).status == 200

    assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    assert elapsed < 6_000, "one shared wait budget (about 1 s), not one per room: #{elapsed} ms"
    body = T.json(conn)

    for {room, a} <- rooms do
      assert membership_pairs(join_state(body, room)) == pairs([{a, "join"}, {b, "join"}]), "the room is degraded to the joined slice"
    end

    assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]" and &1 =~ "served joined-only")), "ONE aggregated warning"
    assert line =~ "12 room(s)" and line =~ "overflow"
  end
end
