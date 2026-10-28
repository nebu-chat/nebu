defmodule Nebu.OAuth.SafariAdminActionsTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `safari-fetch-metadata-compat`, AC2, AC3, AC4 (admin side): the OAuth
  admin actions (approve, reject, bulk removal, revoke) under five request shapes, driven through `Nebu.Admin.Endpoint`:

    * (a) Chrome / Firefox set: the four headers incl. `Sec-Fetch-User: ?1`, no proof field -> the action works (unchanged);
    * (b) Safari set (`Sec-Fetch-Site/-Mode/-Dest`, a WebKit User-Agent, NO `Sec-Fetch-User`) + `_click_proof=1` -> the action works;
    * (c) Safari set without the proof (script blocked, stale page) -> 200 notice page `data-page="oauth-activation-unproven"`, nothing
      changed, nothing audited, the re-authentication marker not consumed, the action repeatable;
    * (d) `fetch()` / iframe / cross-origin / missing Site, Mode or Dest, with the proof -> still the 403 refusal page;
    * (e) `Sec-Fetch-User` present and not `?1`, or the proof on a non-WebKit engine without `Sec-Fetch-User` -> 403.

  Order of checks is unchanged: `require_admin` -> CSRF -> fetch metadata (403 / notice) -> marker (approve / revoke) -> the rest.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)
  @admin "@admin:test.local"
  @clients_path "/admin/oauth/clients"
  @reg_path "/admin/oauth/registrations"

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.enable_oauth()
    {:ok, ids} = Agent.start(fn -> [] end)

    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      T.clear_oauth_config()
      T.cleanup_clients(Agent.get(ids, & &1))
      Agent.stop(ids)
    end)

    {:ok, ids: ids}
  end

  # ── fixtures / helpers ─────────────────────────────────────────────────────

  defp insert_client(ids, status, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    id = "safari-#{n}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    Agent.update(ids, &[id | &1])
    host = Map.get(attrs, :host, "app#{n}.example.com")

    metadata = %{
      "client_name" => "SafariApp-#{n}",
      "client_uri" => "https://#{host}",
      "redirect_uris" => ["https://#{host}/callback"],
      "application_type" => "web"
    }

    T.insert_row!(id, Jason.encode!(metadata), "hash-#{id}", status, "NOW()", "web",
      client_host: host,
      client_domain: Map.get(attrs, :client_domain),
      revoked_reason: nil,
      revoked_by: "@root:test.local"
    )

    %{id: id, host: host}
  end

  defp admin_conn(method, path, params \\ nil) do
    %{conn(method, path, params) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => @admin})
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()
  defp doc(conn), do: Floki.parse_document!(conn.resp_body)
  defp revoke_path(id), do: "#{@clients_path}/#{id}/revoke"
  defp approve_path(id), do: "#{@reg_path}/#{id}/approve"
  defp audit_rows(action, id), do: T.sql!("SELECT 1 FROM audit_log WHERE action = $1 AND target_id = $2", [action, id]).rows

  # The four actions: path, params, marker or not, whether the action took effect.
  defp spec(:approve, ids) do
    c = insert_client(ids, "pending")
    %{name: "approve", path: approve_path(c.id), params: %{}, marker?: true, back: approve_path(c.id), changed?: fn -> T.client_row(c.id)["status"] != "pending" end, audit: {"oauth_client_approved", c.id}}
  end

  defp spec(:reject, ids) do
    c = insert_client(ids, "pending")
    %{name: "reject", path: "#{@reg_path}/#{c.id}/reject", params: %{}, marker?: false, back: @reg_path, changed?: fn -> T.client_row(c.id)["status"] != "pending" end, audit: {"oauth_client_rejected", c.id}}
  end

  defp spec(:bulk, ids) do
    domain = "t#{T.rand(5)}.com"
    c = insert_client(ids, "pending", %{host: "a.#{domain}", client_domain: domain})
    params = %{"host" => domain, "match" => "domain", "as_of" => DateTime.utc_now() |> DateTime.to_iso8601()}
    %{name: "bulk-remove", path: "#{@reg_path}/bulk-remove", params: params, marker?: false, back: @reg_path, changed?: fn -> T.client_row(c.id) == nil end, audit: {"oauth_clients_bulk_removed", "bulk"}}
  end

  defp spec(:revoke, ids) do
    c = insert_client(ids, "approved")
    %{name: "revoke", path: revoke_path(c.id), params: %{"confirm_host" => c.host}, marker?: true, back: revoke_path(c.id), changed?: fn -> T.client_row(c.id)["status"] != "approved" end, audit: {"oauth_client_revoked", c.id}}
  end

  @actions [:approve, :reject, :bulk, :revoke]

  # audit rows of the action's target BEFORE the request (the bulk target id is shared by every test)
  defp audited(s) do
    {action, target} = s.audit
    fn -> length(audit_rows(action, target)) end
  end

  # headers: :chrome | :safari | {:safari_proof, extra headers} ... built by `post/3`
  defp base(spec, params) do
    c = admin_conn(:post, spec.path, params)
    if spec.marker?, do: put_session(c, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", URI.parse(spec.path).path)), else: c
  end

  defp chrome(spec), do: base(spec, spec.params) |> T.put_strict_fetch_headers() |> put_req_header("user-agent", T.chrome_user_agent())
  defp safari(spec, proof?), do: base(spec, if(proof?, do: T.with_click_proof(spec.params), else: spec.params)) |> T.put_safari_fetch_headers()

  defp refused?(conn), do: conn.status == 403 and conn.resp_body =~ ~s(data-error="fetch_metadata")

  # ════════════════════════════════════════════════════════════════════════════
  # (a) + (b) — the action works
  # ════════════════════════════════════════════════════════════════════════════

  for action <- @actions do
    describe "#{action}: Chrome / Firefox and Safari both complete the action" do
      test "(a) Chrome set with Sec-Fetch-User: ?1 and no proof field => the action works (303)", %{ids: ids} do
        s = spec(unquote(action), ids)
        conn = chrome(s) |> call()
        assert conn.status in [302, 303], "got #{conn.status}: #{String.slice(conn.resp_body, 0, 200)}"
        assert s.changed?.()
      end

      test "(a) a Firefox User-Agent with the four headers works the same", %{ids: ids} do
        s = spec(unquote(action), ids)
        conn = chrome(s) |> put_req_header("user-agent", T.firefox_user_agent()) |> call()
        assert conn.status in [302, 303]
        assert s.changed?.()
      end

      test "(b) Safari set (no Sec-Fetch-User) + _click_proof=1 => the action works (303), audited like any other", %{ids: ids} do
        s = spec(unquote(action), ids)
        before = audited(s).()
        conn = safari(s, true) |> call()
        assert conn.status in [302, 303], "got #{conn.status}: #{String.slice(conn.resp_body, 0, 200)}"
        assert s.changed?.()
        assert audited(s).() > before, "the audit row is written"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # (c) — Safari without the proof: a notice, nothing changed, repeatable
  # ════════════════════════════════════════════════════════════════════════════

  for action <- @actions do
    describe "#{action}: Safari without the click proof gets a notice, not an error" do
      test "(c) 200 notice page, no 403, nothing changed, no audit row, one value-free WARNING", %{ids: ids} do
        s = spec(unquote(action), ids)
        before = audited(s).()
        {conn, log} = with_log(fn -> safari(s, false) |> call() end)

        assert conn.status == 200, "got #{conn.status}"
        refute refused?(conn), "not the refusal page"
        assert conn.resp_body =~ ~s(data-page="oauth-activation-unproven")
        refute conn.resp_body =~ "Request refused"
        assert [alert] = doc(conn) |> Floki.find(~s([data-role="activation-notice"]))
        assert Floki.attribute(alert, "role") == ["status"], "a notice (status), not an alert"
        refute s.changed?.(), "nothing changed"
        assert audited(s).() == before, "no audit row"
        assert log =~ ~r/click proof|activation/i, "the WARNING says what is missing"
        refute log =~ "safari-", "never a client id / host in the log"
        refute log =~ T.safari_user_agent(), "never the User-Agent value"
      end

      test "(c) the notice page tells what to do (reload, press again, blocked script) and links back to the page of the action", %{ids: ids} do
        s = spec(unquote(action), ids)
        conn = safari(s, false) |> call()
        text = doc(conn) |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ")
        assert text =~ ~r/nothing was changed/i
        assert text =~ ~r/JavaScript|script/i
        assert text =~ ~r/press the button again|try again|once more/i
        assert [back] = doc(conn) |> Floki.find(~s(a[data-role="back-to-list"]))
        assert Floki.attribute(back, "href") == [s.back]
      end

      test "(c) the notice page keeps the no-framing / no-store headers of the OAuth admin pages", %{ids: ids} do
        s = spec(unquote(action), ids)
        conn = safari(s, false) |> call()
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert get_resp_header(conn, "x-frame-options") == ["DENY"]
        assert hd(get_resp_header(conn, "content-security-policy")) =~ "frame-ancestors 'none'"
      end

      test "(c) repeatable: the same action with the proof right afterwards works (the marker was not consumed)", %{ids: ids} do
        s = spec(unquote(action), ids)
        first = safari(s, false) |> call()
        assert first.status == 200
        refute s.changed?.()

        if Function.identity(s.marker?) do
          marker = first.private.plug_session["admin_reauth"]
          assert marker["sub"] == "admin-1" and marker["path"] == URI.parse(s.path).path, "the unproven request left the marker of this very page in the session"
        end

        second = safari(s, true) |> call()
        assert second.status in [302, 303]
        assert s.changed?.()
      end
    end
  end

  test "the proof is read from the request BODY only: a query-string _click_proof=1 without the body field is no proof (notice)", %{ids: ids} do
    s = spec(:reject, ids)
    c = admin_conn(:post, s.path <> "?_click_proof=1", s.params) |> T.put_safari_fetch_headers()
    conn = call(c)
    assert conn.status == 200 and conn.resp_body =~ "oauth-activation-unproven"
    refute s.changed?.()
  end

  test "the notice page names the next step (use the link, same button, do not reload), the CLI for OAuth pages, and highlights a child nav entry", %{ids: ids} do
    s = spec(:revoke, ids)
    conn = safari(s, false) |> call()
    text = doc(conn) |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ")
    assert text =~ "Do not reload this page"
    assert text =~ "operator command line"
    assert conn.resp_body =~ ~s(data-navkey="oauth-approved-clients")
    assert [_] = doc(conn) |> Floki.find("h1") |> Enum.filter(&(Floki.text(&1) == "Action not carried out"))
  end

  test "order: the notice comes before the marker (an unproven request is not sent through the IdP), the proof does not skip the marker", %{ids: ids} do
    s = spec(:approve, ids)

    no_marker_unproven = admin_conn(:post, s.path, s.params) |> T.put_safari_fetch_headers() |> call()
    assert no_marker_unproven.status == 200 and no_marker_unproven.resp_body =~ "oauth-activation-unproven"

    no_marker_proof = admin_conn(:post, s.path, T.with_click_proof(s.params)) |> T.put_safari_fetch_headers() |> call()
    assert no_marker_proof.status in [302, 303] and location(no_marker_proof) =~ "/admin/login/start", "with the proof the marker is judged as ever"
    refute s.changed?.()
  end

  test "order: CSRF first, then the notice (a bad token never reaches the fetch-metadata judgment)", %{ids: ids} do
    Application.delete_env(:nebu_http, :admin_csrf_bypass)
    s = spec(:revoke, ids)
    get = admin_conn(:get, s.path) |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", s.path)) |> call()
    token = doc(get) |> Floki.find(~s(input[name="_csrf_token"])) |> Floki.attribute("value") |> hd()

    post = fn token, proof? ->
      params = %{"confirm_host" => s.params["confirm_host"], "_csrf_token" => token}
      params = if proof?, do: T.with_click_proof(params), else: params

      %{conn(:post, s.path, params) | secret_key_base: @secret_key_base}
      |> recycle_cookies(get)
      |> T.put_safari_fetch_headers()
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> post.("wrong", true) |> call() end
    unproven = post.(token, false) |> call()
    assert unproven.status == 200 and unproven.resp_body =~ "oauth-activation-unproven"
    refute s.changed?.()
  end

  # ════════════════════════════════════════════════════════════════════════════
  # (d) — fetch() / iframe / cross-origin / missing headers: still refused, with the proof
  # ════════════════════════════════════════════════════════════════════════════

  for action <- @actions do
    describe "#{action}: what the strict level protects against stays refused (403 fetch_metadata), the proof does not help" do
      for {label, header, value} <- [
            {"fetch() of a script (mode cors)", "sec-fetch-mode", "cors"},
            {"fetch() of a script (mode same-origin)", "sec-fetch-mode", "same-origin"},
            {"fetch() of a script (dest empty)", "sec-fetch-dest", "empty"},
            {"a hidden iframe (dest iframe)", "sec-fetch-dest", "iframe"},
            {"a cross-site form post", "sec-fetch-site", "cross-site"},
            {"a same-site (sibling host) form post", "sec-fetch-site", "same-site"},
            {"a typed-in / bookmark request (site none)", "sec-fetch-site", "none"}
          ] do
        test "(d) Safari + proof + #{label} => 403, nothing changed, no audit", %{ids: ids} do
          s = spec(unquote(action), ids)
          before = audited(s).()
          conn = safari(s, true) |> put_req_header(unquote(header), unquote(value)) |> call()
          assert refused?(conn), "got #{conn.status}"
          refute s.changed?.()
          assert audited(s).() == before
        end
      end

      for header <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest) do
        test "(d) Safari + proof + #{header} missing (an old browser / a stripping proxy) => 403, never the notice", %{ids: ids} do
          s = spec(unquote(action), ids)
          conn = safari(s, true) |> delete_req_header(unquote(header)) |> call()
          assert refused?(conn), "got #{conn.status}"
          refute s.changed?.()
          conn2 = safari(s, false) |> delete_req_header(unquote(header)) |> call()
          assert refused?(conn2), "without the proof too: a missing header is a refusal, not a notice"
        end
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # (e) — Sec-Fetch-User present but not ?1, or the proof on an engine that always sends it
  # ════════════════════════════════════════════════════════════════════════════

  for action <- @actions do
    describe "#{action}: Sec-Fetch-User is not replaceable where the browser sends it" do
      test "(e) Safari set + proof + Sec-Fetch-User: ?0 (and other non-?1 values) => 403, nothing changed", %{ids: ids} do
        s = spec(unquote(action), ids)

        for value <- ["?0", "1", "true", ""] do
          conn = safari(s, true) |> put_req_header("sec-fetch-user", value) |> call()
          assert refused?(conn), "Sec-Fetch-User #{inspect(value)}: got #{conn.status}"
        end

        refute s.changed?.()
      end

      test "(e) a duplicated Sec-Fetch-User with the proof => 403", %{ids: ids} do
        s = spec(unquote(action), ids)
        c = safari(s, true)
        conn = %{c | req_headers: c.req_headers ++ [{"sec-fetch-user", "?1"}, {"sec-fetch-user", "?1"}]} |> call()
        assert refused?(conn)
        refute s.changed?.()
      end

      test "(e) Chrome / Firefox / unknown User-Agent without Sec-Fetch-User + the proof => 403 (no downgrade for engines that send the header)", %{ids: ids} do
        s = spec(unquote(action), ids)

        for ua <- [T.chrome_user_agent(), T.firefox_user_agent(), nil] do
          c = safari(s, true) |> delete_req_header("user-agent")
          c = if ua, do: put_req_header(c, "user-agent", ua), else: c
          conn = c |> call()
          assert refused?(conn), "UA #{inspect(ua)}: got #{conn.status}"
          refute s.changed?.()
        end
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # the 403 page after the change, and the forms carry the proof field
  # ════════════════════════════════════════════════════════════════════════════

  test "the 403 refusal page keeps its marker and no longer blames only scripts", %{ids: ids} do
    s = spec(:approve, ids)
    conn = safari(s, true) |> put_req_header("sec-fetch-dest", "iframe") |> call()
    assert refused?(conn)
    text = doc(conn) |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ")
    assert text =~ ~r/nothing was changed/i
    assert text =~ "If you used a script or an embedded page, open the page and press the button yourself."
    assert text =~ "current Chrome, Firefox or Safari", "names the supported browsers"
  end

  describe "AC4 — every strict admin form carries the hidden _click_proof field (empty by default)" do
    defp proof_field(form), do: Floki.find(form, ~s(input[type="hidden"][name="_click_proof"]))

    test "approve confirm page, revoke confirm page", %{ids: ids} do
      p = insert_client(ids, "pending")
      a = insert_client(ids, "approved")

      approve = admin_conn(:get, approve_path(p.id)) |> call()
      assert [form] = doc(approve) |> Floki.find(~s(form[data-role="approve-confirm-form"]))
      assert [field] = proof_field(form)
      assert Floki.attribute(field, "value") == [""] or Floki.attribute(field, "value") == []
      assert Floki.attribute(field, "data-click-proof") != [], "the script finds it by data-click-proof"

      revoke = admin_conn(:get, revoke_path(a.id)) |> call()
      assert [form] = doc(revoke) |> Floki.find(~s(form[data-role="revoke-confirm-form"]))
      assert [_] = proof_field(form)
    end

    test "every reject row of the pending list has its own field; the list has no other state-changing form without it", %{ids: ids} do
      insert_client(ids, "pending")
      insert_client(ids, "pending")
      list = admin_conn(:get, @reg_path) |> call() |> doc()
      forms = Floki.find(list, ~s(form[data-form="reject-client"]))
      assert length(forms) >= 2

      for f <- forms, do: assert([_] = proof_field(f))

      # the bulk form of the list is a GET form (a preview): no proof field needed
      assert [bulk] = Floki.find(list, ~s(form[data-form="bulk-remove"]))
      assert Floki.attribute(bulk, "method") |> Enum.map(&String.downcase/1) == ["get"]
    end

    test "bulk-remove confirm form of the preview", %{ids: ids} do
      domain = "t#{T.rand(5)}.com"
      insert_client(ids, "pending", %{host: "a.#{domain}", client_domain: domain})
      page = admin_conn(:get, "#{@reg_path}/bulk-remove?host=#{domain}&match=domain") |> call() |> doc()
      assert [form] = Floki.find(page, ~s(form[data-form="bulk-remove-confirm"]))
      assert [_] = proof_field(form)
    end
  end
end
