defmodule Nebu.Admin.LogsControllerTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/admin-logs-retention-settings`
  (Acceptance Tests 1, 3-15, 17, 18 from the story's "Acceptance Tests"
  section; AT2 — the nav link on the monitoring page — is covered by
  `describe "AT2"` at the bottom of this file since it targets
  `Nebu.Admin.LogsLive`, not this controller; AT16 is `:pending`, see below).

  Story: docs/stories/enhanced-logging/admin-logs-retention-settings.md
  Design decisions (read FIRST, resolves every naming/architecture ambiguity
  the story text leaves open):
  _bmad-output/nebu/epics/enhanced-logging/step-results/admin-logs-retention-settings/design-decisions.md

  ## Why these MUST FAIL right now

  `Nebu.Admin.LogsController` does not exist yet, the `/admin/logs/config`
  and `/admin/logs/config/retention` routes do not exist in `router.ex`, and
  the new `log_retention_info_max_count` server_config key is not yet in the
  `config_update_mutable` RLS allowlist (no migration for it exists yet).
  Every test below either fails with `UndefinedFunctionError`/404 (route
  missing) or fails a real assertion against the (as-yet-nonexistent)
  behavior.

  ## Real server_config keys used throughout (see design-decisions.md #1)

  `log_collect_info`, `log_retention_info_days`, `log_retention_info_max_count`
  (NEW — this story adds it), `log_collect_debug`, `log_retention_debug_days`,
  `log_retention_debug_max_count`. NOT the story's placeholder names
  (`info_enabled`, `debug_days`, etc.) — those are only the HTML *form field*
  names (see AC13's example JSON), mapped to the real keys by the controller.

  ## Auth gate reality check (see design-decisions.md — AC2 mandates REUSING
  `Nebu.Admin.Auth`'s existing `:require_admin` plug, verbatim, "same as the
  monitoring page"). That plug's real, already-shipped behavior (see
  `Nebu.Admin.Auth.require_admin/2`) does NOT distinguish "unauthenticated"
  from "authenticated but not admin" — both hit the same catch-all clause and
  get a 302 redirect to `/admin/login` with a flash. There is no 401/403 code
  path anywhere in this plug (verified: no other admin controller test in
  this codebase asserts 403 for a non-admin session — see
  `admin_http_controllers_test.exs`'s AC13 tests, all 302). AT1's "401 or 302"
  /  AT18's "403 Forbidden" story text is aspirational and pre-dates AC2's
  explicit reuse mandate; these tests assert the REAL, reused plug's
  behavior (302 to /admin/login) for both cases rather than inventing new
  auth-gate behavior that would deviate from AC2.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-logs-retention-settings-test-key", 2)

  @log_policy_keys ~w(
    log_collect_info log_retention_info_days log_retention_info_max_count
    log_collect_debug log_retention_debug_days log_retention_debug_max_count
  )

  # ── shared helpers (mirrors config_controller_test.exs / device_management_test.exs) ──

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    # Defensive reset — NOT relying on the on_exit DELETEs below actually
    # working. `server_config` has FORCE ROW LEVEL SECURITY and (by design;
    # no production code path ever deletes a config row) NO policy permits
    # DELETE for any key, so every `DELETE FROM server_config WHERE key =
    # ...` below silently affects 0 rows — a value set by an EARLIER test
    # (in this file, or another file sharing the same live Nebu.Repo
    # connection within one `mix test` run, e.g. retention_test.exs) would
    # otherwise leak forward and break a later test's "this key is unset"
    # assumption (e.g. AT10's "blank/zero persists as no limit"). UPSERT-ing
    # each key to its neutral value ("false"/"" — both read back as
    # false/nil) IS permitted by the `config_update_mutable` RLS policy
    # (unlike DELETE), reliably re-establishing a clean baseline before
    # every test. Tests that need a specific value still `seed_policy/1` it
    # explicitly afterward (an UPDATE, which works).
    if Process.whereis(Nebu.Repo) do
      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_info" => "false",
        "log_retention_info_days" => "",
        "log_retention_info_max_count" => "",
        "log_collect_debug" => "false",
        "log_retention_debug_days" => "",
        "log_retention_debug_max_count" => ""
      })
    end

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      Application.delete_env(:nebu_http, :admin_logs_retention_writer)

      if Process.whereis(Nebu.Repo) do
        for key <- @log_policy_keys do
          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [key])
        end
      end
    end)

    :ok
  end

  defp build_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
  end

  defp build_admin_conn(method, path) do
    build_conn(method, path)
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-logs-retention-1",
      "matrix_user_id" => "@admin:test.local"
    })
    # story admin-forms-gate-sweep: strict fetch metadata of a user-clicked submit
    |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
  end

  defp build_non_admin_conn(method, path) do
    build_conn(method, path)
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => false,
      "sub" => "not-an-admin",
      "matrix_user_id" => "@user:test.local"
    })
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp get_config_page(conn_builder \\ &build_admin_conn/2) do
    conn_builder.(:get, "/admin/logs/config") |> endpoint_call()
  end

  defp post_retention(params) do
    build_admin_conn(:post, "/admin/logs/config/retention")
    |> Map.put(:body_params, params)
    |> endpoint_call()
  end

  defp seed_policy(changes) do
    :ok = Nebu.Admin.DB.upsert_server_config(changes)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT1 [AC1/AC2] — route exists and requires admin auth
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT1 [AC1/AC2]: auth gate on GET /admin/logs/config" do
    test "an unauthenticated request is redirected to /admin/login" do
      conn = build_conn(:get, "/admin/logs/config") |> endpoint_call()

      assert conn.status == 302,
             "unauthenticated GET /admin/logs/config must redirect (302); got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"
    end

    test "an authenticated NON-admin request is also redirected to /admin/login (see moduledoc: the reused :require_admin plug has no 403 path)" do
      conn = build_non_admin_conn(:get, "/admin/logs/config") |> endpoint_call()

      assert conn.status == 302,
             "authenticated non-admin GET /admin/logs/config must redirect (302), matching " <>
               "the exact behavior of the reused Nebu.Admin.Auth.require_admin/2 plug; got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"
    end

    test "an authenticated admin request succeeds (200)" do
      conn = get_config_page()
      assert conn.status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT3/AT4 [AC4/AC5/AC6] — trace map bubbles for all 4 levels
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT3/AT4 [AC4/AC5/AC6]: bubbles for WARN, ERROR, INFO, DEBUG" do
    test "renders exactly 4 level bubbles, in WARN, ERROR, INFO, DEBUG order (AC5)" do
      conn = get_config_page()
      body = conn.resp_body

      warn_idx = warn_index(body)
      error_idx = error_index(body)
      info_idx = info_index(body)
      debug_idx = debug_index(body)

      assert warn_idx < error_idx,
             "WARN bubble must render before ERROR (AC5's explicit non-alphabetical order)"

      assert error_idx < info_idx,
             "ERROR bubble must render before INFO (AC5)"

      assert info_idx < debug_idx,
             "INFO bubble must render before DEBUG (AC5)"
    end

    test "WARN and ERROR bubbles are non-interactive (no <button>, or aria-disabled=\"true\")" do
      conn = get_config_page()
      body = conn.resp_body

      warn_fragment = fragment_around(body, "WARN")
      error_fragment = fragment_around(body, "ERROR")

      assert non_interactive?(warn_fragment),
             "WARN bubble must be non-interactive (no <button data-testid=\"trace-map-bubble\"...> " <>
               "without aria-disabled=\"true\"), got fragment: #{warn_fragment}"

      assert non_interactive?(error_fragment),
             "ERROR bubble must be non-interactive, got fragment: #{error_fragment}"
    end

    test "INFO and DEBUG bubbles are interactive <button> elements" do
      conn = get_config_page()
      body = conn.resp_body

      info_fragment = fragment_around(body, "INFO")
      debug_fragment = fragment_around(body, "DEBUG")

      assert String.contains?(info_fragment, "<button"),
             "INFO bubble must be a real <button> element, got: #{info_fragment}"

      assert String.contains?(debug_fragment, "<button"),
             "DEBUG bubble must be a real <button> element, got: #{debug_fragment}"
    end

    test "WARN and ERROR bubbles display '✓ immer' or 'always'" do
      conn = get_config_page()
      body = conn.resp_body

      warn_fragment = fragment_around(body, "WARN")
      error_fragment = fragment_around(body, "ERROR")

      assert String.contains?(warn_fragment, "✓ immer") or
               String.contains?(String.downcase(warn_fragment), "always"),
             "WARN bubble must indicate it is always collected, got: #{warn_fragment}"

      assert String.contains?(error_fragment, "✓ immer") or
               String.contains?(String.downcase(error_fragment), "always"),
             "ERROR bubble must indicate it is always collected, got: #{error_fragment}"
    end

    # Small, deliberately naive substring-index helpers — good enough to pin
    # down relative ORDER in the rendered HTML without a full HTML parser
    # dependency (mirrors the plain-substring-assertion style already used
    # throughout config_controller_test.exs / admin_http_controllers_test.exs).
    defp warn_index(body), do: :binary.match(body, "WARN") |> elem(0)
    defp error_index(body), do: :binary.match(body, "ERROR") |> elem(0)
    defp info_index(body), do: :binary.match(body, "INFO") |> elem(0)
    defp debug_index(body), do: :binary.match(body, "DEBUG") |> elem(0)

    defp fragment_around(body, marker) do
      {idx, _len} = :binary.match(body, marker)
      start = max(idx - 400, 0)
      binary_part(body, start, min(800, byte_size(body) - start))
    end

    defp non_interactive?(fragment) do
      not String.contains?(fragment, "<button") or String.contains?(fragment, ~s(aria-disabled="true"))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT5 [AC7] — INFO/DEBUG toggles accepted and persisted by the controller
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT5 [AC7]: toggle values accepted and persisted" do
    test "info_enabled=true and debug_enabled=false are persisted to server_config" do
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "7",
          "info_max_entries" => "1000",
          "debug_enabled" => "false",
          "debug_days" => "",
          "debug_max_entries" => ""
        })

      assert conn.status in [302, 303]

      {:ok, config} = Nebu.Admin.DB.get_server_config()

      assert config["log_collect_info"] in [true, "true"]
      assert config["log_collect_debug"] in [false, "false"]
    end

    # code-review MAJOR fix regression test: saving the form while a level
    # is disabled must NOT wipe that level's previously-stored retention
    # window. The browser never submits `debug_days`/`debug_max_entries` at
    # all while DEBUG's fields are absent from the DOM (level disabled) —
    # before the fix, the controller unconditionally re-derived and
    # persisted both keys from the (absent -> blank -> "no limit") params on
    # EVERY save, silently resetting a previously-configured DEBUG retention
    # window to "no limit" any time the operator saved the form for an
    # unrelated reason (e.g. only changing INFO).
    test "saving the form while DEBUG is disabled preserves DEBUG's previously-stored retention window" do
      seed_policy(%{
        "log_collect_debug" => "true",
        "log_retention_debug_days" => "14",
        "log_retention_debug_max_count" => "2000"
      })

      # Operator turns DEBUG off and saves — a real browser POST would not
      # even include debug_days/debug_max_entries (absent from the DOM),
      # but the fix must hold regardless of whether they're included blank.
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "7",
          "info_max_entries" => "1000",
          "debug_enabled" => "false"
        })

      assert conn.status in [302, 303],
             "valid submission must succeed, got #{conn.status}: #{conn.resp_body}"

      {:ok, config} = Nebu.Admin.DB.get_server_config()

      assert config["log_collect_debug"] in [false, "false"]

      assert to_string(config["log_retention_debug_days"]) == "14",
             "DEBUG's previously-stored retention days must survive a save that didn't touch " <>
               "DEBUG's own fields, got: #{inspect(config["log_retention_debug_days"])}"

      assert to_string(config["log_retention_debug_max_count"]) == "2000",
             "DEBUG's previously-stored max-count must survive a save that didn't touch DEBUG's " <>
               "own fields, got: #{inspect(config["log_retention_debug_max_count"])}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT6 [AC8] — default retention values on first-time enable
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT6 [AC8]: defaults applied when toggling ON with blank fields" do
    # Dev-implementation note (resolves an apparent conflict with AT10): AC8's
    # "sensible defaults (7 days / 1000 entries)" are pre-filled into the
    # retention <input> fields ENTIRELY CLIENT-SIDE, the instant a level is
    # toggled ON in the browser (see design-decisions.md #2/#4c —
    # `wireLogsConfigToggles()` in app.js; this is also the ONLY thing the
    # Playwright e2e scenario `@ac7-ac8-logs-config-toggle` in
    # `e2e/features/admin/logs-config.feature` verifies). By the time a REAL
    # browser submission reaches the server, the fields therefore already
    # contain the literal strings "7"/"1000" (or whatever the operator typed
    # over them) — NEVER blank. AC9's own text is unconditional either way
    # ("if empty or zero, the server interprets as 'no limit'"), which is
    # exactly what AT10 (test-review MAJOR-1-fixed) pins down: blank/"0" from
    # the CLIENT always means "no limit" server-side, with no exception. This
    # test therefore submits "7"/"1000" explicitly — simulating a real
    # submission of the JS-prefilled values, not a raw blank POST — to prove
    # AC8's defaults actually round-trip through persistence end-to-end,
    # without contradicting AT10's unconditional blank-means-no-limit rule
    # for the SAME info_days/info_max_entries fields.
    test "toggling INFO on and submitting the JS-prefilled 7-day / 1000-entry defaults persists them" do
      seed_policy(%{"log_collect_info" => "false"})

      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "7",
          "info_max_entries" => "1000",
          "debug_enabled" => "false"
        })

      assert conn.status in [302, 303],
             "valid submission (JS-prefilled defaults on first enable) must succeed, got #{conn.status}: #{conn.resp_body}"

      {:ok, config} = Nebu.Admin.DB.get_server_config()
      assert config["log_collect_info"] in [true, "true"]
      assert to_string(config["log_retention_info_days"]) == "7"
      assert to_string(config["log_retention_info_max_count"]) == "1000"

      # Re-render must reflect the just-persisted defaults.
      page = get_config_page()
      assert page.resp_body =~ "7"
      assert page.resp_body =~ "1000"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT7 [AC9] — retention fields appear inline, pre-filled, when a level is ON
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT7 [AC9]: retention fields pre-filled from stored values" do
    test "INFO enabled with days=5 renders an input pre-filled with 5" do
      seed_policy(%{
        "log_collect_info" => "true",
        "log_retention_info_days" => "5",
        "log_retention_info_max_count" => "250"
      })

      conn = get_config_page()
      body = conn.resp_body

      assert body =~ ~s(value="5"),
             "expected the INFO days input to be pre-filled with the stored value 5, body: #{body}"

      assert body =~ ~s(value="250"),
             "expected the INFO max-entries input to be pre-filled with the stored value 250"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT8/AT9 [AC10] — server-side validation bounds
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT8 [AC10]: days bounds validation" do
    test "days=150 (out of bounds) fails validation, re-renders at 200, does not persist" do
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "150",
          "info_max_entries" => "1000",
          "debug_enabled" => "false"
        })

      assert conn.status == 200,
             "invalid days must re-render (200), not redirect; got #{conn.status}"

      assert conn.resp_body =~ "between 1 and 90",
             "expected a flash error mentioning the 1-90 day bound, body: #{conn.resp_body}"

      {:ok, config} = Nebu.Admin.DB.get_server_config()
      refute config["log_retention_info_days"] == "150"
    end

    test "days=-1 and days=\"abc\" both fail validation" do
      for bad <- ["-1", "abc"] do
        conn =
          post_retention(%{
            "info_enabled" => "true",
            "info_days" => bad,
            "info_max_entries" => "1000",
            "debug_enabled" => "false"
          })

        assert conn.status == 200, "days=#{inspect(bad)} must fail validation (200), not persist"
      end
    end
  end

  describe "AT9 [AC10]: max entries bounds validation" do
    test "max_entries=50000 (out of bounds) fails validation, does not persist" do
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "7",
          "info_max_entries" => "50000",
          "debug_enabled" => "false"
        })

      assert conn.status == 200

      assert conn.resp_body =~ "between 1 and 10000",
             "expected a flash error mentioning the 1-10000 entry bound, body: #{conn.resp_body}"

      {:ok, config} = Nebu.Admin.DB.get_server_config()
      refute config["log_retention_info_max_count"] == "50000"
    end
  end

  describe "AT10 [AC10]: blank/zero fields are accepted as 'no limit'" do
    test "blank days and max entries pass validation and persist as no-limit (nil)" do
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "",
          "info_max_entries" => "",
          "debug_enabled" => "true",
          "debug_days" => "0",
          "debug_max_entries" => "0"
        })

      assert conn.status in [302, 303],
             "blank/0 fields must be VALID (no-limit), not a validation error; got #{conn.status}: #{conn.resp_body}"

      {:ok, config} = Nebu.Admin.DB.get_server_config()

      # code-review/test-review MAJOR-1 fix: "0"/"no-limit" MUST persist as nil
      # (or an empty string that reads back as nil), NEVER the literal integer/
      # string "0" — Nebu.Web.LogStore.Retention.prune_ttl/2 and
      # prune_max_count/2 only short-circuit on `nil`; a stored "0" would be
      # parsed to the integer 0 by LogStore.to_int/1 and would cause the very
      # next sweep to delete EVERY row of that level (WHERE inserted_at < now()
      # - '0 days'::interval / LIMIT 0), the opposite of "no limit". A prior,
      # looser version of this assertion accepted "0" as a passing value and
      # would have let exactly that regression through silently.
      refute config["log_retention_debug_days"] == "0",
             "'0' must be normalized to nil/empty before persistence, never stored literally as \"0\" " <>
               "(prune_ttl/2 would then delete every row on the next sweep instead of applying no limit)"

      assert config["log_retention_debug_days"] in [nil, ""],
             "0/blank must persist as 'no limit' (nil/empty), got: #{inspect(config["log_retention_debug_days"])}"

      refute config["log_retention_debug_max_count"] == "0",
             "'0' must be normalized to nil/empty before persistence, never stored literally as \"0\" " <>
               "(prune_max_count/2 would then delete every row on the next sweep instead of applying no limit)"

      assert config["log_retention_debug_max_count"] in [nil, ""],
             "0/blank must persist as 'no limit' (nil/empty), got: #{inspect(config["log_retention_debug_max_count"])}"

      assert config["log_retention_info_days"] in [nil, ""],
             "blank info_days must persist as 'no limit' (nil/empty), got: #{inspect(config["log_retention_info_days"])}"

      assert config["log_retention_info_max_count"] in [nil, ""],
             "blank info_max_entries must persist as 'no limit' (nil/empty), got: #{inspect(config["log_retention_info_max_count"])}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT11 [AC11] — DEBUG excessive-logging warning
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT11 [AC11]: DEBUG warning visibility" do
    test "warning containing 'War Room mode' is visible when DEBUG is enabled" do
      seed_policy(%{"log_collect_debug" => "true"})

      conn = get_config_page()
      assert conn.resp_body =~ "War Room mode"
    end

    test "warning is not visible when DEBUG is disabled" do
      seed_policy(%{"log_collect_debug" => "false"})

      conn = get_config_page()

      # Same false-green guard as AT12 — see its comment.
      assert conn.status == 200,
             "expected the config page to render (200) so this negative " <>
               "assertion is meaningful, got #{conn.status}"

      refute conn.resp_body =~ "War Room mode"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT12 [AC12] — INFO toggle shows no warning
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT12 [AC12]: INFO does not trigger a warning" do
    test "INFO enabled, DEBUG disabled shows no 'War Room mode' warning" do
      seed_policy(%{"log_collect_info" => "true", "log_collect_debug" => "false"})

      conn = get_config_page()

      # Guard against a false-green pass: a 404 (route not implemented yet)
      # would also trivially satisfy `refute ... =~ "War Room mode"` below
      # without proving anything about AC12. Pin the page to a genuine 200
      # render first.
      assert conn.status == 200,
             "expected the config page to render (200) so this negative " <>
               "assertion is meaningful, got #{conn.status}"

      refute conn.resp_body =~ "War Room mode"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT13 [AC13/AC14] — successful form submission redirects + flashes + persists
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT13 [AC13/AC14]: valid submission redirects with success flash" do
    test "valid POST redirects (303) to /admin/logs/config with 'Logging settings saved'" do
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "7",
          "info_max_entries" => "1000",
          "debug_enabled" => "true",
          "debug_days" => "0",
          "debug_max_entries" => "2000"
        })

      assert conn.status in [302, 303],
             "valid submission must redirect; got #{conn.status}: #{conn.resp_body}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/logs/config"

      {:ok, config} = Nebu.Admin.DB.get_server_config()
      assert config["log_collect_debug"] in [true, "true"]
      assert to_string(config["log_retention_debug_max_count"]) == "2000"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT14 [AC15] — validation failure re-renders, preserves input, no persistence
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT14 [AC15]: invalid submission re-renders with preserved input" do
    test "days=150 re-renders at 200 with the submitted value 150 still visible in the form" do
      conn =
        post_retention(%{
          "info_enabled" => "true",
          "info_days" => "150",
          "info_max_entries" => "1000",
          "debug_enabled" => "false"
        })

      assert conn.status == 200
      assert get_resp_header(conn, "location") == [], "must NOT redirect on validation failure"

      assert conn.resp_body =~ ~s(value="150"),
             "the operator's invalid input (150) must still be visible in the re-rendered form, " <>
               "not silently cleared, body: #{conn.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT15 [AC16] — settings loaded from the database on page load
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT15 [AC16]: page reflects DB state on load" do
    test "INFO enabled/5 days, DEBUG disabled: page shows INFO on with 5 days + default 1000 entries, DEBUG off with no fields" do
      seed_policy(%{
        "log_collect_info" => "true",
        "log_retention_info_days" => "5",
        "log_collect_debug" => "false"
      })

      conn = get_config_page()
      body = conn.resp_body

      assert body =~ ~s(value="5")
      assert body =~ "1000"

      debug_fragment = fragment_around_body(body, "DEBUG")

      # test-review MINOR-2 fix: two INDEPENDENT negative assertions, not an
      # `and`-combined single refute — the original would only fail if BOTH
      # substrings co-occurred, so an implementation that leaked
      # name="debug_days" (the actual regression this test exists to catch)
      # but rendered a different `type=` attribute (or where the two
      # attributes fell on either side of the fixed byte window) would have
      # still passed.
      refute String.contains?(debug_fragment, ~s(name="debug_days")),
             "DEBUG must show no 'days' retention input while disabled"

      refute String.contains?(debug_fragment, ~s(name="debug_max_entries")),
             "DEBUG must show no 'max entries' retention input while disabled"
    end

    defp fragment_around_body(body, marker) do
      {idx, _len} = :binary.match(body, marker)
      start = max(idx - 200, 0)
      binary_part(body, start, min(600, byte_size(body) - start))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT16 [AC17] — PubSub notification: Option A chosen (no PubSub), see
  # design-decisions.md #3. Uses ExUnit's real `:skip` tag (test-review MINOR-1
  # fix — a bare `:pending` tag isn't excluded by anything in test_helper.exs
  # and would just run and trivially pass; `:skip` has built-in ExUnit
  # semantics and is honestly reported as "skipped" in test output) per the
  # story's own explicit fallback allowance ("If Option A: test is skipped or
  # marked as :pending").
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT16 [AC17]: PubSub notification (Option B) — NOT IMPLEMENTED, Option A chosen" do
    @tag :skip
    test "no PubSub broadcast is expected (Option A: simple reload, decided in design-decisions.md)" do
      :ok
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT17 [AC18] — CSRF token required
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT17 [AC18]: CSRF protection" do
    setup do
      prior = Application.get_env(:nebu_http, :admin_csrf_bypass)
      Application.put_env(:nebu_http, :admin_csrf_bypass, false)
      on_exit(fn -> restore_csrf_bypass(prior) end)
      :ok
    end

    defp restore_csrf_bypass(nil), do: Application.delete_env(:nebu_http, :admin_csrf_bypass)
    defp restore_csrf_bypass(val), do: Application.put_env(:nebu_http, :admin_csrf_bypass, val)

    test "POST /admin/logs/config/retention without a CSRF token is rejected" do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        build_admin_conn(:post, "/admin/logs/config/retention")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:body_params, %{"info_enabled" => "true"})
        |> endpoint_call()
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT18 [AC19] — only admins can POST
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT18 [AC19]: auth gate on POST" do
    test "an authenticated non-admin POST is redirected to /admin/login (see moduledoc re: 403 vs 302)" do
      conn =
        build_non_admin_conn(:post, "/admin/logs/config/retention")
        |> Map.put(:body_params, %{"info_enabled" => "true"})
        |> endpoint_call()

      assert conn.status == 302,
             "non-admin POST must be redirected (302) by the reused :require_admin plug, matching " <>
               "every other admin controller in this codebase; got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Migration gap check — new server_config key must be added to the
  # config_update_mutable RLS allowlist (design-decisions.md #4b), NOT just
  # writable once as a first-ever INSERT. Mirrors log_store_test.exs's own
  # "AC3: server_config policy keys" test for the SAME reason: a single
  # upsert would pass even if this key were never added to the allowlist —
  # only a SECOND upsert (an UPDATE) genuinely exercises the RLS gate.
  # ══════════════════════════════════════════════════════════════════════════

  describe "RLS allowlist: log_retention_info_max_count is genuinely mutable" do
    test "a second upsert (an UPDATE) of log_retention_info_max_count actually changes the stored value" do
      key = "log_retention_info_max_count"

      assert :ok = Nebu.Admin.DB.upsert_server_config(%{key => "111"})
      {:ok, config1} = Nebu.Admin.DB.get_server_config()
      assert config1[key] == "111"

      assert :ok = Nebu.Admin.DB.upsert_server_config(%{key => "222"})
      {:ok, config2} = Nebu.Admin.DB.get_server_config()

      assert config2[key] == "222",
             "expected the second upsert (an UPDATE) of #{key} to change the stored value — if " <>
               "this key is missing from server_config's config_update_mutable RLS policy " <>
               "allowlist, the UPDATE silently affects 0 rows and \"111\" survives"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT2 [AC3] — navigation link from the monitoring page
  # ══════════════════════════════════════════════════════════════════════════

  describe "AT2 [AC3]: nav link from /admin/logs to /admin/logs/config" do
    import Phoenix.LiveViewTest

    @admin_session %{"current_user" => %{"admin" => true, "sub" => "admin-logs-retention-nav"}}

    test "the monitoring page renders a 'Sammlung konfigurieren →' link to /admin/logs/config" do
      {:ok, _view, html} =
        live_isolated(Plug.Test.conn(:get, "/admin/logs"), Nebu.Admin.LogsLive,
          session: @admin_session
        )

      assert html =~ "Sammlung konfigurieren" or html =~ "Configure collection",
             "expected the monitoring page to render a config-page nav link, got: #{html}"

      assert html =~ ~s(href="/admin/logs/config") or html =~ ~s(href='/admin/logs/config'),
             "expected the nav link to point at /admin/logs/config"
    end
  end
end
