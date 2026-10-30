defmodule Nebu.Admin.MediaSettingsStorageErrorsTest do
  @moduledoc """
  How the storage settings form reports a refused save and what it says about the keys (story
  `media-storage-uses-admin-config`; setup as `Nebu.Admin.MediaSettingsFreshSaveTest`):

  * The three Save validation errors (invalid endpoint, keys required for a different endpoint / Use SSL, half a key pair)
    are rendered INSIDE the Storage Target section, in the position of the Test Connection result and before the form, as
    `<p id="media-storage-error" role="alert" tabindex="-1" autofocus class="alert alert-error ...">`, and the fields they
    are about carry `aria-invalid="true"` and `aria-describedby="media-storage-error"` (#endpoint for the invalid endpoint,
    #access_key and #secret_key for the two key errors). A normal GET and a successful save show none of that.
  * The exact texts of the Save errors and of the Test Connection answers (a neutral one when the stored pair of the SAME
    target is missing or unusable, the "different endpoint" one otherwise).
  * The key field hints depend on the state (configured, not configured, "Required now" after a refused save).
  * The orphan-risk alert says to enter the keys again, and the confirmation (checkbox, ticked) survives a `:secret_required`
    re-render so that the next submit with the keys passes.
  * A save that carries keys always writes `endpoint` and `use_ssl` in the same row write, also when they equal the cached
    view; a save without keys still filters unchanged fields.
  * The page shows "Not currently configured." for half a pair or undecryptable keys, also where the environment credentials
    would apply.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Media.StorageAdminTargetSupport, as: S
  alias Nebu.Media.StorageConfig
  alias Nebu.OAuth.TestSupport, as: T

  Code.require_file("../media/storage_admin_target_support.exs", __DIR__)

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-storage-errors-test-key-base", 2)
  @page "/admin/media/settings"
  @save "/admin/media/settings/storage"
  @test_connection "/admin/media/settings/storage/test-connection"

  @env_endpoint "storage.example.test:9000"
  @other_endpoint "93.184.216.35:9000"

  @secret_required_text "Enter the access key and secret key to use a different endpoint or a changed Use SSL setting. The stored credentials are only used for the stored endpoint and scheme. Nothing was saved."
  @pair_text "Enter both the access key and the secret key. Nothing was saved."
  @neutral_text "The stored access key and secret key are missing or unusable. Enter both keys to test. Nothing was saved."
  @different_text "Enter the access key and secret key to test a different endpoint or a changed Use SSL setting: the stored credentials are only used for the stored endpoint and scheme. Nothing was saved."

  @hint_configured "Currently configured. Leave blank to keep it. Enter both keys again if you change the endpoint or Use SSL; Save and Test Connection both require them."
  @hint_missing "Not currently configured. Required: Save and Test Connection both need both keys."
  @hint_required_now "Required now: enter both the access key and the secret key."

  @orphan_sentence "Enter the access key and secret key again before saving."

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_storage_errors_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  setup do
    S.isolate!()
    test_pid = self()
    S.put_env_scoped(:nebu_http, :admin_csrf_bypass, true)
    S.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    S.put_env_scoped(:compliance, :__test_storage_errors_pid__, test_pid)
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
      "NEBU_MINIO_ACCESS_KEY" => "ENVAKIDERRORS1301",
      "NEBU_MINIO_SECRET_KEY" => "env-secret-errors-1301"
    })

    {:ok, store: store}
  end

  defp stored(store, attrs), do: Agent.update(store, fn _ -> S.saved_row(attrs) end)
  defp stored_raw(store, row), do: Agent.update(store, fn _ -> row end)

  defp keyed(endpoint), do: %{endpoint: endpoint, use_ssl: false, bucket: "stored-bucket", region: "stored-region", access_key: "STOREDAKID1301", secret_key: "stored-secret-1301"}

  defp form(overrides \\ %{}) do
    Map.merge(
      %{
        "endpoint" => @env_endpoint,
        "bucket" => "stored-bucket",
        "region" => "stored-region",
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
  defp save(params), do: admin_conn(:post, @save, params) |> with_marker() |> call()
  defp test_connection(params), do: admin_conn(:post, @test_connection, params) |> call()
  defp page, do: admin_conn(:get, @page, %{}) |> call()

  defp doc(conn) do
    {:ok, doc} = Floki.parse_document(conn.resp_body)
    doc
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
  defp text_of(nodes), do: nodes |> Floki.text() |> squish()
  defp error_nodes(doc), do: Floki.find(doc, "p#media-storage-error")
  defp alert_texts(doc), do: doc |> Floki.find("p[role=alert]") |> Enum.map(&text_of([&1]))
  defp hint(doc, field), do: doc |> Floki.find(~s(label[for="#{field}"] span.label-text-alt)) |> text_of()

  defp attr(doc, selector, name), do: doc |> Floki.find(selector) |> Floki.attribute(name)

  defp assert_nothing_persisted do
    refute_received {:storage_written, _}
    refute_received {:audit_insert, _}
  end

  # {label, form overrides (on top of form/0), the field ids the error is about, expected error text (or a function)}
  defp refusals do
    [
      {:invalid_endpoint, %{"endpoint" => "93.184.216.35:9000/path", "access_key" => "TYPEDAKID1301", "secret_key" => "typed-secret-1301"}, ["endpoint"],
       StorageConfig.describe_invalid_endpoint("93.184.216.35:9000/path")},
      {:secret_required, %{"endpoint" => @other_endpoint}, ["access_key", "secret_key"], @secret_required_text},
      {:secret_required_use_ssl, %{"use_ssl" => "true"}, ["access_key", "secret_key"], @secret_required_text},
      {:key_pair_required, %{"access_key" => "TYPEDAKID1301"}, ["access_key", "secret_key"], @pair_text}
    ]
  end

  describe "Q - a refused save is reported inside the Storage Target section, with aria and focus hooks" do
    for label <- [:invalid_endpoint, :secret_required, :secret_required_use_ssl, :key_pair_required] do
      test "#{label}: p#media-storage-error (role alert, tabindex -1, autofocus) before the form, aria-invalid on the fields it is about", %{store: store} do
        stored(store, keyed(@env_endpoint))
        {_, overrides, fields, expected_text} = List.keyfind(refusals(), unquote(label), 0)

        conn = save(form(overrides))
        assert conn.status == 200
        doc = doc(conn)

        assert [error] = error_nodes(doc)
        assert Floki.attribute(error, "role") == ["alert"]
        assert Floki.attribute(error, "tabindex") == ["-1"]
        assert Floki.attribute([error], "autofocus") != []
        assert "alert-error" in (error |> Floki.attribute("class") |> List.first() |> String.split())
        assert text_of([error]) == expected_text

        # in the Storage Target section: after its heading, before the form (the position of the Test Connection result)
        body = conn.resp_body
        {h2, _} = :binary.match(body, "Storage Target")
        {p, _} = :binary.match(body, ~s(id="media-storage-error"))
        {form, _} = :binary.match(body, ~s(id="media-storage-form"))
        assert h2 < p and p < form

        for id <- ["endpoint", "access_key", "secret_key"] do
          selector = ~s(input##{id})

          if id in fields do
            assert attr(doc, selector, "aria-invalid") == ["true"], "#{id}"
            assert attr(doc, selector, "aria-describedby") == ["media-storage-error"], "#{id}"
          else
            assert attr(doc, selector, "aria-invalid") == [], "#{id}"
          end
        end

        assert_nothing_persisted()
      end
    end

    test "a normal GET and a Test Connection result show none of it", %{store: store} do
      stored(store, keyed(@env_endpoint))

      for conn <- [page(), test_connection(form())] do
        doc = doc(conn)
        assert error_nodes(doc) == []
        assert Floki.find(doc, "[aria-invalid]") == []
        refute conn.resp_body =~ "media-storage-error"
      end
    end

    test "a successful save redirects and renders no error", %{store: store} do
      stored(store, keyed(@env_endpoint))
      conn = save(form(%{"bucket" => "renamed-bucket"}))
      assert conn.status in [302, 303]
      refute conn.resp_body =~ "media-storage-error"
    end
  end

  describe "R - the texts" do
    test "Save, :secret_required for a different endpoint and for a Use SSL toggle: names both, says nothing was saved", %{store: store} do
      stored(store, keyed(@env_endpoint))

      for overrides <- [%{"endpoint" => @other_endpoint}, %{"use_ssl" => "true"}] do
        assert [error] = save(form(overrides)) |> doc() |> error_nodes()
        assert text_of([error]) == @secret_required_text
      end
    end

    test "Save, :key_pair_required ends with a period and says nothing was saved", %{store: store} do
      stored(store, keyed(@env_endpoint))
      assert [error] = save(form(%{"secret_key" => "typed-secret-1301"})) |> doc() |> error_nodes()
      assert text_of([error]) == @pair_text
    end

    test "Test Connection, blank keys, the SAME target whose stored pair is half, undecryptable or missing: the neutral message", %{store: store} do
      rows = [
        S.saved_row(Map.delete(keyed(@other_endpoint), :secret_key)),
        S.saved_row(Map.drop(keyed(@other_endpoint), [:access_key, :secret_key])),
        S.saved_row(Map.drop(keyed(@other_endpoint), [:access_key, :secret_key]))
        |> Map.put("access_key_encrypted", S.corrupt_ciphertext())
        |> Map.put("secret_key_encrypted", S.corrupt_ciphertext())
      ]

      for row <- rows do
        stored_raw(store, row)
        conn = test_connection(form(%{"endpoint" => @other_endpoint}))
        assert @neutral_text in alert_texts(doc(conn))
        refute @different_text in alert_texts(doc(conn))
      end

      refute_received {:tested, _}
    end

    test "Test Connection, blank keys, a different endpoint or Use SSL: the existing message", %{store: store} do
      stored(store, keyed(@other_endpoint))

      for overrides <- [%{"endpoint" => "93.184.216.36:9000"}, %{"endpoint" => @other_endpoint, "use_ssl" => "true"}] do
        conn = test_connection(form(overrides))
        assert @different_text in alert_texts(doc(conn))
        refute @neutral_text in alert_texts(doc(conn))
      end

      refute_received {:tested, _}
    end
  end

  describe "S - the key field hints follow the state" do
    test "configured (saved keys, and the environment keys for the environment's own target)", %{store: store} do
      for attrs <- [keyed(@other_endpoint), Map.drop(keyed(@env_endpoint), [:access_key, :secret_key])] do
        stored(store, attrs)
        doc = doc(page())
        assert hint(doc, "access_key") == @hint_configured
        assert hint(doc, "secret_key") == @hint_configured
      end
    end

    test "not configured", %{store: store} do
      stored(store, Map.drop(keyed(@other_endpoint), [:access_key, :secret_key]))
      doc = doc(page())
      assert hint(doc, "access_key") == @hint_missing
      assert hint(doc, "secret_key") == @hint_missing
    end

    for label <- [:invalid_endpoint, :secret_required, :secret_required_use_ssl, :key_pair_required] do
      test "after a refused save (#{label}) both hints say Required now", %{store: store} do
        stored(store, keyed(@env_endpoint))
        {_, overrides, _, _} = List.keyfind(refusals(), unquote(label), 0)

        doc = save(form(overrides)) |> doc()
        assert hint(doc, "access_key") == @hint_required_now
        assert hint(doc, "secret_key") == @hint_required_now
      end
    end
  end

  describe "T - the orphan-risk round trip" do
    setup %{store: store} do
      S.put_env_scoped(:nebu_http, :media_files_storage_key_count_fun, fn -> 5 end)
      stored(store, keyed(@env_endpoint))
      :ok
    end

    test "the orphan alert says to enter the keys again, the checkbox is not ticked" do
      conn = save(form(%{"endpoint" => @other_endpoint, "access_key" => "TYPEDAKID1301", "secret_key" => "typed-secret-1301"}))

      assert conn.status == 200
      doc = doc(conn)
      assert Enum.any?(alert_texts(doc), &String.contains?(&1, @orphan_sentence)), inspect(alert_texts(doc))
      assert attr(doc, "input#confirm_orphan_risk", "checked") == []
      assert_nothing_persisted()
    end

    test "ticked but without keys: the :secret_required re-render keeps the confirmation (rendered and ticked); the next submit with the keys is saved" do
      conn = save(form(%{"endpoint" => @other_endpoint, "confirm_orphan_risk" => "true"}))

      assert conn.status == 200
      doc = doc(conn)
      assert [error] = error_nodes(doc)
      assert text_of([error]) == @secret_required_text
      assert attr(doc, "input#confirm_orphan_risk", "checked") != [], "the ticked confirmation must stay ticked"
      assert Enum.any?(alert_texts(doc), &String.contains?(&1, "5 existing file(s)")), "the orphan warning stays visible"
      assert_nothing_persisted()

      conn = save(form(%{"endpoint" => @other_endpoint, "confirm_orphan_risk" => "true", "access_key" => "TYPEDAKID1301", "secret_key" => "typed-secret-1301"}))
      assert conn.status in [302, 303]
      assert_received {:storage_written, %{"endpoint" => @other_endpoint, "access_key_encrypted" => _, "secret_key_encrypted" => _}}
    end
  end

  describe "U - a save that carries keys writes endpoint and use_ssl in the same row write" do
    test "keys only (rotation) for the unchanged endpoint: endpoint and use_ssl are in the columns", %{store: store} do
      stored(store, keyed(@other_endpoint))

      conn = save(form(%{"endpoint" => @other_endpoint, "access_key" => "NEWAKID1301", "secret_key" => "new-secret-1301"}))

      assert conn.status in [302, 303]
      assert_received {:storage_written, columns}
      assert columns["endpoint"] == @other_endpoint
      assert columns["use_ssl"] == false
      assert is_binary(columns["access_key_encrypted"]) and is_binary(columns["secret_key_encrypted"])
    end

    test "no keys: unchanged fields are still filtered (only the changed bucket is written)", %{store: store} do
      stored(store, keyed(@other_endpoint))

      conn = save(form(%{"endpoint" => @other_endpoint, "bucket" => "renamed-bucket"}))

      assert conn.status in [302, 303]
      assert_received {:storage_written, columns}
      assert columns["bucket"] == "renamed-bucket"
      refute Map.has_key?(columns, "endpoint")
      refute Map.has_key?(columns, "use_ssl")
      refute Map.has_key?(columns, "access_key_encrypted")
    end
  end

  describe "V - the page shows what the operational path would use (the environment keys apply)" do
    defp unusable_rows do
      corrupt = fn row -> row |> Map.put("access_key_encrypted", S.corrupt_ciphertext()) |> Map.put("secret_key_encrypted", S.corrupt_ciphertext()) end
      base = %{use_ssl: false, bucket: "b", region: "r"}

      [
        {"env-equal endpoint, undecryptable keys", S.saved_row(Map.put(base, :endpoint, @env_endpoint)) |> corrupt.()},
        {"no endpoint, undecryptable keys", S.saved_row(base) |> corrupt.()},
        {"env-equal endpoint, only the access key saved", S.saved_row(Map.merge(base, %{endpoint: @env_endpoint, access_key: "STOREDAKID1301"}))},
        {"no endpoint, only the secret key saved", S.saved_row(Map.merge(base, %{secret_key: "stored-secret-1301"}))},
        {"another endpoint, only the access key saved", S.saved_row(Map.merge(base, %{endpoint: @other_endpoint, access_key: "STOREDAKID1301"}))}
      ]
    end

    for index <- 0..4 do
      test "unusable stored keys (case #{index}): both fields say Not currently configured and no key is shown", %{store: store} do
        {label, row} = Enum.at(unusable_rows(), unquote(index))
        stored_raw(store, row)

        cfg = StorageConfig.get()
        assert cfg.access_key == nil and cfg.secret_key == nil, label

        doc = doc(page())
        assert hint(doc, "access_key") == @hint_missing, label
        assert hint(doc, "secret_key") == @hint_missing, label
      end
    end

    test "consistent with the operational path: the same rows answer :storage_credentials_missing" do
      S.use_recording_client!()
      S.put_env_scoped(:ex_aws, :retries, max_attempts: 1, base_backoff_in_ms: 1, max_backoff_in_ms: 1)

      for {label, row} <- unusable_rows() do
        S.install_row(row)
        assert {:error, :storage_credentials_missing} = Nebu.Media.Storage.put("obj", "x"), label
      end

      refute_receive {:http_request, _, _, _, _}, 50
    end
  end
end
