defmodule Nebu.OAuth.OAuthCacheOwnerStaticTest do
  @moduledoc """
  Static checks (no DB) for story `oauth-hardening-hygiene`, AC9.2 (HY4): the OAuth ETS caches are created by
  ONE supervised owner, never by a request process.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  defp code(rel) do
    @lib
    |> Path.join(rel)
    |> File.read!()
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
    |> Enum.join("\n")
  end

  test "AC9.2: SigningKeyStore and Config never call :ets.new (the owner creates the tables)" do
    refute code("nebu/oauth/signing_key_store.ex") =~ ":ets.new"
    refute code("nebu/oauth/config.ex") =~ ":ets.new"
  end

  test "AC9.1: Nebu.OAuth.CacheOwner creates both named public tables in init/1" do
    assert File.exists?(Path.join(@lib, "nebu/oauth/cache_owner.ex")), "lib/nebu/oauth/cache_owner.ex missing"
    src = code("nebu/oauth/cache_owner.ex")
    assert src =~ ~r/use GenServer|@behaviour GenServer/
    assert src =~ ~r/:ets\.new\(\s*:nebu_oauth_config_cache\b/ or src =~ ":nebu_oauth_config_cache"
    assert src =~ ":nebu_oauth_signing_key_cache"
    assert src =~ ~r/:named_table/ and src =~ ~r/:public/
    assert src =~ ~r/read_concurrency:\s*true/
  end

  test "AC9.1: the owner is a child of Nebu.Supervisor (application.ex names it)" do
    assert code("nebu/application.ex") =~ "Nebu.OAuth.CacheOwner"
  end
end
