defmodule Nebu.Admin.AdminReauthButtonFlowConfirmTest do
  @moduledoc """
  Story `admin-reauth-button-flow`, forms 8 and 9: the approve confirm page (`/admin/oauth/registrations/<id>/approve`) and the revoke confirm page
  (`/admin/oauth/clients/<id>/revoke`), each bound to the marker path of its client and action (assigned as `@reauth` by `OAuthAdminHelpers.assign_reauth/2`).

  Stale: INSIDE the form the link "Sign in again to approve" / "Sign in again to revoke" (href = `reauth_start_path(<confirm page>)`) instead of the submit; the
  `data-role="approve-confirm"` / `"revoke-confirm"` submit exists in the FRESH state only (it keeps `data-role` and, for approve, the `aria-label` naming the client).
  The element `[data-role="reauth-state"]` (+ `data-reauth="fresh" | "needed"`) is the hint: it gets an `id` (the control's `aria-describedby`) and, fresh, the validity line.
  The inputs of the revoke form stay editable and keep `#confirm-host-help` / `#revoke-reason-help`. Real database (integration): the pages read the client rows.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.put_env_scoped(:admin_csrf_bypass, true)
    T.enable_oauth()
    {:ok, ids} = Agent.start(fn -> [] end)

    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      T.clear_oauth_config()
      T.cleanup_clients(Agent.get(ids, & &1))
      Agent.stop(ids)
    end)

    {:ok, ids: ids}
  end

  defp insert_client(ids, status, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    id = "atdd-flow-#{n}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    Agent.update(ids, &[id | &1])
    host = Map.get(attrs, :host, "app#{n}.example.com")
    name = Map.get(attrs, :name, "FlowApp-#{n}-end")

    metadata = %{"client_name" => name, "client_uri" => "https://#{host}", "redirect_uris" => ["https://#{host}/callback"], "application_type" => "web"}
    T.insert_row!(id, Jason.encode!(metadata), "hash-#{id}", status, "NOW()", "web", client_host: host, client_domain: nil, revoked_reason: nil, revoked_by: "@root:test.local")
    %{id: id, name: name, host: host}
  end

  defp debug_logging! do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  # ── form 8: approve ────────────────────────────────────────────────────────────────────────────

  describe "form 8 approve - stale" do
    test "the link replaces the submit: exact text, href of THIS client's approve page, described by the reauth-state element", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = S.get(S.approve_path(c.id))
      assert conn.status == 200
      doc = S.doc(conn)
      link = S.assert_stale!(doc, S.approve_form(c.id))

      assert S.norm(link) == "Sign in again to approve"
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path("/admin/oauth/registrations/#{c.id}/approve")]
      assert Floki.find(doc, ~s([data-role="approve-confirm"])) == [], "the submit with data-role=approve-confirm exists in the fresh state only"
    end

    test "the existing hooks stay: the form, Cancel, the back link, the client summary, the reauth-state element with data-reauth=needed", %{ids: ids} do
      c = insert_client(ids, "pending", %{name: "Label Me"})
      doc = S.get(S.approve_path(c.id)) |> S.doc()

      assert [form] = Floki.find(doc, ~s(form[data-role="approve-confirm-form"]))
      assert Floki.attribute(form, "action") == [S.approve_path(c.id)]
      assert [_] = Floki.find(form, ~s(a[data-role="approve-cancel"]))
      assert [_] = Floki.find(doc, ~s(a[data-role="back-to-list"]))
      assert [_] = Floki.find(doc, ~s([data-role="client-summary"]))
      assert [state] = Floki.find(doc, ~s([data-role="reauth-state"]))
      assert Floki.attribute(state, "data-reauth") == ["needed"]
    end

    test "the sign-in link carries only the page path (never the query string of the request)", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = S.get(S.approve_path(c.id) <> "?return_to=%2Fadmin%2Fdashboard&mode=reauth&leak=secret-qs-80&page=3")
      assert S.signin_hrefs(S.doc(conn)) == [Auth.reauth_start_path(S.approve_path(c.id))]
      refute conn.resp_body =~ "secret-qs-80"
    end

    test "a marker of ANOTHER client's approve page, of the same client's revoke page, or of another admin page does not unlock it", %{ids: ids} do
      c = insert_client(ids, "pending")
      other = insert_client(ids, "pending")

      for path <- [S.approve_path(other.id), S.revoke_path(c.id), S.config_path(), S.claim_path(), S.role_path(), S.media_path(), "/admin/oauth/registrations"] do
        S.assert_stale!(S.get(S.approve_path(c.id), path: path) |> S.doc(), S.approve_form(c.id))
      end
    end

    test "a marker of another subject, and an expired one, do not unlock it", %{ids: ids} do
      c = insert_client(ids, "pending")
      S.assert_stale!(S.get(S.approve_path(c.id), sub: "somebody-else") |> S.doc(), S.approve_form(c.id))
      S.assert_stale!(S.get(S.approve_path(c.id), ago: 310) |> S.doc(), S.approve_form(c.id))
    end
  end

  describe "form 8 approve - fresh" do
    test "the submit button keeps data-role and the aria-label naming the client; the validity line is in the reauth-state element", %{ids: ids} do
      c = insert_client(ids, "pending", %{name: "Label Me"})
      doc = S.get(S.approve_path(c.id), ago: 130) |> S.doc()
      button = S.assert_fresh!(doc, S.approve_form(c.id), 2)

      assert S.norm(button) == "Approve client"
      assert Floki.attribute(button, "data-role") == ["approve-confirm"]
      assert Floki.attribute(button, "aria-label") |> hd() =~ "Approve client"
      assert Floki.attribute(button, "aria-label") |> hd() =~ "Label Me"
      assert S.signin_hrefs(doc) == []
    end

    test "the minutes are the remaining whole minutes, rounded down", %{ids: ids} do
      c = insert_client(ids, "pending")

      for {ago, minutes} <- [{30, 4}, {130, 2}, {190, 1}, {250, :less}] do
        S.assert_fresh!(S.get(S.approve_path(c.id), ago: ago) |> S.doc(), S.approve_form(c.id), minutes)
      end
    end

    test "a marker of the approve page of THIS client only: the next pending client's page is stale with the same session", %{ids: ids} do
      a = insert_client(ids, "pending")
      b = insert_client(ids, "pending")
      S.assert_fresh!(S.get(S.approve_path(a.id), ago: 30) |> S.doc(), S.approve_form(a.id), 4)
      S.assert_stale!(S.get(S.approve_path(b.id), path: S.approve_path(a.id), ago: 30) |> S.doc(), S.approve_form(b.id))
    end
  end

  describe "form 8 approve - consumption and expiry" do
    test "a successful approval consumes the marker (no admin_reauth in the session cookie it sets), the client is approved", %{ids: ids} do
      c = insert_client(ids, "pending")
      post = S.post(S.approve_path(c.id), %{}, S.approve_path(c.id), ago: 10)
      assert post.status in [302, 303]
      assert T.client_row(c.id)["status"] == "approved"
      assert post.private.plug_session["admin_reauth"] == nil
    end

    test "rendered fresh, refused after 300 s: redirect to the sign-in, the client stays pending, nothing leaks", %{ids: ids} do
      debug_logging!()
      c = insert_client(ids, "pending")
      S.assert_fresh!(S.get(S.approve_path(c.id), ago: 20) |> S.doc(), S.approve_form(c.id), 4)

      {post, log} = with_log([level: :debug], fn -> S.post(S.approve_path(c.id), %{"page" => "7", "logos" => "1"}, S.approve_path(c.id), ago: 310) end)

      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [Auth.reauth_start_path(S.approve_path(c.id))]
      refute hd(get_resp_header(post, "location")) =~ "page"
      assert T.client_row(c.id)["status"] == "pending", "nothing was saved"
      refute log =~ S.sub()
      refute log =~ "admin_reauth"

      S.assert_stale!(S.get(S.approve_path(c.id), ago: 310) |> S.doc(), S.approve_form(c.id))
      S.assert_no_replay!(post, S.approve_path(c.id), [], ago: 310)
    end
  end

  # ── form 9: revoke ─────────────────────────────────────────────────────────────────────────────

  describe "form 9 revoke - stale" do
    test "the link replaces the submit: exact text, href of THIS client's revoke page, described by the reauth-state element", %{ids: ids} do
      c = insert_client(ids, "approved")
      conn = S.get(S.revoke_path(c.id))
      assert conn.status == 200
      doc = S.doc(conn)
      link = S.assert_stale!(doc, S.revoke_form(c.id))

      assert S.norm(link) == "Sign in again to revoke"
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path("/admin/oauth/clients/#{c.id}/revoke")]
      assert Floki.find(doc, ~s([data-role="revoke-confirm"])) == [], "the submit with data-role=revoke-confirm exists in the fresh state only"
    end

    test "the sign-in link is not styled as the destructive action: plain btn class, while the fresh submit keeps btn-error", %{ids: ids} do
      c = insert_client(ids, "approved")
      link = S.assert_stale!(S.get(S.revoke_path(c.id)) |> S.doc(), S.revoke_form(c.id))
      # a plain `btn` (also the class of Test Connection): `btn-neutral` and `btn-secondary` fail the contrast and focus-ring checks of the admin theme
      assert String.split(hd(Floki.attribute(link, "class"))) == ["btn"], "signing in is not the destructive step, a plain btn is the contrast-checked secondary style"

      fresh = S.get(S.revoke_path(c.id), ago: 20) |> S.doc()
      assert [submit] = Floki.find(fresh, ~s(button[data-role="revoke-confirm"]))
      assert hd(Floki.attribute(submit, "class")) =~ "btn-error"
    end

    test "the host field takes the autofocus only in the fresh state, and the stale hint says that typed input is lost", %{ids: ids} do
      c = insert_client(ids, "approved")
      stale = S.get(S.revoke_path(c.id)) |> S.doc()
      assert Floki.attribute(Floki.find(stale, ~s(input[name="confirm_host"])), "autofocus") == [], "no autofocus while the sign-in link is the primary control"
      assert S.norm(Floki.find(stale, ~s([data-role="reauth-state"]))) =~ ~r/before signing in is lost/i

      fresh = S.get(S.revoke_path(c.id), ago: 20) |> S.doc()
      assert Floki.attribute(Floki.find(fresh, ~s(input[name="confirm_host"])), "autofocus") != []
    end

    test "the existing hooks stay: form, Cancel, the host and reason inputs with their help texts, the consequences, data-reauth=needed", %{ids: ids} do
      c = insert_client(ids, "approved")
      doc = S.get(S.revoke_path(c.id)) |> S.doc()

      assert [form] = Floki.find(doc, ~s(form[data-role="revoke-confirm-form"]))
      assert Floki.attribute(form, "action") == [S.revoke_path(c.id)]
      assert [_] = Floki.find(form, ~s(a[data-role="revoke-cancel"]))
      assert [_] = Floki.find(doc, "#confirm-host-help")
      assert [_] = Floki.find(doc, "#revoke-reason-help")
      assert [host] = Floki.find(form, ~s(input#confirm-host[name="confirm_host"]))
      assert Floki.attribute(host, "aria-describedby") == ["confirm-host-help"]
      assert [reason] = Floki.find(form, ~s(input#revoke-reason[name="reason"]))
      assert Floki.attribute(reason, "aria-describedby") == ["revoke-reason-help"]
      assert [_] = Floki.find(doc, ~s([data-role="revoke-consequences"]))
      assert [state] = Floki.find(doc, ~s([data-role="reauth-state"]))
      assert Floki.attribute(state, "data-reauth") == ["needed"]
    end

    test "the host and reason inputs stay editable (a typed value can be kept until the sign-in)", %{ids: ids} do
      c = insert_client(ids, "approved")
      doc = S.get(S.revoke_path(c.id)) |> S.doc()

      for name <- ["confirm_host", "reason"] do
        assert [input] = Floki.find(doc, ~s(input[name="#{name}"]))
        assert Floki.attribute(input, "disabled") == []
        assert Floki.attribute(input, "readonly") == []
      end
    end

    test "a marker of ANOTHER client's revoke page, of the same client's approve page, or of another admin page does not unlock it", %{ids: ids} do
      c = insert_client(ids, "approved")
      other = insert_client(ids, "approved")

      for path <- [S.revoke_path(other.id), S.approve_path(c.id), S.config_path(), S.claim_path(), S.role_path(), S.media_path(), "/admin/oauth/clients"] do
        S.assert_stale!(S.get(S.revoke_path(c.id), path: path) |> S.doc(), S.revoke_form(c.id))
      end
    end

    test "a marker of another subject, and an expired one, do not unlock it", %{ids: ids} do
      c = insert_client(ids, "approved")
      S.assert_stale!(S.get(S.revoke_path(c.id), sub: "somebody-else") |> S.doc(), S.revoke_form(c.id))
      S.assert_stale!(S.get(S.revoke_path(c.id), ago: 310) |> S.doc(), S.revoke_form(c.id))
    end
  end

  describe "form 9 revoke - fresh" do
    test "the Revoke client submit keeps data-role; the validity line is in the reauth-state element, the inputs and helps are unchanged", %{ids: ids} do
      c = insert_client(ids, "approved")
      doc = S.get(S.revoke_path(c.id), ago: 130) |> S.doc()
      button = S.assert_fresh!(doc, S.revoke_form(c.id), 2)

      assert S.norm(button) == "Revoke client"
      assert Floki.attribute(button, "data-role") == ["revoke-confirm"]
      assert [_] = Floki.find(doc, "#confirm-host-help")
      assert [_] = Floki.find(doc, "#revoke-reason-help")
      assert S.signin_hrefs(doc) == []
    end

    test "the minutes are the remaining whole minutes, rounded down", %{ids: ids} do
      c = insert_client(ids, "approved")

      for {ago, minutes} <- [{30, 4}, {130, 2}, {190, 1}, {250, :less}] do
        S.assert_fresh!(S.get(S.revoke_path(c.id), ago: ago) |> S.doc(), S.revoke_form(c.id), minutes)
      end
    end

    test "a refused typed host (wrong host) keeps the marker: the page after the redirect (real cookie) is still fresh and shows the error", %{ids: ids} do
      c = insert_client(ids, "approved")
      post = S.post(S.revoke_path(c.id), %{"confirm_host" => "nope.example.org"}, S.revoke_path(c.id), ago: 130)
      assert post.status in [302, 303]
      assert T.client_row(c.id)["status"] == "approved"

      next = S.next_get(post, S.revoke_path(c.id))
      assert next.status == 200
      doc = S.doc(next)
      assert [_] = Floki.find(doc, "#confirm-host-error")
      S.assert_fresh!(doc, S.revoke_form(c.id), 2)
    end
  end

  describe "form 9 revoke - consumption and expiry" do
    test "a successful revocation consumes the marker (no admin_reauth in the session cookie it sets), the client is revoked", %{ids: ids} do
      c = insert_client(ids, "approved")
      post = S.post(S.revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "flow test"}, S.revoke_path(c.id), ago: 10)
      assert post.status in [302, 303]
      assert T.client_row(c.id)["status"] == "revoked"
      assert post.private.plug_session["admin_reauth"] == nil
    end

    test "rendered fresh, refused after 300 s: redirect to the sign-in of this page, the client stays approved, no typed value in the Location or the log", %{ids: ids} do
      debug_logging!()
      c = insert_client(ids, "approved")
      S.assert_fresh!(S.get(S.revoke_path(c.id), ago: 20) |> S.doc(), S.revoke_form(c.id), 4)

      {post, log} = with_log([level: :debug], fn -> S.post(S.revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "canary-reason-zq88"}, S.revoke_path(c.id), ago: 310) end)

      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [Auth.reauth_start_path(S.revoke_path(c.id))]
      refute hd(get_resp_header(post, "location")) =~ "canary"
      refute hd(get_resp_header(post, "location")) =~ c.host
      assert T.client_row(c.id)["status"] == "approved", "nothing was saved"
      refute log =~ "canary"
      refute log =~ c.host
      refute log =~ S.sub()
      refute log =~ "admin_reauth"

      S.assert_stale!(S.get(S.revoke_path(c.id), ago: 310) |> S.doc(), S.revoke_form(c.id))
      S.assert_no_replay!(post, S.revoke_path(c.id), ["canary-reason-zq88"], ago: 310)
    end
  end
end
