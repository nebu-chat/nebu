defmodule Nebu.Media.ConfigTolerantLoaderTest do
  @moduledoc """
  Acceptance tests (red phase) for story `media-config-tolerant-loader` (follow-up `ej`), AC1 - AC6: ONE damaged `media_config` row must affect only
  that one setting, never reset every media setting to its default.

  Today the loader decodes every row inline with `String.to_integer/1`; one row such as `deleted_days = 'abc'` raises inside the `Map.new/2`, the
  loader's own rescue answers `%{}` and `get/0` shows ALL fifteen defaults (an empty `mime_denylist` too: the denylist is OFF), and a binary that reaches
  `build_catalog/1` through a seam crashes the cache holder. The story decodes per row (D1/D2), skips a damaged row (its default is used), logs the key
  and never the value (D3), and exposes the damaged keys through the new `Nebu.Media.Config.damaged_keys/0` (D4).

  ## Part 1 (no database): the seams

  `:media_config_loader` (0-arity fun, STRING-keyed map: what the cache refresh reads) and `:media_config_source` (0-arity fun, what `get/0` reads
  directly). The decode is idempotent on valid typed values, so the seams may carry strings (the stored TEXT form) or typed values.

  ## Part 2 (`:integration`, real PostgreSQL, no seam)

  Rows seeded with `Nebu.OAuth.TestSupport.privileged_sql!/2` (FORCE RLS), the real `Nebu.Compliance.AuditWriter`, cleanup in `on_exit`.

  ## Red-phase notes

  `damaged_keys/0` does not exist yet: it is called through `apply/3` (`damaged/0` below) so that the failure is an `UndefinedFunctionError` of THAT
  test at run time and the file still compiles (also under `--warnings-as-errors`). The cache holder is the application's supervised
  `Nebu.Media.Config`; every test starts and ends with a refresh over an empty loader so that no damaged set leaks from one test to the next.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Media.Config
  alias Nebu.OAuth.TestSupport, as: T

  # the eleven plain non-negative integer keys of the catalogue (deleted_days / infected_days are additionally bounded by 3650)
  @int_keys ~w(max_upload_size_bytes max_file_size_bytes max_pending_per_user max_stall_ms deleted_days infected_days orphaned_hours
               clamav_down_alert_minutes signature_stale_alert_hours backlog_depth_alert_threshold scan_failed_rate_alert_pct)

  setup do
    clear_seams()
    ensure_started()
    reset_cache()

    on_exit(fn ->
      clear_seams()
      ensure_started()
      safe_refresh()
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp clear_seams do
    for k <- [:media_config_loader, :media_config_source, :media_config_writer, :media_config_tx], do: Application.delete_env(:nebu_http, k)
  end

  defp ensure_started do
    case Config.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      _other -> :ok
    end
  end

  defp safe_refresh do
    Config.refresh()
  catch
    :exit, _ -> :ok
  end

  # an empty loader: the cache holds the plain defaults and the "previous damaged set" of the refresh log is empty
  defp reset_cache do
    loader_map(%{})
    :ok = Config.refresh()
    clear_seams()
  end

  defp loader(fun) when is_function(fun, 0), do: Application.put_env(:nebu_http, :media_config_loader, fun)
  defp loader_map(map), do: loader(fn -> map end)
  defp source_map(map), do: Application.put_env(:nebu_http, :media_config_source, fn -> map end)

  # `Config.damaged_keys/0` called dynamically (see the moduledoc: red phase without a compile abort)
  defp damaged, do: apply(Config, :damaged_keys, [])

  defp holder, do: Process.whereis(Config)

  # a refresh that crashes the cache holder (today: ArgumentError of String.to_integer in build_catalog) is a failure of the test, not an exit of it
  defp refresh! do
    Config.refresh()
  catch
    :exit, reason -> flunk("Config.refresh/0 crashed the cache holder: #{inspect(reason, limit: 8)}")
  end

  defp defaults do
    loader_map(%{})
    refresh!()
    clear_seams()
    Config.get()
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1 - per-row tolerance (loader seam)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1 per-row tolerance (loader seam)" do
    test "one damaged row falls back to its own default, every other row keeps its value, the damaged key is reported" do
      default = defaults()
      pid = holder()

      loader_map(%{
        "deleted_days" => "abc",
        "mime_denylist" => "application/x-msdownload",
        "max_upload_size_bytes" => "1000",
        "infected_days" => 3
      })

      assert :ok = refresh!()
      cfg = Config.get()

      assert cfg.deleted_days == default.deleted_days, "the damaged row uses ITS default"
      assert cfg.mime_denylist == "application/x-msdownload", "the other rows are not masked as defaults (the denylist stays ON)"
      assert cfg.max_upload_size_bytes == 1000
      assert cfg.infected_days == 3
      assert map_size(cfg) == 15, "get/0 keeps its shape: 15 atom keys"
      assert damaged() == ["deleted_days"]
      assert holder() == pid, "the cache holder was not restarted"
    end

    test "damaged_keys/0 is empty when every stored row is readable (and for unknown keys, which are ignored, never reported)" do
      loader_map(%{"deleted_days" => "12", "max_stall_ms" => 5000, "some_future_key" => "whatever", "another" => 7})
      assert :ok = refresh!()

      assert Config.get().deleted_days == 12
      assert Config.get().max_stall_ms == 5000
      assert damaged() == []
    end

    test "the damaged keys are sorted, string keys of the catalogue, and never carry a value" do
      loader_map(%{"orphaned_hours" => "x", "deleted_days" => "y", "max_stall_ms" => "z", "scan_failed_rate_alert_pct" => "w"})
      assert :ok = refresh!()

      assert damaged() == ["deleted_days", "max_stall_ms", "orphaned_hours", "scan_failed_rate_alert_pct"]
    end

    test "a refresh that finds the row readable again drops the key from damaged_keys/0 and uses the stored value" do
      loader_map(%{"deleted_days" => "abc"})
      assert :ok = refresh!()
      assert damaged() == ["deleted_days"]

      loader_map(%{"deleted_days" => "45"})
      assert :ok = refresh!()
      assert damaged() == []
      assert Config.get().deleted_days == 45
    end

    test "a failed whole-table read (the loader raises or answers no map) keeps the previous damaged set and is no recovery: no 'readable again' line" do
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)

      loader_map(%{"deleted_days" => "abc"})
      assert :ok = refresh!()
      assert damaged() == ["deleted_days"]

      for {label, failing} <- [raise: fn -> raise "db down" end, error_atom: fn -> :error end, error_tuple: fn -> {:error, :timeout} end, list: fn -> [] end] do
        loader(failing)

        log = capture_log([level: :info], fn -> assert :ok = refresh!() end)

        refute log =~ "readable again", "#{label}: an unreadable table is not a recovery"
        refute log =~ "deleted_days", "#{label}: no line about the key"
        assert damaged() == ["deleted_days"], "#{label}: the previous damaged set is kept"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC2 - what is damaged (table-driven, loader seam)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC2 damaged forms (loader seam, table-driven)" do
    @damaged_forms [
      "abc",
      "-5",
      " 12",
      "12 ",
      "12\n",
      "1e3",
      "1.5",
      "+5",
      "0x10",
      "\u0663",
      "",
      nil,
      1.5,
      -1,
      :forever,
      String.duplicate("9", 19),
      String.duplicate("9", 30)
    ]

    test "every damaged form of a plain integer key (max_stall_ms) is skipped: the default in get/0, the key in damaged_keys/0" do
      default = defaults().max_stall_ms

      for form <- @damaged_forms do
        loader_map(%{"max_stall_ms" => form})
        assert :ok = refresh!()
        assert Config.get().max_stall_ms == default, "max_stall_ms = #{inspect(form)}: default expected"
        assert damaged() == ["max_stall_ms"], "max_stall_ms = #{inspect(form)}: key expected in damaged_keys/0"
      end
    end

    test "every one of the eleven integer keys: a damaged value is skipped for THAT key only" do
      default = defaults()
      loader_map(Map.new(@int_keys, &{&1, "abc"}))
      assert :ok = refresh!()

      assert Config.get() == default
      assert damaged() == Enum.sort(@int_keys)
    end

    test "valid forms are accepted: plain digits (leading zeros too), a non-negative integer, 18 digits" do
      for {form, expected} <- [{"0", 0}, {"007", 7}, {0, 0}, {"3651", 3651}, {3651, 3651}, {"999999999999999999", 999_999_999_999_999_999}] do
        loader_map(%{"max_stall_ms" => form})
        assert :ok = refresh!()
        assert Config.get().max_stall_ms == expected, "max_stall_ms = #{inspect(form)}"
        assert damaged() == [], "max_stall_ms = #{inspect(form)} is not damaged"
      end
    end

    test "deleted_days / infected_days: 0 and 3650 are valid, 3651 and above are damaged (exactly the range retention_days/0 accepts)" do
      for key <- ["deleted_days", "infected_days"] do
        default = Map.fetch!(defaults(), String.to_atom(key))

        for {form, expected} <- [{"0", 0}, {0, 0}, {"3650", 3650}, {3650, 3650}] do
          loader_map(%{key => form})
          assert :ok = refresh!()
          assert Map.fetch!(Config.get(), String.to_atom(key)) == expected, "#{key} = #{inspect(form)}"
          assert damaged() == [], "#{key} = #{inspect(form)}"
        end

        for form <- ["3651", 3651, "99999", 1_000_000] do
          loader_map(%{key => form})
          assert :ok = refresh!()
          assert Map.fetch!(Config.get(), String.to_atom(key)) == default, "#{key} = #{inspect(form)}"
          assert damaged() == [key], "#{key} = #{inspect(form)}"
        end
      end
    end

    test "released_delete_after_days: nil and the empty string mean off (nil, not damaged), a number is kept, anything else is damaged" do
      for form <- ["", nil] do
        loader_map(%{"released_delete_after_days" => form})
        assert :ok = refresh!()
        assert Config.get().released_delete_after_days == nil, "released_delete_after_days = #{inspect(form)}"
        assert damaged() == [], "released_delete_after_days = #{inspect(form)} is not damaged"
      end

      for {form, expected} <- [{"14", 14}, {14, 14}, {"0", 0}] do
        loader_map(%{"released_delete_after_days" => form})
        assert :ok = refresh!()
        assert Config.get().released_delete_after_days == expected
        assert damaged() == []
      end

      for form <- ["x", "-1", " 5", "1.5", 1.5, -1] do
        loader_map(%{"released_delete_after_days" => form})
        assert :ok = refresh!()
        assert Config.get().released_delete_after_days == nil, "released_delete_after_days = #{inspect(form)}: its default (off)"
        assert damaged() == ["released_delete_after_days"], "released_delete_after_days = #{inspect(form)}"
      end
    end

    test "webhook_url, mime_denylist and scan_kill_switch are plain strings: never damaged by this story; unknown keys are ignored, never reported" do
      loader_map(%{
        "webhook_url" => "",
        "mime_denylist" => "application/x-msdownload, not a valid token ;;",
        "scan_kill_switch" => "fail_open",
        "some_future_key" => "x"
      })

      assert :ok = refresh!()
      cfg = Config.get()

      assert cfg.webhook_url == nil, "the stored empty string of webhook_url means unset (nil), on every source"
      assert cfg.mime_denylist == "application/x-msdownload, not a valid token ;;"
      assert cfg.scan_kill_switch == "fail_open"
      assert map_size(cfg) == 15
      assert damaged() == []

      loader_map(%{"webhook_url" => "https://example.com/hook"})
      assert :ok = refresh!()
      assert Config.get().webhook_url == "https://example.com/hook"
    end

    test "a typed negative integer used to be accepted by the cache: it is now damaged (fail-safe reading of D2)" do
      default = defaults()
      loader_map(%{"orphaned_hours" => -3})
      assert :ok = refresh!()

      assert Config.get().orphaned_hours == default.orphaned_hours
      assert damaged() == ["orphaned_hours"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC3 - nothing raises (source seam, loader seam, the GenServer paths)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC3 no raise in build_catalog" do
    test "the source seam with a damaged binary: get/0 answers the default (no raise), damaged_keys/0 is computed from the source map" do
      default = defaults()
      source_map(%{"max_stall_ms" => "abc"})

      assert Config.get().max_stall_ms == default.max_stall_ms
      assert damaged() == ["max_stall_ms"]
    end

    test "the source seam keeps every other value; valid binaries are decoded, a map without damage reports nothing" do
      defaults_deleted_days = defaults().deleted_days
      source_map(%{"max_stall_ms" => "5000", "deleted_days" => "12", "mime_denylist" => "application/x-evil"})

      cfg = Config.get()
      assert cfg.max_stall_ms == 5000
      assert cfg.deleted_days == 12
      assert cfg.mime_denylist == "application/x-evil"
      assert damaged() == []

      source_map(%{"deleted_days" => "oops", "scan_failed_rate_alert_pct" => "?", "max_stall_ms" => "7"})
      assert Config.get().max_stall_ms == 7
      assert Config.get().deleted_days == defaults_deleted_days
      assert damaged() == ["deleted_days", "scan_failed_rate_alert_pct"]
    end

    test "the source seam: an answer that is no map (nil, a list, :error) still gives the defaults and an empty damaged list" do
      default = defaults()

      for answer <- [nil, [], [{"max_stall_ms", "abc"}], :error, "abc"] do
        Application.put_env(:nebu_http, :media_config_source, fn -> answer end)

        assert Config.get() == default, "source answers #{inspect(answer)}"
        assert damaged() == [], "source answers #{inspect(answer)}"
      end
    end

    test "init/1 survives a damaged row: a restarted cache holder starts, serves the default, logs the key once, and damaged_keys/0 works while it is down" do
      old = holder()
      assert is_pid(old)
      default = defaults()

      :ok = Supervisor.terminate_child(Nebu.Media.Config.Supervisor, Config)
      on_exit(fn -> ensure_started() end)
      assert holder() == nil, "the cache holder is down"

      loader_map(%{"deleted_days" => "abc", "max_stall_ms" => "9000"})
      assert damaged() == ["deleted_days"], "without a running cache it is computed from a fresh load"
      assert Config.get().deleted_days == default.deleted_days
      assert Config.get().max_stall_ms == 9000

      log = capture_log(fn -> assert {:ok, _pid} = Config.start_link([]) end)

      new = holder()
      assert is_pid(new) and new != old, "init/1 did not crash: a new holder runs"
      assert [line] = lines_naming(log, "deleted_days")
      assert line =~ "[warning]"
      refute log =~ "abc"
      refute log =~ "ArgumentError"
      assert Config.get().deleted_days == default.deleted_days
      assert Config.get().max_stall_ms == 9000
      assert damaged() == ["deleted_days"]
    end

    test "a loader seam with binary values does not crash the cache holder: refresh/0, the invalidation and the TTL tick keep the same pid" do
      default = defaults()
      pid = holder()
      loader_map(%{"max_stall_ms" => "abc", "deleted_days" => "1e3", "orphaned_hours" => "6"})

      assert :ok = refresh!()
      assert holder() == pid

      send(pid, {:invalidate_media_config})
      :sys.get_state(pid)
      assert holder() == pid, "the peer invalidation re-read survives a damaged binary"

      send(pid, :ttl_tick)
      :sys.get_state(pid)
      assert holder() == pid, "the TTL tick re-read survives a damaged binary"
      assert Process.alive?(pid)

      cfg = Config.get()
      assert cfg.max_stall_ms == default.max_stall_ms
      assert cfg.deleted_days == default.deleted_days
      assert cfg.orphaned_hours == 6
      assert damaged() == ["deleted_days", "max_stall_ms"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 - logging: the key, never the value; only when the damaged set changes
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4 logging (loader seam, capture_log)" do
    @secret "secret-ish-value-123"

    setup do
      # the test config logs at :warning; the "readable again" line is an info line
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)
      :ok
    end

    defp log_of(fun), do: capture_log([level: :info], fun)
    defp lines_naming(log, key), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ key))

    test "a damaged row logs exactly one warning naming the key and none of the stored values" do
      loader_map(%{"deleted_days" => @secret, "max_upload_size_bytes" => "777001", "mime_denylist" => "application/x-quarantine-secret"})

      log = log_of(fn -> assert :ok = refresh!() end)

      assert [line] = lines_naming(log, "deleted_days")
      assert line =~ "[warning]", "the damaged row is a WARNING"
      assert length(Enum.filter(String.split(log, "\n"), &(&1 =~ "Nebu.Media.Config" and &1 =~ "[warning]"))) == 1,
             "exactly one warning line of Nebu.Media.Config, got: #{log}"
      refute log =~ @secret
      refute log =~ "777001", "no other stored value either"
      refute log =~ "x-quarantine-secret"
      refute log =~ "ArgumentError", "the decode exception is not inspected into the log"
    end

    test "a second refresh with the same damaged set logs nothing new about it (no line per key per node every 60 seconds)" do
      loader_map(%{"deleted_days" => @secret})
      _first = log_of(fn -> assert :ok = refresh!() end)

      second = log_of(fn -> assert :ok = refresh!() end)
      refute second =~ "deleted_days", "unchanged damaged set: silent, got: #{second}"
      refute second =~ @secret

      third =
        log_of(fn ->
          send(holder(), {:invalidate_media_config})
          :sys.get_state(holder())
        end)

      refute third =~ "deleted_days", "the peer invalidation re-read is silent for an unchanged damaged set"
    end

    test "a newly damaged key is logged by itself; the key that was already known stays silent" do
      loader_map(%{"deleted_days" => @secret})
      _first = log_of(fn -> assert :ok = refresh!() end)

      loader_map(%{"deleted_days" => @secret, "max_stall_ms" => "second-secret-456"})
      log = log_of(fn -> assert :ok = refresh!() end)

      assert log =~ "max_stall_ms"
      refute log =~ "deleted_days", "only the CHANGE is logged"
      refute log =~ "second-secret-456"
      refute log =~ @secret
    end

    test "a refresh after the row became valid logs one line naming the key, again without a value" do
      loader_map(%{"deleted_days" => @secret})
      _first = log_of(fn -> assert :ok = refresh!() end)

      # 2741, not 7741: deleted_days is damaged above 3650 (D2), so 7741 would not be a recovery
      loader_map(%{"deleted_days" => "2741"})
      log = log_of(fn -> assert :ok = refresh!() end)

      assert [line] = lines_naming(log, "deleted_days")
      assert line =~ "[info]"
      refute log =~ "2741"
      refute log =~ @secret

      again = log_of(fn -> assert :ok = refresh!() end)
      refute again =~ "deleted_days", "recovered and unchanged: silent"
    end

    test "the existing catch-all lines of the loader stay value-free for a damaged row: no inspect of an exception, no 'loader raised' text" do
      loader_map(%{"infected_days" => @secret, "orphaned_hours" => "also-secret-789"})

      log = log_of(fn -> assert :ok = refresh!() end)

      refute log =~ "loader raised"
      refute log =~ "unexpected error loading media_config"
      refute log =~ @secret
      refute log =~ "also-secret-789"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # code review cycle 1 (M2): the writer's bound is exactly what the tolerant decode reads back
  # ═══════════════════════════════════════════════════════════════════════════

  describe "writer / reader bound symmetry (code review M2)" do
    @int_max 999_999_999_999_999_999

    test "a value above 18 digits is refused on write for every plain integer key and for released_delete_after_days, before any DB call" do
      for key <- ["max_stall_ms", "max_upload_size_bytes", "orphaned_hours", "scan_failed_rate_alert_pct", "released_delete_after_days"] do
        assert {:error, :invalid_value} == Config.upsert(key, @int_max + 1), "#{key} = 10^18"
        assert {:error, :invalid_value} == Config.upsert(key, @int_max * 1000), "#{key} = huge"
      end
    end

    test "the largest accepted value is read back as that value, never as damaged (seam: the stored TEXT form of the writer)" do
      for key <- ["max_stall_ms", "released_delete_after_days"] do
        loader_map(%{key => Integer.to_string(@int_max)})
        assert :ok = refresh!()

        assert Map.fetch!(Config.get(), String.to_atom(key)) == @int_max
        assert damaged() == []
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 / AC6 - real media_config rows (integration, no seam)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "real media_config rows (integration)" do
    @describetag :integration

    @actor "@tolerant-loader-admin:test.local"
    @keys ["deleted_days", "infected_days", "mime_denylist", "max_pending_per_user", "max_stall_ms"]

    setup do
      prior = T.privileged_sql!("SELECT key, value, set_at FROM media_config WHERE key = ANY($1)", [@keys]).rows
      T.privileged_sql!("DELETE FROM media_config WHERE key = ANY($1)", [@keys])
      T.privileged_sql!("DELETE FROM audit_log WHERE action = 'media_config_updated' AND target_id = ANY($1)", [@keys])

      # the real database path: no loader / source / writer seam, the real audit writer
      clear_seams()
      Application.delete_env(:compliance, :repo)
      ensure_started()
      :ok = Config.refresh()

      on_exit(fn ->
        clear_seams()
        Application.delete_env(:compliance, :repo)
        T.privileged_sql!("DELETE FROM media_config WHERE key = ANY($1)", [@keys])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
        T.privileged_sql!("DELETE FROM audit_log WHERE action = 'media_config_updated' AND target_id = ANY($1)", [@keys])
        ensure_started()
        safe_refresh()
      end)

      :ok
    end

    defp seed(key, value), do: T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, 1)", [key, value])
    defp stored(key), do: T.privileged_sql!("SELECT value FROM media_config WHERE key = $1", [key]).rows |> List.first() |> List.wrap() |> List.first()

    defp audit_rows(key),
      do: T.privileged_sql!("SELECT actor_user_id, target_type, metadata FROM audit_log WHERE action = 'media_config_updated' AND target_id = $1 ORDER BY id", [key]).rows

    test "AC5 a damaged deleted_days row masks nothing else: the stored denylist and limit stay in effect, the key is reported, the cleanup stays paused" do
      default = defaults()
      seed("deleted_days", "abc")
      seed("mime_denylist", "application/x-msdownload")
      seed("max_pending_per_user", "5")

      log = capture_log(fn -> assert :ok = Config.refresh() end)
      cfg = Config.get()

      refute log =~ "abc", "the stored text of the damaged row is not logged"
      refute log =~ "ArgumentError"
      refute log =~ "unexpected error loading", "the loader's catch-all is not reached by a damaged row"
      assert cfg.deleted_days == default.deleted_days
      assert cfg.mime_denylist == "application/x-msdownload", "today the whole table is masked as defaults: the denylist is OFF"
      assert cfg.max_pending_per_user == 5
      assert damaged() == ["deleted_days"]
      assert Nebu.Media.mime_denylist_rejected?("application/x-msdownload"), "the security-relevant setting is still enforced"
      assert Config.retention_days() == {:error, :invalid}, "the strict read of the cleanup worker is unchanged: it still refuses"
      assert stored("deleted_days") == "abc", "nothing is repaired on read"
    end

    test "AC5 several damaged rows and a healthy one: every damaged key is reported, the healthy row keeps its value" do
      default = defaults()
      seed("max_stall_ms", "9 ")
      seed("infected_days", "3651")
      seed("max_pending_per_user", "007")

      log = capture_log(fn -> assert :ok = Config.refresh() end)

      refute log =~ "unexpected error loading"
      assert Config.get().max_pending_per_user == 7
      assert Config.get().max_stall_ms == default.max_stall_ms
      assert Config.get().infected_days == default.infected_days
      assert damaged() == ["infected_days", "max_stall_ms"]
      assert Config.retention_days() == {:error, :invalid}
    end

    test "AC6 a plain save of the shown default repairs a damaged retention row: written, cache clean, audit old_value unknown and never the stored text" do
      seed("deleted_days", "abc")
      capture_log(fn -> assert :ok = Config.refresh() end)
      assert damaged() == ["deleted_days"]

      assert :ok = Config.upsert("deleted_days", 30, @actor)

      assert stored("deleted_days") == "30"
      assert damaged() == []
      assert {:ok, %{deleted_days: 30}} = Config.retention_days()

      assert [[@actor, "media_config", metadata]] = audit_rows("deleted_days")
      assert metadata["old_value"] == "unknown"
      assert metadata["new_value"] == 30
      refute inspect(metadata) =~ "abc", "the damaged stored text is never copied into an audit row"
    end

    test "AC6 repair of a damaged NON-retention key records old_value unknown, not the default it was masked by" do
      default = defaults()
      seed("max_stall_ms", "abc")
      capture_log(fn -> assert :ok = Config.refresh() end)
      assert damaged() == ["max_stall_ms"]

      assert :ok = Config.upsert("max_stall_ms", default.max_stall_ms, @actor)

      assert stored("max_stall_ms") == to_string(default.max_stall_ms)
      assert damaged() == []

      assert [[@actor, "media_config", metadata]] = audit_rows("max_stall_ms")
      assert metadata["old_value"] == "unknown", "the old value of a damaged row is unknown, not the default #{default.max_stall_ms}"
      assert metadata["new_value"] == default.max_stall_ms
      refute inspect(metadata) =~ "abc"
    end

    test "code review M2: the largest value the writer accepts is stored and read back, not reported as damaged right after the save" do
      assert :ok = Config.upsert("max_stall_ms", @int_max, @actor)

      assert stored("max_stall_ms") == Integer.to_string(@int_max)
      assert Config.get().max_stall_ms == @int_max
      assert damaged() == []
    end

    test "code review M3: while the table cannot be read at all (loader answers no map) the audit old_value is unknown, not the default" do
      loader(fn -> :error end)

      assert :ok = Config.upsert("max_stall_ms", 4321, @actor)

      assert stored("max_stall_ms") == "4321"
      assert [[@actor, "media_config", metadata]] = audit_rows("max_stall_ms")
      assert metadata["old_value"] == "unknown"
      assert metadata["new_value"] == 4321
    end

    test "AC6 the audit old_value of a healthy key next to a damaged one is that key's own stored value, not the default" do
      seed("max_stall_ms", "abc")
      seed("max_pending_per_user", "5")
      capture_log(fn -> assert :ok = Config.refresh() end)

      assert :ok = Config.upsert("max_pending_per_user", 6, @actor)

      assert [[@actor, "media_config", %{"old_value" => 5, "new_value" => 6}]] = audit_rows("max_pending_per_user")
      assert stored("max_stall_ms") == "abc", "an unrelated save never rewrites the damaged row"
      assert damaged() == ["max_stall_ms"]
    end
  end
end
