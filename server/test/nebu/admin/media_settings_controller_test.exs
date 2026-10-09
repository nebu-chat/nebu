defmodule Nebu.Admin.MediaSettingsControllerTest do
  @moduledoc """
  RED-phase ATDD tests for story `9b-media-settings-ui` (epic
  `media-security-admin-control`).

  ## What is under test

  `GET /admin/media/settings` (`Nebu.Admin.MediaSettingsController.index/2`) and
  `POST /admin/media/settings` (`.save/2`) — a plain HTTP controller (NOT a
  LiveView, per AC12/the router moduledoc) that reads/writes the 9
  admin-editable `media_config` keys (Story 9a's 10-key catalog minus
  `mime_denylist`, which this page does not expose) exclusively through
  `Nebu.Media.Config.get/0` / `Nebu.Media.Config.upsert/2`/`upsert/3`
  (ADR-020).

  ## Why every test below MUST fail right now (and for the RIGHT reason)

  Neither `Nebu.Admin.MediaSettingsController` nor
  `Nebu.Admin.MediaSettingsHTML` exist yet, and no `GET`/`POST
  /admin/media/settings` route exists in `server/lib/nebu/admin/router.ex`.
  Every test below therefore fails with `UndefinedFunctionError` (unknown
  action/plug) or a 404 (`Phoenix.Router.NoRouteError` surfaced by the
  endpoint as a 404 response) — NOT a `Nebu.Repo`-not-started error, since
  this suite never touches a live Postgres connection (see next section).

  ## Why this suite avoids a live Postgres/`Nebu.Repo` entirely

  Mirrors `server/test/nebu/media/config_test.exs` and
  `server/test/nebu/admin/config_controller_test.exs`: `mix test`
  (`make test-unit-elixir`) never starts `Nebu.Repo`, so any code path that
  touched real Postgres would fail with a Repo-not-started error instead of
  the required "module/route missing" reason. `Nebu.Media.Config` already
  ships full test seams (see its moduledoc):

    * `Application.get_env(:nebu_http, :media_config_source)` — 0-arity fun,
      full bypass for `Config.get/0` (used to control what the GET renders
      as "current values").
    * `Application.get_env(:nebu_http, :media_config_loader)` — 0-arity fun,
      all currently persisted overrides (consulted by `upsert/2`'s old-value
      lookup and the cache's DB-refresh step). Left unset in most tests below
      — `Nebu.Media.Config`'s own `default_loader/0` safely returns `%{}`
      when `Nebu.Repo` isn't running, so no live-DB fallback is needed here.
    * `Application.get_env(:nebu_http, :media_config_writer)` — arity-3 fun
      `fn key, value, set_at -> :ok | {:error, term()} end`, the ONLY
      observable persistence seam. Every test that asserts persistence
      behavior installs this and asserts on the messages it sends, rather
      than reading any table.
    * `Application.put_env(:compliance, :repo, FakeAuditRepo)` — every
      successful `Nebu.Media.Config.upsert/2` call unconditionally writes a
      `media_config_updated` audit-log entry via
      `Nebu.Compliance.AuditWriter.log/6`; this in-process fake (copied from
      `config_test.exs`) keeps that write off a live Repo.

  `Nebu.Media.Config`'s own supervised GenServer/ETS cache IS part of the
  normal `Nebu.Application` supervision tree (started unconditionally, see
  `lib/nebu/application.ex`) and therefore may already be running during
  this suite — this is harmless: `Config.get/0` checks the
  `:media_config_source` seam BEFORE ever consulting ETS, so every test that
  sets it fully controls the "current value" the controller sees regardless
  of the cache's real-world state.

  ## IMPORTANT — the real `Nebu.Media.Config` public API (Story 9a, already
  shipped) is `upsert/2` / `upsert/3` (`upsert(key, value, actor \\\\
  @audit_actor)`), ONE call per key — NOT a single map-based `upsert/1`. The
  story text's own "AC5 ... `Nebu.Media.Config.upsert/1`" phrasing is
  aspirational/stale; every test below that exercises AC5 asserts against
  the REAL arity-2/3 function via the `:media_config_writer` seam described
  above, never a literal `upsert/1` call.

  ## Form-field conventions this suite assumes (dev-story's own choice to make,
  pinned here as the observable contract)

  * Input `name`/param-map key is the bare `media_config` key itself (e.g.
    `"max_upload_size_bytes"`), mirroring `LogsController`'s
    `params["info_days"]`-style direct key usage — no nested/prefixed params.
  * A blank submitted `webhook_url` / `released_delete_after_days` means
    "unset" (`nil`), mirroring this codebase's own established
    blank-means-no-limit convention (`LogsController` AC9/AC10).
  * The `mime_denylist` key (Story 9a's 10th catalog key) is NOT part of this
    page's form (AC1's literal 9-key list) and is out of scope for this file.

  ## Nav wiring — out of scope for this file

  The story's own Technical Requirements section mentions wiring a "Settings"
  child nav link into a "Media" parent nav item. That parent nav item (and
  its Explorer/Settings/Health children) was since built by
  `bugfix/admin-media-nav-grouping` (see
  `server/test/nebu/admin/layouts_media_nav_grouping_test.exs`) — nav
  wiring/grouping is exercised there, not in this file. This file continues
  to test only the settings page's own controller behavior (AC1-AC8 above),
  not nav presentation.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-settings-ui-test-key-abc", 2)

  # ── FakeAuditRepo ──────────────────────────────────────────────────────────
  #
  # Reused shape from config_test.exs — replaces Nebu.Repo for
  # Nebu.Compliance.AuditWriter.log/6 (unconditionally invoked by every
  # successful Nebu.Media.Config.upsert/2 call) via the `:compliance, :repo`
  # seam, so a valid save never touches a live Postgres connection.

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter. Test-private."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  @numeric_fields ~w(
    max_upload_size_bytes
    max_file_size_bytes
    max_pending_per_user
    max_stall_ms
    deleted_days
    infected_days
    orphaned_hours
  )

  @all_fields @numeric_fields ++ ~w(webhook_url released_delete_after_days)

  # A fully valid baseline submission — every numeric field within any sane
  # bound, webhook_url/released_delete_after_days blank ("unset"). Individual
  # tests override one field at a time via valid_params/1.
  @baseline_valid_params %{
    "max_upload_size_bytes" => "52428800",
    "max_file_size_bytes" => "104857600",
    "max_pending_per_user" => "20",
    "max_stall_ms" => "20000",
    "deleted_days" => "30",
    "infected_days" => "90",
    "orphaned_hours" => "24",
    "webhook_url" => "",
    "released_delete_after_days" => ""
  }

  # ── Setup / Teardown ───────────────────────────────────────────────────────

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:compliance, :repo, FakeAuditRepo)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      Application.delete_env(:nebu_http, :media_config_source)
      Application.delete_env(:nebu_http, :media_config_loader)
      Application.delete_env(:nebu_http, :media_config_writer)
      Application.delete_env(:compliance, :repo)
      # 11b (storage-ui-test-connection) seams — cleaned up here too so a test
      # in THIS file that forgets to reset one never leaks into a later test
      # in the same run (mirrors the cleanup list above for 9b's own seams).
      Application.delete_env(:nebu_http, :media_storage_config_source)
      Application.delete_env(:nebu_http, :media_storage_config_loader)
      Application.delete_env(:nebu_http, :media_storage_config_writer)
      Application.delete_env(:nebu_http, :media_storage_env_reader)
      Application.delete_env(:nebu_http, :media_storage_test_connection_fun)
      Application.delete_env(:nebu_http, :media_files_storage_key_count_fun)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)
    end)

    :ok
  end

  # ── conn-building helpers (mirrors config_controller_test.exs / logs_controller_test.exs) ──

  defp build_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
  end

  defp build_admin_conn(method, path) do
    build_conn(method, path)
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-media-settings-1",
      "matrix_user_id" => "@admin:test.local"
    })
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

  defp build_admin_conn_with_flash(method, path, flash) do
    build_admin_conn(method, path)
    |> put_session("phoenix_flash", flash)
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp get_settings_page(conn_builder \\ &build_admin_conn/2) do
    conn_builder.(:get, "/admin/media/settings") |> endpoint_call()
  end

  defp post_settings(params, conn_builder \\ &build_admin_conn/2) do
    conn_builder.(:post, "/admin/media/settings")
    |> Map.put(:body_params, params)
    |> endpoint_call()
  end

  defp valid_params(overrides \\ %{}), do: Map.merge(@baseline_valid_params, overrides)

  # Extracts flash (info/error) + resp_body as one blob so a "does this
  # response carry X copy" assertion doesn't need to care whether the
  # implementation renders the copy inline (200 re-render) or via a
  # redirect-carried flash (302/303) — both are legitimate implementation
  # choices this suite deliberately does not pin down further than the
  # story's own AT wording does.
  defp observable_text(conn) do
    flash =
      conn.assigns[:flash] || get_session(conn, "phoenix_flash") || get_session(conn, "_flash") ||
        %{}

    info = Phoenix.Flash.get(flash, :info) || ""
    error = Phoenix.Flash.get(flash, :error) || ""
    warning = Phoenix.Flash.get(flash, :warning) || ""
    Enum.join([to_string(info), to_string(error), to_string(warning), conn.resp_body || ""], " ")
  end

  defp flash_get(conn, kind) do
    flash =
      conn.assigns[:flash] || get_session(conn, "phoenix_flash") || get_session(conn, "_flash") ||
        %{}

    Phoenix.Flash.get(flash, kind)
  end

  # AC4's "harder to miss" warning must, at minimum, mention that released
  # media will be deleted AND that this is now automatic/permanent — the
  # exact copy is the dev-story's own choice (mirrors LogsController's own
  # invented bounds/copy), but this is the minimum observable contract a
  # competent implementation satisfies.
  defp contains_strong_warning?(text) do
    downcased = String.downcase(text)

    String.contains?(downcased, "delet") and
      Enum.any?(
        ["perman", "automat", "no longer", "irreversib"],
        &String.contains?(downcased, &1)
      )
  end

  defp has_label_or_aria?(body, field) do
    String.contains?(body, ~s(for="#{field}")) or has_aria_label_near?(body, field)
  end

  defp has_aria_label_near?(body, field) do
    case :binary.match(body, ~s(name="#{field}")) do
      {idx, _len} ->
        start = max(idx - 200, 0)
        fragment = binary_part(body, start, min(400, byte_size(body) - start))
        String.contains?(fragment, "aria-label=")

      :nomatch ->
        false
    end
  end

  # test-review MAJOR M1 fix: asserts that the SAME <input>/<textarea> tag
  # carries BOTH name="<field>" and value="<value>" (attribute-order-
  # independent), rather than a bare whole-body substring check — closes the
  # false-positive gap where a short digit value (e.g. "12", "6", "45") is a
  # substring of a DIFFERENT field's own rendered value.
  defp field_rendered_with_value?(body, field, value) do
    name_needle = ~s(name="#{field}")
    value_needle = ~s(value="#{value}")

    ~r/<(?:input|textarea)\b[^>]*>/
    |> Regex.scan(body)
    |> List.flatten()
    |> Enum.any?(fn tag ->
      String.contains?(tag, name_needle) and String.contains?(tag, value_needle)
    end)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1: GET /admin/media/settings renders current values
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: GET /admin/media/settings renders current values" do
    test "renders all nine media_config fields pre-filled with their current stored values" do
      Application.put_env(:nebu_http, :media_config_source, fn ->
        %{
          "max_upload_size_bytes" => 12_345_678,
          "max_file_size_bytes" => 87_654_321,
          "max_pending_per_user" => 33,
          "max_stall_ms" => 15_000,
          "deleted_days" => 12,
          "infected_days" => 77,
          "orphaned_hours" => 6,
          "webhook_url" => "https://example.org/media-hook",
          "released_delete_after_days" => 45
        }
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      # test-review MAJOR M1 fix: a bare whole-body substring check (e.g. "12",
      # "6", "45") is a false-positive risk — those short digit strings are ALL
      # substrings of OTHER fields' rendered values (e.g. "12"/"6"/"45" are
      # substrings of max_upload_size_bytes's "12345678"), so a controller that
      # omitted rendering deleted_days/orphaned_hours/released_delete_after_days
      # entirely would still pass. Scope each assertion to the specific field's
      # OWN rendered <input>, via field_rendered_with_value?/3 below (matches
      # name="<field>" and value="<value>" on the SAME tag, order-independent).
      for {field, value} <- [
            {"max_upload_size_bytes", 12_345_678},
            {"max_file_size_bytes", 87_654_321},
            {"max_pending_per_user", 33},
            {"max_stall_ms", 15_000},
            {"deleted_days", 12},
            {"infected_days", 77},
            {"orphaned_hours", 6},
            {"released_delete_after_days", 45}
          ] do
        assert field_rendered_with_value?(body, field, value),
               "expected #{field}'s own <input> to be pre-filled with its current stored value " <>
                 "#{inspect(value)}, body: #{body}"
      end

      assert field_rendered_with_value?(body, "webhook_url", "https://example.org/media-hook"),
             "expected the current webhook_url to be pre-filled in the form"
    end

    test "a key with no media_config row falls back to its config.exs default (env-var pre-fill on first load)" do
      # CI-gate fix (make test-integration, real Nebu.Repo + a genuinely
      # SHARED, singleton Nebu.Media.Config GenServer running across the
      # WHOLE mix test run): leaving :media_config_source unset and relying
      # on "nothing has ever written media_config" is NOT safe under
      # --include integration. ANY earlier test in ANY file (this file's own
      # AC5/AC6/etc. — which fake ONLY :media_config_writer, not
      # :media_config_loader) that calls the real Nebu.Media.Config.upsert/3
      # triggers trigger_refresh/0 -> do_refresh/0, which re-reads via
      # Application.get_env(:nebu_http, :media_config_loader,
      # &default_loader/0) — unset here, so it falls through to the REAL
      # `SELECT key, value FROM media_config` against the live dev Postgres,
      # repopulating the ONE shared ETS cache with whatever real rows
      # happen to exist (e.g. from Story 9a's own :integration-tagged
      # DB-verification tests). That cached catalog then leaks into this
      # test if it runs later in the same suite. Explicitly install the
      # :media_config_source bypass returning an empty map so this test's
      # "no row exists" premise is enforced directly, independent of
      # whatever the shared cache/real DB happens to hold at this point in
      # the run — mirrors config_test.exs's own "on a fresh media_config
      # table (no rows)" test, which uses the exact same bypass for the
      # exact same reason.
      Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      # test-review MAJOR M1 fix: same per-field scoping as the test above —
      # "20" is a substring of "20000" and "24" is a substring of "52428800",
      # so max_pending_per_user/orphaned_hours were effectively unverified by
      # the original whole-body substring check.
      for {field, default_value} <- [
            {"max_upload_size_bytes", 52_428_800},
            {"max_file_size_bytes", 104_857_600},
            {"max_pending_per_user", 20},
            {"max_stall_ms", 20_000},
            {"deleted_days", 30},
            {"infected_days", 90},
            {"orphaned_hours", 24}
          ] do
        assert field_rendered_with_value?(body, field, default_value),
               "expected #{field}'s own <input> to be pre-filled with its config.exs default " <>
                 "#{inspect(default_value)} on first load, body: #{body}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2: numeric bounds validation
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: numeric bounds validation" do
    test "max_upload_size_bytes out of bounds fails validation, re-renders at 200, does not persist" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      conn = post_settings(valid_params(%{"max_upload_size_bytes" => "999999999999999"}))

      assert conn.status == 200,
             "an out-of-bounds max_upload_size_bytes must re-render at 200, not redirect; got #{conn.status}"

      assert get_resp_header(conn, "location") == [],
             "an out-of-bounds submission must NOT redirect"

      refute_received {:media_config_written, _key, _value},
                      "an out-of-bounds value must be rejected before ANY key reaches Nebu.Media.Config.upsert"
    end

    test "a negative value for any numeric field is rejected without reaching Nebu.Media.Config.upsert/1" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      for field <- @numeric_fields do
        conn = post_settings(valid_params(%{field => "-1"}))

        assert conn.status == 200,
               "a negative value for #{field} must re-render at 200, not redirect; got #{conn.status}"

        refute_received {:media_config_written, _key, _value},
                        "a negative value for #{field} must be rejected before ANY key reaches " <>
                          "Nebu.Media.Config.upsert"
      end
    end

    test "non-numeric input for a numeric field is rejected with a specific error message" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      conn = post_settings(valid_params(%{"max_pending_per_user" => "abc"}))

      assert conn.status == 200,
             "non-numeric input must re-render at 200, not redirect; got #{conn.status}"

      assert conn.resp_body =~ ~r/number|integer|numeric|invalid/i,
             "expected a specific validation error message about the non-numeric input, " <>
               "body: #{conn.resp_body}"

      refute_received {:media_config_written, _key, _value}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3: webhook_url save-time validation
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: webhook_url save-time validation" do
    test "a webhook_url with an http:// (non-HTTPS) scheme is rejected" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      conn = post_settings(valid_params(%{"webhook_url" => "http://example.com/hook"}))

      assert conn.status == 200,
             "a non-HTTPS webhook_url must re-render at 200, not redirect; got #{conn.status}"

      assert conn.resp_body =~ ~r/https/i,
             "expected an error message mentioning the HTTPS requirement, body: #{conn.resp_body}"

      # test-review MINOR m1 fix: widened to the ANY-key form (matching AC2's
      # atomicity refutes) — a controller that pre-validates/persists the 7
      # numeric fields and only THEN delegates webhook_url validation to
      # Config.upsert would previously pass this test despite persisting 7
      # keys before failing, contradicting AC2's atomicity/AC6's "not silently
      # discarded" contract.
      refute_received {:media_config_written, _key, _value},
                      "a non-HTTPS webhook_url must be rejected before ANY key reaches " <>
                        "Nebu.Media.Config.upsert"
    end

    test "a webhook_url resolving to a private or link-local IP range is rejected" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      # Literal IPs — no real DNS lookup needed (mirrors config_test.exs's own
      # SSRF fixtures: 127.0.0.1 loopback, 169.254.169.254 cloud metadata).
      for url <- ["https://127.0.0.1/hook", "https://169.254.169.254/hook"] do
        conn = post_settings(valid_params(%{"webhook_url" => url}))

        assert conn.status == 200,
               "a private/link-local webhook_url (#{url}) must re-render at 200, not redirect; " <>
                 "got #{conn.status}"

        assert conn.resp_body =~ ~r/block|private|not allowed|invalid/i,
               "expected an error message about the blocked address for #{url}, body: #{conn.resp_body}"

        # test-review MINOR m1 fix: widened to the ANY-key form, same rationale
        # as the http:// test above.
        refute_received {:media_config_written, _key, _value},
                        "a private/link-local webhook_url (#{url}) must be rejected before ANY " <>
                          "key reaches Nebu.Media.Config.upsert"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4: released_delete_after_days nil-to-value warning
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: released_delete_after_days nil-to-value warning" do
    test "changing released_delete_after_days from unset to a concrete value renders the stronger warning copy, not just the generic success flash" do
      # code review (Cycle 1, MINOR-3) fix: explicitly bypass Config.get/0 to
      # an empty map instead of relying on "nothing has ever written
      # media_config" via the REAL shared singleton ETS cache. Under `mix
      # test --include integration` (real Nebu.Repo + the one shared
      # Nebu.Media.Config GenServer running across the WHOLE test run), a
      # non-nil released_delete_after_days row can already exist in the real
      # dev Postgres from an earlier test/run, which would make this test's
      # "old_value is genuinely nil" premise false and the warning silently
      # not fire — same class of flake fix already applied to the AC1 "falls
      # back to config.exs default" test above and used by the sibling
      # "between two concrete values" test right below.
      Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)
      Application.put_env(:nebu_http, :media_config_writer, fn _key, _value, _set_at -> :ok end)

      conn = post_settings(valid_params(%{"released_delete_after_days" => "30"}))

      assert conn.status in [200, 302, 303],
             "expected a successful save response, got #{conn.status}: #{conn.resp_body}"

      text = observable_text(conn)

      assert contains_strong_warning?(text),
             "expected a stronger, harder-to-miss warning (mentioning that released media will " <>
               "now be automatically/permanently deleted) when released_delete_after_days changes " <>
               "from unset to a concrete value, got: #{inspect(text)}"
    end

    test "changing released_delete_after_days between two concrete values does not trigger the stronger warning" do
      Application.put_env(:nebu_http, :media_config_source, fn ->
        %{"released_delete_after_days" => 10}
      end)

      Application.put_env(:nebu_http, :media_config_writer, fn _key, _value, _set_at -> :ok end)

      conn = post_settings(valid_params(%{"released_delete_after_days" => "20"}))

      assert conn.status in [200, 302, 303],
             "expected a successful save response, got #{conn.status}: #{conn.resp_body}"

      text = observable_text(conn)

      refute contains_strong_warning?(text),
             "did not expect the stronger nil-to-value warning when changing between two concrete " <>
               "values, got: #{inspect(text)}"

      assert String.downcase(text) =~ "saved",
             "expected the plain generic success flash instead, got: #{inspect(text)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5: persistence goes through Nebu.Media.Config exclusively
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5: persistence goes through Nebu.Media.Config exclusively" do
    test "a valid submission calls Nebu.Media.Config.upsert/1 and never issues a direct media_config INSERT/UPDATE" do
      test_pid = self()

      # NOTE: the story text's own "Nebu.Media.Config.upsert/1" phrasing is
      # stale (see moduledoc) — the REAL public API is upsert/2 or upsert/3,
      # ONE call per key. This test asserts persistence happened via THAT
      # real seam (the only observable write path Nebu.Media.Config exposes)
      # rather than any direct SQL against media_config, which this suite
      # cannot even attempt (no live Nebu.Repo is started under plain `mix
      # test` — a direct SQL call from the controller would itself fail
      # loudly rather than silently succeed).
      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      conn = post_settings(valid_params(%{"max_pending_per_user" => "25"}))

      assert conn.status in [302, 303],
             "a valid submission must redirect on success; got #{conn.status}: #{conn.resp_body}"

      assert_received {:media_config_written, "max_pending_per_user", 25},
                      "expected the changed field to be persisted via Nebu.Media.Config's real " <>
                        "arity-2/3 upsert (observed through the :media_config_writer seam) with " <>
                        "the coerced integer value 25"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6: flash messaging
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: flash messaging" do
    test "a valid update persists and shows a success flash" do
      Application.put_env(:nebu_http, :media_config_writer, fn _key, _value, _set_at -> :ok end)

      conn = post_settings(valid_params())

      assert conn.status in [302, 303],
             "a valid submission must redirect; got #{conn.status}: #{conn.resp_body}"

      info_flash = flash_get(conn, :info)

      refute is_nil(info_flash),
             "expected a success (:info) flash to be set on a valid save"

      assert info_flash =~ ~r/media settings saved/i,
             "expected a short, past-tense success flash matching " <>
               "ConfigController/LogsController copy style, got: #{inspect(info_flash)}"
    end

    test "an invalid submission shows an error flash and re-renders with the submitted values preserved" do
      conn = post_settings(valid_params(%{"max_stall_ms" => "-500"}))

      assert conn.status == 200,
             "an invalid submission must re-render at 200, not redirect; got #{conn.status}"

      error_flash = flash_get(conn, :error)

      refute is_nil(error_flash),
             "expected an error flash to be set on an invalid save"

      assert conn.resp_body =~ ~s(-500),
             "expected the submitted (invalid) value -500 to still be visible in the re-rendered " <>
               "form, not silently discarded, body: #{conn.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7: admin-only access
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC7: admin-only access" do
    test "an unauthenticated request to GET /admin/media/settings is redirected to /admin/login" do
      conn = build_conn(:get, "/admin/media/settings") |> endpoint_call()

      assert conn.status == 302,
             "an unauthenticated GET must redirect (302); got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"
    end

    test "a non-admin session's POST /admin/media/settings is redirected to /admin/login, not persisted" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:media_config_written, key, value})
        :ok
      end)

      conn = post_settings(valid_params(), &build_non_admin_conn/2)

      assert conn.status == 302,
             "a non-admin POST must redirect (302) to /admin/login; got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"

      refute_received {:media_config_written, _key, _value},
                      "a non-admin POST must never reach Nebu.Media.Config.upsert"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC8: accessibility
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC8: accessibility" do
    test "every form input has an associated label or aria-label" do
      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      for field <- @all_fields do
        assert has_label_or_aria?(body, field),
               "expected an associated <label for=\"#{field}\"> or a nearby aria-label for the " <>
                 "#{field} input, body: #{body}"
      end
    end

    test "the success flash carries role=\"status\" and the error flash carries role=\"alert\"" do
      # Error path: a real invalid submission naturally sets the :error flash
      # via put_flash inside the controller — assert the RENDERED page marks
      # it with role="alert" (matches ConfigController/LogsController's own
      # template convention, e.g. lib/nebu/admin/templates/config/index.html.heex).
      error_conn = post_settings(valid_params(%{"max_stall_ms" => "-500"}))

      assert error_conn.status == 200,
             "expected the invalid submission to re-render at 200; got #{error_conn.status}"

      assert error_conn.resp_body =~ ~s(role="alert"),
             "expected the error flash to be rendered with role=\"alert\", body: #{error_conn.resp_body}"

      # Success path: rather than depending on cookie-recycling across two
      # separate requests, seed the one-time Phoenix session flash directly
      # (the exact mechanism a real browser round-trip would produce after a
      # successful POST redirect) and assert the template renders it with
      # role="status".
      success_conn =
        get_settings_page(fn method, path ->
          build_admin_conn_with_flash(method, path, %{"info" => "Media settings saved"})
        end)

      assert success_conn.status == 200,
             "expected the settings page to render (200); got #{success_conn.status}"

      assert success_conn.resp_body =~ ~s(role="status"),
             "expected the success flash to be rendered with role=\"status\", " <>
               "body: #{success_conn.resp_body}"

      assert success_conn.resp_body =~ "Media settings saved",
             "expected the seeded success flash text to be rendered, body: #{success_conn.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Story 11b (storage-ui-test-connection) — RED-phase ATDD tests
  # ══════════════════════════════════════════════════════════════════════════
  #
  # ## What is under test
  #
  # `GET /admin/media/settings` (extended to also render 11a's storage-target
  # form) plus two NEW actions this story adds to
  # `Nebu.Admin.MediaSettingsController`: `save_storage/2`
  # (`POST /admin/media/settings/storage`) and `test_connection/2`
  # (`POST /admin/media/settings/storage/test-connection`).
  #
  # ## Why every test below MUST fail right now (and for the RIGHT reason)
  #
  # Neither `save_storage/2` nor `test_connection/2` exist on
  # `Nebu.Admin.MediaSettingsController` yet, and NEITHER of the two POST
  # routes above exists in `server/lib/nebu/admin/router.ex` yet (only 9b's
  # `GET`/`POST /admin/media/settings` do). Every POST-based test below
  # therefore anchors on a definite status-code assertion tied to the AC's
  # intended outcome (200 for a blocked/error re-render, 302/303 for a
  # successful save, 302 for an unauthenticated redirect) — since the actual
  # current response is a plain 404 (`Phoenix.Router.NoRouteError`, surfaced
  # by the endpoint as a 404 response, same as 9b's own moduledoc already
  # documented for ITS RED phase), that anchor assertion fails deterministically
  # BEFORE any negative-only assertion (`refute_received`, `refute ... =~`)
  # could otherwise pass vacuously just because the feature doesn't exist yet.
  # The GET-based tests (AC1/AC2/AC8's label test) hit the ALREADY-EXISTING
  # `index/2` action (200 OK) but assert on storage-form markup that `index/2`
  # does not render yet — those fail on a missing-content assertion, not a
  # routing error, which is an equally correct RED reason (the GET route
  # itself is not missing; the SECOND form section on it is).
  #
  # ## Deviations from the story's literal wording (documented, mirrors 9b's
  # own "stale phrasing" section above)
  #
  # 1. **Secret presence contract.** The story's AC2 text describes
  #    `Nebu.Media.StorageConfig.get/0` returning a boolean presence flag
  #    (`access_key_set: true/false`). The REAL 11a implementation (already
  #    shipped, see `server/lib/nebu/media/storage_config.ex`) instead returns
  #    the secret itself **masked** (`"••••" <> last 4 chars`, or `nil` when
  #    unset) — `get/0` masks internally, so a decrypted plaintext already
  #    never reaches this controller. Tests below assert against THAT real
  #    contract (a masked/`nil` value + a textual "configured" hint), not a
  #    literal `access_key_set` boolean.
  # 2. **Existing-files-count test seam.** The story's Technical Requirements
  #    section names the query and its home (inline SQL inside `Nebu.Admin`,
  #    e.g. `Nebu.Admin.DB.count_media_with_storage_key/0`) but does not pin an
  #    exact test-injection seam name. This suite invents
  #    `Application.get_env(:nebu_http, :media_files_storage_key_count_fun)`
  #    (0-arity fun returning a non-negative integer) — mirroring the SAME
  #    fn-backed-fake convention already used throughout this codebase
  #    (`:media_storage_config_source`/`_loader`/`_writer`/`_env_reader` right
  #    above, `Nebu.Web.MediaFakes`'s `:media_storage_get_fun`/etc.) — for
  #    dev-story to wire the real helper to, falling back to a genuine
  #    `SELECT COUNT(*) FROM media_files WHERE storage_key IS NOT NULL` when
  #    unset, exactly like every other seam in this file/module.
  # 3. **Acknowledgment checkbox field name.** Not pinned by the story; AC8's
  #    test below asserts only that a native `<input type="checkbox">` is
  #    present in the blocked re-render, not a specific `name=` attribute —
  #    dev-story's own choice, mirroring this file's existing tolerance for
  #    unspecified markup details (e.g. AC8's `has_label_or_aria?` helper).
  #
  # ## Test count vs. the story's own count
  #
  # The story's prose says "24 tests total" but its own "Acceptance Tests"
  # list enumerates 26 concrete test names across AC1–AC8. This file
  # implements all 26 listed names verbatim; no name was dropped or invented
  # beyond what's necessary for the seam/anchor reasons above.

  @storage_path "/admin/media/settings/storage"
  @test_connection_path "/admin/media/settings/storage/test-connection"

  @storage_fields ~w(endpoint bucket region use_ssl access_key secret_key s3_key_prefix_template archive_bucket iam_endpoint sts_endpoint)

  # M-2/M-3 fix (epic security review, 2026-07-20): endpoint is now validated
  # via Nebu.Media.SSRF.checked_target/1 on both the test-connection and
  # persist paths, so a literal public IP is used here (no live DNS lookup
  # needed — mirrors webhook_delivery_test.exs's own convention) instead of
  # a made-up hostname like "s3.example.com" that would never resolve.
  @baseline_storage_params %{
    "endpoint" => "93.184.216.34:9000",
    "bucket" => "nebu-media-new",
    "region" => "eu-central-1",
    "use_ssl" => "true",
    "access_key" => "",
    "secret_key" => "",
    "s3_key_prefix_template" => "{media_id}",
    "archive_bucket" => "",
    # bugfix-add-sts-iam-endpoints-to-admin-ui (AC3): optional, but NOT the
    # plain blank-omit convention region/archive_bucket use above — these two
    # go through put_env_backed_field/5's clear/no-op/override rule instead
    # (see media_settings_controller.ex for the full rationale).
    "iam_endpoint" => "",
    "sts_endpoint" => ""
  }

  defp storage_params(overrides \\ %{}), do: Map.merge(@baseline_storage_params, overrides)

  defp post_storage(params, conn_builder \\ &build_admin_conn/2) do
    conn_builder.(:post, @storage_path)
    |> Map.put(:body_params, params)
    |> endpoint_call()
  end

  defp post_test_connection(params, conn_builder \\ &build_admin_conn/2) do
    conn_builder.(:post, @test_connection_path)
    |> Map.put(:body_params, params)
    |> endpoint_call()
  end

  # Finds the FIRST rendered <input ... name="field" ...> tag verbatim, or
  # `nil` if no such input exists on the page. Used (unlike
  # `field_rendered_with_value?/3` above) when the assertion needs to inspect
  # attributes OTHER than `value=` — e.g. "has type=\"password\"", "has NO
  # value= attribute at all" — and, critically, doubles as the RED-phase
  # anchor for AC2's negative-only assertions: `nil` (input doesn't exist yet)
  # fails the `assert tag, ...` immediately, instead of letting a
  # `refute String.contains?(...)` pass vacuously.
  defp find_input_tag(body, field) do
    ~r/<input\b[^>]*name="#{field}"[^>]*>/
    |> Regex.scan(body)
    |> List.flatten()
    |> List.first()
  end

  # Configures a real Nebu.Web.SecretBox at-rest key and encrypts `plaintext`
  # under it — used only by the AC3 "blank secret resolves against the
  # currently stored secret" test, which needs a genuine
  # SecretBox-encrypted `secret_key_encrypted`/`access_key_encrypted` column
  # value for `Nebu.Media.StorageConfig.get_for_connection/0`'s real decrypt
  # path to hand `test_connection/1` a real plaintext to resolve against.
  defp encrypt_stored_secret(plaintext) do
    Application.put_env(:nebu_http, :admin_secret_at_rest, "test-11b-storage-ui-at-rest-secret")
    Nebu.Web.SecretBox.encrypt(plaintext)
  end

  @storage_config_loader_row %{
    "endpoint" => "old-endpoint:9000",
    "bucket" => "old-bucket",
    "region" => "us-east-1",
    "use_ssl" => false,
    "access_key_encrypted" => nil,
    "secret_key_encrypted" => nil,
    "s3_key_prefix_template" => "{media_id}",
    "archive_bucket" => nil,
    # bugfix-add-sts-iam-endpoints-to-admin-ui (AC1): unset by default, same
    # as archive_bucket above — DB row fixture individual tests override.
    "iam_endpoint" => nil,
    "sts_endpoint" => nil
  }

  defp storage_config_loader_row(overrides \\ %{}),
    do: Map.merge(@storage_config_loader_row, overrides)

  # ══════════════════════════════════════════════════════════════════════════
  # AC1: storage section renders on GET /admin/media/settings
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: storage section renders on GET /admin/media/settings" do
    test "renders the storage form pre-filled with the current media_storage_config values" do
      Application.put_env(:nebu_http, :media_storage_config_source, fn ->
        %{
          endpoint: "custom.s3.example.com:9000",
          bucket: "custom-bucket",
          region: "eu-west-1",
          use_ssl: true,
          access_key: nil,
          secret_key: nil,
          s3_key_prefix_template: "{media_id}/orig",
          archive_bucket: "custom-archive"
        }
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      for {field, value} <- [
            {"endpoint", "custom.s3.example.com:9000"},
            {"bucket", "custom-bucket"},
            {"region", "eu-west-1"},
            {"s3_key_prefix_template", "{media_id}/orig"},
            {"archive_bucket", "custom-archive"}
          ] do
        assert field_rendered_with_value?(body, field, value),
               "expected the storage form's #{field} input to be pre-filled with " <>
                 "#{inspect(value)} from Nebu.Media.StorageConfig.get/0, body: #{body}"
      end
    end

    test "a fresh/empty storage config pre-fills endpoint/bucket/region from NEBU_MINIO_* env vars" do
      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_ENDPOINT" => "env-minio:9000",
          "NEBU_MINIO_BUCKET" => "env-bucket",
          "NEBU_S3_REGION" => "env-region-1"
        }
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      for {field, value} <- [
            {"endpoint", "env-minio:9000"},
            {"bucket", "env-bucket"},
            {"region", "env-region-1"}
          ] do
        assert field_rendered_with_value?(body, field, value),
               "expected #{field} to fall back to its NEBU_MINIO_*/NEBU_S3_REGION env var " <>
                 "#{inspect(value)} when no media_storage_config row exists yet, body: #{body}"
      end
    end

    test "once a media_storage_config row exists, env vars no longer override the stored value on reload" do
      Application.put_env(
        :nebu_http,
        :media_storage_config_loader,
        fn ->
          storage_config_loader_row(%{
            "endpoint" => "db-stored-endpoint:9000",
            "bucket" => "db-stored-bucket",
            "region" => "db-stored-region"
          })
        end
      )

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_ENDPOINT" => "should-be-ignored:9000",
          "NEBU_MINIO_BUCKET" => "should-be-ignored-bucket",
          "NEBU_S3_REGION" => "should-be-ignored-region"
        }
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      assert field_rendered_with_value?(body, "endpoint", "db-stored-endpoint:9000"),
             "expected the DB-stored endpoint to win over the env-var fallback once a row " <>
               "exists, body: #{body}"

      refute field_rendered_with_value?(body, "endpoint", "should-be-ignored:9000"),
             "the env-var value must NOT override a persisted media_storage_config row"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2: secret fields are write-only
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: secret fields are write-only" do
    test "access_key and secret_key inputs render with no value attribute, regardless of a configured secret" do
      Application.put_env(:nebu_http, :media_storage_config_source, fn ->
        %{access_key: "AKIAEXAMPLEPLAINTEXT1234", secret_key: "super-secret-plaintext-value-5678"}
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      for field <- ["access_key", "secret_key"] do
        tag = find_input_tag(body, field)

        assert tag,
               "expected a #{field} <input> to be rendered on the storage form, body: #{body}"

        assert String.contains?(tag, ~s(type="password")),
               "expected the #{field} input to be type=\"password\", got: #{tag}"

        refute String.contains?(tag, "value="),
               "expected the #{field} input to carry NO value attribute at all, got: #{tag}"
      end
    end

    test "the rendered HTML never contains the actual stored plaintext access_key or secret_key" do
      plaintext_access_key = "AKIA_MUST_NEVER_LEAK_9999"
      plaintext_secret_key = "must-never-leak-secret-plaintext-abcd"

      Application.put_env(:nebu_http, :media_storage_config_source, fn ->
        %{access_key: plaintext_access_key, secret_key: plaintext_secret_key}
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      assert find_input_tag(body, "access_key"),
             "expected the storage form to render (so this test can meaningfully check it " <>
               "does not leak the secret), body: #{body}"

      refute String.contains?(body, plaintext_access_key),
             "the rendered HTML must never contain the stored plaintext access_key"

      refute String.contains?(body, plaintext_secret_key),
             "the rendered HTML must never contain the stored plaintext secret_key"
    end

    test "each secret field renders a presence hint (configured/not configured) without the plaintext" do
      Application.put_env(:nebu_http, :media_storage_config_source, fn ->
        %{access_key: "AKIAHINTCHECK0001", secret_key: nil}
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      assert find_input_tag(body, "access_key"),
             "expected the storage form to render before checking presence hints, body: #{body}"

      assert body =~ ~r/configured|currently set|leave blank/i,
             "expected a presence hint (e.g. 'configured'/'leave blank to keep the current " <>
               "value') near the secret fields, body: #{body}"

      refute String.contains?(body, "AKIAHINTCHECK0001"),
             "the presence hint must never leak the actual plaintext access_key"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3: Test Connection against submitted, unsaved values
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: Test Connection against submitted, unsaved values" do
    test "test-connection success (mocked S3 client) renders a role=status confirmation and does not persist" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn _candidate -> :ok end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_test_connection(storage_params(%{"endpoint" => "93.184.216.34:9000"}))

      assert conn.status == 200,
             "expected a Test Connection POST to re-render the page (200), not redirect or " <>
               "404; got #{conn.status}"

      assert conn.resp_body =~ ~s(role="status"),
             "expected a role=\"status\" success confirmation, body: #{conn.resp_body}"

      refute_received {:storage_config_written, _columns, _set_at},
                      "Test Connection must never call Nebu.Media.StorageConfig.upsert/1"
    end

    test "test-connection failure (mocked S3 client returning an error) renders a role=alert message without leaking secret material" do
      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn _candidate ->
        {:error,
         %{
           reason: :nxdomain,
           url: "https://AKIALEAKED1234:s3cr3t@candidate.s3.example.com/bucket"
         }}
      end)

      conn =
        post_test_connection(
          storage_params(%{
            "endpoint" => "93.184.216.34:9000",
            "access_key" => "AKIALEAKED1234"
          })
        )

      assert conn.status == 200,
             "expected a failed Test Connection to re-render the page (200); got #{conn.status}"

      assert conn.resp_body =~ ~s(role="alert"),
             "expected a role=\"alert\" failure message, body: #{conn.resp_body}"

      refute String.contains?(conn.resp_body, "AKIALEAKED1234"),
             "a Test Connection failure message must never echo credential material from the " <>
               "raw ExAws/:hackney error"

      refute String.contains?(conn.resp_body, "nxdomain"),
             "a Test Connection failure message must be a fixed, generic message, not the " <>
               "raw error reason"
    end

    test "test-connection with a blank secret field resolves it against the currently stored secret server-side, never round-tripping plaintext to the response" do
      stored_plaintext_secret = "server-side-only-secret-abc123"
      encrypted = encrypt_stored_secret(stored_plaintext_secret)
      test_pid = self()

      Application.put_env(
        :nebu_http,
        :media_storage_config_loader,
        fn -> storage_config_loader_row(%{"secret_key_encrypted" => encrypted}) end
      )

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
        send(test_pid, {:test_connection_candidate, candidate})
        :ok
      end)

      conn = post_test_connection(storage_params(%{"secret_key" => ""}))

      assert conn.status == 200,
             "expected the Test Connection POST to re-render the page (200); got #{conn.status}"

      assert_received {:test_connection_candidate, candidate},
                      "expected Nebu.Media.StorageConfig.test_connection/1 to be called with " <>
                        "a candidate map"

      assert candidate.secret_key == stored_plaintext_secret,
             "a blank submitted secret_key must be resolved server-side against the currently " <>
               "stored decrypted secret before the S3 call, got: #{inspect(candidate.secret_key)}"

      refute String.contains?(conn.resp_body, stored_plaintext_secret),
             "the resolved plaintext secret must never round-trip into the response body"
    end

    test "test-connection does not call Nebu.Media.StorageConfig.upsert/1" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn _candidate -> :ok end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_test_connection(storage_params())

      assert conn.status == 200,
             "expected the Test Connection POST to re-render the page (200), not redirect or " <>
               "404; got #{conn.status}"

      refute_received {:storage_config_written, _columns, _set_at},
                      "Test Connection must never reach Nebu.Media.StorageConfig.upsert/1's " <>
                        "write seam"
    end

    # M-2 fix (epic security review, 2026-07-20): a private/loopback/
    # link-local/cloud-metadata endpoint must be rejected end-to-end through
    # the full HTTP path, before the (mocked) test-connection fun is ever
    # invoked — mirrors the existing "a webhook_url resolving to a private or
    # link-local IP range is rejected" test's convention exactly (same
    # literal-IP fixtures, same role="alert" rendering contract).
    test "a storage endpoint resolving to a private, loopback, or cloud-metadata address is rejected before any real request" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
        send(test_pid, {:test_connection_called, candidate})
        :ok
      end)

      for endpoint <- ["127.0.0.1:9000", "10.0.0.5:9000", "169.254.169.254:80"] do
        conn = post_test_connection(storage_params(%{"endpoint" => endpoint}))

        assert conn.status == 200,
               "a blocked endpoint (#{endpoint}) must re-render at 200, not redirect or crash; " <>
                 "got #{conn.status}"

        assert conn.resp_body =~ ~s(role="alert"),
               "expected a role=\"alert\" rejection for #{endpoint}, body: #{conn.resp_body}"

        refute_received {:test_connection_called, _candidate},
                        "a blocked endpoint (#{endpoint}) must never reach the test-connection " <>
                          "fun / any real ExAws request"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4: orphan-risk warning on endpoint/bucket change
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: orphan-risk warning on endpoint/bucket change" do
    test "changing endpoint with existing media_files (storage_key IS NOT NULL) blocks the first save and renders the warning with the correct count N" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 7 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"endpoint" => "new-endpoint:9000"}))

      assert conn.status == 200,
             "an orphan-risk-blocked save must re-render at 200, not redirect; got #{conn.status}"

      assert conn.resp_body =~ "7",
             "expected the exact existing-files count (7) to appear in the warning, " <>
               "body: #{conn.resp_body}"

      refute_received {:storage_config_written, _columns, _set_at},
                      "the first submission of an endpoint change with existing files " <>
                        "present must NOT reach Nebu.Media.StorageConfig.upsert/1"
    end

    test "changing bucket with existing media_files blocks the first save and renders the warning" do
      test_pid = self()

      Application.put_env(
        :nebu_http,
        :media_storage_config_loader,
        fn -> storage_config_loader_row(%{"endpoint" => "same-endpoint:9000"}) end
      )

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 3 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{"endpoint" => "same-endpoint:9000", "bucket" => "new-bucket"})
        )

      assert conn.status == 200,
             "an orphan-risk-blocked bucket change must re-render at 200, not redirect; " <>
               "got #{conn.status}"

      assert conn.resp_body =~ ~s(role="alert"),
             "expected the orphan-risk warning to carry role=\"alert\", body: #{conn.resp_body}"

      refute_received {:storage_config_written, _columns, _set_at},
                      "a bucket change with existing files present must NOT persist on the " <>
                        "first submission"
    end

    test "checking the acknowledgment checkbox and resubmitting persists the endpoint/bucket change" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 5 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "93.184.216.34:9000",
            "confirm_orphan_risk" => "true"
          })
        )

      assert conn.status in [200, 302, 303],
             "expected the acknowledged resubmission to succeed; got #{conn.status}: " <>
               "#{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at},
                      "expected the acknowledged endpoint change to reach " <>
                        "Nebu.Media.StorageConfig.upsert/1's write seam"

      assert Map.get(columns, "endpoint") == "93.184.216.34:9000",
             "expected the persisted endpoint column to be the new, submitted value, " <>
               "got: #{inspect(columns)}"
    end

    test "the warning does NOT appear when the storage config is fresh/empty (no media_storage_config row yet)" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 42 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"endpoint" => "93.184.216.34:9000"}))

      assert conn.status in [200, 302, 303],
             "a fresh/empty storage config must save normally; got #{conn.status}: " <>
               "#{conn.resp_body}"

      if conn.status == 200 do
        refute conn.resp_body =~ ~s(role="alert"),
               "a fresh/empty config must not gate on the orphan-risk warning, " <>
                 "body: #{conn.resp_body}"
      end

      assert_received {:storage_config_written, _columns, _set_at},
                      "a fresh/empty config's first save must persist without requiring " <>
                        "acknowledgment"
    end

    test "the warning does NOT appear when media_files has zero rows with a non-null storage_key" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"endpoint" => "93.184.216.34:9000"}))

      assert conn.status in [200, 302, 303],
             "expected a normal save when zero files reference storage_key; got " <>
               "#{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, _columns, _set_at},
                      "a zero-count existing-files check must never block persistence"
    end

    test "the warning does NOT appear when only region, use_ssl, s3_key_prefix_template, or archive_bucket change without an endpoint/bucket change" do
      test_pid = self()

      Application.put_env(
        :nebu_http,
        :media_storage_config_loader,
        fn ->
          storage_config_loader_row(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket"
          })
        end
      )

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 9 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "region" => "eu-central-1",
            "use_ssl" => "true",
            "archive_bucket" => "new-archive"
          })
        )

      assert conn.status in [200, 302, 303],
             "expected a normal save when endpoint/bucket are unchanged; got #{conn.status}: " <>
               "#{conn.resp_body}"

      assert_received {:storage_config_written, _columns, _set_at},
                      "changing only region/use_ssl/s3_key_prefix_template/archive_bucket " <>
                        "must never trigger the orphan-risk gate"
    end

    test "submitting without checking the acknowledgment checkbox a second time still does not persist" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 4 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"endpoint" => "new-endpoint:9000"}))

      assert conn.status == 200,
             "a resubmission without the acknowledgment checkbox must still re-render at 200; " <>
               "got #{conn.status}"

      refute_received {:storage_config_written, _columns, _set_at},
                      "a second submission that STILL omits the acknowledgment checkbox must " <>
                        "not persist either"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5/AC6: persistence and existing-files count ownership
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5/AC6: persistence and existing-files count ownership" do
    test "a valid save calls Nebu.Media.StorageConfig.upsert/1 and never issues a direct media_storage_config INSERT/UPDATE" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"bucket" => "brand-new-bucket"}))

      assert conn.status in [200, 302, 303],
             "expected a valid save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at},
                      "expected the save to reach Nebu.Media.StorageConfig.upsert/1's real " <>
                        "write seam (the ONLY observable persistence path, since this suite " <>
                        "never starts a live Nebu.Repo — a direct SQL write from the " <>
                        "controller would itself fail loudly rather than silently succeed)"

      assert Map.get(columns, "bucket") == "brand-new-bucket",
             "expected the persisted bucket column to be the new, submitted value, " <>
               "got: #{inspect(columns)}"
    end

    test "the existing-files count is read via inline SQL in the Nebu.Admin namespace, not a Nebu.Media public-API call" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn ->
        send(test_pid, :existing_files_count_queried)
        6
      end)

      conn = post_storage(storage_params(%{"endpoint" => "new-endpoint:9000"}))

      assert conn.status == 200,
             "expected the endpoint change to be blocked and re-rendered at 200; got " <>
               "#{conn.status}"

      assert_received :existing_files_count_queried,
                      "expected the existing-files check to go through the Nebu.Admin-owned " <>
                        "count seam (mirroring Nebu.Admin.DB's role and the ADR-018 " <>
                        "exception already established for Nebu.Admin.MediaLive, Story 5a) " <>
                        "rather than any Nebu.Media public-API call — there is no Nebu.Media " <>
                        "function that returns this count, so this seam is the only place " <>
                        "it can legitimately come from"

      assert conn.resp_body =~ "6",
             "expected the queried count (6) to appear in the rendered warning, body: " <>
               "#{conn.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7: admin-only access
  # ══════════════════════════════════════════════════════════════════════════

  # NOTE: named "AC7 (11b)" rather than the bare "AC7: admin-only access" the
  # story's Acceptance Tests section literally lists — 9b's OWN AC7 describe
  # block (line ~649 above) already claims that exact string, and ExUnit
  # rejects two `describe` blocks with an identical description in the same
  # module (`ArgumentError: describe "..." is already defined`). Both
  # stories' ACs happen to share the number "7" (each counts its own
  # criteria from 1); this is a naming collision between two stories sharing
  # one test file, not a test-content deviation — the two test names inside
  # are exactly as the 11b story specifies.
  describe "AC7 (11b): admin-only access — storage endpoints" do
    test "an unauthenticated POST to /admin/media/settings/storage is redirected to /admin/login, not persisted" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(), &build_conn/2)

      assert conn.status == 302,
             "an unauthenticated POST must redirect (302); got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"

      refute_received {:storage_config_written, _columns, _set_at},
                      "an unauthenticated POST must never reach " <>
                        "Nebu.Media.StorageConfig.upsert/1"
    end

    test "an unauthenticated POST to /admin/media/settings/storage/test-connection is redirected to /admin/login" do
      conn = post_test_connection(storage_params(), &build_conn/2)

      assert conn.status == 302,
             "an unauthenticated POST must redirect (302); got #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/login"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC8: accessibility
  # ══════════════════════════════════════════════════════════════════════════

  # NOTE: named "AC8 (11b)" for the same reason as "AC7 (11b)" above — 9b's
  # own AC8 describe block already claims the bare "AC8: accessibility"
  # string.
  describe "AC8 (11b): accessibility — storage form" do
    test "every storage-form input has an associated label" do
      Application.put_env(:nebu_http, :media_storage_config_source, fn -> %{} end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      for field <- @storage_fields do
        assert has_label_or_aria?(body, field),
               "expected an associated <label for=\"#{field}\"> or nearby aria-label for the " <>
                 "storage form's #{field} input, body: #{body}"
      end
    end

    test "the Test Connection and Save buttons are both native submit buttons with distinct formaction attributes, no onclick handler" do
      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      assert body =~ ~r/<button[^>]*formaction="#{Regex.escape(@test_connection_path)}"[^>]*>/,
             "expected a native submit button with formaction=\"#{@test_connection_path}\", " <>
               "body: #{body}"

      refute body =~ ~r/onclick=/i,
             "the Test Connection / Save distinction must use native formaction, never a JS " <>
               "onclick handler"
    end

    test "the acknowledgment checkbox is a native input[type=checkbox]" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 2 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"endpoint" => "new-endpoint:9000"}))

      assert conn.status == 200,
             "expected the orphan-risk-blocked re-render at 200; got #{conn.status}"

      assert conn.resp_body =~ ~r/<input\b[^>]*type="checkbox"[^>]*>/,
             "expected a native <input type=\"checkbox\"> for the acknowledgment, never a " <>
               "custom widget, body: #{conn.resp_body}"
    end

    test "the test-connection result carries role=\"status\" on success and role=\"alert\" on failure" do
      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn _candidate -> :ok end)

      success_conn = post_test_connection(storage_params())

      assert success_conn.status == 200,
             "expected a successful Test Connection to re-render at 200; got " <>
               "#{success_conn.status}"

      assert success_conn.resp_body =~ ~s(role="status"),
             "expected role=\"status\" on Test Connection success, body: " <>
               "#{success_conn.resp_body}"

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn _candidate ->
        {:error, :connection_refused}
      end)

      failure_conn = post_test_connection(storage_params())

      assert failure_conn.status == 200,
             "expected a failed Test Connection to re-render at 200; got #{failure_conn.status}"

      assert failure_conn.resp_body =~ ~s(role="alert"),
             "expected role=\"alert\" on Test Connection failure, body: " <>
               "#{failure_conn.resp_body}"
    end

    test "the orphan-risk warning carries role=\"alert\"" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row()
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 1 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn = post_storage(storage_params(%{"bucket" => "new-bucket"}))

      assert conn.status == 200,
             "expected the orphan-risk-blocked re-render at 200; got #{conn.status}"

      assert conn.resp_body =~ ~s(role="alert"),
             "expected the orphan-risk warning to carry role=\"alert\", body: #{conn.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # bugfix-add-sts-iam-endpoints-to-admin-ui — iam_endpoint/sts_endpoint admin
  # UI exposure (follow-on to story 11b / bugfix-upcloud-s3-iam-sts-endpoints,
  # which added these two fields to Nebu.Media.StorageConfig's resolved
  # config env-only, with no DB-override column and no admin-UI exposure).
  #
  # RED-phase note: `validate_storage_params/1` does not read
  # `params["iam_endpoint"]`/`params["sts_endpoint"]` at all today, and
  # neither `candidate_from_params/1` nor `storage_config_from_params/1`
  # include these keys in their returned maps — so every assertion below that
  # checks a SUBMITTED/non-blank value made it through fails on a plain
  # value-mismatch (nil/absent vs. the expected submitted value), not a
  # crash. The `index.html.heex` template also has no iam_endpoint/
  # sts_endpoint input yet (AC6), so every `field_rendered_with_value?`/
  # `has_label_or_aria?` assertion below fails for that reason too, until the
  # dev-story step adds the markup.
  # ══════════════════════════════════════════════════════════════════════════

  describe "bugfix-add-sts-iam-endpoints AC3: optional form params" do
    # code review (cycle 1, MAJOR-1): this test previously asserted the plain
    # blank-omit rule (`refute Map.has_key?(columns, "iam_endpoint")`) that
    # MAJOR-1's fix deliberately overturns for these two fields ONLY — a
    # blank submission now clears an existing/potential DB override via an
    # EXPLICIT `nil`, never a silent omission. Updated to assert the new
    # 3-way rule's "blank -> explicit nil" + "differs from env -> persisted"
    # clauses together (still per-field independent); see the two dedicated
    # MAJOR-1 tests below for the "matches env -> omitted" no-op clause.
    #
    # code review (cycle 1 re-review, MAJOR-N1): the rule is now baselined on
    # `StorageConfig.get()`'s RESOLVED value, not the env-only value — "blank
    # -> explicit nil" only fires when the resolved baseline was actually
    # non-blank (there is something to clear). This test's iam_endpoint case
    # therefore now needs a genuine EXISTING DB override to blank out
    # (previously it blanked an already-nil field, which under the
    # MAJOR-N1 fix is correctly a no-op/omit — see the dedicated case-5 test
    # below for that scenario).
    test "blank iam/sts is written as an explicit NULL (clears an override), non-blank differing from env is persisted, per field independently" do
      test_pid = self()
      old_iam = "https://db-existing.example.com:4443/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "iam_endpoint" => old_iam
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): a
      # submitted, non-blank sts_endpoint is now validated (https:// +
      # Nebu.Media.SSRF.checked_target/1), so a literal public IP is used
      # here (no live DNS lookup needed — mirrors this file's own
      # @baseline_storage_params["endpoint"] convention) instead of a
      # hostname like "7mf5k.upcloudobjects.com" that does not resolve.
      sts_url = "https://93.184.216.34:4443/sts"

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "iam_endpoint" => "",
            "sts_endpoint" => sts_url
          })
        )

      assert conn.status in [200, 302, 303],
             "expected a save with one blank and one set endpoint field to succeed; got " <>
               "#{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      assert Map.has_key?(columns, "iam_endpoint") and Map.get(columns, "iam_endpoint") == nil,
             "MAJOR-1: a blank iam_endpoint must be written as an EXPLICIT NULL (not omitted) " <>
               "so it actually clears the existing DB override (#{inspect(old_iam)}) back to " <>
               "env-controlled, got: #{inspect(columns)}"

      assert Map.get(columns, "sts_endpoint") == sts_url,
             "expected the submitted sts_endpoint value (differing from the resolved baseline) " <>
               "to be persisted to its own DB column, got: #{inspect(columns)}"
    end

    test "MAJOR-1: a blank submission clears an EXISTING DB override back to env-controlled (explicit NULL)" do
      test_pid = self()
      old_iam = "https://7mf5k.upcloudobjects.com:4443/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "iam_endpoint" => old_iam
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "iam_endpoint" => ""
          })
        )

      assert conn.status in [200, 302, 303],
             "expected clearing an existing iam_endpoint override to succeed; got " <>
               "#{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      assert Map.has_key?(columns, "iam_endpoint") and Map.get(columns, "iam_endpoint") == nil,
             "expected a blank iam_endpoint submission (where a DB override of " <>
               "#{inspect(old_iam)} already exists) to reach the writer as an explicit " <>
               "SET iam_endpoint = NULL — there is no other UI way to go back to " <>
               "env-controlled, got: #{inspect(columns)}"
    end

    test "MAJOR-1: the first save on a fresh config that only changes region does not silently promote the untouched, env-pre-filled iam/sts values into the DB" do
      test_pid = self()

      # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): these
      # values are RESUBMITTED verbatim below, so they are validated by the
      # new https:// + SSRF.checked_target/1 guard even though Rule 1 omits
      # them from the write — a literal public IP needs no live DNS lookup.
      iam_env = "https://93.184.216.34:4443/iam"
      sts_env = "https://93.184.216.34:4443/sts"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_IAM_ENDPOINT" => iam_env,
          "NEBU_MINIO_STS_ENDPOINT" => sts_env
        }
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      # Simulates the exact MAJOR-1 scenario: a never-configured install's
      # form pre-fills iam_endpoint/sts_endpoint from the env values above
      # (AC5). The admin only intends to change `region` and submits the
      # form as rendered — every other field, including the untouched
      # iam/sts inputs, is resubmitted verbatim, exactly as a real browser
      # would.
      conn =
        post_storage(
          storage_params(%{
            "region" => "eu-west-2",
            "iam_endpoint" => iam_env,
            "sts_endpoint" => sts_env
          })
        )

      assert conn.status in [200, 302, 303],
             "expected the save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      refute Map.has_key?(columns, "iam_endpoint"),
             "MAJOR-1: an untouched, env-pre-filled iam_endpoint must NOT be written to the " <>
               "DB just because an unrelated field (region) was saved — got: #{inspect(columns)}"

      refute Map.has_key?(columns, "sts_endpoint"),
             "MAJOR-1: an untouched, env-pre-filled sts_endpoint must NOT be written to the " <>
               "DB just because an unrelated field (region) was saved — got: #{inspect(columns)}"

      assert Map.get(columns, "region") == "eu-west-2",
             "the actually-changed region must still be persisted normally, got: " <>
               "#{inspect(columns)}"
    end

    # code review (cycle 1 re-review, MAJOR-N1): this is the actual
    # regression the cycle-1 fix introduced — reproduces the exact scenario
    # from the review finding. A DB override already exists; the admin
    # deliberately edits the field to the env value (a legitimate,
    # intentional change — "go back to what the environment says, I happen
    # to know what that is"). The OLD rule baselined "untouched -> omit" on
    # `StorageConfig.env_only_iam_sts/0` (env-var-only), so this submission
    # matched the env value and was silently discarded — the admin's edit
    # never reached the DB, with a false "saved successfully" flash and no
    # error, no log. The fix baselines that comparison on the RESOLVED
    # (DB-override-aware) value instead, so a value that differs from what's
    # actually in effect is always persisted, even if it happens to equal
    # the env var.
    test "MAJOR-N1: a DB override deliberately changed TO the current env value is persisted, not silently discarded" do
      test_pid = self()
      db_override_iam = "https://db-override.example.com:4443/iam"
      # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08):
      # resubmitted below (the whole point of this test), so it must pass
      # the new https:// + SSRF.checked_target/1 guard — a literal public
      # IP needs no live DNS lookup. `db_override_iam` above is never
      # submitted (loader-seam/baseline fixture only), so it is untouched.
      env_iam = "https://93.184.216.34:4443/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "iam_endpoint" => db_override_iam
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_IAM_ENDPOINT" => env_iam}
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "iam_endpoint" => env_iam
          })
        )

      assert conn.status in [200, 302, 303],
             "expected the save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      assert Map.has_key?(columns, "iam_endpoint") and Map.get(columns, "iam_endpoint") == env_iam,
             "MAJOR-N1: changing an existing DB override (#{inspect(db_override_iam)}) to the " <>
               "current env value (#{inspect(env_iam)}) must be PERSISTED, not silently " <>
               "discarded just because the submitted value happens to match the env var — " <>
               "got: #{inspect(columns)}"
    end

    # code review (cycle 1 re-review, MINOR-2): companion fix bundled with
    # MAJOR-N1 — `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` set but
    # EMPTY (common when a Terraform/env template always defines the var,
    # just blank by default). The form pre-fills both inputs with "" (the
    # resolved value), and the admin leaves them untouched. Under the OLD
    # rule, Rule 1 ("blank submission -> explicit nil") fired unconditionally
    # with no baseline check, so this resubmitted EVERY single save as a
    # redundant `SET iam_endpoint = NULL` / `SET sts_endpoint = NULL` plus a
    # bogus `changed_fields` audit entry claiming the field changed when it
    # never did. The fix: both sides normalize through `blank_to_nil/1`
    # before comparing, so submitted (nil) == baseline (nil) -> omit, exactly
    # like every other already-blank, untouched field.
    test "MINOR-2: NEBU_MINIO_IAM_ENDPOINT/NEBU_MINIO_STS_ENDPOINT set but empty, on a fresh install, converges — no redundant write, no phantom audit entry" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_IAM_ENDPOINT" => "", "NEBU_MINIO_STS_ENDPOINT" => ""}
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "region" => "eu-west-2",
            "iam_endpoint" => "",
            "sts_endpoint" => ""
          })
        )

      assert conn.status in [200, 302, 303],
             "expected the save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      refute Map.has_key?(columns, "iam_endpoint"),
             "MINOR-2: a field whose resolved baseline is already blank (env var set but " <>
               "empty, no DB override) must be OMITTED, not re-written as an explicit NULL, " <>
               "when the admin leaves it untouched — got: #{inspect(columns)}"

      refute Map.has_key?(columns, "sts_endpoint"),
             "MINOR-2: same as above for sts_endpoint — got: #{inspect(columns)}"

      assert Map.get(columns, "region") == "eu-west-2",
             "the actually-changed region must still be persisted normally, got: " <>
               "#{inspect(columns)}"

      # Nebu.Media.StorageConfig.write_audit/2 derives the audit log's
      # `changed_fields` directly from `Map.keys/1` of this SAME `fields` map
      # handed to the writer above — so refuting the keys here already
      # proves no bogus "iam_endpoint"/"sts_endpoint" audit entry is recorded
      # for this no-op save; there is no separate audit code path to assert
      # on.
    end

    # code review (cycle 2, N2-MINOR-1): distinct from the MINOR-2 test
    # above (env var set but EMPTY — baseline already blank by construction)
    # and from the two dedicated MAJOR-1 tests above (a genuine, non-blank
    # DB override exists). Here the env var is set to a genuine, NON-BLANK
    # URL, and NO media_storage_config row has ever been written for this
    # field (has_db_override? must be false) — there is nothing in the DB to
    # clear. Before this fix, Rule 2 fired on ANY non-blank baseline
    # (DB- or env-sourced indistinguishably), writing a redundant explicit
    # `SET iam_endpoint = NULL` plus a false `changed_fields` audit entry on
    # every single save, forever non-convergent.
    test "N2-MINOR-1: blanking an env-sourced (no DB override) iam_endpoint is omitted, not written as a redundant explicit NULL" do
      test_pid = self()
      env_iam = "https://env-only.example.com:4443/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_IAM_ENDPOINT" => env_iam}
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "region" => "eu-west-2",
            "iam_endpoint" => ""
          })
        )

      assert conn.status in [200, 302, 303],
             "expected the save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      refute Map.has_key?(columns, "iam_endpoint"),
             "N2-MINOR-1: blanking an env-sourced iam_endpoint with NO existing DB override " <>
               "must be OMITTED (there is nothing to clear), not written as a redundant " <>
               "explicit SET iam_endpoint = NULL, got: #{inspect(columns)}"

      assert Map.get(columns, "region") == "eu-west-2",
             "the actually-changed region must still be persisted normally, got: " <>
               "#{inspect(columns)}"
    end

    # code review (cycle 3 re-review, N3-M4): distinct from the N2-MINOR-1
    # test above in one crucial way — there, `media_storage_config_loader`
    # returned `nil` (no row has EVER been written at all). Here a row DOES
    # exist (the loader returns a real row, exercising `persisted_iam_sts/0`'s
    # `row -> ...` branch, not its `nil -> ...` branch) but that row's OWN
    # `iam_endpoint` column was never overridden (`nil`, the
    # `storage_config_loader_row/1` fixture's default). `has_db_override?`
    # must still correctly read `false` here — if `persisted_iam_sts/0`
    # or its caller mixed up "no row" with "row exists but this column is
    # unset," this is the one case that would catch it.
    test "N3-M4: blanking iam_endpoint when a media_storage_config row exists but that column was never overridden is omitted, not written as a redundant explicit NULL" do
      test_pid = self()
      env_iam = "https://row-exists-column-unset.example.com:4443/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket"
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_IAM_ENDPOINT" => env_iam}
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "region" => "eu-south-1",
            "iam_endpoint" => ""
          })
        )

      assert conn.status in [200, 302, 303],
             "expected the save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      refute Map.has_key?(columns, "iam_endpoint"),
             "N3-M4: a media_storage_config row existing (with its OWN iam_endpoint " <>
               "column unset) must be treated identically to no row existing at all — " <>
               "blanking the env-pre-filled field must be OMITTED, not written as a " <>
               "redundant explicit SET iam_endpoint = NULL, got: #{inspect(columns)}"

      assert Map.get(columns, "region") == "eu-south-1",
             "the actually-changed region must still be persisted normally, got: " <>
               "#{inspect(columns)}"
    end

    # code review (cycle 2, N2-MINOR-2): a POST that OMITS the iam_endpoint
    # param entirely (the key itself absent from `params`, never even an
    # empty-string VALUE — only reachable via a scripted/non-browser POST,
    # every real HTML form submission sends the field) must be a pure no-op,
    # exactly like every other optional field's maybe_put_field/3. Before
    # this fix, an absent param came through as `raw = nil`, indistinguishable
    # from "admin submitted blank," and an EXISTING DB override would be
    # destructively cleared by a request that never even mentioned the field.
    test "N2-MINOR-2: a POST that omits iam_endpoint entirely (not blank, absent) is a no-op — an existing DB override survives untouched" do
      test_pid = self()
      old_iam = "https://db-existing.example.com:4443/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "iam_endpoint" => old_iam
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      params =
        storage_params(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "region" => "eu-west-3"
        })
        |> Map.delete("iam_endpoint")

      conn = post_storage(params)

      assert conn.status in [200, 302, 303],
             "expected the save to succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      refute Map.has_key?(columns, "iam_endpoint"),
             "N2-MINOR-2: an iam_endpoint param entirely ABSENT from the POST (not submitted " <>
               "blank) must be a no-op — the existing DB override (#{inspect(old_iam)}) must " <>
               "survive untouched, never cleared, got: #{inspect(columns)}"

      assert Map.get(columns, "region") == "eu-west-3",
             "the actually-changed region must still be persisted normally, got: " <>
               "#{inspect(columns)}"
    end

    test "candidate_from_params/1 carries iam/sts through to test_connection/1's candidate map" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
        send(test_pid, {:test_connection_candidate, candidate})
        :ok
      end)

      iam_url = "https://7mf5k.upcloudobjects.com:4443/iam"
      sts_url = "https://7mf5k.upcloudobjects.com:4443/sts"

      conn =
        post_test_connection(
          storage_params(%{"iam_endpoint" => iam_url, "sts_endpoint" => sts_url})
        )

      assert conn.status == 200,
             "expected the Test Connection POST to re-render the page (200); got #{conn.status}"

      assert_received {:test_connection_candidate, candidate},
                      "expected Nebu.Media.StorageConfig.test_connection/1 to be called with " <>
                        "a candidate map"

      assert Map.get(candidate, :iam_endpoint) == iam_url,
             "expected candidate_from_params/1 to carry iam_endpoint through to the " <>
               "test-connection candidate map, got: #{inspect(candidate)}"

      assert Map.get(candidate, :sts_endpoint) == sts_url,
             "expected candidate_from_params/1 to carry sts_endpoint through to the " <>
               "test-connection candidate map, got: #{inspect(candidate)}"
    end

    test "storage_config_from_params/1 echoes submitted iam/sts back on a blocked/invalid re-render" do
      iam_url = "https://7mf5k.upcloudobjects.com:4443/iam"
      sts_url = "https://7mf5k.upcloudobjects.com:4443/sts"

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "",
            "iam_endpoint" => iam_url,
            "sts_endpoint" => sts_url
          })
        )

      assert conn.status == 200,
             "expected an invalid submission (blank endpoint) to re-render at 200; got " <>
               "#{conn.status}"

      body = conn.resp_body

      assert field_rendered_with_value?(body, "iam_endpoint", iam_url),
             "expected the submitted iam_endpoint to be echoed back on the invalid re-render, " <>
               "body: #{body}"

      assert field_rendered_with_value?(body, "sts_endpoint", sts_url),
             "expected the submitted sts_endpoint to be echoed back on the invalid re-render, " <>
               "body: #{body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08) —
  # iam_endpoint/sts_endpoint scheme + SSRF validation
  # ══════════════════════════════════════════════════════════════════════════
  #
  # iam_endpoint/sts_endpoint were admin-UI-writable and DB-persisted (the
  # describe block above) with NO scheme assertion and NO SSRF guard — the
  # only admin-writable, DB-persisted, URL-shaped fields on this page
  # without one, unlike `endpoint` (invalid_endpoint_scheme?/1 here +
  # Nebu.Media.StorageConfig.validate_candidate_endpoint/1) and `webhook_url`
  # (validate_webhook_url/1, "AC3: webhook_url save-time validation" above,
  # whose test shape these three tests deliberately mirror).

  describe "F-1: iam_endpoint/sts_endpoint scheme + SSRF validation" do
    test "a non-https iam_endpoint/sts_endpoint is rejected before the save reaches the writer seam" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      for field <- ["iam_endpoint", "sts_endpoint"],
          bad_value <- ["93.184.216.34:4443/iam", "http://93.184.216.34:4443/iam"] do
        conn = post_storage(storage_params(%{field => bad_value}))

        assert conn.status == 200,
               "a non-https #{field} (#{bad_value}) must re-render at 200, not redirect; " <>
                 "got #{conn.status}"

        assert conn.resp_body =~ ~r/https/i,
               "expected an error message mentioning the HTTPS requirement for #{field}=" <>
                 "#{bad_value}, body: #{conn.resp_body}"

        refute_received {:storage_config_written, _columns, _set_at},
                        "a non-https #{field} (#{bad_value}) must be rejected before the save " <>
                          "reaches the writer seam"
      end
    end

    test "an https iam_endpoint/sts_endpoint resolving to a private/loopback/link-local address is rejected" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      # Literal IPs — no live DNS lookup needed (mirrors the webhook_url SSRF
      # test above and webhook_delivery_test.exs's own convention).
      for field <- ["iam_endpoint", "sts_endpoint"],
          blocked_url <- ["https://127.0.0.1/iam", "https://169.254.169.254/iam"] do
        conn = post_storage(storage_params(%{field => blocked_url}))

        assert conn.status == 200,
               "a private/link-local #{field} (#{blocked_url}) must re-render at 200, not " <>
                 "redirect; got #{conn.status}"

        assert conn.resp_body =~ ~r/block|private|not allowed|invalid/i,
               "expected an error message about the blocked address for #{field}=" <>
                 "#{blocked_url}, body: #{conn.resp_body}"

        refute_received {:storage_config_written, _columns, _set_at},
                        "a private/link-local #{field} (#{blocked_url}) must be rejected " <>
                          "before the save reaches the writer seam"
      end
    end

    test "a valid https, non-private iam_endpoint/sts_endpoint still saves successfully (regression)" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      iam_url = "https://93.184.216.34:4443/iam"
      sts_url = "https://93.184.216.34:4443/sts"

      conn =
        post_storage(storage_params(%{"iam_endpoint" => iam_url, "sts_endpoint" => sts_url}))

      assert conn.status in [200, 302, 303],
             "expected a valid https iam/sts save to succeed; got #{conn.status}: " <>
               "#{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      assert Map.get(columns, "iam_endpoint") == iam_url,
             "expected the valid iam_endpoint to reach the write seam, got: #{inspect(columns)}"

      assert Map.get(columns, "sts_endpoint") == sts_url,
             "expected the valid sts_endpoint to reach the write seam, got: #{inspect(columns)}"
    end

    # ════════════════════════════════════════════════════════════════════
    # R-1 fix (focused follow-up code review, 2026-10-08) — the F-1 guard
    # above must validate the DECIDED `changes` value, not the raw submitted
    # param. The original F-1 fix validated params["iam_endpoint"]/
    # params["sts_endpoint"] unconditionally, BEFORE `changes` was built —
    # so an untouched, env-pre-filled value that fails the new scheme/SSRF
    # check permanently blocked ALL storage saves (not just that field),
    # since the form always re-renders the same env value on every GET.
    # ════════════════════════════════════════════════════════════════════

    test "R-1 regression: an untouched, env-sourced iam_endpoint that fails the https/SSRF guard does not block saving an unrelated field" do
      test_pid = self()

      # Literal loopback IP (no DNS lookup needed) — simulates the shape of
      # this project's own NEBU_MINIO_ENDPOINT: "minio:9000" docker-compose
      # convention, if ever applied to NEBU_MINIO_IAM_ENDPOINT.
      bad_env_iam = "https://127.0.0.1:9000/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{"NEBU_MINIO_IAM_ENDPOINT" => bad_env_iam}
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      # Exactly what a real browser does: the admin only intends to change
      # `region`, but resubmits the env-pre-filled iam_endpoint input
      # verbatim, untouched.
      conn =
        post_storage(
          storage_params(%{
            "region" => "eu-west-2",
            "iam_endpoint" => bad_env_iam
          })
        )

      assert conn.status in [200, 302, 303],
             "R-1: resubmitting an untouched, env-sourced iam_endpoint that fails the " <>
               "https/SSRF guard must NOT block saving an unrelated field (region); got " <>
               "#{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at},
                      "R-1: the save must actually reach the writer seam, not be rejected"

      refute Map.has_key?(columns, "iam_endpoint"),
             "R-1: the untouched, invalid-shaped env iam_endpoint must be OMITTED (nothing " <>
               "changed, nothing to validate) rather than rejected, got: #{inspect(columns)}"

      assert Map.get(columns, "region") == "eu-west-2",
             "the actually-changed region must still be persisted normally, got: " <>
               "#{inspect(columns)}"
    end

    test "R-1: a genuine new iam_endpoint override attempt with an invalid value is still blocked, even when a different value is currently in effect" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "iam_endpoint" => "https://93.184.216.34:4443/iam"
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "iam_endpoint" => "https://127.0.0.1/iam"
          })
        )

      assert conn.status == 200,
             "R-1: a genuinely new, invalid iam_endpoint override must still be rejected " <>
               "(re-render at 200, not redirect); got #{conn.status}"

      assert conn.resp_body =~ ~r/block|private|not allowed|invalid/i,
             "expected an error message about the blocked address, body: #{conn.resp_body}"

      refute_received {:storage_config_written, _columns, _set_at},
                      "R-1: a genuinely new, invalid iam_endpoint override must be rejected " <>
                        "before reaching the writer seam"
    end

    test "R-1: a blank submission can still clear an EXISTING DB override even if that override's own stored value is itself invalid-shaped" do
      test_pid = self()

      # Simulates a bad value that somehow got persisted before this guard
      # existed — the fix must never make an already-bad DB value
      # impossible to remove. Never submitted, so it is never itself
      # validated (only the explicit `nil` clear is).
      bad_db_iam = "http://insecure-legacy.example.com/iam"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{
          "endpoint" => "stable-endpoint:9000",
          "bucket" => "stable-bucket",
          "iam_endpoint" => bad_db_iam
        })
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "iam_endpoint" => ""
          })
        )

      assert conn.status in [200, 302, 303],
             "expected clearing an existing, invalid-shaped iam_endpoint override to " <>
               "succeed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      assert Map.has_key?(columns, "iam_endpoint") and Map.get(columns, "iam_endpoint") == nil,
             "expected the blank submission to clear the existing invalid-shaped override " <>
               "(#{inspect(bad_db_iam)}) via an explicit SET iam_endpoint = NULL — nil is " <>
               "always a valid 'clear to env-controlled' value regardless of what it " <>
               "replaces, got: #{inspect(columns)}"
    end
  end

  describe "bugfix-add-sts-iam-endpoints AC4: orphan-risk gate regression" do
    test "changing only iam/sts (no endpoint/bucket change) does not trigger the orphan-risk gate" do
      test_pid = self()

      Application.put_env(
        :nebu_http,
        :media_storage_config_loader,
        fn ->
          storage_config_loader_row(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket"
          })
        end
      )

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 9 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): these
      # are submitted (changed) below, so a literal public IP is used (no
      # live DNS lookup needed) instead of a non-resolving hostname.
      iam_url = "https://93.184.216.34:4443/iam"
      sts_url = "https://93.184.216.34:4443/sts"

      conn =
        post_storage(
          storage_params(%{
            "endpoint" => "stable-endpoint:9000",
            "bucket" => "stable-bucket",
            "iam_endpoint" => iam_url,
            "sts_endpoint" => sts_url
          })
        )

      assert conn.status in [200, 302, 303],
             "expected a normal save when endpoint/bucket are unchanged, even though " <>
               "iam_endpoint/sts_endpoint changed; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at},
                      "changing only iam_endpoint/sts_endpoint must never trigger the " <>
                        "orphan-risk gate"

      assert Map.get(columns, "iam_endpoint") == iam_url,
             "expected the changed iam_endpoint to reach the write seam, got: #{inspect(columns)}"

      assert Map.get(columns, "sts_endpoint") == sts_url,
             "expected the changed sts_endpoint to reach the write seam, got: #{inspect(columns)}"
    end

    test "changed_storage_keys/1 includes iam/sts in the written columns only when they change" do
      test_pid = self()
      # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): literal
      # public IPs, no live DNS lookup needed. Only `new_sts` actually goes
      # through the https:// + SSRF.checked_target/1 guard below — the
      # unchanged `old_iam` is omitted from `changes` by
      # put_env_backed_field/5's rule 1 (R-1 fix, cycle 5) before validation
      # ever runs, so it's never re-checked.
      old_iam = "https://93.184.216.34:4443/iam"
      new_sts = "https://93.184.216.34:4443/sts-new"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{"iam_endpoint" => old_iam, "sts_endpoint" => nil})
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, set_at ->
        send(test_pid, {:storage_config_written, columns, set_at})
        :ok
      end)

      conn =
        post_storage(
          storage_params(%{
            # pinned to the loader row's defaults (test-review MINOR-1): isolates
            # "only iam/sts changed" as the test name implies, independent of the
            # orphan-risk gate's own endpoint/bucket diffing (bypassed here via
            # the stubbed zero file count regardless).
            "endpoint" => "old-endpoint:9000",
            "bucket" => "old-bucket",
            # unchanged from the persisted value above
            "iam_endpoint" => old_iam,
            # changed (was unset)
            "sts_endpoint" => new_sts
          })
        )

      assert conn.status in [200, 302, 303],
             "expected a normal save; got #{conn.status}: #{conn.resp_body}"

      assert_received {:storage_config_written, columns, _set_at}

      refute Map.has_key?(columns, "iam_endpoint"),
             "resubmitting the unchanged iam_endpoint must be diffed out by " <>
               "changed_storage_keys/1 (no-op field must not be rewritten), got: " <>
               "#{inspect(columns)}"

      assert Map.get(columns, "sts_endpoint") == new_sts,
             "the actually-changed sts_endpoint must be included in the written columns, " <>
               "got: #{inspect(columns)}"
    end
  end

  describe "bugfix-add-sts-iam-endpoints AC5: form pre-fill + save round-trip" do
    test "the storage form pre-fills iam/sts from the env-resolved config when no DB row exists" do
      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)

      iam_url = "https://7mf5k.upcloudobjects.com:4443/iam"
      sts_url = "https://7mf5k.upcloudobjects.com:4443/sts"

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_IAM_ENDPOINT" => iam_url,
          "NEBU_MINIO_STS_ENDPOINT" => sts_url
        }
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      assert field_rendered_with_value?(body, "iam_endpoint", iam_url),
             "expected iam_endpoint to pre-fill from NEBU_MINIO_IAM_ENDPOINT when no DB row " <>
               "exists, body: #{body}"

      assert field_rendered_with_value?(body, "sts_endpoint", sts_url),
             "expected sts_endpoint to pre-fill from NEBU_MINIO_STS_ENDPOINT when no DB row " <>
               "exists, body: #{body}"
    end

    test "once a DB row sets iam/sts, GET /admin/media/settings reflects the DB values over env" do
      db_iam = "https://db-iam.example.com:4443/iam"
      db_sts = "https://db-sts.example.com:4443/sts"

      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        storage_config_loader_row(%{"iam_endpoint" => db_iam, "sts_endpoint" => db_sts})
      end)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_IAM_ENDPOINT" => "https://should-be-ignored.example.com/iam",
          "NEBU_MINIO_STS_ENDPOINT" => "https://should-be-ignored.example.com/sts"
        }
      end)

      conn = get_settings_page()

      assert conn.status == 200,
             "expected GET /admin/media/settings to render (200); got #{conn.status}"

      body = conn.resp_body

      assert field_rendered_with_value?(body, "iam_endpoint", db_iam),
             "expected the DB-stored iam_endpoint to win over the env var once a row exists, " <>
               "body: #{body}"

      assert field_rendered_with_value?(body, "sts_endpoint", db_sts),
             "expected the DB-stored sts_endpoint to win over the env var once a row exists, " <>
               "body: #{body}"

      refute field_rendered_with_value?(body, "iam_endpoint", "https://should-be-ignored.example.com/iam"),
             "the env-var iam_endpoint must NOT override a persisted media_storage_config row"

      refute field_rendered_with_value?(body, "sts_endpoint", "https://should-be-ignored.example.com/sts"),
             "the env-var sts_endpoint must NOT override a persisted media_storage_config row"
    end
  end
end
