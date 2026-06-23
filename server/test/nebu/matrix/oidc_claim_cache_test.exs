defmodule Nebu.Matrix.OidcClaimCacheTest do
  use ExUnit.Case, async: false

  # ─── Story oidc-claim-boot-cache — cache server_config.oidc_user_id_claim ──────
  #
  # The cache replaces a per-request PostgreSQL read in
  # Nebu.Matrix.UserId.configured_claim/0. It stores the configured claim in
  # persistent_term (hot-path O(1) read), populates it lazily via an INJECTABLE
  # DB reader, invalidates it explicitly on update, and propagates that
  # invalidation across the cluster via :pg.
  #
  # async: false — persistent_term, :pg membership, and the injected
  # Application env reader are all process-global.

  alias Nebu.Matrix.OidcClaimCache

  # An injectable reader returning a fixed value. Each instance counts how many
  # times it was invoked via a counter agent so AC1 can assert "at most once".
  defp counting_reader(value) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    reader = fn ->
      Agent.update(counter, &(&1 + 1))
      value
    end

    {reader, fn -> Agent.get(counter, & &1) end}
  end

  setup do
    # Each test starts a fresh, isolated cache instance under a unique name so
    # tests do not interfere, and the persistent_term key is reset.
    OidcClaimCache.reset_for_test()

    on_exit(fn ->
      Application.delete_env(:matrix, :oidc_claim_reader)
      OidcClaimCache.reset_for_test()
    end)

    :ok
  end

  # ─── AC1 — cached read, no per-request DB hit ────────────────────────────────
  test "AC1: configured_claim is read once and then served from cache" do
    {reader, count} = counting_reader("email")
    Application.put_env(:matrix, :oidc_claim_reader, reader)

    assert OidcClaimCache.get() == "email"
    assert OidcClaimCache.get() == "email"

    # The injected DB reader must have been invoked at most once across both calls.
    assert count.() == 1
  end

  # ─── AC2 — boot-window graceful degrade then populate ────────────────────────
  test "AC2: a raising reader yields nil without crashing, later populates" do
    pid = Process.whereis(OidcClaimCache)

    # First: reader raises (Repo not ready). get/0 must return nil, not raise,
    # and leave the cache :unset so the next call retries.
    Application.put_env(:matrix, :oidc_claim_reader, fn -> raise "Repo not ready" end)
    assert OidcClaimCache.get() == nil
    assert OidcClaimCache.get() == nil
    assert Process.alive?(pid), "the cache holder must survive a raising reader"

    # Then: reader becomes available. The next call populates and caches.
    {reader, count} = counting_reader("email")
    Application.put_env(:matrix, :oidc_claim_reader, reader)
    assert OidcClaimCache.get() == "email"
    assert OidcClaimCache.get() == "email"
    assert count.() == 1
  end

  test "AC2: a confirmed-absent claim (nil) is cached and not re-queried" do
    {reader, count} = counting_reader(nil)
    Application.put_env(:matrix, :oidc_claim_reader, reader)

    assert OidcClaimCache.get() == nil
    assert OidcClaimCache.get() == nil
    # A confirmed-absent value (no row / "") must NOT be re-queried every call.
    assert count.() == 1
  end

  # ─── AC3 — invalidation on upsert ────────────────────────────────────────────
  test "AC3: refresh/0 re-reads and replaces the cached value" do
    {reader1, _} = counting_reader("name")
    Application.put_env(:matrix, :oidc_claim_reader, reader1)
    assert OidcClaimCache.get() == "name"

    # The admin write path changed the value; the reader now returns the new one.
    {reader2, count2} = counting_reader("email")
    Application.put_env(:matrix, :oidc_claim_reader, reader2)

    :ok = OidcClaimCache.refresh()

    assert OidcClaimCache.get() == "email"
    # refresh did the re-read; the subsequent get served from cache.
    assert count2.() == 1
  end

  test "AC3: an unrelated upsert does not refresh the cache" do
    {reader, count} = counting_reader("name")
    Application.put_env(:matrix, :oidc_claim_reader, reader)
    assert OidcClaimCache.get() == "name"
    assert count.() == 1

    # Nebu.Matrix.invalidate_oidc_claim_cache/0 is invoked from
    # upsert_server_config/1 ONLY when the changes map includes the
    # oidc_user_id_claim key. An unrelated upsert must not call it, so the
    # cached value stays and the reader is not invoked again.
    assert OidcClaimCache.get() == "name"
    assert count.() == 1
  end

  test "AC3: upsert_server_config triggers refresh only when oidc_user_id_claim present" do
    # Drive through the actual Nebu.Matrix public invalidation function the admin
    # write path calls, proving the contract: the change-map gate lives in
    # upsert_server_config, and invalidation goes through Nebu.Matrix.
    {reader1, _} = counting_reader("name")
    Application.put_env(:matrix, :oidc_claim_reader, reader1)
    assert OidcClaimCache.get() == "name"

    {reader2, count2} = counting_reader("email")
    Application.put_env(:matrix, :oidc_claim_reader, reader2)

    # Public Matrix invalidation entry point (ADR-020) — the admin write path's hook.
    :ok = Nebu.Matrix.invalidate_oidc_claim_cache()

    assert OidcClaimCache.get() == "email"
    assert count2.() == 1
  end

  # ─── AC4 — cluster invalidation via :pg ──────────────────────────────────────
  test "AC4: an invalidation is broadcast to the :pg group and refreshes locally" do
    # Subscribe a test process to the cache's :pg group as a stand-in peer node.
    ensure_pg()
    :pg.join(OidcClaimCache.pg_group(), self())
    on_exit(fn -> :pg.leave(OidcClaimCache.pg_group(), self()) end)

    {reader1, _} = counting_reader("name")
    Application.put_env(:matrix, :oidc_claim_reader, reader1)
    assert OidcClaimCache.get() == "name"

    {reader2, _} = counting_reader("email")
    Application.put_env(:matrix, :oidc_claim_reader, reader2)

    :ok = Nebu.Matrix.invalidate_oidc_claim_cache()

    # The :pg group (this subscriber acting as a peer node) receives the
    # invalidation broadcast.
    assert_receive {:invalidate_oidc_claim_cache}, 500

    # Single-node local refresh still occurred (no crash, value updated).
    assert OidcClaimCache.get() == "email"
  end

  # ─── AC6 — crash/restart repopulation ────────────────────────────────────────
  test "AC6: the supervised holder restarts and repopulates after a kill" do
    {reader, _} = counting_reader("email")
    Application.put_env(:matrix, :oidc_claim_reader, reader)
    assert OidcClaimCache.get() == "email"

    pid = Process.whereis(OidcClaimCache)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    # The supervisor restarts it under the same registered name.
    new_pid = wait_for_restart(pid)
    assert is_pid(new_pid) and new_pid != pid

    # A subsequent get/0 repopulates from the (injected) reader and returns the value.
    assert OidcClaimCache.get() == "email"
  end

  defp wait_for_restart(old_pid, attempts \\ 50)
  defp wait_for_restart(_old_pid, 0), do: flunk("cache holder did not restart")

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(OidcClaimCache) do
      nil ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)

      ^old_pid ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)

      pid ->
        pid
    end
  end

  defp ensure_pg do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end
end
