defmodule Nebu.Matrix.ToDeviceSendGateTest do
  @moduledoc """
  Unit tests (no database) of `Nebu.Matrix.ToDeviceSendGate`, the monitor based slots of the to-device SENDS (story to-device-messaging; lesson of the sibling story's reviews: a rate limit
  is not a concurrency limit), in the style of `room_keys_read_gate_test.exs`: the seams and their defaults (4 per user, 6 per node, below the pool of 10 connections, read per admission), acquire / release, the cap per
  user, the cap per node, a killed holder frees its slots on `:DOWN`, a raising holder frees its slot, a call that times out answers `:overflow` and cancels, a gate that is not running
  refuses (fail closed). The HTTP behaviour (429 BEFORE the body is read, slots freed by every ending, no cross-user starvation) is pinned by `to_device_concurrency_test.exs`.

  The gate is node-local by design (documented: in a cluster the effective limit is N x the limit), a supervised GenServer registered under its own module name, a child of
  `Nebu.Supervisor` with the module as child id.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ToDeviceSendGate, as: Gate

  @user_key :to_device_max_concurrent_sends_per_user
  @node_key :to_device_max_concurrent_sends_per_node

  setup do
    prior = for k <- [@user_key, @node_key], into: %{}, do: {k, Application.fetch_env(:nebu, k)}
    for k <- [@user_key, @node_key], do: Application.delete_env(:nebu, k)

    on_exit(fn ->
      for {k, v} <- prior do
        case v do
          {:ok, value} -> Application.put_env(:nebu, k, value)
          :error -> Application.delete_env(:nebu, k)
        end
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

  test "the defaults are 4 sends per user and 6 per node; a strictly positive integer of the application key applies, anything else falls back" do
    assert {Gate.max_per_user(), Gate.max_per_node()} == {4, 6}
    Application.put_env(:nebu, @user_key, 2)
    Application.put_env(:nebu, @node_key, 7)
    assert {Gate.max_per_user(), Gate.max_per_node()} == {2, 7}

    for junk <- [0, -1, 1.5, "3", nil, :on] do
      Application.put_env(:nebu, @user_key, junk)
      Application.put_env(:nebu, @node_key, junk)
      assert {Gate.max_per_user(), Gate.max_per_node()} == {4, 6}, "junk #{inspect(junk)}"
    end
  end

  test "a sender runs and returns its result; the slot is free after it finished" do
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}
    assert Gate.run("@a:test", fn -> :ran_again end) == {:ok, :ran_again}
  end

  test "the cap per user: with 2 slots a third send of the same user is refused, another user is admitted, a released slot admits the next" do
    Application.put_env(:nebu, @user_key, 2)
    a1 = hold!("@a:test")
    a2 = hold!("@a:test")
    assert Gate.run("@a:test", fn -> flunk("must not run: the user holds its slots") end) == :overflow
    assert Gate.run("@b:test", fn -> :ran end) == {:ok, :ran}, "another user runs"

    release!(a1)
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}, "a slot of the user is free again"
    release!(a2)
  end

  test "the cap per node: two users hold the two node slots, a third is refused, and the seam is read per admission" do
    Application.put_env(:nebu, @node_key, 2)
    a = hold!("@a:test")
    b = hold!("@b:test")
    assert Gate.run("@c:test", fn -> flunk("must not run: the node is full") end) == :overflow

    Application.put_env(:nebu, @node_key, 3)
    assert Gate.run("@c:test", fn -> :ran end) == {:ok, :ran}, "the raised seam admits the third sender at once"

    Application.put_env(:nebu, @node_key, 2)
    release!(a)
    assert Gate.run("@c:test", fn -> :ran end) == {:ok, :ran}, "a released slot admits the next sender"
    release!(b)
  end

  test "one user cannot take the node: with 4 per user and 6 per node, a user's fifth send is refused although 2 node slots are free" do
    holders = for _ <- 1..4, do: hold!("@a:test")
    assert Gate.run("@a:test", fn -> flunk("the fifth send of one user") end) == :overflow
    assert Gate.run("@b:test", fn -> :ran end) == {:ok, :ran}
    Enum.each(holders, &release!/1)
  end

  test "a sender that raises frees its slot (the after)" do
    Application.put_env(:nebu, @user_key, 1)
    assert_raise RuntimeError, fn -> Gate.run("@a:test", fn -> raise "boom" end) end
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}
  end

  test "a killed holder frees its user slot and its node slot on :DOWN at once" do
    Application.put_env(:nebu, @user_key, 1)
    Application.put_env(:nebu, @node_key, 2)
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

  @tag timeout: 60_000
  test "a call that times out (a suspended gate) answers :overflow and cancels: the late grant is not held by the living caller" do
    Application.put_env(:nebu, @user_key, 1)
    Application.put_env(:nebu, @node_key, 1)
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
    assert Gate.run("@b:test", fn -> :ran end) == {:ok, :ran}, "no slot is held by the caller: a new sender is admitted at the limit 1"
    send(caller, :stop)
  end

  test "an unexpected message to the gate is ignored (the gate keeps serving)" do
    send(Process.whereis(Gate), :unexpected)
    assert Gate.run("@a:test", fn -> :ran end) == {:ok, :ran}
  end

  test "a gate that is not running refuses every sender (fail closed: the route answers 429)" do
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
