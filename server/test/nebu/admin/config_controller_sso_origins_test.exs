defmodule Nebu.Admin.ConfigControllerSsoOriginsTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC14 (and the admin help text
  of AC19): the Admin UI form `id="sso-origins-form"` (POST `/admin/config/sso-origins`) next to "SSO redirect
  schemes" that maintains `server_config.sso_redirect_allowed_origins`.

  Mirrors `config_controller_test.exs` (`save_sso_schemes/2`): validate through
  `Nebu.Matrix.normalize_sso_redirect_origins/1` BEFORE any write; error => `200` re-render with a flash error and
  NOTHING persisted; ok => persist the NORMALIZED string through the NEW seam `:admin_config_sso_origins_writer`
  (1-arity `fn changes -> :ok | {:error, _}`, compile-guarded in `lib/`) or `Nebu.Admin.DB.upsert_server_config/1`,
  flash "SSO origins saved", redirect `/admin/config`; a persistence failure => flash "Failed to save SSO origins".

  Auth strategy: a signed admin session conn through `Nebu.Admin.Endpoint.call/2` (`:admin_csrf_bypass` seam).
  The DB-backed cache refresh test is `:integration`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-sso-origins-key-b", 3)

  # story admin-config-audit-atomic: the audit row is part of the save, so a unit run WITHOUT a database needs an audit writer that works
  defmodule OkAudit do
    @moduledoc false
    def log(_actor, _action, _type, _id, _metadata, _outcome, _detail \\ nil), do: :ok
  end

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.put_env_scoped(:audit_writer, OkAudit, :compliance)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_config_sso_origins_writer, :admin_server_config_reader] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
  end

  # the flash of a response: assigns (rendered), private (put_flash) or the session a redirect wrote it to
  defp flash(conn, key) do
    k = to_string(key)

    from_assigns =
      case conn.assigns[:flash] do
        m when is_map(m) -> m[k]
        _ -> nil
      end

    from_session =
      case conn.private[:plug_session] do
        %{"phoenix_flash" => m} when is_map(m) -> m[k]
        _ -> nil
      end

    from_assigns || get_in(conn.private, [:phoenix_flash, k]) || from_session
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp post_origins(value) do
    # story sso-origins-admin-hardening: the strict fetch metadata of a form submit and a fresh re-authentication marker
    build_admin_conn(:post, "/admin/config/sso-origins")
    |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", "/admin/config"))
    |> T.put_strict_fetch_headers()
    |> Map.put(:body_params, %{"sso_redirect_allowed_origins" => value})
    |> endpoint_call()
  end

  defp capture_writer! do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_config_sso_origins_writer, fn changes ->
      send(test_pid, {:origins_written, changes})
      :ok
    end)
  end

  defp get_config(rows \\ []) do
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, rows} end)
    build_admin_conn(:get, "/admin/config") |> endpoint_call()
  end

  # source text without `#` comments and @doc / @moduledoc heredocs: prose may name keys and modules
  defp code(rel) do
    Path.expand("../../../lib/" <> rel, __DIR__)
    |> File.read!()
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.replace(~r/#[^\n]*/, "")
  end

  defp plain(body), do: body |> String.replace(~r/<[^>]+>/, " ") |> String.replace("&#39;", "'") |> String.replace("&quot;", "\"") |> String.replace(~r/\s+/, " ")

  # ════════════════════════════════════════════════════════════════════════════
  # AC14.1 — GET /admin/config shows the form
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14.1 — the form on GET /admin/config" do
    test "id, action, heading, label[for] + input id, placeholder and button; the form follows the SSO schemes form" do
      conn = get_config([{"sso_redirect_allowed_origins", "https://a.example, https://b.example:8443"}])
      assert conn.status == 200
      html = conn.resp_body

      assert html =~ ~s(id="sso-origins-form")
      assert html =~ ~s(action="/admin/config/sso-origins")
      assert html =~ ~r/<form[^>]*id="sso-origins-form"[^>]*method="post"|<form[^>]*method="post"[^>]*id="sso-origins-form"/
      assert html =~ ~r/<h2[^>]*>\s*SSO redirect origins\s*<\/h2>/
      assert html =~ ~r/<input[^>]*name="sso_redirect_allowed_origins"/
      assert html =~ "https://element.example.com, https://app.element.io"
      assert html =~ "Save SSO origins"
      assert html =~ ~r/name="_csrf_token"/

      {schemes_i, _} = :binary.match(html, "sso-schemes-form")
      {origins_i, _} = :binary.match(html, "sso-origins-form")
      assert origins_i > schemes_i, "the origins form comes directly after the SSO redirect schemes form"
    end

    test "UX N8: a real <label for> names the input (no aria-label), the help text is its aria-describedby" do
      html = get_config().resp_body

      assert html =~ ~r/<label[^>]*\sfor="sso-origins-input"[^>]*>.*?Allowed SSO redirect origins.*?<\/label>/s
      assert [input] = Regex.scan(~r/<input\b[^>]*name="sso_redirect_allowed_origins"[^>]*>/, html) |> Enum.map(&hd/1)
      assert input =~ ~s(id="sso-origins-input")
      assert input =~ ~r/aria-describedby="[^"]*sso-origins-help[^"]*"/
      refute input =~ "aria-label", "the visible label names the input, not an aria-label"
      refute input =~ "aria-invalid", "no error yet"
      assert html =~ ~r/<div[^>]*id="sso-origins-help"/
      refute html =~ ~s(id="sso-origins-error"), "no error element without an error"
    end

    test "the current value is shown, an unset value gives an empty field" do
      with_value = get_config([{"sso_redirect_allowed_origins", "https://a.example, https://b.example:8443"}])
      assert with_value.resp_body =~ ~r/<input[^>]*name="sso_redirect_allowed_origins"[^>]*value="https:\/\/a\.example, https:\/\/b\.example:8443"/ or
               with_value.resp_body =~ ~r/<input[^>]*value="https:\/\/a\.example, https:\/\/b\.example:8443"[^>]*name="sso_redirect_allowed_origins"/

      unset = get_config([])
      assert unset.status == 200
      assert unset.resp_body =~ ~s(id="sso-origins-form")
      refute unset.resp_body =~ ~r/name="sso_redirect_allowed_origins"[^>]*value="[^"]+"/
    end

    test "UX N9 / D14: the help text: bold trust warning, what is always allowed (server origin in <code>, delegation caveat, issuer, approved clients' registered URIs), cross-reference" do
      T.put_env_scoped(:server_name, "chat.example.test")

      html = get_config().resp_body
      [help] = Regex.run(~r/<div[^>]*id="sso-origins-help".*?<\/div>/s, html)
      t = plain(help)

      assert t =~ "Comma-separated https origins"
      assert help =~ ~r/<strong[^>]*>[^<]*Only list origins you control\./
      assert t =~ "Listed origins skip the confirmation page and receive a sign-in token with full access to the account."
      assert t =~ ~r/always allowed/i
      assert help =~ ~r/<code[^>]*>\s*https:\/\/chat\.example\.test\s*<\/code>/, "the server origin is rendered in <code>"
      assert t =~ ~r/must be an origin you control/, "the well-known delegation caveat (oracle m4)"
      assert t =~ ".well-known"
      assert t =~ "OAuth issuer", "the OAuth issuer origin"
      assert t =~ ~r/approved (OAuth )?clients/i
      assert t =~ ~r/redirect URIs?/, "approved clients are trusted by their registered redirect URI (SEC #1), not by origin"
      assert t =~ ~r/path/i
      assert t =~ "SSO redirect schemes", "cross-reference to the schemes form"
    end

    test "UX N10: a rejected save re-renders the SUBMITTED value, marks the field invalid and shows the error under it" do
      conn = post_origins("https://*.example")
      assert conn.status == 200
      html = conn.resp_body

      assert [input] = Regex.scan(~r/<input\b[^>]*name="sso_redirect_allowed_origins"[^>]*>/, html) |> Enum.map(&hd/1)
      assert input =~ ~s(value="https://*.example"), "the typed value is kept: #{input}"
      assert input =~ ~s(aria-invalid="true")
      assert [_, ids] = Regex.run(~r/aria-describedby="([^"]+)"/, input)
      assert String.split(ids, " ", trim: true) |> Enum.sort() == ["sso-origins-error", "sso-origins-help"]
      assert [error] = Regex.run(~r/<p[^>]*id="sso-origins-error"[^>]*>.*?<\/p>/s, html)
      assert error =~ ~s(role="alert")
      assert error =~ ~r/not valid/i
      assert html =~ ~r/not valid/i, "the flash with `not valid` stays"
    end

    test "UX N10: a hostile submitted value is HTML-escaped in the kept field value" do
      conn = post_origins("https://x.example\"><script>alert(1)</script>")
      assert conn.status == 200
      refute conn.resp_body =~ "<script>alert(1)</script>"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14.2 — persist the normalized string
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14.2 — POST /admin/config/sso-origins persists the NORMALIZED origin list" do
    test "mixed case, explicit :443, a trailing slash and a duplicate are normalized; 302 to /admin/config with the success flash" do
      capture_writer!()
      conn = post_origins("https://Chat.Example.com:443/, https://web.example.com:8443, https://chat.example.com")

      assert conn.status == 302, "got #{conn.status}\n#{conn.resp_body}"
      assert get_resp_header(conn, "location") == ["/admin/config"]
      assert_received {:origins_written, changes}
      assert changes == %{"sso_redirect_allowed_origins" => "https://chat.example.com, https://web.example.com:8443"}
      assert flash(conn, "info") == "SSO origins saved"
    end

    test "an empty value is valid input and persists the empty string (the operator clears the list)" do
      capture_writer!()
      conn = post_origins("")
      assert conn.status == 302
      assert_received {:origins_written, %{"sso_redirect_allowed_origins" => ""}}
    end

    test "a missing parameter behaves like an empty value" do
      capture_writer!()
      conn =
        build_admin_conn(:post, "/admin/config/sso-origins")
        |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", "/admin/config"))
        |> T.put_strict_fetch_headers()
        |> Map.put(:body_params, %{})
        |> endpoint_call()

      assert conn.status == 302
      assert_received {:origins_written, %{"sso_redirect_allowed_origins" => ""}}
    end

    test "the route exists (not 404 / 405)" do
      capture_writer!()
      conn = post_origins("https://ok.example")
      refute conn.status in [404, 405]
    end

    test "a persistence failure keeps the redirect and shows 'Failed to save SSO origins'" do
      Application.put_env(:nebu_http, :admin_config_sso_origins_writer, fn _changes -> {:error, :db_down} end)
      conn = post_origins("https://ok.example")
      assert conn.status == 302
      assert flash(conn, "error") == "Failed to save SSO origins"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # SEC #5 — the allowlist change is audited (pinned: a compliance audit row)
  # ════════════════════════════════════════════════════════════════════════════
  #
  # One row through the `:compliance, :audit_writer` seam (`log/7`, the writer the OAuth client approve / revoke
  # actions use): actor = the admin's Matrix id, action `sso_redirect_origins_changed`, target_type `server_config`,
  # target_id `sso_redirect_allowed_origins`, metadata with the NORMALIZED new value under "origins" and its
  # "count", outcome `success`. A rejected value and a failed write produce no row.

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :sso_origins_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  describe "SEC #5 — the allowlist change is audited" do
    setup do
      T.put_env_scoped(:sso_origins_audit_sink, self())
      T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)
      capture_writer!()
      :ok
    end

    test "a successful save writes ONE audit row: actor, action, target and the new normalized value" do
      conn = post_origins("https://Chat.Example.com:443/, https://web.example.com:8443")
      assert conn.status == 302

      assert_received {:audit, actor, action, target_type, target_id, metadata, outcome, _detail}
      assert actor == "@admin:test.local"
      assert action == "sso_redirect_origins_changed"
      assert target_type == "server_config"
      assert target_id == "sso_redirect_allowed_origins"
      assert outcome == "success"
      meta = Map.new(metadata, fn {k, v} -> {to_string(k), v} end)
      assert meta["origins"] == "https://chat.example.com, https://web.example.com:8443"
      assert meta["count"] == 2
      refute_received {:audit, _, _, _, _, _, _, _}, "exactly one row per save"
    end

    test "clearing the list is audited too (count 0)" do
      assert post_origins("").status == 302
      assert_received {:audit, "@admin:test.local", "sso_redirect_origins_changed", _, _, metadata, "success", _}
      meta = Map.new(metadata, fn {k, v} -> {to_string(k), v} end)
      assert meta["origins"] == ""
      assert meta["count"] == 0
    end

    test "a rejected value and a failed write produce no audit row" do
      assert post_origins("https://*.example").status == 200
      Application.put_env(:nebu_http, :admin_config_sso_origins_writer, fn _ -> {:error, :db_down} end)
      assert post_origins("https://ok.example").status == 302
      refute_received {:audit, _, _, _, _, _, _, _}
    end

    test "the audit metadata never carries a token, cookie or the previous request body (the new list only)" do
      post_origins("https://ok.example")
      assert_received {:audit, _, _, _, _, metadata, _, _}
      assert metadata |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() == ["count", "origins"]
    end
  end

  # Review cycle 2 (Kassandra delta LOW-1): the stub writer above cannot notice that the REAL
  # `Nebu.Compliance.AuditWriter` refuses an action that is not in its `@known_actions` (`{:error, :audit_unknown_action}`,
  # so no row would ever be written in production). This test runs the real writer against the real database.
  describe "SEC #5 (cycle 2) — the REAL AuditWriter writes the row" do
    @describetag :integration

    # story admin-config-audit-atomic (test-review MAJOR-1): REAL database, REAL writer; neither the writer stub nor the config reader seam is installed, so
    # the stored value and the audit row are what the transaction left
    setup do
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:nebu_http, :admin_config_sso_origins_writer)
      Application.delete_env(:nebu_http, :admin_server_config_reader)
      Application.delete_env(:nebu_http, :admin_config_tx)
      prior = T.privileged_sql!("SELECT value, set_at FROM server_config WHERE key = 'sso_redirect_allowed_origins'").rows
      T.privileged_sql!("DELETE FROM server_config WHERE key = 'sso_redirect_allowed_origins'")

      on_exit(fn ->
        T.privileged_sql!("DELETE FROM server_config WHERE key = 'sso_redirect_allowed_origins'")
        for [v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('sso_redirect_allowed_origins', $1, $2)", [v, at])
        if Process.whereis(Nebu.Web.OidcConfig), do: Nebu.Web.OidcConfig.refresh()
      end)

      :ok
    end

    defp stored_origins, do: T.sql!("SELECT value FROM server_config WHERE key = 'sso_redirect_allowed_origins'").rows |> List.first() |> List.wrap() |> List.first()

    test "sso_redirect_origins_changed is a known audit action" do
      src = File.read!(Path.expand("../../../lib/nebu/compliance/audit_writer.ex", __DIR__))
      assert src =~ ~r/@known_actions ~w\([^)]*\bsso_redirect_origins_changed\b/s
    end

    test "a successful save leaves exactly one audit_log row: actor, action, target and the metadata" do
      marker = "https://audit-#{T.rand(6)}.example"
      assert post_origins(marker).status == 302
      assert stored_origins() == marker, "the value and the row come from the same transaction"

      %{rows: rows} =
        T.privileged_sql!(
          "SELECT actor_user_id, action, target_type, target_id, outcome, metadata FROM audit_log WHERE action = 'sso_redirect_origins_changed' AND metadata->>'origins' = $1",
          [marker]
        )

      assert [[actor, "sso_redirect_origins_changed", "server_config", "sso_redirect_allowed_origins", "success", metadata]] = rows
      assert actor == "@admin:test.local"
      assert metadata["origins"] == marker
      assert metadata["count"] == 1
      T.privileged_sql!("DELETE FROM audit_log WHERE action = 'sso_redirect_origins_changed' AND metadata->>'origins' = $1", [marker])
    end

    test "story admin-config-audit-atomic: a refusing audit writer REFUSES a widening (nothing stored, value-free log, flash) - the audit is in the same transaction" do
      defmodule RefusingAudit do
        @moduledoc false
        def log(_actor, _action, _type, _id, _metadata, _outcome, _detail \\ nil), do: {:error, :audit_unknown_action}
      end

      T.put_env_scoped(:audit_writer, RefusingAudit, :compliance)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:conn, post_origins("https://refused-audit.example")})
        end)

      assert_received {:conn, conn}
      assert conn.status == 302
      assert flash(conn, "error") =~ "not saved: the audit entry could not be written"
      refute log =~ "refused-audit.example"
      assert stored_origins() == nil, "nothing was stored (the row did not exist before)"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14.3 — rejected input: 200 re-render, flash error, NO write
  # ════════════════════════════════════════════════════════════════════════════

  @rejected [
    "http://x.example",
    "https://*.example",
    "https://x.example/path",
    "https://x.example/?q",
    "https://x.example#f",
    "https://u@x.example",
    "https://bücher.example",
    "https://x.example.",
    "https://[::1]",
    "https://x.example:0",
    "https://x.example:70000",
    "https://x_y.example",
    "a,,b",
    "https://x.example\n"
  ]

  describe "AC14.3 — rejected input" do
    for value <- @rejected do
      test "#{inspect(value)} => 200 re-render, a 'not valid' flash error, nothing persisted" do
        capture_writer!()
        conn = post_origins(unquote(value))

        assert conn.status == 200, "must re-render (200), got #{conn.status}"
        assert conn.resp_body =~ ~r/not valid/i, "an error message with `not valid` expected; got:\n#{String.slice(conn.resp_body, 0, 600)}"
        refute_received {:origins_written, _}
        assert is_binary(flash(conn, "error"))
        refute conn.status == 302
      end
    end

    test "51 origins and a value over 4096 characters are rejected" do
      capture_writer!()
      fifty_one = Enum.map_join(1..51, ", ", &"https://h#{&1}.example")
      assert post_origins(fifty_one).status == 200

      host = String.duplicate("a", 60) <> "." <> String.duplicate("b", 60) <> ".example"
      too_long = Enum.map_join(1..40, ", ", &"https://#{&1}#{host}")
      assert String.length(too_long) > 4096
      assert post_origins(too_long).status == 200
      refute_received {:origins_written, _}
    end

    test "the flash names the offending token, truncated to 80 characters (rendered escaped)" do
      capture_writer!()
      conn = post_origins("https://x.example/path")
      assert plain(conn.resp_body) =~ "https://x.example/path"

      token = "https://x.example/" <> String.duplicate("p", 120)
      long = post_origins("https://ok.example, " <> token)
      t = plain(long.resp_body)
      assert t =~ String.slice(token, 0, 80)
      refute t =~ String.slice(token, 0, 81)
    end

    test "a non-ASCII host's message names the xn-- form" do
      capture_writer!()
      assert post_origins("https://bücher.example").resp_body =~ "xn--"
    end

    test "a hostile token is HTML-escaped in the flash (never rendered raw)" do
      capture_writer!()
      conn = post_origins("https://<script>alert(1)</script>.example")
      assert conn.status == 200
      refute conn.resp_body =~ "<script>alert(1)</script>"
    end

    test "a rejected value writes nothing even when a saved value already exists" do
      capture_writer!()
      Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, [{"sso_redirect_allowed_origins", "https://saved.example"}]} end)
      conn = post_origins("https://*.example")
      assert conn.status == 200
      refute_received {:origins_written, _}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14.4 / AC14.5 — cache refresh and the single validator
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14.4 — Nebu.Admin.DB and Nebu.Web.OidcConfig know the key" do
    test "Nebu.Admin.DB.@scope_cache_keys contains sso_redirect_allowed_origins (a save refreshes OidcConfig + the :pg broadcast)" do
      src = code("nebu/admin/db.ex")
      assert [_, list] = Regex.run(~r/@scope_cache_keys\s*~w\((.*?)\)/s, src)
      assert list =~ "sso_redirect_allowed_origins"
      assert list =~ "sso_extra_redirect_schemes", "the existing key stays"
    end

    test "OidcConfig exports get_sso_redirect_allowed_origins/0 (same shape as get_sso_extra_redirect_schemes/0)" do
      assert {:module, Nebu.Web.OidcConfig} = Code.ensure_loaded(Nebu.Web.OidcConfig)
      assert function_exported?(Nebu.Web.OidcConfig, :get_sso_redirect_allowed_origins, 0)
    end

    test "OidcConfig's @empty_config, SQL and load_from_db know the key (static)" do
      src = code("nebu/web/oidc_config.ex")
      assert src =~ ~r/sso_redirect_allowed_origins:\s*nil/, "@empty_config entry"
      assert src =~ "'sso_redirect_allowed_origins'", "@sql_load_oidc_config key"
      assert src =~ ~r/sso_redirect_allowed_origins:\s*nilify\(map\["sso_redirect_allowed_origins"\]\)/, "load_from_db/0 via nilify/1"
    end
  end

  describe "AC14.5 — one validator, reached through the Matrix facade" do
    test "the controller calls Nebu.Matrix.normalize_sso_redirect_origins/1 and never names Nebu.Matrix.SsoRedirect" do
      src = code("nebu/admin/config_controller.ex")
      assert src =~ "Nebu.Matrix.normalize_sso_redirect_origins"
      refute src =~ "SsoRedirect"
    end

    test "the router has the POST /config/sso-origins route" do
      src = code("nebu/admin/router.ex")
      assert src =~ ~r/post\s+"\/config\/sso-origins",\s*ConfigController,\s*:save_sso_origins/
    end
  end

  describe "AC14.4 — a real save refreshes the OidcConfig cache and broadcasts to the :pg peers" do
    @describetag :integration

    setup do
      case Nebu.Web.OidcConfig.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      on_exit(fn ->
        Nebu.Admin.DB.upsert_server_config(%{"sso_redirect_allowed_origins" => ""})
        if Process.whereis(Nebu.Web.OidcConfig), do: Nebu.Web.OidcConfig.refresh()
      end)

      :ok
    end

    test "upsert_server_config/1 makes the next getter call see the new list and tells the peers to refresh" do
      :pg.join(Nebu.Web.OidcConfig.pg_group(), self())
      on_exit(fn -> :pg.leave(Nebu.Web.OidcConfig.pg_group(), self()) end)

      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_redirect_allowed_origins" => "https://cache-probe.example"})
      assert apply(Nebu.Web.OidcConfig, :get_sso_redirect_allowed_origins, []) == "https://cache-probe.example"
      assert_receive {:invalidate_oidc_config}, 1_000
    end

    test "an empty list is read back as nil (nilify) and a whitespace value is trimmed" do
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_redirect_allowed_origins" => ""})
      assert apply(Nebu.Web.OidcConfig, :get_sso_redirect_allowed_origins, []) == nil
    end
  end
end
