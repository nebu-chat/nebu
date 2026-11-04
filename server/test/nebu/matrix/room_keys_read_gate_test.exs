defmodule Nebu.Matrix.RoomKeysReadGateTest do
  @moduledoc """
  Unit tests (no database) of `Nebu.Matrix.RoomKeysReadGate`, the monitor based slots of the bulk key backup reads (story server-side-key-backup, cycle 2),
  in the style of `member_slice_gate_test.exs`: the seam and its default, acquire / release, one slot per user, the cap per node, a killed holder frees its
  slot on `:DOWN`, a double release is a no-op, a `{:cancel, pid}` (the caller's call timed out) frees the slot of a still living caller, and a gate that is
  not running refuses (fail closed). The HTTP behaviour (429 before any database work) is pinned by `room_keys_bulk_flight_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysReadGate, as: Gate

  @key :room_keys_max_concurrent_bulk_reads_per_node

  setup do
    prior = Application.fetch_env(:nebu, @key)
    Application.delete_env(:nebu, @key)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:nebu, @key, value)
        :error -> Application.delete_env(:nebu, @key)
      end
    end)

    :ok
  end

  # a process that holds a slot of `user` until it gets :release; returns its pid once it holds
  defp hold!(user) do
    parent = self()

    pid =
      spawn(fn ->
        result =
          Gate.run(user, fn ->
            send(parent, {:holding, self()})

            receive do
              :release -> :ok
            end
          end)

        send(parent, {:finished, self(), result})
      end)

    assert_receive {:holding, ^pid}, 2_000
    pid
  end

  defp release!(pid) do
    send(pid, :release)
    assert_receive {:finished, ^pid, {:ok, :ok}}, 2_000
  end

  test "the default is 2 readers per node; a strictly positive integer of the application key applies, anything else falls back to 2" do
    assert Gate.max_per_node() == 2

    Application.put_env(:nebu, @key, 5)
    assert Gate.max_per_node() == 5

    for junk <- [0, -1, 1.5, "3", nil, :on] do
      Application.put_env(:nebu, @key, junk)
      assert Gate.max_per_node() == 2, "junk #{inspect(junk)}"
    end
  end

  test "a reader runs and returns its result; the slot is free after it finished" do
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}
    assert Gate.run("@a:test", fn -> :ran_again end) == {:ok, :ran_again}
  end

  test "one slot per user: a second reader of the same user is refused, another user is admitted, the slot is free after the release" do
    a = hold!("@a:test")
    assert Gate.run("@a:test", fn -> flunk("must not run: the user holds a slot") end) == :overflow
    assert Gate.run("@b:test", fn -> :ran end) == {:ok, :ran}, "another user runs"

    release!(a)
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}, "the slot of the user is free again"
  end

  test "the cap per node: two users hold the two slots, a third is refused, and the seam is read per admission" do
    a = hold!("@a:test")
    b = hold!("@b:test")
    assert Gate.run("@c:test", fn -> flunk("must not run: the node is full") end) == :overflow

    Application.put_env(:nebu, @key, 3)
    assert Gate.run("@c:test", fn -> :ran end) == {:ok, :ran}, "the raised seam admits the third reader at once"

    Application.delete_env(:nebu, @key)
    release!(a)
    assert Gate.run("@c:test", fn -> :ran end) == {:ok, :ran}, "a released slot admits the next reader"
    release!(b)
  end

  test "a reader that raises frees its slot (the after)" do
    assert_raise RuntimeError, fn -> Gate.run("@a:test", fn -> raise "boom" end) end
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}
  end

  test "a killed holder frees its user slot and its node slot on :DOWN at once" do
    parent = self()

    killed =
      spawn(fn ->
        Gate.run("@a:test", fn ->
          send(parent, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding, 2_000
    other = hold!("@b:test")
    assert Gate.run("@c:test", fn -> flunk("full") end) == :overflow

    ref = Process.monitor(killed)
    Process.exit(killed, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000

    assert Gate.run("@c:test", fn -> :ran end) == {:ok, :ran}, "the node slot of the killed holder is free"
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}, "the user slot of the killed holder is free"
    release!(other)
  end

  test "a release that arrives twice (or for an unknown slot) is a no-op: it frees nothing that another reader holds" do
    Application.put_env(:nebu, @key, 1)
    parent = self()

    # a reader that takes a slot by the gate's own protocol, then releases it twice
    first =
      spawn(fn ->
        {:ok, slot} = GenServer.call(Gate, {:acquire, "@a:test", self()})
        GenServer.cast(Gate, {:release, slot})
        GenServer.cast(Gate, {:release, slot})
        send(parent, :released_twice)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :released_twice, 2_000
    second = hold!("@b:test")
    GenServer.cast(Gate, {:release, make_ref()})
    assert Gate.run("@c:test", fn -> flunk("the second release must not have freed the slot of the other reader") end) == :overflow

    release!(second)
    send(first, :stop)
  end

  test "{:cancel, pid} frees the slots a still living caller holds (a grant that came after its call timed out)" do
    Application.put_env(:nebu, @key, 1)
    parent = self()

    caller =
      spawn(fn ->
        {:ok, _slot} = GenServer.call(Gate, {:acquire, "@a:test", self()})
        send(parent, :granted)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :granted, 2_000
    assert Gate.run("@b:test", fn -> flunk("full") end) == :overflow

    GenServer.cast(Gate, {:cancel, caller})
    assert Gate.run("@b:test", fn -> :ran end) == {:ok, :ran}, "the cancelled slot is free although the caller lives on"
    assert Process.alive?(caller)
    send(caller, :stop)
  end

  @tag timeout: 60_000
  test "a call that times out (a suspended gate) answers :overflow and cancels: the late grant is not held by the living caller" do
    Application.put_env(:nebu, @key, 1)
    gate = Process.whereis(Gate)
    parent = self()
    :ok = :sys.suspend(gate)

    caller =
      spawn(fn ->
        send(parent, {:caller_result, Gate.run("@a:test", fn -> :ran end)})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:caller_result, :overflow}, 15_000
    after
      :ok = :sys.resume(gate)
    end

    assert Process.alive?(caller), "the caller lives on (a keep-alive connection process)"
    assert Gate.run("@b:test", fn -> :ran end) == {:ok, :ran}, "no slot is held by the caller: a new reader is admitted at the limit 1"
    send(caller, :stop)
  end

  test "an unexpected message to the gate is ignored (the gate keeps serving)" do
    send(Process.whereis(Gate), :unexpected)
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}
  end

  test "a gate that is not running refuses every reader (fail closed: the route answers 429)" do
    assert is_pid(Process.whereis(Gate))
    :ok = Supervisor.terminate_child(Nebu.Supervisor, Gate)

    try do
      assert Process.whereis(Gate) == nil
      assert Gate.run("@a:test", fn -> flunk("must not run without a gate") end) == :overflow
    after
      {:ok, _} = Supervisor.restart_child(Nebu.Supervisor, Gate)
    end

    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}, "the restarted gate serves again"
  end
end
