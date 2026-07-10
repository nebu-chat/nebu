defmodule Nebu.ApplicationTest do
  use ExUnit.Case, async: true

  # enhanced-logging/matrix-payload-debug-logging (cycle-4 regression test):
  #
  # `Nebu.Application.repo_children/0` (server/lib/nebu/application.ex) uses
  # `Application.get_env(:nebu, Nebu.Repo)` as the SOLE signal for "a real DB
  # is configured" — plain unit runs (no NEBU_DB_URL) must start zero DB
  # children (Nebu.Repo, Sweeper, RefreshWorker). That invariant only holds if
  # `config :nebu, Nebu.Repo, ...` is NEVER set unconditionally anywhere
  # (config.exs is compiled into every build regardless of env/runtime env
  # vars) — it must only ever be set from config/runtime.exs, gated behind
  # `if db_url = System.get_env("NEBU_DB_URL")`.
  #
  # Cycle 2 of this story accidentally added an unconditional
  # `config :nebu, Nebu.Repo, log: false` to config.exs, which made this key
  # always-truthy and broke the invariant. Cycle 4 fixed it by moving `log:
  # false` into the two NEBU_DB_URL-gated `config :nebu, Nebu.Repo, url: ...`
  # calls in runtime.exs instead. This test locks the invariant in.
  #
  # This assertion is only meaningful under plain `mix test` (no NEBU_DB_URL
  # set). `mix test --include integration` (make test-integration-elixir) DOES
  # set NEBU_DB_URL, which legitimately makes `Application.get_env(:nebu,
  # Nebu.Repo)` non-nil for a completely different, correct reason (a real DB
  # is configured there) — this test is not tagged `:integration` and is
  # excluded from that run's rationale, but since it does not assert anything
  # about NEBU_DB_URL being unset, running it under --include integration
  # would fail for the (correct) reason that a DB IS configured there. Keep
  # this file plain-unit-only in intent; do not add :integration coverage here.
  test "Application.get_env(:nebu, Nebu.Repo) is nil when NEBU_DB_URL is not set" do
    if System.get_env("NEBU_DB_URL") do
      # This test only asserts the invariant for the plain-unit-test context.
      # Under make test-integration-elixir, NEBU_DB_URL is set and Nebu.Repo
      # is legitimately configured — skip rather than fail for the wrong
      # reason.
      :ok
    else
      assert Application.get_env(:nebu, Nebu.Repo) == nil,
             "config :nebu, Nebu.Repo must never be set unconditionally (e.g. in " <>
               "config.exs) — it must only be set from config/runtime.exs, gated " <>
               "behind `if db_url = System.get_env(\"NEBU_DB_URL\")`, so that plain " <>
               "unit runs (no NEBU_DB_URL) start zero DB children via " <>
               "Nebu.Application.repo_children/0. Got: " <>
               inspect(Application.get_env(:nebu, Nebu.Repo))
    end
  end
end
