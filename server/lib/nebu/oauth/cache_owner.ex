defmodule Nebu.OAuth.CacheOwner do
  @moduledoc """
  Supervised owner of the per-node OAuth ETS caches (story oauth-hardening-hygiene, HY4).

  Creates both named, public tables in `init/1`:

    * `:nebu_oauth_config_cache` (`read_concurrency: true`) — the TTL cache of `Nebu.OAuth.Config.get/1`
      (HY1, entry `{:config, map, loaded_at_ms}`);
    * `:nebu_oauth_signing_key_cache` — the DECODED id_token signing keys of `Nebu.OAuth.SigningKeyStore`
      (keyed by `kid` + ciphertext, immutable rows).

  Before this process existed the first request process that needed the signing-key cache created (and
  therefore owned) the table, which vanished with that request process. Request processes never create
  tables any more: a missing table (owner not running, early boot, unit runs) is a MISS everywhere
  (read-through, no crash); an owner restart starts with empty tables (a cold cache is always correct).

  The process does nothing else. A child of `Nebu.Supervisor`, started after `Nebu.Repo`, before Bandit.
  """
  use GenServer

  @tables [
    {:nebu_oauth_config_cache, [:set, :public, :named_table, read_concurrency: true]},
    {:nebu_oauth_signing_key_cache, [:set, :public, :named_table, read_concurrency: true]}
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    for {name, options} <- @tables, do: :ets.new(name, options)
    {:ok, %{}}
  end
end
