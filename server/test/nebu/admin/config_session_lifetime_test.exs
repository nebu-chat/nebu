defmodule Nebu.Admin.ConfigSessionLifetimeTest do
  @moduledoc """
  Story `session-lifetime-setting` (epic oauth-session-and-consent), scenarios 2, 3, 5 and 6 at the Admin UI: the section "Matrix session lifetime" of
  `/admin/config` and `POST /admin/config/session-lifetime` (`Nebu.Admin.ConfigController.save_session_lifetime/2`). No database: the config reader, the
  transaction function of `Nebu.Admin.DB.save_config_audited/2` (`:nebu_http, :admin_config_tx`) and the audit writer are test seams, as in
  `config_oauth_switch_test.exs`. The real database (RLS, audit row, cache) is `config_session_lifetime_db_test.exs`.

  ## Contract pinned here (decisions of the ATDD step)

    * A SEPARATE form in its own section next to the OAuth switch (the setting also governs the legacy login, so it must not be bound to the OAuth
      kill-switch form, its issuer acknowledgement or its audit asymmetry): `section#session-lifetime` (`aria-labelledby="session-lifetime-heading"`,
      `h2#session-lifetime-heading` "Matrix session lifetime"), `form#session-lifetime-form` (POST `/admin/config/session-lifetime`, CSRF field,
      click proof), the text input `#session-lifetime-input` (`name="matrix_session_ttl_seconds"`, whole seconds, label "Session lifetime in
      seconds"), the current value as human text in `#session-lifetime-current` ("8 hours"), the hint `#session-lifetime-help` (bounds, that existing OAuth sessions
      keep their ceiling, the env fallback). Same marker flow as the other `/admin/config` forms: submit "Save session lifetime" with a fresh sign-in (marker
      bound to `/admin/config`), else the link "Sign in again to save" (see `Nebu.Admin.ReauthButtonFlowSupport.forms/0`).
    * Validation `Nebu.Admin.OAuthSwitch.validate_session_lifetime/1` BEFORE anything is written; a refusal is a 200 re-render with the submitted text in the
      field, `aria-invalid="true"`, `aria-describedby` naming `session-lifetime-help` and `session-lifetime-error`, and `p#session-lifetime-error[role=alert]`
      INSIDE the section. Nothing is written or audited, the marker is kept.
    * One transaction (`save_config_audited`): the upsert of `matrix_session_ttl_seconds` (canonical decimal text) and the audit row `session_lifetime_changed`
      (target_type `server_config`, target_id `matrix_session_ttl_seconds`, metadata exactly `%{"before_seconds" => n, "after_seconds" => n}`: numbers only). The
      audit is ALWAYS required (no way-back exemption): a failing audit saves nothing and is not retried without it. The old number is the value in effect
      (the saved one, else env, else 8 hours). A value equal to the SAVED one (not to the value in effect: nothing saved + the default entered IS saved) writes and audits nothing.
    * The marker is consumed after a successful save only.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test, only: [conn: 2]
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  @page "/admin/config"
  @post "/admin/config/session-lifetime"
  @form S.form(:session_lifetime)
  @field "matrix_session_ttl_seconds"
  @admin "@admin:test.local"
  @endpoint Nebu.Admin.Endpoint

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :lifetime_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})

      case Application.get_env(:nebu_http, :lifetime_audit_result, :ok) do
        :ok -> :ok
        :raise -> raise "audit writer boom"
        other -> other
      end
    end
  end

  setup do
    test_pid = self()
    T.put_env_scoped(:admin_csrf_bypass, true)
    T.put_env_scoped(:lifetime_audit_sink, self())
    T.put_env_scoped(:lifetime_audit_result, :ok)
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)
    T.put_env_scoped(:admin_server_config_reader, fn -> {:ok, []} end)
    T.clear_oauth_config()
    L.clear_env_ttl!()

    # the fake transaction: records the changes and whether an audit function came along, runs the audit function like the real one (inside), and
    # reports its failure the way the real one does
    Application.put_env(:nebu_http, :admin_config_tx, fn changes, audit ->
      send(test_pid, {:tx, changes, audit != nil})

      case audit && audit.() do
        nil -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:audit, reason}}
      end
    end)

    # a stray write through any OTHER seam would be a bug: this form writes its one key through the config transaction
    for key <- [:admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_refresh_mode_writer, :admin_config_scopes_writer] do
      Application.put_env(:nebu_http, key, fn changes ->
        send(test_pid, {:stray_write, key, changes})
        :ok
      end)
    end

    Application.put_env(:nebu_http, :oauth_switch_tx, fn changes, _audit ->
      send(test_pid, {:stray_write, :oauth_switch_tx, changes})
      :ok
    end)

    on_exit(fn ->
      for k <- [:admin_config_tx, :oauth_switch_tx, :admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_refresh_mode_writer, :admin_config_scopes_writer],
          do: Application.delete_env(:nebu_http, k)

      T.clear_oauth_config()
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp reader(pairs), do: Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, pairs} end)
  defp stored(value), do: reader([{@field, value}])

  defp text(node), do: S.norm(node)

  defp page(pairs \\ [], marker \\ [ago: 30]) do
    reader(pairs)
    conn = S.get(@page, marker)
    assert conn.status == 200
    {conn, S.doc(conn)}
  end

  defp section(doc), do: S.one!(Floki.find(doc, "section#session-lifetime"), "exactly one section#session-lifetime")
  defp input(doc), do: S.one!(Floki.find(section(doc), "input#session-lifetime-input"), "exactly one #session-lifetime-input")

  defp post(value, opts \\ []), do: S.post(@post, %{@field => value}, @page, Keyword.merge([ago: 10], opts))

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

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # the bounds as one literal phrase, as an old template would have spelled them
  defp lifetime_literal(min, max), do: "#{min} (#{Nebu.Admin.OAuthSwitch.lifetime_text(min)}) to #{max} (#{Nebu.Admin.OAuthSwitch.lifetime_text(max)})"

  defp refute_nothing_written do
    refute_received {:tx, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
    refute_received {:stray_write, _, _}
  end

  defp debug_logging! do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # the page
  # ════════════════════════════════════════════════════════════════════════════

  describe "the section and the form" do
    test "section, heading, form, field and label carry the contract" do
      {_conn, doc} = page()
      section = section(doc)
      assert Floki.attribute(section, "aria-labelledby") == ["session-lifetime-heading"]
      assert [heading] = Floki.find(section, "h2#session-lifetime-heading")
      assert text(heading) == "Matrix session lifetime"

      assert [form] = Floki.find(section, "form#session-lifetime-form")
      assert Floki.attribute(form, "method") == ["post"]
      assert Floki.attribute(form, "action") == ["/admin/config/session-lifetime"]
      assert [_] = Floki.find(form, ~s(input[type="hidden"][name="_csrf_token"]))
      assert [_] = Floki.find(form, ~s(input[type="hidden"][name="_click_proof"][value=""][data-click-proof]))

      assert [field] = Floki.find(form, ~s(input[name="matrix_session_ttl_seconds"]))
      assert Floki.attribute(field, "id") == ["session-lifetime-input"]
      assert Floki.attribute(field, "type") in [["text"], ["number"]]
      assert [label] = Floki.find(form, ~s(label[for="session-lifetime-input"]))
      assert text(label) =~ ~r/session lifetime/i
      assert text(label) =~ ~r/seconds/i

      assert Floki.find(doc, "form form") == [], "no nested forms"
      assert [_] = Floki.find(doc, "form#oauth-switch-form"), "the OAuth switch form is untouched"
    end

    test "the field shows the effective value in seconds and the current value as human text: nothing saved = 8 hours" do
      {_conn, doc} = page([])
      assert Floki.attribute(input(doc), "value") == ["28800"]
      assert [current] = Floki.find(section(doc), "#session-lifetime-current")
      assert text(current) =~ "8 hours"
    end

    test "a saved value is shown, in seconds and as text" do
      for {raw, human} <- [{"7200", "2 hours"}, {"3600", "1 hour"}, {"86400", "1 day"}, {"7776000", "90 days"}, {"5400", "30 minutes"}] do
        {_conn, doc} = page([{@field, raw}])
        assert Floki.attribute(input(doc), "value") == [raw], raw
        assert text(hd(Floki.find(section(doc), "#session-lifetime-current"))) =~ human, raw
      end
    end

    test "nothing saved: the env value is what is in effect and what is shown" do
      L.put_env_ttl!(14_400)
      {_conn, doc} = page([])
      assert Floki.attribute(input(doc), "value") == ["14400"]
      assert text(hd(Floki.find(section(doc), "#session-lifetime-current"))) =~ "4 hours"
    end

    test "a damaged or out-of-range saved value is not shown as the lifetime: the value in effect is" do
      for raw <- ["junk", "", "100", "99999999", "7200.5"] do
        {_conn, doc} = page([{@field, raw}])
        assert Floki.attribute(input(doc), "value") == ["28800"], raw
        assert text(hd(Floki.find(section(doc), "#session-lifetime-current"))) =~ "8 hours", raw
      end
    end

    test "the help block (the description of the field) holds range, units and the env fallback; it is described by it and wraps long words" do
      {_conn, doc} = page([])
      assert [help] = Floki.find(section(doc), "#session-lifetime-help")
      t = text(help)
      assert t =~ "1 hour"
      assert t =~ "90 days"
      assert t =~ "NEBU_MATRIX_SESSION_TTL_SECONDS"
      refute t =~ ~r/existing OAuth sessions|legacy/i, "the explanation of what happens to existing sessions is NOT part of the description read at every focus (UX M3)"
      assert "session-lifetime-help" in (input(doc) |> Floki.attribute("aria-describedby") |> Enum.flat_map(&String.split/1))
      assert "break-words" in (help |> Floki.attribute("class") |> Enum.flat_map(&String.split/1)), "a long environment variable name must not widen the page (UX I3)"
    end

    test "a 'Common values' sentence names 3600, 28800, 86400, 604800 and 2592000 (the field takes seconds only; UX M4)" do
      {_conn, doc} = page([])
      t = text(hd(Floki.find(section(doc), "#session-lifetime-help")))
      assert t =~ "Common values"
      for n <- ["3600", "28800", "86400", "604800", "2592000"], do: assert(t =~ n, n)
    end

    test "the bounds shown are those of Nebu.OAuth.matrix_session_ttl_bounds/0 (the template has no copy of them that can drift)" do
      {min, max} = Nebu.OAuth.matrix_session_ttl_bounds()
      {_conn, doc} = page([])
      t = text(hd(Floki.find(section(doc), "#session-lifetime-help")))
      assert t =~ "#{min}" and t =~ "#{max}"
      assert t =~ Nebu.Admin.OAuthSwitch.lifetime_text(min) and t =~ Nebu.Admin.OAuthSwitch.lifetime_text(max)

      source = File.read!(Path.expand("../../../lib/nebu/admin/templates/config/index.html.heex", __DIR__))
      refute source =~ Integer.to_string(max), "the maximum must come from the bounds assign, not from a literal in the template"
      refute source =~ lifetime_literal(min, max), "bounds as one hard-coded phrase"
    end

    test "the note about existing sessions is OUTSIDE the describedby block, inside the section, in the wording of the UX review (UX M3 / M5, CR-6)" do
      {_conn, doc} = page([])
      section = section(doc)
      assert [note] = Floki.find(section, "#session-lifetime-note")
      assert Floki.find(hd(Floki.find(section, "#session-lifetime-help")), "#session-lifetime-note") == [], "not inside the help block"
      assert (input(doc) |> Floki.attribute("aria-describedby") |> Enum.flat_map(&String.split/1)) == ["session-lifetime-help"]

      t = text(note)
      assert t =~ ~r/A session ends this long after sign-in, even if it is still in use/
      assert t =~ ~r/Renewing the token does not make it longer/
      assert t =~ ~r/A change applies to new sign-ins only/
      assert t =~ ~r/Sessions created through the OAuth login keep the lifetime they started with/
      assert t =~ ~r/Sessions from the legacy login store no end date/
      assert t =~ ~r/use the current setting when they are renewed/
      assert t =~ ~r/a shorter value can end them earlier than before/
      # CR-6: a legacy login is capped by the token expiry of the identity provider too: a longer setting does not lengthen it beyond that
      assert t =~ ~r/legacy login/i
      assert t =~ ~r/identity provider/i
      assert t =~ ~r/expir/i
    end

    test "autofocus: only a refused value puts the focus on the field (UX M1)" do
      {_conn, plain} = page([])
      assert Floki.attribute(input(plain), "autofocus") == []

      refused = S.doc(post("8640000"))
      assert Floki.attribute(input(refused), "autofocus") != []
    end

    test "aria-describedby lists the error FIRST, then the help (UX M2); without an error only the help" do
      refused = S.doc(post("8640000"))
      assert (input(refused) |> Floki.attribute("aria-describedby") |> Enum.flat_map(&String.split/1)) == ["session-lifetime-error", "session-lifetime-help"]

      {_conn, plain} = page([])
      assert (input(plain) |> Floki.attribute("aria-describedby") |> Enum.flat_map(&String.split/1)) == ["session-lifetime-help"]
    end

    test "no error and no aria-invalid on a plain page" do
      {_conn, doc} = page([])
      assert Floki.find(doc, "#session-lifetime-error") == []
      assert Floki.attribute(input(doc), "aria-invalid") == []
    end
  end

  describe "scenario 5 - the marker state is shown on the primary control" do
    test "no fresh sign-in: the link 'Sign in again to save' instead of the submit; inputs stay editable" do
      {_conn, doc} = page([], nil)
      link = S.assert_stale!(doc, @form)
      assert S.norm(link) == "Sign in again to save"
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path("/admin/config")]
    end

    test "an expired marker, a marker of another page and one of another admin are all stale" do
      for marker <- [[ago: 310], [ago: 3600], [path: "/admin/config/claim-mapping"], [path: "/admin/media/settings"], [sub: "someone-else"]] do
        {_conn, doc} = page([], marker)
        S.assert_stale!(doc, @form)
      end
    end

    test "a fresh marker: the submit 'Save session lifetime' and the validity line; no sign-in link in the form" do
      {_conn, doc} = page([], ago: 30)
      button = S.assert_fresh!(doc, @form, 4)
      assert S.norm(button) == "Save session lifetime"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 5 (second half) - the gate: a stale marker saves nothing
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 5 - submitting without a fresh sign-in does not save" do
    test "no marker: redirect to the sign-in of /admin/config, nothing written, nothing audited" do
      conn = S.post(@post, %{@field => "7200"})
      assert conn.status in [302, 303]
      assert location(conn) == Auth.reauth_start_path("/admin/config")
      refute_nothing_written()
    end

    test "an expired marker, a marker of another page and one of another admin: the same" do
      for opts <- [[ago: 400], [path: "/admin/config/claim-mapping"], [sub: "someone-else"]] do
        {path, opts} = Keyword.pop(opts, :path, @page)
        conn = S.post(@post, %{@field => "7200"}, path, opts)
        assert conn.status in [302, 303], inspect(opts)
        assert location(conn) == Auth.reauth_start_path("/admin/config"), inspect(opts)
        refute_nothing_written()
      end
    end

    test "a POST without the strict fetch metadata of a user-clicked submit is refused (403), nothing written" do
      conn = S.admin_conn(:post, @post, %{@field => "7200"}) |> S.with_marker(@page) |> S.call()
      assert conn.status == 403
      refute_nothing_written()
    end

    test "the form is read from the BODY: a value in the query string saves nothing" do
      # no `params` override: the endpoint's parsers run, the query string lands in `conn.params`, never in `conn.body_params`
      conn =
        S.admin_conn(:post, @post <> "?matrix_session_ttl_seconds=7200")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> S.with_marker(@page)
        |> T.put_strict_fetch_headers()
        |> S.call()

      assert conn.params["matrix_session_ttl_seconds"] == "7200", "the query string did reach conn.params (else this test proves nothing)"
      assert conn.status == 200, "a missing body field is a refused (blank) value"
      refute_nothing_written()
    end

    test "the response of every kind is not frameable and not cacheable, also under the other spellings of the path" do
      responses = [
        S.get(@page, ago: 30),
        post("7200"),
        post("8640000"),
        S.post(@post, %{@field => "7200"}),
        S.admin_conn(:post, @post, %{@field => "7200"}) |> S.with_marker(@page) |> S.call()
      ]

      for conn <- responses do
        assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'none'", "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "cache-control") == ["no-store"], "#{conn.request_path} #{conn.status}"
      end

      for path <- ["/admin/config/session-lifetime/", "/admin//config/session-lifetime", "/admin/config//session-lifetime"] do
        conn = S.admin_conn(:post, path, %{}) |> S.call()
        refute conn.status == 404, "#{path} is routed"
        assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'none'", path
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], path
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # the mutating route is closed to everything but a real admin click (same order of checks as the OAuth switch)
  # ════════════════════════════════════════════════════════════════════════════

  describe "access and order of checks" do
    test "the gate comes BEFORE the validation: an invalid value without strict fetch metadata is the 403, without a marker the redirect, never the 200 re-render" do
      invalid = %{@field => "8640000"}
      assert (S.admin_conn(:post, @post, invalid) |> S.with_marker(@page) |> S.call()).status == 403
      assert (S.admin_conn(:post, @post, invalid) |> T.put_strict_fetch_headers() |> S.call()).status in [302, 303]
      refute_nothing_written()
    end

    test "the 403 page is the neutral config page (back link to /admin/config, config nav highlighted)" do
      conn = S.admin_conn(:post, @post, %{@field => "7200"}) |> S.with_marker(@page) |> S.call()
      assert conn.status == 403
      doc = S.doc(conn)
      assert [back] = Floki.find(doc, ~s(a[data-role="back-to-list"]))
      assert Floki.attribute(back, "href") == ["/admin/config"]
      assert [_] = Floki.find(doc, ~s([data-navkey="config-general"][aria-current="page"]))
    end

    test "require_admin first: no session at all, a non-admin session and an admin flag of false never reach the form" do
      anon =
        conn(:post, @post)
        |> Map.put(:secret_key_base, S.secret_key_base())
        |> @endpoint.admin_session([])
        |> fetch_session()
        |> Map.put(:body_params, %{@field => "7200"})
        |> T.put_strict_fetch_headers()
        |> S.call()

      assert anon.status in [302, 303, 401, 403]
      refute anon.status == 200

      user =
        S.admin_conn(:post, @post, %{@field => "7200"})
        |> put_session("current_user", %{"admin" => false, "sub" => "u", "matrix_user_id" => "@u:test.local"})
        |> S.with_marker(@page)
        |> T.put_strict_fetch_headers()
        |> S.call()

      assert user.status in [302, 303, 401, 403]
      refute user.resp_body =~ ~s(data-error="fetch_metadata")
      refute_nothing_written()

      # no marker, no fetch metadata at all: still the admin check first, never the gate's 403 page
      bare = S.admin_conn(:post, @post, %{@field => "7200"}) |> put_session("current_user", %{"admin" => false, "sub" => "u", "matrix_user_id" => "@u:test.local"}) |> S.call()
      refute bare.resp_body =~ ~s(data-error="fetch_metadata")
      refute bare.status == 200
      refute_nothing_written()
    end

    test "the CSRF check still runs first: without the bypass a request without a token is refused before the gate" do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      conn = S.admin_conn(:post, @post, %{@field => "7200"}) |> S.with_marker(@page) |> T.put_strict_fetch_headers()
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> S.call(conn) end
      refute_nothing_written()
    end

    test "other methods on the path are not routed and write nothing" do
      for method <- [:get, :put, :patch, :delete] do
        result =
          try do
            S.admin_conn(method, @post, nil) |> S.with_marker(@page) |> T.put_strict_fetch_headers() |> S.call()
          rescue
            e in Phoenix.Router.NoRouteError -> e
          end

        refute match?(%Plug.Conn{status: status} when status in [200, 302, 303], result), "#{method}"
      end

      refute_nothing_written()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 3 - an out-of-range value is refused, nothing is saved
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 3 - refused values" do
    test "100 days: 200 re-render, the error next to the field (aria-invalid, aria-describedby, role=alert inside the section), nothing saved or audited" do
      stored("7200")
      conn = post("8640000")
      assert conn.status == 200
      refute_nothing_written()

      doc = S.doc(conn)
      section = section(doc)
      input = input(doc)
      assert Floki.attribute(input, "aria-invalid") == ["true"]
      describedby = input |> Floki.attribute("aria-describedby") |> Enum.flat_map(&String.split/1)
      assert "session-lifetime-error" in describedby
      assert "session-lifetime-help" in describedby

      assert [error] = Floki.find(section, "p#session-lifetime-error")
      assert Floki.attribute(error, "role") == ["alert"]
      assert text(error) =~ "3600"
      assert text(error) =~ "7776000"
      assert Floki.attribute(input, "value") == ["8640000"], "the submitted text stays in the field"
      assert text(hd(Floki.find(section, "#session-lifetime-current"))) =~ "2 hours", "the stored value is still shown as the current one"
    end

    test "every kind of refused value: 200, error, nothing written" do
      for raw <- ["3599", "7776001", "0", "-1", "", "   ", "abc", "7200.5", "1e4", "2 hours", "7,200", "99999999999999999999"] do
        conn = post(raw)
        assert conn.status == 200, inspect(raw)
        refute_nothing_written()
        assert [_] = Floki.find(S.doc(conn), "section#session-lifetime p#session-lifetime-error[role=alert]"), inspect(raw)
        assert Floki.attribute(input(S.doc(conn)), "aria-invalid") == ["true"], inspect(raw)
      end
    end

    test "a missing field and a list or map value (parameter pollution) are refused too" do
      for params <- [%{}, %{@field => ["7200", "3600"]}, %{@field => %{"a" => "7200"}}] do
        conn = S.post(@post, params, @page, ago: 10)
        assert conn.status == 200, inspect(params)
        refute_nothing_written()
        assert [_] = Floki.find(S.doc(conn), "section#session-lifetime p#session-lifetime-error"), inspect(params)
      end
    end

    test "a refusal keeps the fresh sign-in (the admin corrects the value with the same marker) and the re-render still shows the Save button" do
      conn = post("8640000")
      assert conn.private.plug_session["admin_reauth"] != nil
      S.assert_fresh!(S.doc(conn), @form, :any)
    end

    test "the refused text is escaped when it is shown again, and never reaches the log" do
      debug_logging!()
      canary = "\"><script>alert('canary-lt-31')</script>"
      log = capture_log(fn -> send(self(), {:conn, post(canary)}) end)
      assert_received {:conn, conn}
      assert conn.status == 200
      refute conn.resp_body =~ "<script>alert('canary-lt-31')</script>"
      assert Floki.attribute(input(S.doc(conn)), "value") == [canary]
      refute log =~ "canary-lt-31", log
      refute_nothing_written()
    end

    test "Phoenix's parameter logging masks the field (like the field of every other marker-gated form): a pasted value is not logged at debug" do
      filter = Application.get_env(:phoenix, :filter_parameters, [])
      masked = Phoenix.Logger.filter_values(%{"matrix_session_ttl_seconds" => "canary-value-zq77"}, filter)

      assert masked["matrix_session_ttl_seconds"] == "[FILTERED]",
             "config :phoenix, filter_parameters (server/config/config.exs) must mask matrix_session_ttl_seconds, got #{inspect(masked)}"
    end

    test "the field is 'valid' again after a good save: no error markup on the next page" do
      _ = post("8640000")
      {_conn, doc} = page([{@field, "7200"}])
      assert Floki.find(doc, "#session-lifetime-error") == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenarios 2 and 6 - the save and its audit entry
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenarios 2 and 6 - a valid value is saved and audited in one transaction" do
    test "2 hours from 8 hours: one transaction with the canonical value and an audit function, flash, redirect, marker consumed, one audit row with numbers only" do
      stored("28800")
      conn = post("7200")

      assert conn.status in [302, 303]
      assert location(conn) |> String.starts_with?("/admin/config")
      assert flash(conn, :info) =~ "Session lifetime saved", "the e2e step looks for this text"
      assert flash(conn, :info) =~ "Existing OAuth sessions keep their lifetime", "legacy sessions follow the setting, so the flash must not promise 'existing sessions' in general (UX M5)"
      refute flash(conn, :error)
      assert conn.private.plug_session["admin_reauth"] == nil, "one fresh sign-in, one save"

      assert_received {:tx, %{"matrix_session_ttl_seconds" => "7200"} = changes, true}
      assert map_size(changes) == 1
      refute_received {:tx, _, _}, "exactly one transaction"

      assert_received {:audit, @admin, "session_lifetime_changed", "server_config", "matrix_session_ttl_seconds", metadata, "success", nil}
      assert metadata == %{"before_seconds" => 28_800, "after_seconds" => 7200}
      assert Enum.all?(Map.values(metadata), &is_integer/1), "numbers only"
      refute_received {:audit, _, _, _, _, _, _, _}, "exactly one audit entry"
      refute_received {:stray_write, _, _}
    end

    test "nothing saved before: the old number is the 8 hour default" do
      conn = post("7200")
      assert conn.status in [302, 303]
      assert_received {:audit, @admin, "session_lifetime_changed", _, _, %{"before_seconds" => 28_800, "after_seconds" => 7200}, "success", nil}
    end

    test "nothing saved before, an env value in effect: the old number is the env value" do
      L.put_env_ttl!(21_600)
      conn = post("7200")
      assert conn.status in [302, 303]
      assert_received {:audit, _, "session_lifetime_changed", _, _, %{"before_seconds" => 21_600, "after_seconds" => 7200}, "success", nil}
    end

    test "a damaged saved value is not 'the old value': the value in effect is" do
      stored("garbage")
      assert post("7200").status in [302, 303]
      assert_received {:audit, _, "session_lifetime_changed", _, _, %{"before_seconds" => 28_800, "after_seconds" => 7200}, "success", nil}
    end

    test "a longer lifetime than before is saved the same way (the audit row is not only for shortening)" do
      stored("3600")
      assert post("86400").status in [302, 303]
      assert_received {:tx, %{"matrix_session_ttl_seconds" => "86400"}, true}
      assert_received {:audit, _, "session_lifetime_changed", _, _, %{"before_seconds" => 3600, "after_seconds" => 86_400}, "success", nil}
    end

    test "both bounds are saved" do
      for value <- ["3600", "7776000"] do
        conn = post(value)
        assert conn.status in [302, 303], value
        assert_received {:tx, %{"matrix_session_ttl_seconds" => ^value}, true}
        assert_received {:audit, _, "session_lifetime_changed", _, _, %{"after_seconds" => _}, "success", nil}
      end
    end

    test "the value is stored as canonical decimal text: surrounding white space is trimmed" do
      assert post(" 7200 ").status in [302, 303]
      assert_received {:tx, %{"matrix_session_ttl_seconds" => "7200"}, true}
    end

    test "after the save the sign-in link is back on the next page (real cookie round trip)" do
      post = post("7200")
      next = S.next_get(post, @page)
      assert next.status == 200
      S.assert_stale!(S.doc(next), @form)
    end

    test "the same value as the SAVED one: no change, no transaction, no audit entry, the marker is kept" do
      stored("7200")
      conn = post("7200")
      assert conn.status in [302, 303]
      assert flash(conn, :info) =~ ~r/no change/i
      assert conn.private.plug_session["admin_reauth"] != nil
      refute_nothing_written()
    end

    test "'no change' compares with the SAVED value only: nothing saved and the default entered is saved and audited (an explicit 8 hours can be persisted)" do
      reader([])
      conn = post("28800")
      assert conn.status in [302, 303]
      assert flash(conn, :info) =~ "Session lifetime saved"
      assert_received {:tx, %{"matrix_session_ttl_seconds" => "28800"}, true}
      assert_received {:audit, @admin, "session_lifetime_changed", _, _, %{"before_seconds" => 28_800, "after_seconds" => 28_800}, "success", nil}
    end

    test "a damaged saved value is no saved value: entering the value in effect saves it" do
      stored("garbage")
      assert post("28800").status in [302, 303]
      assert_received {:tx, %{"matrix_session_ttl_seconds" => "28800"}, true}
    end

    test "an env value below the form's minimum (30 seconds, the e2e stack): shown as it is, refused when posted back, an allowed value is saved over it" do
      L.put_env_ttl!(30)
      {_conn, doc} = page([])
      assert Floki.attribute(input(doc), "value") == ["30"]
      assert text(hd(Floki.find(section(doc), "#session-lifetime-current"))) =~ "30 seconds"

      conn = post("30")
      assert conn.status == 200
      assert [error] = Floki.find(S.doc(conn), "section#session-lifetime p#session-lifetime-error[role=alert]")
      assert text(error) =~ "3600"
      refute_nothing_written()

      assert post("28800").status in [302, 303]
      assert_received {:tx, %{"matrix_session_ttl_seconds" => "28800"}, true}
      assert_received {:audit, _, "session_lifetime_changed", _, _, %{"before_seconds" => 30, "after_seconds" => 28_800}, "success", nil}
    end

    test "a failing audit writer: nothing is saved, no retry without the audit, an error flash, the marker is kept" do
      T.put_env_scoped(:lifetime_audit_result, {:error, :audit_write_failed})
      stored("28800")
      log = capture_log(fn -> send(self(), {:conn, post("7313")}) end)
      assert_received {:conn, conn}

      assert conn.status in [302, 303]
      assert flash(conn, :error) =~ ~r/not saved/i
      refute flash(conn, :info)
      assert conn.private.plug_session["admin_reauth"] != nil

      assert_received {:tx, _, true}
      refute_received {:tx, _, _}, "the audit is mandatory for every change of the lifetime: no second attempt without it"
      refute log =~ "7313", "the value is not logged"
    end

    test "a raising audit writer counts as a failed audit" do
      T.put_env_scoped(:lifetime_audit_result, :raise)
      capture_log(fn -> send(self(), {:conn, post("7200")}) end)
      assert_received {:conn, conn}
      assert conn.status in [302, 303]
      assert flash(conn, :error) =~ ~r/not saved/i
      refute_received {:tx, _, false}
    end

    test "a failing database transaction: an error flash, the marker is kept, no value or reason in the log" do
      Application.put_env(:nebu_http, :admin_config_tx, fn _changes, _audit -> {:error, %RuntimeError{message: "boom canary-lt-77 7200"}} end)
      log = capture_log(fn -> send(self(), {:conn, post("7200")}) end)
      assert_received {:conn, conn}
      assert conn.status in [302, 303]
      assert flash(conn, :error)
      refute flash(conn, :info)
      assert conn.private.plug_session["admin_reauth"] != nil
      refute log =~ "canary-lt-77", log
    end

    test "the audit action is known to the real audit writer (else every save would roll back with :audit_unknown_action)" do
      result = Nebu.Compliance.AuditWriter.log(@admin, "session_lifetime_changed", "server_config", "matrix_session_ttl_seconds", %{"before_seconds" => 28_800, "after_seconds" => 7200}, "success")
      refute result == {:error, :audit_unknown_action}
    end

    test "no other form of the page is written by this POST" do
      assert post("7200").status in [302, 303]
      refute_received {:stray_write, _, _}
    end
  end
end
