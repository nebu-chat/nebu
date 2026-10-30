defmodule Nebu.Admin.AdminReauthButtonFlowMediaTest do
  @moduledoc """
  Story `admin-reauth-button-flow`, forms 6 and 7: the two marker forms of `/admin/media/settings` (storage policy `#media-settings-form`, storage target
  `#media-storage-form`), bound to the ONE marker path `/admin/media/settings`. The second submit of the storage form, "Test Connection"
  (`formaction="/admin/media/settings/storage/test-connection"`, a `:click` gate), stays a plain submit in both states and its answer page renders in the
  state of the marker. The reworded storage hint keeps saying that the access key and the secret key are never filled in.

  Seams: the ones of `admin_media_settings_gate_test.exs` (config / storage writers, the storage loader, the audit repo fake). No database.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @page S.media_path()
  @storage_path "/admin/media/settings/storage"
  @test_connection_path "/admin/media/settings/storage/test-connection"

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}
    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  @policy %{
    "max_upload_size_bytes" => "52428800",
    "max_file_size_bytes" => "104857600",
    "max_pending_per_user" => "20",
    "max_stall_ms" => "20000",
    "deleted_days" => "31",
    "infected_days" => "7",
    "orphaned_hours" => "24",
    "webhook_url" => "",
    "released_delete_after_days" => ""
  }

  @storage %{"endpoint" => "93.184.216.34:9000", "bucket" => "media-bucket", "region" => "us-east-1", "use_ssl" => "false", "access_key" => "AKIAFLOWTEST", "secret_key" => "flow-test-secret-zq91", "s3_key_prefix_template" => "{media_id}"}

  setup do
    test_pid = self()
    T.put_env_scoped(:admin_csrf_bypass, true)
    Application.put_env(:compliance, :repo, FakeAuditRepo)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "media-flow-test-at-rest-secret")

    Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
      send(test_pid, {:policy_written, key, value})
      :ok
    end)

    Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      send(test_pid, {:storage_written, Map.keys(columns)})
      :ok
    end)

    Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
    Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

    Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
      send(test_pid, {:tested, candidate.endpoint})
      :ok
    end)

    Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    on_exit(fn ->
      for k <- [:admin_secret_at_rest, :media_config_writer, :media_storage_config_writer, :media_storage_config_loader, :media_storage_env_reader, :media_storage_test_connection_fun, :media_files_storage_key_count_fun, :media_config_source, :media_config_loader] do
        Application.delete_env(:nebu_http, k)
      end

      Application.delete_env(:compliance, :repo)
    end)

    :ok
  end

  defp debug_logging! do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  defp refute_nothing_written do
    refute_received {:policy_written, _, _}
    refute_received {:storage_written, _}
  end

  defp all_stale!(doc) do
    for form <- S.forms_of(@page), do: S.assert_stale!(doc, form)
    assert_test_connection_plain!(doc)
  end

  defp all_fresh!(doc, minutes) do
    for form <- S.forms_of(@page), do: S.assert_fresh!(doc, form, minutes)
    assert_test_connection_plain!(doc)
  end

  # "Test Connection" is a submit of the storage form with its own formaction in BOTH states (the `:click` gate, no fresh sign-in)
  defp assert_test_connection_plain!(doc) do
    assert [form] = Floki.find(doc, "form#media-storage-form")
    assert [button] = form |> Floki.find("button") |> Enum.filter(&(S.norm(&1) == "Test Connection"))
    assert Floki.attribute(button, "formaction") == [@test_connection_path]
    assert Floki.attribute(button, "type") in [["submit"], []]
  end

  # ── scenario 1: stale ──────────────────────────────────────────────────────────────────────────

  describe "scenario 1 - stale: Sign in again link" do
    for form <- S.forms_of(@page) do
      test "#{form.key}: link with exact text and href of the media page, described by the hint, no Save submit" do
        conn = S.get(@page)
        assert conn.status == 200
        link = S.assert_stale!(S.doc(conn), unquote(Macro.escape(form)))
        assert S.norm(link) == "Sign in again to save"
        assert Floki.attribute(link, "href") == [Auth.reauth_start_path("/admin/media/settings")]
      end
    end

    test "both forms carry the same link, Test Connection stays a plain submit" do
      doc = S.get(@page) |> S.doc()
      assert S.signin_hrefs(doc) == List.duplicate(Auth.reauth_start_path(@page), 2)
      all_stale!(doc)
    end

    test "the storage hint is reworded to sign in first and still says the access key and secret key are never filled in" do
      text = S.get(@page) |> S.doc() |> S.assert_stale_hint!(S.form(:media_storage))
      assert text =~ ~r/never/i
      refute text =~ "If you are asked to sign in again"
      assert text =~ ~r/Test Connection does not use up the sign-in, so you can test and then save/, "the stale hint tells that testing first costs no sign-in: #{text}"
    end

    test "the FRESH storage hint says the validity AND that the access key and secret key are never filled in and Test Connection needs no sign-in" do
      text = S.get(@page, ago: 20) |> S.doc() |> S.assert_fresh_hint!(S.form(:media_storage), 4)
      assert text =~ ~r/secret key[^.]*never|never[^.]*secret key/i
      assert text =~ ~r/test connection needs no new sign-in/i
    end

    test "the inputs stay editable and the secret key is never pre-filled in either state" do
      for marker <- [nil, [ago: 30]] do
        doc = S.get(@page, marker) |> S.doc()
        assert [f] = Floki.find(doc, "form#media-storage-form")

        for name <- ["access_key", "secret_key"] do
          assert [input] = Floki.find(f, ~s(input[name="#{name}"]))
          assert Floki.attribute(input, "value") in [[], [""]], "#{name} is never pre-filled"
        end

        assert [_] = Floki.find(f, ~s(input#endpoint))
        assert Floki.find(f, ~s(input#endpoint[disabled])) == []
      end
    end

    test "the sign-in link is built from the page path, never from the request query string" do
      conn = S.get("/admin/media/settings?return_to=%2Fadmin%2Fdashboard&mode=reauth&leak=secret-qs-79")
      assert S.signin_hrefs(S.doc(conn)) == List.duplicate(Auth.reauth_start_path(@page), 2)
      refute conn.resp_body =~ "secret-qs-79"
    end
  end

  # ── scenario 2: fresh ──────────────────────────────────────────────────────────────────────────

  describe "scenario 2 - fresh: Save and validity line" do
    for form <- S.forms_of(@page) do
      test "#{form.key}: the normal Save submit, described by the hint with the minutes and one save" do
        conn = S.get(@page, ago: 190)
        assert conn.status == 200
        button = S.assert_fresh!(S.doc(conn), unquote(Macro.escape(form)), 1)
        assert S.norm(button) == "Save"
      end
    end

    test "ONE marker bound to /admin/media/settings unlocks BOTH forms; the minutes are floored" do
      for {ago, minutes} <- [{30, 4}, {130, 2}, {190, 1}, {270, :less}] do
        all_fresh!(S.get(@page, ago: ago) |> S.doc(), minutes)
      end
    end

    test "no sign-in link anywhere on the page of a fresh marker" do
      assert S.get(@page, ago: 30) |> S.doc() |> S.signin_hrefs() == []
    end
  end

  # ── scenario 3: consumption and re-render paths ────────────────────────────────────────────────

  describe "scenario 3 - the links come back after a save" do
    test "the policy saved: the page rendered next (real cookie) shows the links of BOTH forms again" do
      post = S.post(@page, @policy, @page, ago: 10)
      assert post.status in [302, 303]
      assert get_resp_header(post, "location") == [@page]
      assert_received {:policy_written, _, _}

      next = S.next_get(post, @page)
      assert next.status == 200
      all_stale!(S.doc(next))
    end

    test "the storage target saved: the links of BOTH forms come back" do
      post = S.post(@storage_path, @storage, @page, ago: 10)
      assert post.status in [302, 303]
      assert_received {:storage_written, _}
      all_stale!(S.next_get(post, @page) |> S.doc())
    end

    test "a policy validation error re-renders (200) with the marker kept: BOTH forms still fresh, no write" do
      post = S.post(@page, %{@policy | "max_pending_per_user" => "0"}, @page, ago: 130)
      assert post.status == 200
      all_fresh!(S.doc(post), 2)
      refute_nothing_written()
    end

    test "a storage validation error re-renders (200) with the marker kept: BOTH forms still fresh, no write" do
      post = S.post(@storage_path, %{@storage | "endpoint" => "https://scheme-prefixed.example"}, @page, ago: 130)
      assert post.status == 200
      all_fresh!(S.doc(post), 2)
      refute_nothing_written()
    end

    test "the orphan-risk warning (200, nothing saved) renders with the marker kept: BOTH forms still fresh" do
      Application.put_env(:nebu_http, :media_storage_config_loader, fn ->
        %{"endpoint" => "old-endpoint:9000", "bucket" => "old-bucket", "region" => "us-east-1", "use_ssl" => false, "access_key_encrypted" => nil, "secret_key_encrypted" => nil, "s3_key_prefix_template" => "{media_id}", "archive_bucket" => nil, "iam_endpoint" => nil, "sts_endpoint" => nil}
      end)

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 7 end)
      post = S.post(@storage_path, @storage, @page, ago: 130)
      assert post.status == 200
      doc = S.doc(post)
      # the REAL orphan-risk render path: the warning with the count and the acknowledgement checkbox, not just any "7"
      assert [warning] = Floki.find(doc, "div.alert-error")
      assert S.norm(warning) =~ "does not migrate existing objects"
      assert S.norm(warning) =~ "7"
      assert [_] = Floki.find(doc, "input#confirm_orphan_risk")
      all_fresh!(doc, 2)
      refute_nothing_written()
    end
  end

  describe "Test Connection stays a plain submit and its answer renders in the state of the marker" do
    test "without a marker: the answer page shows the links, Test Connection works, nothing is saved" do
      post = S.post(@test_connection_path, @storage)
      assert post.status == 200
      assert post.resp_body =~ "Connection succeeded."
      assert_received {:tested, "93.184.216.34:9000"}
      all_stale!(S.doc(post))
      refute_nothing_written()
    end

    test "with a fresh marker: the answer page shows the Save buttons and the marker is not consumed" do
      post = S.post(@test_connection_path, @storage, @page, ago: 130)
      assert post.status == 200
      assert post.resp_body =~ "Connection succeeded."
      all_fresh!(S.doc(post), 2)
      assert post.private.plug_session["admin_reauth"] != nil
      refute_nothing_written()
    end

    test "the answer page of a failed test keeps the state too (a marker of another page: links)" do
      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn _candidate -> {:error, :econnrefused} end)
      post = S.post(@test_connection_path, @storage, "/admin/config", ago: 30)
      assert post.status == 200
      all_stale!(S.doc(post))
    end
  end

  # ── scenario 4: expired ────────────────────────────────────────────────────────────────────────

  describe "scenario 4 - marker expires while the page is open" do
    for {key, path, canary} <- [{:media_policy, "/admin/media/settings", "https://canary-hook-zq84.example/x"}, {:media_storage, "/admin/media/settings/storage", "canary-secret-zq85"}] do
      test "#{key}: refused after 300 s, redirect to the sign-in, nothing saved, no value or secret in the Location or the log" do
        debug_logging!()
        form = S.form(unquote(key))
        S.assert_fresh!(S.get(@page, ago: 20) |> S.doc(), form, 4)

        params =
          if unquote(key) == :media_policy,
            do: %{@policy | "webhook_url" => unquote(canary)},
            else: %{@storage | "secret_key" => unquote(canary), "access_key" => "canary-access-zq86"}

        {post, log} = with_log([level: :debug], fn -> S.post(unquote(path), params, @page, ago: 310) end)

        assert post.status in [302, 303]
        assert get_resp_header(post, "location") == [Auth.reauth_start_path(@page)]
        refute hd(get_resp_header(post, "location")) =~ "canary"
        refute post.resp_body =~ "canary"
        refute_nothing_written()
        refute log =~ "canary", "no form value or secret in any log line"
        refute log =~ S.sub()
        refute log =~ "admin_reauth"

        S.assert_stale!(S.get(@page, ago: 310) |> S.doc(), form)

        canaries = if unquote(key) == :media_policy, do: ["canary-hook-zq84"], else: ["canary-secret-zq85", "canary-access-zq86"]
        S.assert_no_replay!(post, @page, canaries, ago: 310)
      end
    end

    test "at the edge: 270 s old is fresh (less than a minute), 310 s old is stale, for both forms" do
      all_fresh!(S.get(@page, ago: 270) |> S.doc(), :less)
      all_stale!(S.get(@page, ago: 310) |> S.doc())
    end
  end

  # ── scenario 5: another marker does not unlock ─────────────────────────────────────────────────

  describe "scenario 5 - another marker does not unlock the media page" do
    for {label, other} <- [{"the config page", "/admin/config"}, {"claim mapping", "/admin/config/claim-mapping"}, {"role mapping", "/admin/config/role-mapping"}, {"an approve page", "/admin/oauth/registrations/c1/approve"}, {"a revoke page", "/admin/oauth/clients/c1/revoke"}, {"the storage POST path", "/admin/media/settings/storage"}] do
      test "a marker bound to #{label} leaves BOTH forms stale, Test Connection plain" do
        all_stale!(S.get(@page, path: unquote(other)) |> S.doc())
      end
    end

    test "a marker of another subject leaves both forms stale" do
      all_stale!(S.get(@page, sub: "somebody-else") |> S.doc())
    end

    test "the sign-in links of the media page carry only the page path, whatever the marker" do
      for marker <- [nil, [ago: 400], [path: "/admin/config"]] do
        doc = S.get(@page, marker) |> S.doc()
        S.assert_clean_links!(doc, [@page])
        assert length(S.signin_hrefs(doc)) == 2, "stale: two links, not none (a vacuous check proves nothing)"
      end
    end
  end
end
