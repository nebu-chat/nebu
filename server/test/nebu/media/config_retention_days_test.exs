defmodule Nebu.Media.ConfigRetentionDaysTest do
  @moduledoc """
  Acceptance tests for story `media-cleanup-reads-media-config` (follow-up `du`), AC7: `Nebu.Media.Config.retention_days/0`, the STRICT read of the
  two retention windows the `MediaCleanupWorker` deletes by.

  `retention_days/0` returns `{:ok, %{deleted_days: n, infected_days: n}}` or `{:error, :unavailable | :invalid}`. Unlike `get/0` (an unreadable table
  turns into the defaults) an unreadable or damaged value is an ERROR, so the destructive caller can delete nothing instead of guessing. It reads
  fresh on every call (no ETS cache). The unit part drives it through the `:media_config_loader` seam (a 0-arity fun returning a map, as for `get/0`);
  the `:integration` part uses real `media_config` rows.
  """
  use ExUnit.Case, async: false

  alias Nebu.Media.Config
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_config_loader)
      Application.delete_env(:nebu_http, :media_config_source)
    end)

    :ok
  end

  defp loader(fun) when is_function(fun, 0), do: Application.put_env(:nebu_http, :media_config_loader, fun)
  defp loader_map(map), do: loader(fn -> map end)

  describe "defaults and overrides" do
    test "no stored rows: the effective defaults 30 (deleted) and 7 (infected), the retention of an instance nobody configured" do
      loader_map(%{})
      assert {:ok, %{deleted_days: 30, infected_days: 7}} == Config.retention_days()
    end

    test "the catalogue default of infected_days is 7 (the worker's effective retention since story 8a), deleted_days 30" do
      Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)
      assert %{deleted_days: 30, infected_days: 7} = Config.get() |> Map.take([:deleted_days, :infected_days])
    end

    test "stored integers are used, one key alone overrides only that key" do
      loader_map(%{"deleted_days" => 10, "infected_days" => 3})
      assert {:ok, %{deleted_days: 10, infected_days: 3}} == Config.retention_days()

      loader_map(%{"infected_days" => 90})
      assert {:ok, %{deleted_days: 30, infected_days: 90}} == Config.retention_days()
    end

    test "the boundaries 0 and 3650 are valid; keys of other settings are ignored" do
      loader_map(%{"deleted_days" => 0, "infected_days" => 3650, "webhook_url" => "https://example.com/x", "max_stall_ms" => 5})
      assert {:ok, %{deleted_days: 0, infected_days: 3650}} == Config.retention_days()
    end

    @tag :no_repo
    test "a no-Repo environment without a loader seam is {:error, :unavailable}, never the defaults" do
      assert Process.whereis(Nebu.Repo) == nil
      assert {:error, :unavailable} == Config.retention_days()
    end

    test "numeric strings (the stored TEXT form) are accepted, leading zeros included" do
      loader_map(%{"deleted_days" => "12", "infected_days" => "007"})
      assert {:ok, %{deleted_days: 12, infected_days: 7}} == Config.retention_days()
    end
  end

  describe "strict reader accepts 1 to 18 plain digits (story media-config-tolerant-loader)" do
    test "leading zeros up to 18 digits read as the number they spell (0000000 = 0, 0003650 = 3650)" do
      loader_map(%{"deleted_days" => "0000000", "infected_days" => "0003650"})
      assert {:ok, %{deleted_days: 0, infected_days: 3650}} == Config.retention_days()

      loader_map(%{"deleted_days" => String.duplicate("0", 17) <> "7", "infected_days" => "0"})
      assert {:ok, %{deleted_days: 7, infected_days: 0}} == Config.retention_days()
    end

    test "19 digits, even all zeros, and a value above 3650 behind leading zeros stay invalid" do
      for bad <- [String.duplicate("0", 19), "0003651", "0000000000000000000001"] do
        loader_map(%{"deleted_days" => bad})
        assert {:error, :invalid} == Config.retention_days(), "deleted_days = #{inspect(bad)}"
      end
    end
  end

  describe "the writer accepts exactly what the reader accepts (Kassandra L-1)" do
    test "upsert of deleted_days / infected_days above 3650 (or negative, not an integer) is refused before any DB call" do
      for key <- ["deleted_days", "infected_days"], value <- [3651, 1_000_000, -1, "30", 1.5, nil] do
        assert {:error, :invalid_value} == Config.upsert(key, value), "#{key} = #{inspect(value)}"
      end
    end
  end

  describe "reads fresh, never the cache" do
    test "every call reads the loader again: a changed stored value shows at the next call without a refresh or a restart" do
      {:ok, store} = Agent.start_link(fn -> %{"deleted_days" => 30} end)
      loader(fn -> Agent.get(store, & &1) end)

      assert {:ok, %{deleted_days: 30}} = Config.retention_days()
      Agent.update(store, &Map.put(&1, "deleted_days", 12))
      assert {:ok, %{deleted_days: 12}} = Config.retention_days()
    end

    test "the get/0 source seam (the cached catalogue) is not consulted" do
      Application.put_env(:nebu_http, :media_config_source, fn -> %{"deleted_days" => 999, "infected_days" => 999} end)
      loader_map(%{})
      assert {:ok, %{deleted_days: 30, infected_days: 7}} == Config.retention_days()
    end
  end

  describe "an unreadable table is an error, never the defaults (fail-safe)" do
    test "the loader raising, exiting or answering something that is not a map is {:error, :unavailable}" do
      for {label, fun} <- [
            raise: fn -> raise "db down" end,
            exit: fn -> exit(:noproc) end,
            throw: fn -> throw(:boom) end,
            error_atom: fn -> :error end,
            error_tuple: fn -> {:error, :timeout} end,
            nil: fn -> nil end,
            list: fn -> [{"deleted_days", 5}] end
          ] do
        loader(fun)
        assert {:error, :unavailable} == Config.retention_days(), "#{label}"
      end
    end
  end

  describe "a damaged or out-of-range value is an error, never clamped or defaulted" do
    test "deleted_days and infected_days: negative, 3651, huge, non-numeric, empty, nil, float, atom, trailing garbage" do
      bad = [-1, -3650, 3651, 1_000_000_000_000, "abc", "", nil, 1.5, :forever, "12x", " 12", "0x10", "1e3", "+5", "5.0", "12\n", "\u0663", "-0", [1], %{"a" => 1}]

      for key <- ["deleted_days", "infected_days"], value <- bad do
        loader_map(%{key => value})
        assert {:error, :invalid} == Config.retention_days(), "#{key} = #{inspect(value)}"
      end
    end

    test "one bad value fails the whole read (the caller deletes nothing), even when the other value is fine" do
      loader_map(%{"deleted_days" => 10, "infected_days" => -1})
      assert {:error, :invalid} == Config.retention_days()
      loader_map(%{"deleted_days" => "x", "infected_days" => 5})
      assert {:error, :invalid} == Config.retention_days()
    end
  end

  # the real strict read against media_config rows (the default loader path)
  describe "real media_config rows (integration)" do
    @describetag :integration

    setup do
      T.privileged_sql!("DELETE FROM media_config WHERE key IN ('deleted_days', 'infected_days')")
      on_exit(fn -> T.privileged_sql!("DELETE FROM media_config WHERE key IN ('deleted_days', 'infected_days')") end)
      :ok
    end

    defp seed(key, value), do: T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, 1)", [key, value])

    test "no rows: the defaults; rows: their values; read without any refresh of the ETS cache" do
      assert {:ok, %{deleted_days: 30, infected_days: 7}} == Config.retention_days()

      seed("deleted_days", "11")
      seed("infected_days", "2")
      assert {:ok, %{deleted_days: 11, infected_days: 2}} == Config.retention_days()
    end

    test "a damaged stored value (not a number, negative, too large) is {:error, :invalid}" do
      for bad <- ["abc", "", "-4", "3651", "99999999999999999999"] do
        T.privileged_sql!("DELETE FROM media_config WHERE key = 'deleted_days'")
        seed("deleted_days", bad)
        assert {:error, :invalid} == Config.retention_days(), "stored #{inspect(bad)}"
      end
    end
  end
end
