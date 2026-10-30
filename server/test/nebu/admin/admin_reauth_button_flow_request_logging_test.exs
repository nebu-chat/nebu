defmodule Nebu.Admin.AdminReauthButtonFlowRequestLoggingTest do
  @moduledoc """
  Story `admin-reauth-button-flow` (Kassandra #1): the form values of the marker-gated admin forms never reach a log line at `:debug`, on EITHER logging path:

    * `Phoenix.Logger` ("Parameters: ..."), masked by `config :phoenix, filter_parameters`;
    * `Nebu.Web.Plugs.RequestLogger` (mounted in `Nebu.Web.Router`, which serves `/admin/*`), which captures `conn.body_params` of Matrix requests,
      filtered by the exact-key `PayloadRedactor`. Request bodies of `/admin/*` are not captured at all (new forms and fields are covered without a list).

  The request goes through the plugs of the top-level router in front of the admin endpoint (`RequestId`, `RequestLogger`, then `Nebu.Admin.Endpoint`;
  the router itself does not dispatch to the admin endpoint in the test environment). No database.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}
    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  @canaries ~w(canary-secret-rl71 canary-access-rl72 canary-hook-rl73 canary-claim-rl74 canary-endpoint-rl75)

  @storage %{
    "endpoint" => "93.184.216.34:9000",
    "bucket" => "media-bucket",
    "region" => "us-east-1",
    "use_ssl" => "false",
    "access_key" => "canary-access-rl72",
    "secret_key" => "canary-secret-rl71",
    "s3_key_prefix_template" => "{media_id}"
  }
  @claims %{"oidc_user_id_claim" => "canary-claim-rl74", "oidc_displayname_claim" => "canary-claim-rl74", "oidc_email_claim" => "canary-claim-rl74"}

  setup do
    test_pid = self()
    T.put_env_scoped(:admin_csrf_bypass, true)
    Application.put_env(:compliance, :repo, FakeAuditRepo)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "request-logging-test-at-rest-secret")
    Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      send(test_pid, {:storage_written, Map.keys(columns)})
      :ok
    end)

    Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
    Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)
    Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    on_exit(fn ->
      for k <- [:admin_secret_at_rest, :media_storage_config_writer, :media_storage_config_loader, :media_storage_env_reader, :media_files_storage_key_count_fun, :media_config_source] do
        Application.delete_env(:nebu_http, k)
      end

      Application.delete_env(:compliance, :repo)
    end)

    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
    :ok
  end

  # the plugs of `Nebu.Web.Router` that run in front of the admin endpoint and log the request
  defp through_router(conn) do
    conn
    |> Nebu.Web.Plugs.RequestId.call(Nebu.Web.Plugs.RequestId.init([]))
    |> Nebu.Web.Plugs.RequestLogger.call(Nebu.Web.Plugs.RequestLogger.init([]))
    |> S.call()
  end

  defp post_logged(path, params, marker_path, opts) do
    conn = S.admin_conn(:post, path, params)
    conn = if marker_path == :none, do: conn, else: S.with_marker(conn, marker_path, opts)
    conn |> T.put_strict_fetch_headers() |> through_router()
  end

  defp refute_canaries!(log) do
    # the request itself is logged (the capture is not empty), only the values are not
    assert log =~ "Processing with Nebu.Admin."
    assert log =~ "request_body"
    for canary <- @canaries, do: refute(log =~ canary, "#{canary} must not appear in any log line")
  end

  describe "the storage target form (access key, secret key, endpoint)" do
    test "a saved POST (fresh marker): no canary in any log line, and the save happened" do
      {conn, log} = with_log([level: :debug], fn -> post_logged("/admin/media/settings/storage", @storage, S.media_path(), ago: 5) end)

      assert conn.status in [302, 303]
      assert_received {:storage_written, _}
      refute_canaries!(log)
    end

    test "a refused POST (expired marker): no canary in any log line, nothing saved" do
      {conn, log} = with_log([level: :debug], fn -> post_logged("/admin/media/settings/storage", @storage, S.media_path(), ago: 310) end)

      assert conn.status in [302, 303]
      refute_received {:storage_written, _}
      refute_canaries!(log)
    end

    test "a refused POST (no marker at all): no canary in any log line" do
      {_conn, log} = with_log([level: :debug], fn -> post_logged("/admin/media/settings/storage", @storage, :none, []) end)

      refute_canaries!(log)
    end
  end

  describe "an endpoint with user info (https://user:password@host)" do
    for {label, field, url} <- [
          {"plain password", "iam_endpoint", "https://canary-user:canary-endpoint-rl75@93.184.216.34/iam"},
          {"slash in the password", "iam_endpoint", "https://canary-user:se/cret-canary-endpoint-rl75@93.184.216.34/iam"},
          {"plain password", "sts_endpoint", "https://canary-user:canary-endpoint-rl75@93.184.216.34/sts"},
          {"question mark in the password", "sts_endpoint", "https://canary-user:se?cret-canary-endpoint-rl75@93.184.216.34/sts"}
        ] do
      test "#{field} (#{label}): refused, nothing saved, nothing of the URL in any log line or on the page" do
        params = Map.put(@storage, unquote(field), unquote(url))

        {conn, log} = with_log([level: :debug], fn -> post_logged("/admin/media/settings/storage", params, S.media_path(), ago: 5) end)

        refute_received {:storage_written, _}
        refute conn.resp_body =~ "canary-user", "the page does not echo the URL"
        refute conn.resp_body =~ "canary-endpoint"
        assert log =~ "IAM/STS endpoint rejected: the URL carries user info", "the rejection ran (positive control)"
        assert log =~ ~s("#{unquote(field)}" => "[FILTERED]"), "Phoenix prints the parameter, masked"
        refute_canaries!(log)
        refute log =~ "canary-user", "not even the user name (URI.parse reads it as the host when the password holds a slash)"
      end
    end

    test "a user info pasted into the plain endpoint is refused and in no log line" do
      params = Map.put(@storage, "endpoint", "canary-user:canary-endpoint-rl75@93.184.216.34")

      {conn, log} = with_log([level: :debug], fn -> post_logged("/admin/media/settings/storage", params, S.media_path(), ago: 5) end)

      refute_received {:storage_written, _}
      refute conn.resp_body =~ "canary-endpoint"
      assert log =~ ~s("endpoint" => "[FILTERED]")
      refute_canaries!(log)
      refute log =~ "canary-user"
    end
  end

  describe "a percent-encoded /admin path (the routers decode before they match)" do
    test "/%61dmin/media/settings/storage reaches the admin app and its body is not captured" do
      {conn, log} = with_log([level: :debug], fn -> post_logged("/%61dmin/media/settings/storage", @storage, S.media_path(), ago: 5) end)

      assert conn.status in [302, 303]
      assert_received {:storage_written, _}, "the request was routed to the admin form (so the exemption matters)"
      refute_canaries!(log)
    end
  end

  describe "another admin form (claim mapping)" do
    test "a refused POST (expired marker) with canary claim names: no canary in any log line" do
      {conn, log} = with_log([level: :debug], fn -> post_logged("/admin/config/claim-mapping", @claims, "/admin/config/claim-mapping", ago: 310) end)

      assert conn.status in [302, 303]
      refute_canaries!(log)
    end
  end

  describe "a Matrix request body is still captured by the RequestLogger (the admin exemption is narrow)" do
    test "a JSON body of a non-admin path is logged redacted at :debug" do
      conn = Plug.Test.conn(:post, "/_matrix/client/v3/some/route", %{"visible_field" => "canary-visible-rl76"})
      conn = %{conn | body_params: %{"visible_field" => "canary-visible-rl76"}}

      log =
        with_log([level: :debug], fn ->
          conn
          |> Nebu.Web.Plugs.RequestId.call(Nebu.Web.Plugs.RequestId.init([]))
          |> Nebu.Web.Plugs.RequestLogger.call(Nebu.Web.Plugs.RequestLogger.init([]))
          |> Plug.Conn.send_resp(200, "")
        end)
        |> elem(1)

      assert log =~ "canary-visible-rl76"
    end
  end
end
