defmodule Nebu.OAuth.LastGood do
  @moduledoc """
  The per-node LAST KNOWN GOOD saved Matrix session lifetime (story session-lifetime-setting): the last successfully read valid value of
  `server_config.matrix_session_ttl_seconds`, kept WITHOUT a TTL for as long as the cache owner lives. A saved lifetime that is stricter than the env value /
  8 hours must never turn longer because a read failed or the row is damaged, so `Nebu.OAuth.Config` answers this value in those cases.

  Cluster note: the value is per node (ETS table `:nebu_oauth_last_good`, owned by `Nebu.OAuth.CacheOwner` like the TTL cache; the source of truth is the
  database). A node that never loaded a good value (fresh boot, owner restart) has none and falls back to the env value / 8 hours until its first successful
  read. A missing table (owner not running, unit runs) is "no value" and a skipped write, never a crash.

  A generation counter makes it safe against a read that was in flight while an Admin save committed: the reader captures `generation/0` before its query
  and writes only while it is unchanged (compare-and-set); a save bumps it.

  Private to the OAuth domain: the reader is `Nebu.OAuth.Config`. A separate module on purpose: `Nebu.OAuth.Config` holds the only TTL cache of the switch
  state and has no state without a TTL.
  """

  @table :nebu_oauth_last_good
  @key :matrix_session_ttl

  # One object `{@key, value | nil, generation}`. A DELIBERATE change (`put_saved/1`, an Admin save on this node) bumps the generation; a reader captures
  # `generation/0` BEFORE its query and may write its answer (`put_if/2`, `clear_if/1`) only while the generation is unchanged (compare-and-set with
  # `:ets.select_replace/2`): a read that was in flight while a save committed can never overwrite the newer value (cycle 2, Kassandra delta LOW #1).

  @doc "The last good value, or nil when none was loaded on this node (or it was cleared by a successful read that found no row). Never raises."
  @spec get() :: pos_integer() | nil
  def get do
    case :ets.lookup(@table, @key) do
      [{@key, seconds, _gen}] -> seconds
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The current generation (0 before the first deliberate change). Capture it BEFORE a read of `server_config`. Never raises."
  @spec generation() :: non_neg_integer()
  def generation do
    case :ets.lookup(@table, @key) do
      [{@key, _seconds, gen}] -> gen
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Remembers `seconds` as the answer of a read that started at generation `gen`, only while the generation is unchanged. Returns `seconds`. Never raises."
  @spec put_if(non_neg_integer(), pos_integer()) :: pos_integer()
  def put_if(gen, seconds) when is_integer(seconds), do: cas(gen, seconds)

  @doc "Forgets the value (a read that started at generation `gen` found no row), only while the generation is unchanged. Returns nil. Never raises."
  @spec clear_if(non_neg_integer()) :: nil
  def clear_if(gen), do: cas(gen, nil) && nil

  @doc "A deliberate change on this node: `seconds` becomes the value and the generation is bumped, so every read in flight is discarded. Returns `seconds`. Never raises."
  @spec put_saved(pos_integer()) :: pos_integer()
  def put_saved(seconds) when is_integer(seconds) do
    gen = generation()

    if :ets.select_replace(@table, [{{@key, :_, gen}, [], [{{@key, seconds, gen + 1}}]}]) == 1 or :ets.insert_new(@table, {@key, seconds, gen + 1}) do
      seconds
    else
      put_saved(seconds)
    end
  rescue
    ArgumentError -> seconds
  end

  @doc "Forgets everything including the generation (test builds use it between tests). Never raises."
  @spec reset() :: :ok
  def reset do
    :ets.delete(@table, @key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cas(gen, value) do
    replaced = :ets.select_replace(@table, [{{@key, :_, gen}, [], [{{@key, value, gen}}]}])
    if replaced == 0 and gen == 0, do: :ets.insert_new(@table, {@key, value, 0})
    value
  rescue
    ArgumentError -> value
  end
end
