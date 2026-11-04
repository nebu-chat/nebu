defmodule Nebu.OAuth.SessionLifetimeLastGoodTest do
  @moduledoc """
  Story `session-lifetime-setting`, CYCLE 1 (security review Kassandra #1 MEDIUM + #4, code review INFO): LAST KNOWN GOOD.

  A saved lifetime that is STRICTER than the env value / 8 hours (say 1 hour) must never silently become LONGER because a read of `server_config` fails or the
  row is damaged. `Nebu.OAuth.Config` therefore keeps, per node and WITHOUT a TTL, the last successfully read saved value, and
  `Nebu.Web.SessionConfig.matrix_session_ttl_seconds/0` (hence every caller: the OAuth login, the legacy login, `MatrixSessionStore.extend_in_place/3`, the
  reuse window, `RefreshWorker.candidates/0`) answers it whenever the current read yields no usable value because it FAILED or is DAMAGED. Contract pinned here:

    * last good = the value of the last SUCCESSFUL read that yielded a valid saved value (a read through the real database; the `:oauth_config_source` seam
      does not take part). Not a TTL entry: it survives the cache TTL, `invalidate_cache/0` and a stopped cache owner.
    * a failed read (repo down, query error, timeout) or a damaged / out of range row after a good one: the last good value (the damaged row still logs its
      warning). The failed read is still not cached (the next call reads again) and `Nebu.OAuth.Config.get/0` stays FAIL CLOSED for the OAuth switch
      (`state: :unknown`, `enabled: false`): only the lifetime is sticky.
    * env value / 8 hours ONLY when no good value was ever loaded on this node, or after a SUCCESSFUL read that found NO row (the operator removed the row on
      purpose: that read is the new truth).
    * a deliberate save by this node (`Nebu.Admin.DB.save_config_audited/2` of the key) replaces it at once, without a read in between.
    * test contract: `Nebu.OAuth.Config.reset_last_good_for_test/0` (test builds only) forgets it; `Nebu.SessionLifetime.TestSupport.clear_env_ttl!/0` calls it
      in setup and on exit.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L
  alias Nebu.Web.SessionConfig

  @t0 1_000_000
  @cache :nebu_oauth_config_cache

  setup do
    T.clear_oauth_config()
    T.put_env_scoped(:admin_csrf_bypass, true)
    L.clear_env_ttl!()
    L.delete_row!()
    L.clear_audit_rows!()
    L.real_seams!()

    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, @t0)
    prior_ttl = Application.fetch_env(:nebu_http, :oauth_config_cache_ms)
    prior_clock = Application.fetch_env(:nebu_http, :oauth_config_cache_clock_fn)
    Application.put_env(:nebu_http, :oauth_config_cache_clock_fn, fn -> :atomics.get(clock, 1) end)
    cache_ms(2000)
    clear_cache()

    on_exit(fn ->
      restore(:oauth_config_cache_ms, prior_ttl)
      restore(:oauth_config_cache_clock_fn, prior_clock)
      Application.delete_env(:nebu_http, :oauth_config_repo)
      clear_cache()
      L.clear_audit_rows!()
    end)

    {:ok, clock: clock}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:nebu_http, key, value)
  defp restore(key, :error), do: Application.delete_env(:nebu_http, key)
  defp cache_ms(ms), do: Application.put_env(:nebu_http, :oauth_config_cache_ms, ms)
  defp clear_cache, do: if(:ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache))
  defp set_clock(clock, offset_ms), do: :atomics.put(clock, 1, @t0 + offset_ms)
  defp ttl, do: SessionConfig.matrix_session_ttl_seconds()

  defp break_repo! do
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
    Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)
    on_exit(fn -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end) end)
  end

  defp fix_repo!, do: Application.delete_env(:nebu_http, :oauth_config_repo)

  # a read that fails, quietly
  defp ttl_while_broken do
    {value, _log} = with_log(fn -> ttl() end)
    value
  end

  describe "the test contract" do
    test "Nebu.OAuth.Config.reset_last_good_for_test/0 exists (the last good value is node-global state that tests must be able to forget)" do
      assert Code.ensure_loaded?(Nebu.OAuth.Config)
      assert function_exported?(Nebu.OAuth.Config, :reset_last_good_for_test, 0)
      assert :ok = apply(Nebu.OAuth.Config, :reset_last_good_for_test, [])
    end
  end

  describe "a failed read keeps the last good value" do
    test "cache on: the value read hours ago is served when the read fails (the TTL cache is gone, the last good value has no TTL)", %{clock: clock} do
      L.set_row!("3600")
      assert ttl() == 3600

      set_clock(clock, 36_000_000)
      break_repo!()
      assert ttl_while_broken() == 3600
      assert ttl_while_broken() == 3600
    end

    test "cache off: the same", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      assert ttl() == 3600
      break_repo!()
      assert ttl_while_broken() == 3600
    end

    test "also with an env value that is LONGER (and with a longer saved value: the saved one wins either way)", %{clock: _clock} do
      cache_ms(0)
      L.put_env_ttl!(14_400)
      L.set_row!("3600")
      assert ttl() == 3600
      break_repo!()
      assert ttl_while_broken() == 3600
    end

    test "the failed read is not cached: the next call after the repo healed reads the row again", %{clock: clock} do
      L.set_row!("3600")
      assert ttl() == 3600
      break_repo!()
      set_clock(clock, 5000)
      assert ttl_while_broken() == 3600

      L.set_row!("7200")
      fix_repo!()
      assert ttl() == 7200
    end

    test "a successful read of a NEW valid value replaces it: the next failure serves the new one", %{clock: clock} do
      L.set_row!("3600")
      assert ttl() == 3600
      L.set_row!("10800")
      set_clock(clock, 2000)
      assert ttl() == 10_800

      break_repo!()
      set_clock(clock, 9000)
      assert ttl_while_broken() == 10_800
    end

    test "Nebu.OAuth.Config.get/0 stays FAIL CLOSED for the OAuth switch: only the lifetime is sticky", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      assert ttl() == 3600
      T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => T.issuer()})
      assert %{state: :enabled} = Nebu.OAuth.Config.get()

      break_repo!()
      {config, _log} = with_log(fn -> Nebu.OAuth.Config.get() end)
      assert %{enabled: false, state: :unknown} = config
    end

    test "legacy bound callers get the same value: MatrixSessionStore.extend_in_place/3 is capped at created_at + the last good lifetime", %{clock: _clock} do
      cache_ms(0)
      user_id = T.provision_user!()
      s = T.legacy_session!(user_id, "LASTGOOD" <> T.rand(3), expires_at: DateTime.add(DateTime.utc_now(), 60, :second))
      L.set_row!("3600")
      assert ttl() == 3600

      break_repo!()
      with_log(fn -> assert :ok = Store.extend_in_place(s.at, DateTime.add(DateTime.utc_now(), 7200, :second), nil) end)

      %{rows: [[span]]} = T.sql!("SELECT extract(epoch FROM expires_at - created_at)::float8 FROM matrix_sessions WHERE access_token_hash = $1", [T.token_hash(s.at)])
      assert_in_delta span, 3600, 3, "bounded by the last good lifetime, not by the 8 hour fallback (that would be 7200 here)"
    end

    test "legacy bound callers: RefreshWorker.candidates/0 (the reuse / extension window) uses it too: a row older than the last good lifetime is no candidate", %{clock: _clock} do
      worker_row_is_candidate?(last_good: true)
      |> then(&refute(&1, "created 2 hours ago, the last good lifetime is 1 hour: not a candidate although the 8 hour fallback would make it one"))
    end

    test "control of the worker test: without a last good value the same failed read falls back to 8 hours and the row IS a candidate", %{clock: _clock} do
      assert worker_row_is_candidate?(last_good: false)
    end
  end

  describe "a damaged row after a good one" do
    test "keeps the last good value (and still logs its warning that names the key and never the value)", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      assert ttl() == 3600
      T.reset_rate_limits()
      on_exit(&T.restore_rate_limits/0)

      for raw <- ["canary-lg-9931-junk", "100", "99999999", " "] do
        L.set_row!(raw)
        T.reset_rate_limits()
        log = capture_log([level: :warning], fn -> send(self(), {:v, ttl()}) end)
        assert_received {:v, 3600}
        assert log =~ "matrix_session_ttl_seconds", "a warning for #{inspect(raw)}"
        refute log =~ "canary-lg-9931"
      end
    end

    test "with no good value ever read the damaged row falls back to the env value / 8 hours (nothing to keep)", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("canary-lg-junk")
      assert with_log(fn -> ttl() end) |> elem(0) == 28_800
      L.put_env_ttl!(14_400)
      assert with_log(fn -> ttl() end) |> elem(0) == 14_400
    end
  end

  describe "when the last good value is NOT used" do
    test "never loaded on this node + a failed read: the env value / 8 hours", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      break_repo!()
      assert ttl_while_broken() == 28_800
      L.put_env_ttl!(600)
      assert ttl_while_broken() == 600
    end

    test "a SUCCESSFUL read that finds no row is the new truth: the row removed on purpose ends the saved value (env / 8 hours apply)", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      assert ttl() == 3600
      L.delete_row!()
      assert ttl() == 28_800

      break_repo!()
      assert ttl_while_broken() == 28_800, "the last SUCCESSFUL read found no saved value"
    end
  end

  describe "a deliberate change by this node replaces it" do
    test "the admin save of 7200 is the last good value at once: a failed read right after it answers 7200, not the old 3600", %{clock: _clock} do
      L.set_row!("3600")
      assert ttl() == 3600

      conn = S.post("/admin/config/session-lifetime", %{"matrix_session_ttl_seconds" => "7200"}, "/admin/config", ago: 10)
      assert conn.status in [302, 303]
      assert L.row_value() == "7200"

      break_repo!()
      assert ttl_while_broken() == 7200
    end

    test "invalidating the cache does NOT forget it (invalidate_cache/0 only drops the TTL entry): a failed read after it still answers the last good value", %{clock: _clock} do
      L.set_row!("3600")
      assert ttl() == 3600
      assert :ok = Nebu.OAuth.invalidate_config_cache()
      break_repo!()
      assert ttl_while_broken() == 3600
    end
  end

  describe "the :no_repo branch answers last-known-good too (cycle 2, Kassandra delta LOW #2)" do
    test "saved 3600 seen, then no repository process at all (a Repo restart): 3600, also with a longer env value", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      assert ttl() == 3600

      L.put_env_ttl!(14_400)
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.NoSuchRepoAtdd)
      assert Process.whereis(Nebu.NoSuchRepoAtdd) == nil
      assert ttl() == 3600
    end

    test "nothing ever loaded + no repository process: the env value / 8 hours", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.NoSuchRepoAtdd)
      assert ttl() == 28_800
      L.put_env_ttl!(600)
      assert ttl() == 600
    end

    test "the OAuth switch stays what it was without a repository (disabled, fail closed): only the lifetime is sticky", %{clock: _clock} do
      cache_ms(0)
      L.set_row!("3600")
      assert ttl() == 3600
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.NoSuchRepoAtdd)
      assert %{enabled: false, state: :disabled, matrix_session_ttl_seconds: 3600} = Nebu.OAuth.Config.get()
    end
  end

  # ── the worker: is a legacy row 2 hours old a candidate? ───────────────────

  # `last_good: true`: the lifetime 3600 was read before the read fails; false: nothing was ever read. Returns whether the worker redeemed the row at the IdP.
  defp worker_row_is_candidate?(opts) do
    cache_ms(0)
    test_pid = self()
    T.setup_idp!()
    user_id = T.provision_user!()
    rt = "idp-rt-lg-" <> T.rand(6)
    s = T.legacy_session!(user_id, "LGWORKER" <> T.rand(3), expires_at: DateTime.add(DateTime.utc_now(), 600, :second), oidc_refresh_token: Nebu.Web.SecretBox.encrypt(rt))

    T.sql!("UPDATE matrix_sessions SET created_at = now() - interval '2 hours', expires_at = now() + interval '10 minutes' WHERE access_token_hash = $1", [T.token_hash(s.at)])

    T.put_env_scoped(:matrix_refresh_worker_lookahead_seconds, 3600)

    T.put_env_scoped(:matrix_oidc_refresh_override, fn decrypted ->
      send(test_pid, {:idp_called, decrypted})
      {:error, {:transient_check_failed, :atdd}}
    end)

    L.set_row!("3600")
    if Keyword.fetch!(opts, :last_good), do: assert(ttl() == 3600)
    break_repo!()

    _ = stop_supervised(Nebu.Matrix.Session.RefreshWorker)
    pid = start_supervised!(Nebu.Matrix.Session.RefreshWorker)
    with_log(fn ->
      send(pid, :refresh)
      :sys.get_state(pid)
    end)

    receive do
      {:idp_called, ^rt} -> true
    after
      300 -> false
    end
  end
end
