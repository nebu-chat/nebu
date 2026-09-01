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

  @storage_fields ~w(endpoint bucket region use_ssl access_key secret_key s3_key_prefix_template archive_bucket)

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
    "archive_bucket" => ""
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
    "archive_bucket" => nil
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
end
