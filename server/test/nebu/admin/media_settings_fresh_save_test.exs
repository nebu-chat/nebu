defmodule Nebu.Admin.MediaSettingsFreshSaveTest do
  @moduledoc """
  The storage settings form (`POST /admin/media/settings/storage`, `.../storage/test-connection`, `GET
  /admin/media/settings`) together with the operational calls (story `media-storage-uses-admin-config`):

  * A FIRST save on a fresh config that keeps the environment's own endpoint and Use SSL and only changes the bucket,
    region or key prefix template (blank keys) must not break the media: the next `Nebu.Media.Storage` calls succeed,
    signed with the environment credentials (the row's endpoint is the environment's own target).
  * Half a key pair typed: the form re-renders (200) with "Enter both the access key and the secret key", writes and
    audits nothing, keeps the sign-in marker.
  * The re-renders for `:secret_required`, the half pair and an invalid endpoint keep the TYPED non-secret values
    (endpoint, bucket, region, Use SSL, template) and never echo a key.
  * The key fields say "Not currently configured." for a row with another endpoint and no usable keys (no masked
    environment key as if saved) and "Currently configured." when the environment keys are what is used; their hint
    mentions Save as well as Test Connection.
  * Test Connection with blank keys for a saved endpoint without usable keys never calls the test function.

  Seams as in `Nebu.Admin.MediaSettingsStorageSaveTest`; the written row is kept in an Agent so the saved config is read back.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Media.Storage
  alias Nebu.Media.StorageAdminTargetSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  Code.require_file("../media/storage_admin_target_support.exs", __DIR__)

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-fresh-save-test-key-base", 2)
  @page "/admin/media/settings"
  @save "/admin/media/settings/storage"
  @test_connection "/admin/media/settings/storage/test-connection"
  @pair_message "Enter both the access key and the secret key"
  @different_endpoint_message "Enter the access key and secret key to use a different endpoint"

  @env_endpoint "storage.example.test:9000"
  @env_akid "ENVAKIDFRESH1201"
  @env_secret "env-secret-fresh-1201"

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_fresh_save_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  setup do
    S.isolate!()
    test_pid = self()
    S.put_env_scoped(:nebu_http, :admin_csrf_bypass, true)
    S.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    S.put_env_scoped(:compliance, :__test_fresh_save_pid__, test_pid)
    S.put_env_scoped(:nebu_http, :media_config_source, fn -> %{} end)
    S.put_env_scoped(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
    S.put_env_scoped(:nebu_http, :media_ssrf_resolver, fn _host -> {:ok, [{93, 184, 216, 34}]} end)

    {:ok, store} = Agent.start_link(fn -> nil end)

    S.put_env_scoped(:nebu_http, :media_storage_config_loader, fn -> Agent.get(store, & &1) end)

    S.put_env_scoped(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      Agent.update(store, fn
        nil -> columns
        row -> Map.merge(row, columns)
      end)

      send(test_pid, {:storage_written, columns})
      :ok
    end)

    S.put_env_scoped(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
      send(test_pid, {:tested, candidate})
      :ok
    end)

    S.install_env(%{
      "NEBU_MINIO_ENDPOINT" => @env_endpoint,
      "NEBU_MINIO_USE_SSL" => "false",
      "NEBU_S3_REGION" => "env-region-1",
      "NEBU_MINIO_ACCESS_KEY" => @env_akid,
      "NEBU_MINIO_SECRET_KEY" => @env_secret
    })

    {:ok, store: store}
  end

  defp stored(store, attrs), do: Agent.update(store, fn _ -> S.saved_row(attrs) end)

  defp form(overrides \\ %{}) do
    Map.merge(
      %{
        "endpoint" => @env_endpoint,
        "bucket" => "fresh-bucket",
        "region" => "fresh-region",
        "use_ssl" => "false",
        "access_key" => "",
        "secret_key" => "",
        "s3_key_prefix_template" => "{media_id}",
        "archive_bucket" => "",
        "iam_endpoint" => "",
        "sts_endpoint" => ""
      },
      overrides
    )
  end

  defp admin_conn(method, path, params) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> T.put_strict_fetch_headers()
  end

  defp with_marker(conn), do: put_session(conn, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @page))
  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp marker_kept?(conn), do: conn.private.plug_session["admin_reauth"] != nil
  defp save(params), do: admin_conn(:post, @save, params) |> with_marker() |> call()
  defp page, do: admin_conn(:get, @page, %{}) |> call()
  defp saved?(conn), do: conn.status in [302, 303]

  defp assert_nothing_persisted do
    refute_received {:storage_written, _}
    refute_received {:audit_insert, _}
  end

  defp doc(conn) do
    {:ok, doc} = Floki.parse_document(conn.resp_body)
    doc
  end

  defp akid(headers) do
    auth = Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "authorization", do: v end) || ""

    case Regex.run(~r/Credential=([^\/]+)\/[^\/]+\/([^\/]+)\//, auth) do
      [_, id, region] -> {id, region}
      _ -> nil
    end
  end

  describe "a first save on a fresh config that keeps the environment's own target" do
    test "bucket, region and template changed, blank keys: saved, and the next storage calls work with the environment credentials" do
      S.use_recording_client!()

      conn = save(form(%{"s3_key_prefix_template" => "{year}/{media_id}"}))

      assert saved?(conn), "status #{conn.status}: #{conn.resp_body}"
      assert_received {:storage_written, columns}
      assert columns["endpoint"] == @env_endpoint
      refute Map.has_key?(columns, "access_key_encrypted")

      assert :ok = Storage.put("obj", "x")
      assert_receive {:http_request, :put, url, headers, _}, 1_000
      assert URI.parse(url).host == "storage.example.test"
      assert URI.parse(url).path == "/fresh-bucket/obj"
      assert akid(headers) == {@env_akid, "fresh-region"}

      assert {:ok, _} = Storage.get("obj")
      assert_receive {:http_request, :get, _, headers, _}, 1_000
      assert akid(headers) == {@env_akid, "fresh-region"}
    end
  end

  describe "half a key pair typed" do
    for {label, keys} <- [{"access key only", %{"access_key" => "TYPEDAKID1201"}}, {"secret key only", %{"secret_key" => "typed-secret-1201"}}] do
      test "#{label}, endpoint unchanged: the page asks for both keys, nothing is written or audited, the marker is kept", %{store: store} do
        stored(store, %{endpoint: @env_endpoint, use_ssl: false, bucket: "stored-bucket", region: "r", access_key: "STOREDAKID1201", secret_key: "stored-secret-1201"})

        conn = save(form(Map.merge(%{"bucket" => "renamed-bucket"}, unquote(Macro.escape(keys)))))

        assert conn.status == 200
        assert conn.resp_body =~ @pair_message
        assert_nothing_persisted()
        assert marker_kept?(conn)
      end
    end

    test "on a fresh config as well" do
      conn = save(form(%{"access_key" => "TYPEDAKID1201"}))
      assert conn.status == 200
      assert conn.resp_body =~ @pair_message
      assert_nothing_persisted()
    end

    test "both keys typed: saved" do
      assert saved?(save(form(%{"access_key" => "TYPEDAKID1201", "secret_key" => "typed-secret-1201"})))
      assert_received {:storage_written, %{"access_key_encrypted" => _, "secret_key_encrypted" => _}}
    end
  end

  describe "the re-render keeps the typed non-secret values and never echoes a key" do
    setup %{store: store} do
      stored(store, %{endpoint: @env_endpoint, use_ssl: false, bucket: "stored-bucket", region: "stored-region", access_key: "STOREDAKID1201", secret_key: "stored-secret-1201"})
      :ok
    end

    defp assert_typed_values_kept(conn, endpoint) do
      assert conn.status == 200
      doc = doc(conn)
      assert Floki.attribute(doc, ~s(input[name="endpoint"]), "value") == [endpoint]
      assert Floki.attribute(doc, ~s(input[name="bucket"]), "value") == ["typed-bucket"]
      assert Floki.attribute(doc, ~s(input[name="region"]), "value") == ["typed-region"]
      assert Floki.attribute(doc, ~s(input[name="s3_key_prefix_template"]), "value") == ["{year}/{media_id}"]
      assert Floki.attribute(doc, ~s(input[name="use_ssl"]), "checked") != []
      refute conn.resp_body =~ "TYPEDKEYCANARY1201"
      refute conn.resp_body =~ "typed-secret-canary-1201"
    end

    @typed %{"bucket" => "typed-bucket", "region" => "typed-region", "use_ssl" => "true", "s3_key_prefix_template" => "{year}/{media_id}"}

    test "a different endpoint without keys (:secret_required)" do
      conn = save(form(Map.merge(@typed, %{"endpoint" => "93.184.216.35:9000"})))
      assert conn.resp_body =~ @different_endpoint_message
      assert_typed_values_kept(conn, "93.184.216.35:9000")
      assert_nothing_persisted()
    end

    test "half a key pair", %{store: store} do
      conn = save(form(Map.merge(@typed, %{"endpoint" => "93.184.216.35:9000", "access_key" => "TYPEDKEYCANARY1201"})))
      assert conn.resp_body =~ @different_endpoint_message or conn.resp_body =~ @pair_message
      assert_typed_values_kept(conn, "93.184.216.35:9000")

      stored(store, %{endpoint: @env_endpoint, use_ssl: true, bucket: "stored-bucket", region: "stored-region", access_key: "STOREDAKID1201", secret_key: "stored-secret-1201"})
      conn = save(form(Map.merge(@typed, %{"endpoint" => @env_endpoint, "secret_key" => "typed-secret-canary-1201"})))
      assert conn.resp_body =~ @pair_message
      assert_typed_values_kept(conn, @env_endpoint)
      assert_nothing_persisted()
    end

    test "an invalid endpoint (with both keys typed)" do
      conn = save(form(Map.merge(@typed, %{"endpoint" => "93.184.216.35:9000/path", "access_key" => "TYPEDKEYCANARY1201", "secret_key" => "typed-secret-canary-1201"})))
      assert conn.resp_body =~ ~s(role="alert")
      assert_typed_values_kept(conn, "93.184.216.35:9000/path")
      assert_nothing_persisted()
    end
  end

  describe "what the page shows for the keys" do
    test "a row with another endpoint and NULL keys (environment keys set): both key fields say Not currently configured", %{store: store} do
      stored(store, %{endpoint: "other.example.test:9000", use_ssl: false, bucket: "b", region: "r"})

      body = page().resp_body
      refute body =~ "Currently configured."
      assert length(String.split(body, "Not currently configured.")) - 1 >= 2
    end

    test "a row with the environment's own endpoint and NULL keys: the environment keys are what is used, Currently configured", %{store: store} do
      stored(store, %{endpoint: @env_endpoint, use_ssl: false, bucket: "b", region: "r"})

      body = page().resp_body
      assert length(String.split(body, "Currently configured.")) - 1 >= 2
    end

    test "the hint of both key fields mentions Save as well as Test Connection", %{store: store} do
      stored(store, %{endpoint: @env_endpoint, use_ssl: false, bucket: "b", region: "r"})
      doc = doc(page())

      for field <- ["access_key", "secret_key"] do
        text = doc |> Floki.find(~s(label[for="#{field}"] span.label-text-alt)) |> Floki.text()
        assert text =~ "Save", "#{field}: #{text}"
        assert text =~ "Test Connection", "#{field}: #{text}"
      end
    end
  end

  describe "Test Connection with blank keys" do
    test "a saved endpoint without usable keys (another than the environment's): an alert, the test function is never called", %{store: store} do
      stored(store, %{endpoint: "93.184.216.35:9000", use_ssl: false, bucket: "b", region: "r"})

      conn = admin_conn(:post, @test_connection, form(%{"endpoint" => "93.184.216.35:9000"})) |> call()

      assert conn.status == 200
      assert conn.resp_body =~ ~s(role="alert")
      refute_received {:tested, _}
    end

    test "the environment's own endpoint: the test runs with the environment credentials", %{store: store} do
      stored(store, %{endpoint: @env_endpoint, use_ssl: false, bucket: "b", region: "r"})

      conn = admin_conn(:post, @test_connection, form()) |> call()

      assert conn.status == 200
      assert_received {:tested, %{access_key: @env_akid, secret_key: @env_secret}}
    end
  end
end
