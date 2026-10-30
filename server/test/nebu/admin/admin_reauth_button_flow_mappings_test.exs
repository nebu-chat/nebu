defmodule Nebu.Admin.AdminReauthButtonFlowMappingsTest do
  @moduledoc """
  Story `admin-reauth-button-flow`, forms 4 and 5: `/admin/config/claim-mapping` and `/admin/config/role-mapping`, each bound to its OWN marker path. Both submits
  are described by TWO hints (the lock-out hint and the reauth hint) in both states. The role mapping keeps its inline link "Sign in again, then enter the value
  once more" next to the refusal error (decision of the story; both links use `reauth_start_path(<role mapping page>)`); the fingerprint check of the marker
  (`Nebu.Admin.Auth.reauth_role_check/2`) is unchanged and tested in `role_mapping_self_lockout_test.exs`.

  Seams: the ones of `config_privileged_forms_sweep_test.exs` (claim / role mapping writers, audit writer, no stored admin claim path). No database.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @claim S.claim_path()
  @role S.role_path()
  @inline_link "Sign in again, then enter the value once more"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :reauth_flow_map_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      Application.get_env(:nebu_http, :reauth_flow_map_audit_result, :ok)
    end
  end

  setup do
    test_pid = self()
    T.put_env_scoped(:admin_csrf_bypass, true)
    T.put_env_scoped(:reauth_flow_map_sink, self())
    T.put_env_scoped(:reauth_flow_map_audit_result, :ok)
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    for {key, label} <- [admin_config_claim_mapping_writer: :claim, admin_config_role_mapping_writer: :role] do
      Application.put_env(:nebu_http, key, fn changes ->
        send(test_pid, {:written, label, changes})
        :ok
      end)
    end

    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _key -> nil end)

    on_exit(fn ->
      for k <- [:admin_config_claim_mapping_writer, :admin_config_role_mapping_writer, :admin_server_config_reader, :admin_oidc_config_reader], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp debug_logging! do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  defp refute_nothing_written do
    refute_received {:written, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
  end

  @claim_ok %{"oidc_user_id_claim" => "preferred_username", "oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}

  # ── claim mapping (4) ──────────────────────────────────────────────────────────────────────────

  describe "form 4 claim mapping - stale" do
    test "the link, exact text and href of THIS page, described by the reauth hint AND the lock-out hint, no submit" do
      conn = S.get(@claim)
      assert conn.status == 200
      link = S.assert_stale!(S.doc(conn), S.form(:claim_mapping))
      assert S.norm(link) == "Sign in again to save"
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path("/admin/config/claim-mapping")]
    end

    test "the lock-out warning, the three inputs and their labels are unchanged" do
      doc = S.get(@claim) |> S.doc()
      assert [warning] = Floki.find(doc, "#claim-mapping-lockout-hint")
      assert S.norm(warning) =~ ~r/wrong or onto other users/i
      for name <- ["oidc_user_id_claim", "oidc_displayname_claim", "oidc_email_claim"], do: assert([_] = Floki.find(doc, "input[name=\"#{name}\"]"))
      for id <- ["oidc_user_id_claim", "oidc_displayname_claim", "oidc_email_claim"], do: assert([_] = Floki.find(doc, ~s(label[for="#{id}"])))
    end

    test "a marker of the config page, the role mapping page or the media page does not unlock it" do
      for other <- [S.config_path(), @role, S.media_path(), S.approve_path("c1"), S.revoke_path("c1")] do
        S.assert_stale!(S.get(@claim, path: other) |> S.doc(), S.form(:claim_mapping))
      end
    end
  end

  describe "form 4 claim mapping - fresh" do
    test "the normal Save button, described by both hints, the validity line with the whole minutes and for one save" do
      doc = S.get(@claim, ago: 130) |> S.doc()
      button = S.assert_fresh!(doc, S.form(:claim_mapping), 2)
      assert S.norm(button) == "Save"
    end

    test "less than a minute below 60 s, 1 minute (singular) from 60 s, never a link" do
      S.assert_fresh!(S.get(@claim, ago: 250) |> S.doc(), S.form(:claim_mapping), :less)
      S.assert_fresh!(S.get(@claim, ago: 190) |> S.doc(), S.form(:claim_mapping), 1)
      assert S.get(@claim, ago: 190) |> S.doc() |> S.signin_hrefs() == []
    end

    test "a validation error re-renders the page (200) and keeps the marker: still the Save button" do
      post = S.post(@claim, %{@claim_ok | "oidc_user_id_claim" => ""}, @claim, ago: 130)
      assert post.status == 200
      assert S.doc(post) |> Floki.find(~s([data-field="oidc_user_id_claim"][role="alert"])) != []
      S.assert_fresh!(S.doc(post), S.form(:claim_mapping), 2)
      refute_nothing_written()
    end

    test "a refused audit row re-renders the page (200, nothing saved) and keeps the marker: still the Save button" do
      Application.put_env(:nebu_http, :reauth_flow_map_audit_result, {:error, :audit_write_failed})
      post = S.post(@claim, @claim_ok, @claim, ago: 130)
      assert post.status == 200
      assert post.resp_body =~ "not saved: the audit entry could not be written"
      S.assert_fresh!(S.doc(post), S.form(:claim_mapping), 2)
    end
  end

  describe "form 4 claim mapping - consumption and expiry" do
    test "a successful save consumes the marker: the page rendered next (real session cookie) shows the link again" do
      post = S.post(@claim, @claim_ok, @claim, ago: 10)
      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [@claim]
      assert_received {:written, :claim, _}

      S.assert_stale!(S.next_get(post, @claim) |> S.doc(), S.form(:claim_mapping))
    end

    test "rendered fresh, refused after 300 s: the redirect to the sign-in, nothing saved, no value in the Location or the log" do
      debug_logging!()
      S.assert_fresh!(S.get(@claim, ago: 20) |> S.doc(), S.form(:claim_mapping), 4)
      canary = %{"oidc_user_id_claim" => "canary_claim_zq77", "oidc_displayname_claim" => "canary_name_zq79", "oidc_email_claim" => "canary_mail_zq80"}

      {post, log} = with_log([level: :debug], fn -> S.post(@claim, canary, @claim, ago: 310) end)

      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [Auth.reauth_start_path(@claim)]
      refute hd(get_resp_header(post, "location")) =~ "canary"
      refute_nothing_written()
      for value <- ["canary_claim_zq77", "canary_name_zq79", "canary_mail_zq80"], do: refute(log =~ value, "no log line holds #{value}")
      refute log =~ S.sub()
      S.assert_stale!(S.get(@claim, ago: 310) |> S.doc(), S.form(:claim_mapping))
      S.assert_no_replay!(post, @claim, ["canary_claim_zq77", "canary_name_zq79", "canary_mail_zq80"], ago: 310)
    end
  end

  # ── role mapping (5) ───────────────────────────────────────────────────────────────────────────

  describe "form 5 role mapping - stale" do
    test "the link, exact text and href of THIS page, described by the reauth hint AND the lock-out hint, no submit" do
      conn = S.get(@role)
      assert conn.status == 200
      link = S.assert_stale!(S.doc(conn), S.form(:role_mapping))
      assert S.norm(link) == "Sign in again to save"
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path("/admin/config/role-mapping")]
    end

    test "the plain page has the primary link only: no refusal error and no inline link" do
      doc = S.get(@role) |> S.doc()
      assert S.signin_hrefs(doc) == [Auth.reauth_start_path(@role)]
      assert Floki.find(doc, ~s(p[role="alert"][data-field="admin_group_claim"])) == []
      refute S.norm(doc) =~ @inline_link
    end

    test "the claim path line, the lock-out warning and the input keep their ids and describedby" do
      doc = S.get(@role) |> S.doc()
      assert [_] = Floki.find(doc, "#admin-claim-path-line")
      assert [_] = Floki.find(doc, "#role-mapping-lockout-hint")
      assert [input] = Floki.find(doc, "input#admin_group_claim")
      assert Floki.attribute(input, "aria-describedby") == ["admin-claim-path-line"]
    end

    test "a marker of the claim mapping page, the config page or the media page does not unlock it" do
      for other <- [@claim, S.config_path(), S.media_path(), S.approve_path("c1"), S.revoke_path("c1")] do
        S.assert_stale!(S.get(@role, path: other) |> S.doc(), S.form(:role_mapping))
      end
    end
  end

  describe "form 5 role mapping - fresh" do
    test "the normal Save button, described by both hints, the validity line with the whole minutes and for one save" do
      doc = S.get(@role, ago: 190) |> S.doc()
      button = S.assert_fresh!(doc, S.form(:role_mapping), 1)
      assert S.norm(button) == "Save"
      assert S.signin_hrefs(doc) == []
    end

    test "a value missing from the token is refused (200): inline link next to the error, form still fresh" do
      post = S.post(@role, %{"admin_group_claim" => "not-in-my-token-zq5"}, @role, ago: 30)
      assert post.status == 200
      doc = S.doc(post)

      assert [alert] = Floki.find(doc, ~s(p[role="alert"][data-field="admin_group_claim"]))
      assert [inline] = alert |> Floki.find("a") |> Enum.filter(&(S.norm(&1) == @inline_link))
      assert Floki.attribute(inline, "href") == [Auth.reauth_start_path(@role)]
      assert S.norm(alert) =~ ~r/joined this group[^.?]*\?.*only after a new sign-in/i, "the case of the link is explained next to it (a fresh Save button and a sign-in link side by side)"

      S.assert_fresh!(doc, S.form(:role_mapping), 4)
      assert S.signin_hrefs(doc) == [Auth.reauth_start_path(@role)], "only the inline link: the form is fresh, no second link"
      refute_nothing_written()
    end

    test "a marker without a fingerprint (an older build) is refused the same way, with the inline link" do
      conn =
        S.admin_conn(:post, @role, %{"admin_group_claim" => "admins"})
        |> put_session("admin_reauth", T.fresh_marker(S.sub(), 30, "auth_time", @role))
        |> T.put_strict_fetch_headers()
        |> S.call()

      assert conn.status == 200
      doc = S.doc(conn)
      assert [inline] = doc |> Floki.find(~s(p[role="alert"][data-field="admin_group_claim"] a)) |> Enum.filter(&(S.norm(&1) == @inline_link))
      assert Floki.attribute(inline, "href") == [Auth.reauth_start_path(@role)]
      S.assert_fresh!(doc, S.form(:role_mapping), 4)
    end

    test "refusals without an inline link (empty value, a value of every token) re-render in the fresh state too" do
      for value <- ["", "offline_access"] do
        post = S.post(@role, %{"admin_group_claim" => value}, @role, ago: 30)
        assert post.status == 200, value
        doc = S.doc(post)
        assert [_] = Floki.find(doc, ~s(p[role="alert"][data-field="admin_group_claim"]))
        assert S.signin_hrefs(doc) == [], "no link at all: #{inspect(value)}"
        S.assert_fresh!(doc, S.form(:role_mapping), 4)
      end

      refute_nothing_written()
    end

    test "a refused audit row re-renders the page (200, nothing saved) and keeps the marker: still the Save button" do
      Application.put_env(:nebu_http, :reauth_flow_map_audit_result, {:error, :audit_write_failed})
      post = S.post(@role, %{"admin_group_claim" => "ops-admins"}, @role, ago: 30)
      assert post.status == 200
      S.assert_fresh!(S.doc(post), S.form(:role_mapping), 4)
    end
  end

  describe "form 5 role mapping - consumption and expiry" do
    test "a successful save consumes the marker: the page rendered next (real session cookie) shows the link again" do
      post = S.post(@role, %{"admin_group_claim" => "ops-admins"}, @role, ago: 10)
      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [@role]
      assert_received {:written, :role, %{"admin_group_claim" => "ops-admins"}}

      S.assert_stale!(S.next_get(post, @role) |> S.doc(), S.form(:role_mapping))
    end

    test "rendered fresh, refused after 300 s: the redirect to the sign-in, nothing saved, no value in the Location or the log" do
      debug_logging!()
      S.assert_fresh!(S.get(@role, ago: 20) |> S.doc(), S.form(:role_mapping), 4)

      {post, log} = with_log([level: :debug], fn -> S.post(@role, %{"admin_group_claim" => "canary-role-zq78"}, @role, ago: 310) end)

      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [Auth.reauth_start_path(@role)]
      refute hd(get_resp_header(post, "location")) =~ "canary"
      refute_nothing_written()
      refute log =~ "canary-role-zq78"
      refute log =~ S.sub()
      S.assert_stale!(S.get(@role, ago: 310) |> S.doc(), S.form(:role_mapping))
      S.assert_no_replay!(post, @role, ["canary-role-zq78"], ago: 310)
    end

    test "the sign-in links of the two pages carry only their own page path (no value, no marker content)" do
      for {page, marker} <- [{@claim, nil}, {@claim, [ago: 400]}, {@role, nil}, {@role, [path: @claim]}] do
        doc = S.get(page, marker) |> S.doc()
        S.assert_clean_links!(doc, [page])
        assert length(S.signin_hrefs(doc)) == 1, "stale: one link, not none (a vacuous check proves nothing)"
      end
    end
  end
end
