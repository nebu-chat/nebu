defmodule Nebu.Workers.ClientIPCheckWorkerTest do
  @moduledoc """
  RED-phase acceptance tests for story `client-ip-misconfiguration-warnings` (epic oauth-broker, SEC gate 3 G3-2),
  W2 (D2) and the static guards of AC13 / AC14: the periodic collapsed-client-address check.

    * AC9  - `Nebu.Workers.ClientIPCheckWorker.assess/1` (pure decision table, no DB)
    * AC10 - `Nebu.Matrix.device_address_spread/1` against the real database (`@tag :integration`)
    * AC11 - the worker end to end (`perform/1`, clock seam, log text, counts only)
    * AC12 - the error path (spread seam, SQLSTATE-only log, `{:error, _}`, never raises)
    * AC13 - static wiring (Oban cron entry, `__opts__/0`, ADR-020 facade, SQL shape, statement timeout)
    * AC14 - no migration, no new env variable, only the three compile-guarded test seams

  ## Contract the implementation MUST honour (exact names)

    * `Nebu.Workers.ClientIPCheckWorker` (`use Oban.Worker, queue: :oauth_cleanup, max_attempts: 1`) with
      `perform/1` (`%Oban.Job{}` -> `:ok | {:error, reason}`) and `assess/1` (`@doc false`, public).
    * `Nebu.Matrix.device_address_spread(since_ms)` -> `{:ok, %{devices: n, users: u, addresses: a}} | {:error, reason}`
      (delegates to `Nebu.Matrix.DeviceKeyStore.address_spread/1`).
    * Test seams, read ONLY when `Mix.env() == :test` (compile-guarded) from `Application.get_env(:nebu_http, key)`:
      `:client_ip_check_now_ms_fn` (zero-arity, replaces `System.system_time(:millisecond)`) and
      `:client_ip_check_spread_fn` (one-arity `since_ms`, replaces the call to `Nebu.Matrix.device_address_spread/1`).
    * Log lines (WARNING, exact texts in the tests below) and the Logger metadata key `oauth_offered` (D11).

  `async: false`: seams are global application env. Oban is not started in the test env, so `perform/1` is called
  directly (pattern: `oauth_code_store_test.exs` "AC11 purge worker wiring"). DB fixtures are timestamped 10 years in
  the FUTURE (no sandbox in this suite): only they can fall into the window, whatever else is in the shared test DB.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @lib Path.expand("../../../lib", __DIR__)
  @day_ms 86_400_000
  @now_seam :client_ip_check_now_ms_fn
  @spread_seam :client_ip_check_spread_fn

  # Resolved at runtime so the file compiles warning-free before the module exists (red phase).
  defp worker, do: Module.concat(["Nebu.Workers.ClientIPCheckWorker"])
  defp assess(map), do: apply(worker(), :assess, [map])
  defp perform, do: apply(worker(), :perform, [%Oban.Job{args: %{}}])
  defp spread(since_ms), do: apply(Nebu.Matrix, :device_address_spread, [since_ms])

  defp read_lib(rel), do: File.read!(Path.join(@lib, rel))

  # Source scans look at CODE only: @moduledoc / @doc heredocs and comments are dropped (test review m3).
  defp code_lib(rel) do
    rel
    |> read_lib()
    |> String.replace(~r/@(?:moduledoc|doc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s, "")
    |> String.replace(~r/^\s*#[^\n]*$/m, "")
    |> String.replace(~r/\s#(?!\{)\s[^\n]*$/m, "")
  end

  # body of one function: from its `def` line to the next def / defp / @doc / @spec at the same indent
  defp code_lib_text(src) do
    src
    |> String.replace(~r/@(?:moduledoc|doc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s, "")
    |> String.replace(~r/^\s*#[^\n]*$/m, "")
  end

  defp fun_body(src, head) do
    assert src =~ head, "#{head} not found"
    [_, rest] = String.split(src, head, parts: 2)
    rest |> String.split(~r/\n  (?:(?:def|defp)\s+(?!address_spread\b)|@doc\b|@spec\b|@moduledoc\b)/, parts: 2) |> hd()
  end

  defp put_seam(key, fun) do
    previous = Application.fetch_env(:nebu_http, key)
    Application.put_env(:nebu_http, key, fun)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:nebu_http, key, v)
        :error -> Application.delete_env(:nebu_http, key)
      end
    end)
  end

  # T: ten years in the future, in epoch milliseconds
  defp far_future_ms, do: System.system_time(:millisecond) + 10 * 365 * @day_ms

  defp occurrences(log, needle), do: length(String.split(log, needle)) - 1

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 - assess/1
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9 - assess/1 decision table (10 devices, 5 users, at most 2 addresses)" do
    for {label, input, expected} <- [
          {"10 devices / 5 users / 1 address", %{devices: 10, users: 5, addresses: 1}, :collapsed},
          {"10 devices / 5 users / 2 addresses (two LB nodes)", %{devices: 10, users: 5, addresses: 2}, :collapsed},
          {"9 devices (one below the device threshold)", %{devices: 9, users: 5, addresses: 1}, :ok},
          {"4 users (one below the user threshold)", %{devices: 10, users: 4, addresses: 1}, :ok},
          {"3 addresses (real spread)", %{devices: 10, users: 5, addresses: 3}, :ok},
          {"0 addresses (no data)", %{devices: 0, users: 0, addresses: 0}, :ok},
          {"0 addresses with large counts is still :ok (cannot be a collapse)", %{devices: 10, users: 5, addresses: 0}, :ok},
          {"1000 devices / 300 users / 2 addresses", %{devices: 1000, users: 300, addresses: 2}, :collapsed},
          {"1000 devices / 300 users / 3 addresses", %{devices: 1000, users: 300, addresses: 3}, :ok}
        ] do
      test "#{label} -> #{inspect(expected)}" do
        assert assess(unquote(Macro.escape(input))) == unquote(expected)
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 - Nebu.Matrix.device_address_spread/1 (database)
  # ════════════════════════════════════════════════════════════════════════════

  # Inserts `devices` rows: `specs` is a list of {user_n, device_n, last_seen_ts, last_seen_ip}.
  defp insert_devices!(prefix, specs) do
    for {user_n, device_n, ts, ip} <- specs do
      T.sql!(
        "INSERT INTO devices (user_id, device_id, last_seen_ts, last_seen_ip, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $5)",
        ["@#{prefix}-#{user_n}:test", "D#{device_n}", ts, ip, 1_700_000_000_000]
      )
    end

    :ok
  end

  defp cleanup_devices!(prefix), do: T.sql!("DELETE FROM devices WHERE user_id LIKE $1", ["@#{prefix}-%"])

  # no sandbox in this suite: stale fixture rows of an aborted earlier run (far-future timestamps!) must not survive
  defp preclean_devices!, do: T.sql!("DELETE FROM devices WHERE user_id LIKE '@cipw%'", [])

  defp unique_prefix, do: "cipw" <> T.rand(6)

  # 5 users x 2 devices, every device seen one hour before `t_ms`, every address given by `ip_fun.(user_n, device_n)`
  defp collapse_fixture!(prefix, t_ms, ip_fun) do
    insert_devices!(prefix, for(u <- 1..5, d <- 1..2, do: {u, d, t_ms - 3_600_000, ip_fun.(u, d)}))
  end

  describe "AC10 - Nebu.Matrix.device_address_spread/1" do
    @describetag :integration

    setup do
      preclean_devices!()
      prefix = unique_prefix()
      on_exit(fn -> cleanup_devices!(prefix) end)
      {:ok, prefix: prefix, t: far_future_ms()}
    end

    test "returns the exact counts (devices, users, addresses) and exactly these three keys, never an address", %{prefix: prefix, t: t} do
      collapse_fixture!(prefix, t, fn _u, _d -> "10.0.0.4" end)

      assert {:ok, %{} = result} = spread(t - @day_ms)
      assert result == %{devices: 10, users: 5, addresses: 1}
      assert result |> Map.keys() |> Enum.sort() == [:addresses, :devices, :users]
      refute inspect(result) =~ "10.0.0.4"
    end

    test "rows with a NULL or empty last_seen_ip and rows older than since_ms are not counted", %{prefix: prefix, t: t} do
      collapse_fixture!(prefix, t, fn _u, _d -> "10.0.0.4" end)

      insert_devices!(prefix, [
        {6, 1, t - 3_600_000, nil},
        {7, 1, t - 3_600_000, ""},
        {8, 1, t - 2 * @day_ms, "10.9.9.9"},
        {9, 1, nil, "10.9.9.8"}
      ])

      assert {:ok, %{devices: 10, users: 5, addresses: 1}} = spread(t - @day_ms)
    end

    test "the window is inclusive at since_ms and counts distinct users and distinct addresses", %{prefix: prefix, t: t} do
      since = t - @day_ms

      insert_devices!(prefix, [
        {1, 1, since, "10.0.0.4"},
        {1, 2, since + 1, "10.0.0.5"},
        {2, 1, since + 2, "10.0.0.4"},
        {2, 2, since - 1, "10.0.0.6"}
      ])

      assert {:ok, %{devices: 3, users: 2, addresses: 2}} = spread(since)
    end

    test "an empty window answers zeros, not an error", %{t: t} do
      assert {:ok, %{devices: 0, users: 0, addresses: 0}} = spread(t - @day_ms)
    end

    # Takes about 5 s. Safe: the module is async: false and the lock is held on a separate privileged connection only
    # while this one read runs; it is released in the `after` clause (also when the read raises).
    @tag :slow
    test "it runs under a 5 s statement timeout: a blocked devices table ends in query_canceled after about 5 s, never raises", %{t: t} do
      parent = self()

      locker =
        Task.async(fn ->
          T.with_privileged_conn(fn conn ->
            Postgrex.transaction(conn, fn c ->
              Postgrex.query!(c, "LOCK TABLE devices IN ACCESS EXCLUSIVE MODE", [])
              send(parent, :devices_locked)

              receive do
                :release -> :ok
              after
                30_000 -> :lock_holder_gave_up
              end
            end)
          end)
        end)

      assert_receive :devices_locked, 10_000

      started = System.monotonic_time(:millisecond)

      result =
        try do
          spread(t - @day_ms)
        after
          send(locker.pid, :release)
          Task.await(locker, 15_000)
        end

      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, reason} = result
      assert inspect(reason) =~ "query_canceled", "the statement timeout (SQLSTATE 57014) must end the read, got #{inspect(reason)}"
      assert elapsed >= 4_000 and elapsed < 9_000, "the bound is 5 s (SET LOCAL statement_timeout = '5s'), took #{elapsed} ms"
    end

    test "after the blocked read the table is usable again (the lock holder is gone)", %{prefix: prefix, t: t} do
      collapse_fixture!(prefix, t, fn _u, _d -> "10.0.0.4" end)
      assert {:ok, %{devices: 10}} = spread(t - @day_ms)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 - the worker end to end
  # ════════════════════════════════════════════════════════════════════════════

  defp collapsed_line_prefix(devices, users), do: "client IP: all #{devices} devices of #{users} users"

  describe "AC11 - perform/1 with the clock seam against the real database" do
    @describetag :integration

    setup do
      preclean_devices!()
      prefix = unique_prefix()
      t = far_future_ms()
      put_seam(@now_seam, fn -> t end)
      T.disable_oauth()

      on_exit(fn ->
        T.clear_oauth_config()
        cleanup_devices!(prefix)
      end)

      {:ok, prefix: prefix, t: t}
    end

    test "10 devices of 5 users on ONE address: :ok and exactly one WARNING with the counts, no address, oauth_offered=false", %{prefix: prefix, t: t} do
      collapse_fixture!(prefix, t, fn _u, _d -> "10.0.0.4" end)

      log = capture_log(fn -> assert perform() == :ok end)

      assert occurrences(log, "client IP:") == 1, "exactly one line expected, got: #{log}"
      assert log =~ ~r/\[warning\]\s+#{Regex.escape(collapsed_line_prefix(10, 5))}/
      assert log =~ "at most 1 client address(es)"
      assert log =~ "POSITIVE client-IP test"
      assert log =~ "single NAT"
      assert log =~ "oauth_offered=false"
      refute log =~ "10.0.0.4"
      refute log =~ "@cipw", "no user id of the fixtures"
      refute log =~ prefix
    end

    test "the same fixtures spread over 3 addresses: :ok and NO line", %{prefix: prefix, t: t} do
      collapse_fixture!(prefix, t, fn u, _d -> "10.0.0.#{rem(u, 3) + 4}" end)

      log = capture_log(fn -> assert perform() == :ok end)
      assert occurrences(log, "client IP:") == 0, "3 addresses are a real spread, got: #{log}"
    end

    test "two addresses (two LB nodes): one line with `at most 2`, neither address in the log", %{prefix: prefix, t: t} do
      collapse_fixture!(prefix, t, fn u, _d -> if rem(u, 2) == 0, do: "10.0.0.4", else: "10.0.0.5" end)

      log = capture_log(fn -> assert perform() == :ok end)

      assert occurrences(log, "client IP:") == 1, "got: #{log}"
      assert log =~ collapsed_line_prefix(10, 5)
      assert log =~ "at most 2 client address(es)"
      refute log =~ "10.0.0.4"
      refute log =~ "10.0.0.5"
      refute log =~ "@cipw", "no user id of the fixtures"
      refute log =~ prefix
    end

    test "below the thresholds (9 devices) nothing is logged", %{prefix: prefix, t: t} do
      insert_devices!(prefix, for(u <- 1..5, d <- 1..2, {u, d} != {5, 2}, do: {u, d, t - 3_600_000, "10.0.0.4"}))
      log = capture_log(fn -> assert perform() == :ok end)
      assert occurrences(log, "client IP:") == 0, "got: #{log}"
    end

    test "when OAuth is offered the line says oauth_offered=true (still a WARNING, never an error)", %{prefix: prefix, t: t} do
      T.enable_oauth()
      collapse_fixture!(prefix, t, fn _u, _d -> "10.0.0.4" end)

      log = capture_log(fn -> assert perform() == :ok end)
      assert log =~ "oauth_offered=true"
      assert log =~ "[warning]"
      refute log =~ "[error]"
      refute log =~ "10.0.0.4"
    end
  end

  describe "AC11/D11 - Logger metadata and window (no database, spread seam)" do
    setup do
      put_seam(@now_seam, fn -> 5_000_000_000_000 end)
      T.disable_oauth()
      on_exit(&T.clear_oauth_config/0)
      :ok
    end

    test "the WARNING carries oauth_offered as Logger metadata too (D11)" do
      put_seam(@spread_seam, fn _since -> {:ok, %{devices: 10, users: 5, addresses: 1}} end)

      log = capture_log([format: "$metadata\n", metadata: :all], fn -> assert perform() == :ok end)
      assert log =~ "oauth_offered=false"

      T.enable_oauth()
      log = capture_log([format: "$metadata\n", metadata: :all], fn -> assert perform() == :ok end)
      assert log =~ "oauth_offered=true"
    end

    test "the seam-based collapsed line is a WARNING with the counts and no address" do
      put_seam(@spread_seam, fn _since -> {:ok, %{devices: 10, users: 5, addresses: 2}} end)

      log = capture_log(fn -> assert perform() == :ok end)
      assert log =~ ~r/\[warning\]\s+#{Regex.escape(collapsed_line_prefix(10, 5))}/
      assert log =~ "at most 2 client address(es)"
      assert log =~ "oauth_offered=false"
      refute log =~ "[error]"
    end

    test "the spread is asked for the last 24 h: since_ms = now - 24 h, with the SAME clock as last_seen_ts (system time, ms)" do
      parent = self()
      put_seam(@spread_seam, fn since ->
        send(parent, {:since, since})
        {:ok, %{devices: 0, users: 0, addresses: 0}}
      end)

      log = capture_log(fn -> assert perform() == :ok end)
      assert_received {:since, since}
      assert since == 5_000_000_000_000 - @day_ms
      assert occurrences(log, "client IP:") == 0
    end

    test "the real clock is used when no seam is set: since_ms lies 24 h before the system time" do
      Application.delete_env(:nebu_http, @now_seam)
      parent = self()
      put_seam(@spread_seam, fn since ->
        send(parent, {:since, since})
        {:ok, %{devices: 0, users: 0, addresses: 0}}
      end)

      before = System.system_time(:millisecond)
      capture_log(fn -> assert perform() == :ok end)
      after_ms = System.system_time(:millisecond)

      assert_received {:since, since}
      assert since >= before - @day_ms and since <= after_ms - @day_ms
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 - error path
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12 - a failing read" do
    setup do
      put_seam(@now_seam, fn -> 5_000_000_000_000 end)
      :ok
    end

    test "query_canceled: {:error, _}, exactly ONE WARNING with the SQLSTATE only, never raises" do
      error = %Postgrex.Error{postgres: %{code: :query_canceled, message: "canceling statement due to statement timeout"}}
      put_seam(@spread_seam, fn _since -> {:error, error} end)

      log = capture_log(fn -> assert {:error, _} = perform() end)

      assert occurrences(log, "client IP:") == 1, "exactly one line expected, got: #{log}"
      assert log =~ ~r/\[warning\]\s+client IP: device address check failed: postgres query_canceled/
      refute log =~ "canceling statement", "only the SQLSTATE / struct name is logged, never the server message"
      refute log =~ "[error]"
    end

    test "the returned reason is the error of the read itself (no retry: max_attempts is 1, the next cron run is the retry)" do
      error = %Postgrex.Error{postgres: %{code: :query_canceled}}
      put_seam(@spread_seam, fn _since -> {:error, error} end)

      capture_log(fn -> send(self(), {:result, perform()}) end)
      assert_received {:result, {:error, ^error}}
    end

    test "a stopped repo ({:error, :repo_not_started}) is handled: {:error, :repo_not_started}, one WARNING, no raise" do
      put_seam(@spread_seam, fn _since -> {:error, :repo_not_started} end)

      log = capture_log(fn -> assert perform() == {:error, :repo_not_started} end)
      assert occurrences(log, "client IP: device address check failed:") == 1, "got: #{log}"
    end

    test "an exception struct reason logs only its struct name (log_reason/1 shape of OAuthFlowPurgeWorker)" do
      put_seam(@spread_seam, fn _since -> {:error, %RuntimeError{message: "secret row data 10.0.0.4"}} end)

      log = capture_log(fn -> assert {:error, _} = perform() end)
      assert log =~ "client IP: device address check failed: RuntimeError"
      refute log =~ "secret row data"
      refute log =~ "10.0.0.4"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC13 - static wiring
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC13 - static wiring" do
    test "the Oban cron crontab runs the worker every 6 hours at minute 37" do
      oban = Application.get_env(:nebu, Oban)
      {_plugin, cron_opts} = Enum.find(oban[:plugins], fn {mod, _} -> mod == Oban.Plugins.Cron end)
      assert {"37 */6 * * *", worker()} in cron_opts[:crontab]
    end

    test "no new queue: `queues:` is untouched and the worker uses oauth_cleanup with max_attempts 1" do
      assert Code.ensure_loaded?(worker()), "Nebu.Workers.ClientIPCheckWorker missing"
      opts = apply(worker(), :__opts__, [])
      assert to_string(opts[:queue]) == "oauth_cleanup"
      assert opts[:max_attempts] == 1

      queues = Application.get_env(:nebu, Oban)[:queues]
      assert Keyword.has_key?(queues, :oauth_cleanup)
      refute Keyword.has_key?(queues, :client_ip_check)
    end

    test "the worker reaches `devices` only through Nebu.Matrix.device_address_spread/1 (ADR-020), never DeviceKeyStore or SQL" do
      code = code_lib("nebu/workers/client_ip_check_worker.ex")
      refute code =~ "DeviceKeyStore"
      refute code =~ "Nebu.Repo"
      refute code =~ "SELECT"
      assert code =~ "Nebu.Matrix.device_address_spread("
      assert code =~ "Nebu.OAuth.oauth_aware?"
      assert code =~ "use Oban.Worker"
      assert code =~ ~r/queue:\s*:oauth_cleanup/
      assert code =~ ~r/max_attempts:\s*1\b/
    end

    test "Nebu.Matrix delegates device_address_spread/1 to DeviceKeyStore.address_spread/1" do
      src = read_lib("nebu/matrix.ex")
      assert src =~ ~r/defdelegate\s+device_address_spread\(since_ms\),\s*to:\s*Nebu\.Matrix\.DeviceKeyStore,\s*as:\s*:address_spread/
    end

    test "address_spread/1 never SELECTs an address (only count(DISTINCT last_seen_ip)) and runs under SET LOCAL statement_timeout" do
      src = read_lib("nebu/matrix/device_key_store.ex")
      assert src =~ "def address_spread(", "DeviceKeyStore.address_spread/1 missing"

      flat = String.replace(src, ~r/\s+/, " ")

      assert [_, select_list] =
               Regex.run(~r/SELECT (count\(\*\).*?) FROM devices WHERE last_seen_ts >= \$1/i, flat),
             "the address_spread SELECT (count(*), count(DISTINCT user_id), count(DISTINCT last_seen_ip) ... FROM devices WHERE last_seen_ts >= $1) not found"

      assert select_list == "count(*), count(DISTINCT user_id), count(DISTINCT last_seen_ip)"
      assert flat =~ ~r/last_seen_ip IS NOT NULL AND last_seen_ip <> ''/
      assert flat =~ "SET LOCAL statement_timeout = '5s'"
      assert flat =~ "Nebu.Repo.transaction"

      {set_at, _} = :binary.match(flat, "SET LOCAL statement_timeout")
      {select_at, _} = :binary.match(flat, "count(DISTINCT last_seen_ip)")
      assert set_at < select_at, "SET LOCAL must be the first statement of the transaction"

      # scoped to the function: `safe_query/2` elsewhere in the file already contains the atom
      body = src |> code_lib_text() |> fun_body("def address_spread(")
      assert body =~ ":repo_not_started", "address_spread/1 itself must map a stopped repo to {:error, :repo_not_started}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14 - no migration, no new env variable, only the three compile-guarded seams
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14 - nothing beyond the story" do
    test "no migration mentions this story's objects and `devices` gets no index on last_seen_ts / last_seen_ip" do
      dir = Path.expand("../../../priv/migrations", __DIR__)
      files = Path.wildcard(Path.join(dir, "*.sql"))
      assert length(files) > 50, "the scan sees the migrations"

      names = Enum.map(files, &Path.basename/1)
      assert Enum.filter(names, &(&1 =~ ~r/client_ip|address_spread|collapsed/i)) == []

      offenders =
        for f <- files, text = File.read!(f), text =~ ~r/CREATE\s+(UNIQUE\s+)?INDEX[^;]*ON\s+devices\s*\([^)]*last_seen/i, do: Path.basename(f)

      assert offenders == [], "an index on devices.last_seen_* would cost the hottest devices write its HOT updates: #{inspect(offenders)}"
    end

    test "the only :client_ip_*_fn atoms in lib are the three compile-guarded test seams, each next to Mix.env() == :test" do
      seams = [:client_ip_warn_clock_fn, @now_seam, @spread_seam]

      found =
        for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
            text = code_lib(Path.relative_to(path, @lib)),
            [atom] <- Regex.scan(~r/:client_ip_[a-z_]+/, text, capture: :first),
            do: {Path.relative_to(path, @lib), atom}

      atoms = found |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
      assert atoms == seams |> Enum.map(&inspect/1) |> Enum.sort(), "unexpected :client_ip_* atoms in lib: #{inspect(atoms)}"

      for rel <- found |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
        assert code_lib(rel) =~ "Mix.env() == :test", "#{rel} reads a seam outside a Mix.env() == :test guard"
      end
    end

    test "the worker and the W1 code read no environment variable and no server_config key" do
      for rel <- ["nebu/workers/client_ip_check_worker.ex", "nebu/web/client_ip.ex", "nebu/web/plugs/client_ip.ex"] do
        refute code_lib(rel) =~ "server_config", "#{rel} must not touch server_config"
      end

      refute code_lib("nebu/workers/client_ip_check_worker.ex") =~ "System.get_env"
    end
  end
end
