defmodule Nebu.Admin.AdminDbLockedConfigTest do
  @moduledoc """
  Story `session-lifetime-setting`, CYCLE 2 (Kassandra delta LOW #3, code review delta MINOR 1, 2, 5): the contract of `Nebu.Admin.DB.with_locked_config/2` and of the
  after-commit queue behind it (the `after_config_write/1` effects of a save made INSIDE it are queued and run after the OUTER commit).

  Decisions pinned here:

    * `fun` returns `{:commit, result}` or `{:rollback, result}`; a rollback decision runs NO effect; the answer is `result` either way.
    * The queue (process dictionary key `{Nebu.Admin.DB, :deferred_after_commit}`) exists only during the call: it is gone after a commit, after a rollback decision and
      after an exception, so nothing leaks into later saves of the same process (a plain `save_config_audited/2` afterwards runs its effects at once).
    * NO NESTING: a `with_locked_config/2` called inside the `fun` of another one raises `ArgumentError` (it would reset or drop the outer queue); the outer transaction is
      rolled back, its queue dropped, the exception propagates.
    * An exception raised by the caller's `fun` is NOT swallowed into `{:error, :db}`: the transaction is rolled back, the queue dropped, the exception re-raised.
    * Effects run in the order of the saves; an effect that raises does NOT skip the remaining ones: all run, the failed one is logged as ONE value-free line (the
      exception type, never its message), the commit already happened, so the call still returns the result of `fun`.
    * The `:unlocked` seam branch (`:admin_config_tx`, or no repository) calls `fun.(:unlocked)` and the effects of its saves run immediately (no queue).
    * An infrastructure failure of the locked transaction (a `Postgrex.Error` from the lock query, a connection error, an exit) is `{:error, :db}` plus ONE value-free log
      line (`error_type/1`: the SQLSTATE name, never a message, a key or a value), `fun` is not called; never an exception (a 500).

  Test seam used to observe the effects (test builds only): `:nebu_http, :admin_after_config_write`, a 1-arity fun called with `changes` at the start of every
  `after_config_write/1`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Admin.DB
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  @key {Nebu.Admin.DB, :deferred_after_commit}
  @cap "oauth_pending_cap"

  setup do
    test_pid = self()
    T.put_env_scoped(:admin_after_config_write, fn changes -> send(test_pid, {:effect, changes}) end)
    :ok
  end

  defp save!(changes), do: assert({:ok, %{audited: true}} = DB.save_config_audited(changes, audit: fn -> :ok end, unaudited_ok: false, form: :atdd))
  # every {:effect, changes} in the mailbox, in the order they were sent
  defp effects_in_order do
    receive do
      {:effect, changes} -> [changes | effects_in_order()]
    after
      0 -> []
    end
  end

  defp flush_effects, do: receive(do: ({:effect, _} -> flush_effects()), after: (0 -> :ok))

  describe "queue semantics (real database)" do
    @describetag :integration

    setup do
      %{rows: prior} = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = $1", [@cap])
      T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [@cap])

      on_exit(fn ->
        T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [@cap])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      end)

      L.real_seams!()
      Application.delete_env(:nebu_http, :admin_config_tx)
      :ok
    end

    defp row, do: T.sql!("SELECT value FROM server_config WHERE key = $1", [@cap]).rows |> List.first() |> List.wrap() |> List.first()

    test "commit: the effect runs once, AFTER the commit and after fun returned; the answer is the result of fun; the queue is gone" do
      result =
        DB.with_locked_config([@cap], fn _stored ->
          save!(%{@cap => "11"})
          refute_received {:effect, _}, "the effect of a save inside the lock waits for the outer commit"
          assert Process.get(@key) == [%{@cap => "11"}]
          {:commit, :done}
        end)

      assert result == :done
      assert row() == "11"
      assert_received {:effect, %{@cap => "11"}}
      refute_received {:effect, _}, "exactly once"
      assert Process.get(@key) == nil
    end

    test "a rollback decision runs NO effect, changes nothing and answers the result of fun; the queue is gone" do
      assert :nope ==
               DB.with_locked_config([@cap], fn _stored ->
                 save!(%{@cap => "12"})
                 {:rollback, :nope}
               end)

      assert row() == nil
      refute_received {:effect, _}
      assert Process.get(@key) == nil
    end

    test "an exception of fun is re-raised (not turned into {:error, :db}), the transaction is rolled back, the queue is gone, later saves are not deferred" do
      assert_raise RuntimeError, ~r/canary-wl-1/, fn ->
        DB.with_locked_config([@cap], fn _stored ->
          save!(%{@cap => "13"})
          raise "canary-wl-1"
        end)
      end

      assert row() == nil
      refute_received {:effect, _}
      assert Process.get(@key) == nil

      # nothing leaked into the process: a plain save runs its effect AT ONCE
      save!(%{@cap => "14"})
      assert_received {:effect, %{@cap => "14"}}
      assert row() == "14"
    end

    test "nesting is refused with ArgumentError; the outer transaction is rolled back, its queue dropped, the key gone" do
      assert_raise ArgumentError, fn ->
        DB.with_locked_config([@cap], fn _stored ->
          save!(%{@cap => "15"})
          DB.with_locked_config([@cap], fn _inner -> {:commit, :inner} end)
        end)
      end

      assert row() == nil
      refute_received {:effect, _}
      assert Process.get(@key) == nil
    end

    test "after a nested attempt, a commit and a rollback in the same process, the next call starts with an empty queue" do
      assert :first ==
               DB.with_locked_config([@cap], fn _ ->
                 save!(%{@cap => "16"})
                 {:commit, :first}
               end)

      assert_received {:effect, %{@cap => "16"}}

      assert :second ==
               DB.with_locked_config([@cap], fn _ ->
                 save!(%{@cap => "17"})
                 {:rollback, :second}
               end)

      refute_received {:effect, _}, "the effect of the first call is not run again, the rolled back one is dropped"
      assert row() == "16"
      assert Process.get(@key) == nil
    end

    test "several saves: the effects run in the order of the saves, once each" do
      DB.with_locked_config([@cap], fn _ ->
        save!(%{@cap => "21"})
        save!(%{@cap => "22"})
        save!(%{@cap => "23"})
        {:commit, :ok}
      end)

      assert effects_in_order() == [%{@cap => "21"}, %{@cap => "22"}, %{@cap => "23"}]
      assert row() == "23"
    end

    test "an effect that raises does not skip the remaining ones: all run in order, ONE value-free error line, the result of fun is returned" do
      test_pid = self()

      T.put_env_scoped(:admin_after_config_write, fn changes ->
        send(test_pid, {:effect, changes})
        if changes[@cap] == "32", do: raise("hook boom canary-wl-2")
      end)

      log =
        capture_log([level: :warning], fn ->
          result =
            DB.with_locked_config([@cap], fn _ ->
              save!(%{@cap => "31"})
              save!(%{@cap => "32"})
              save!(%{@cap => "33"})
              {:commit, :ok_result}
            end)

          send(test_pid, {:result, result})
        end)

      assert_received {:result, :ok_result}
      assert effects_in_order() == [%{@cap => "31"}, %{@cap => "32"}, %{@cap => "33"}], "all three ran in order, also the one after the failing one"
      assert length(Regex.scan(~r/\[error\]/, log)) == 1, log
      refute log =~ "canary-wl-2", "only the exception type is logged"
      assert row() == "33", "the commit had happened"
      assert Process.get(@key) == nil
    end
  end

  describe "the locked transaction fails (real database)" do
    @describetag :integration

    setup do
      L.real_seams!()
      Application.delete_env(:nebu_http, :admin_config_tx)
      :ok
    end

    test "a Postgrex.Error from the lock query is {:error, :db} with ONE value-free log line, fun is not called, nothing leaks" do
      test_pid = self()
      # a NUL byte in a key: the server refuses the statement (22021), a Postgrex.Error raised by the query inside the transaction
      keys = ["matrix_session_ttl_seconds", "canary-pg-4417" <> <<0>>]

      log =
        capture_log([level: :warning], fn ->
          result =
            DB.with_locked_config(keys, fn _ ->
              send(test_pid, :fun_called)
              {:commit, :x}
            end)

          send(test_pid, {:result, result})
        end)

      assert_received {:result, {:error, :db}}
      refute_received :fun_called
      assert length(Regex.scan(~r/\[error\]/, log)) == 1, log
      assert log =~ "postgres", "error_type/1 of a Postgrex.Error: the SQLSTATE name"
      refute log =~ "canary-pg-4417"
      refute_received {:effect, _}
      assert Process.get(@key) == nil
    end

    test "after the failure the process is clean: the next locked call works" do
      capture_log(fn -> DB.with_locked_config(["x" <> <<0>>], fn _ -> {:commit, :x} end) end)
      assert :fine == DB.with_locked_config(["matrix_session_ttl_seconds"], fn _ -> {:rollback, :fine} end)
    end
  end

  describe "the :unlocked seam branch (no database)" do
    setup do
      T.put_env_scoped(:admin_config_tx, fn _changes, audit ->
        case audit && audit.() do
          nil -> :ok
          :ok -> :ok
          {:error, reason} -> {:error, {:audit, reason}}
        end
      end)

      :ok
    end

    test "fun gets :unlocked, the effects of its saves run immediately (no queue), the answer is the result of fun" do
      result =
        DB.with_locked_config([@cap], fn locked ->
          assert locked == :unlocked
          save!(%{@cap => "41"})
          assert_received {:effect, %{@cap => "41"}}
          assert Process.get(@key) == nil
          {:commit, :unlocked_done}
        end)

      assert result == :unlocked_done
      flush_effects()
    end

    test "a rollback decision answers the result as well" do
      assert :same == DB.with_locked_config([@cap], fn :unlocked -> {:rollback, :same} end)
    end
  end
end
