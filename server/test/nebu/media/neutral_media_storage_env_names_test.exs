defmodule Nebu.Media.NeutralMediaStorageEnvNamesTest do
  @moduledoc """
  ATDD for story `neutral-media-storage-env-names` (REQ-2026-001) — Neutral media storage environment variable names (hard break).

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`. Red until the story is implemented.

  No database and no network: the boot-time contract is checked by evaluating the REAL `config/runtime.exs`
  with `Config.Reader.read!/2` under a patched OS environment (same technique as `Nebu.RuntimeStorageEndpointTest`), the
  per-request contract by `Nebu.Media.StorageConfig` with its loader seam (no saved row) and its DEFAULT env reader (the real
  OS environment), and the documentation scenario by file-content checks of `CHANGELOG.md` and `07-deployment.md`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  @root Path.expand("../../../..", __DIR__)
  @runtime Path.join(@root, "server/config/runtime.exs")
  @changelog Path.join(@root, "CHANGELOG.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")

  # what runtime.exs insists on outside :test; throwaway values that only live during the read
  @required_env %{
    "NEBU_DB_URL" => "postgresql://u:p@localhost:5432/atdd",
    "NEBU_PII_ENCRYPTION_KEY" => String.duplicate("ab", 32),
    "NEBU_ADMIN_SECRET_KEY_BASE" => String.duplicate("k", 64)
  }

  @other_env ~w(CLUSTER_STRATEGY KUBERNETES_NAMESPACE KUBERNETES_SELECTOR KUBERNETES_SERVICE_NAME)

  # removed name => its replacement (the hard break)
  @renames [
    {"NEBU_MINIO_ENDPOINT", "NEBU_MEDIA_STORAGE_ENDPOINT"},
    {"NEBU_MINIO_USE_SSL", "NEBU_MEDIA_STORAGE_USE_SSL"},
    {"NEBU_MINIO_BUCKET", "NEBU_MEDIA_STORAGE_BUCKET"},
    {"NEBU_MINIO_ARCHIVE_BUCKET", "NEBU_MEDIA_STORAGE_ARCHIVE_BUCKET"},
    {"NEBU_MINIO_ACCESS_KEY", "NEBU_MEDIA_STORAGE_ACCESS_KEY"},
    {"NEBU_MINIO_ACCESS_KEY_FILE", "NEBU_MEDIA_STORAGE_ACCESS_KEY_FILE"},
    {"NEBU_MINIO_SECRET_KEY", "NEBU_MEDIA_STORAGE_SECRET_KEY"},
    {"NEBU_MINIO_SECRET_KEY_FILE", "NEBU_MEDIA_STORAGE_SECRET_KEY_FILE"},
    {"NEBU_MINIO_IAM_ENDPOINT", "NEBU_MEDIA_STORAGE_IAM_ENDPOINT"},
    {"NEBU_MINIO_STS_ENDPOINT", "NEBU_MEDIA_STORAGE_STS_ENDPOINT"},
    {"NEBU_TEST_MINIO_ENDPOINT", "NEBU_TEST_MEDIA_STORAGE_ENDPOINT"}
  ]

  defp scoped?(name), do: String.starts_with?(name, "NEBU_") or name in @other_env

  setup do
    snapshot = for {name, value} <- System.get_env(), scoped?(name), do: {name, value}

    on_exit(fn ->
      for {name, _} <- System.get_env(), scoped?(name), do: System.delete_env(name)
      for {name, value} <- snapshot, do: System.put_env(name, value)
    end)

    # a clean slate: no ambient NEBU_* value (a dev shell, a CI job) may change what is read
    for {name, _} <- System.get_env(), scoped?(name), do: System.delete_env(name)
    for {name, value} <- @required_env, do: System.put_env(name, value)

    T.isolate!()
    T.install_row(nil)
    :ok
  end

  defp put_env(vars), do: for({name, value} <- vars, do: System.put_env(name, value))

  # evaluates the real runtime.exs with the CURRENT OS environment
  defp read_runtime(env \\ :prod), do: Config.Reader.read!(@runtime, env: env, target: :host)

  defp s3(config), do: config |> Keyword.fetch!(:ex_aws) |> Keyword.fetch!(:s3)
  defp ex_aws(config), do: Keyword.fetch!(config, :ex_aws)

  defp raised(fun) do
    fun.()
    nil
  rescue
    e -> e
  end

  # Scenario: Server reads object store settings from the neutral names
  #   Given the environment sets NEBU_MEDIA_STORAGE_ENDPOINT and NEBU_MEDIA_STORAGE_BUCKET
  #   When the server starts
  #   Then media uploads and downloads use that endpoint and bucket
  @tag ac: "server-reads-object-store-settings-from-the-neutral-names"
  test "Scenario: Server reads object store settings from the neutral names" do
    put_env(%{
      "NEBU_MEDIA_STORAGE_ENDPOINT" => "store.internal:9100",
      "NEBU_MEDIA_STORAGE_BUCKET" => "neutral-bucket",
      "NEBU_MEDIA_STORAGE_ACCESS_KEY" => "NEUTRALACCESS0001",
      "NEBU_MEDIA_STORAGE_SECRET_KEY" => "neutral-secret-0001"
    })

    # boot-time contract (config/runtime.exs)
    config = read_runtime()
    assert Keyword.take(s3(config), [:host, :port]) == [host: "store.internal", port: 9100]
    assert config[:nebu_http][:media_bucket] == "neutral-bucket"

    # per-request contract (what uploads and downloads address): the default env reader of StorageConfig
    assert %{endpoint: "store.internal:9100", bucket: "neutral-bucket"} = StorageConfig.get()

    assert {:ok, %{overrides: overrides, bucket: "neutral-bucket"}} = StorageConfig.request_target()
    assert Keyword.take(overrides, [:host, :port]) == [host: "store.internal", port: 9100]
  end

  # Scenario: The *_FILE secret variant keeps precedence over the plain variable
  #   Given NEBU_MEDIA_STORAGE_SECRET_KEY_FILE points to a readable file and NEBU_MEDIA_STORAGE_SECRET_KEY is also set
  #   When the server loads the storage configuration
  #   Then the secret read from the file is used
  @tag ac: "the-file-secret-variant-keeps-precedence-over-the-plain-variable"
  test "Scenario: The *_FILE secret variant keeps precedence over the plain variable" do
    access_file = T.write_secret_file!("file-access-0002")
    secret_file = T.write_secret_file!("file-secret-0002")

    put_env(%{
      "NEBU_MEDIA_STORAGE_ACCESS_KEY_FILE" => access_file,
      "NEBU_MEDIA_STORAGE_ACCESS_KEY" => "plain-access-0002",
      "NEBU_MEDIA_STORAGE_SECRET_KEY_FILE" => secret_file,
      "NEBU_MEDIA_STORAGE_SECRET_KEY" => "plain-secret-0002"
    })

    config = read_runtime()
    assert ex_aws(config)[:access_key_id] == "file-access-0002"
    assert ex_aws(config)[:secret_access_key] == "file-secret-0002"

    assert %{access_key: "file-access-0002", secret_key: "file-secret-0002"} = StorageConfig.get_for_connection()

    assert {:ok, %{overrides: overrides}} = StorageConfig.request_target()
    assert overrides[:access_key_id] == "file-access-0002"
    assert overrides[:secret_access_key] == "file-secret-0002"
  end

  # Scenario: Legacy NEBU_MINIO_* names are ignored and not read
  #   Given a deployment still sets NEBU_MINIO_ENDPOINT and does not set NEBU_MEDIA_STORAGE_ENDPOINT
  #   When the server starts
  #   Then the default endpoint "minio:9000" is used and the legacy NEBU_MINIO_ENDPOINT value is not read
  @tag ac: "legacy-nebu-minio-names-are-ignored-and-not-read"
  test "Scenario: Legacy NEBU_MINIO_* names are ignored and not read" do
    put_env(%{
      "NEBU_MINIO_ENDPOINT" => "legacy.example:9999",
      "NEBU_MINIO_USE_SSL" => "true",
      "NEBU_MINIO_BUCKET" => "legacy-bucket",
      "NEBU_MINIO_ARCHIVE_BUCKET" => "legacy-archive",
      "NEBU_MINIO_ACCESS_KEY" => "LEGACYACCESS0003",
      "NEBU_MINIO_SECRET_KEY" => "legacy-secret-0003",
      "NEBU_MINIO_IAM_ENDPOINT" => "https://iam.legacy.example",
      "NEBU_MINIO_STS_ENDPOINT" => "https://sts.legacy.example"
    })

    config = read_runtime()
    s3 = s3(config)
    assert {s3[:scheme], s3[:host], s3[:port]} == {"http://", "minio", 9000}
    assert ex_aws(config)[:access_key_id] == ""
    assert ex_aws(config)[:secret_access_key] == ""
    assert config[:nebu_http][:media_bucket] == "nebu-media"
    assert config[:nebu_http][:media_archive_bucket] == "nebu-media-archive"
    assert config[:nebu_http][:media_iam_endpoint] == nil
    assert config[:nebu_http][:media_sts_endpoint] == nil

    cfg = StorageConfig.get_for_connection()
    assert cfg.endpoint == "minio:9000"
    assert cfg.bucket == "nebu-media"
    assert cfg.use_ssl == false
    assert cfg.access_key == nil
    assert cfg.secret_key == nil
    assert cfg.iam_endpoint == nil
    assert cfg.sts_endpoint == nil
  end

  @tag ac: "legacy-nebu-minio-names-are-ignored-and-not-read"
  test "Scenario: Legacy NEBU_MINIO_* names are ignored and not read (a blank or unreadable legacy value does not abort boot)" do
    put_env(%{"NEBU_MINIO_ENDPOINT" => "", "NEBU_MINIO_SECRET_KEY_FILE" => "/nonexistent/legacy-secret-file"})

    assert raised(fn -> read_runtime() end) == nil, "the legacy names are not read, so neither value can abort boot"
  end

  # Scenario: The breaking change is documented for operators
  #   Given the release containing the rename is prepared
  #   When an operator reads the CHANGELOG and the deployment documentation
  #   Then the CHANGELOG has a breaking-change entry listing every removed NEBU_MINIO_* name with its NEBU_MEDIA_STORAGE_* replacement, and the operator-facing deployment note says that old names are silently ignored
  @tag ac: "the-breaking-change-is-documented-for-operators"
  test "Scenario: The breaking change is documented for operators" do
    changelog = File.read!(@changelog)
    [_, after_unreleased] = String.split(changelog, "## [0.4.0]", parts: 2)
    unreleased = after_unreleased |> String.split(~r/\n## \[/, parts: 2) |> hd() |> String.replace(~r/\s+/, " ")

    # one entry that is marked as breaking and names the rename
    entry =
      after_unreleased
      |> String.split(~r/\n## \[/, parts: 2)
      |> hd()
      |> String.split("\n")
      |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
      |> Enum.find(&(&1 =~ ~r/BREAKING/i and &1 =~ "NEBU_MEDIA_STORAGE_"))

    assert entry, "the [Unreleased] section has a BREAKING entry for the NEBU_MEDIA_STORAGE_* rename"

    for {old, new} <- @renames do
      assert entry =~ old, "the breaking-change entry lists the removed name #{old}"
      assert entry =~ new, "the breaking-change entry lists the replacement #{new} of #{old}"
    end

    assert unreleased =~ ~r/no fallback|not read|ignored/i

    deploy = @deploy |> File.read!() |> String.replace(~r/\s+/, " ")
    assert deploy =~ "NEBU_MEDIA_STORAGE_ENDPOINT", "the deployment documentation uses the neutral names"
    assert deploy =~ ~r/NEBU_MINIO_\*[^.]{0,200}silently ignored|silently ignored[^.]{0,200}NEBU_MINIO_\*/,
           "the operator-facing deployment note says that the old NEBU_MINIO_* names are silently ignored"
  end

  # Scenario: Object store credentials never appear in logs or errors
  #   Given object store credentials are configured through the neutral variables
  #   When the server logs its startup configuration or reports a storage error
  #   Then neither the access key nor the secret key value appears in any log line or error message
  @tag ac: "object-store-credentials-never-appear-in-logs-or-errors"
  test "Scenario: Object store credentials never appear in logs or errors" do
    access = "NEUTRALCANARYACCESS0005"
    secret = "neutral-canary-secret-0005"

    put_env(%{
      "NEBU_MEDIA_STORAGE_ACCESS_KEY" => access,
      "NEBU_MEDIA_STORAGE_SECRET_KEY" => secret,
      "NEBU_MEDIA_STORAGE_ENDPOINT" => "   "
    })

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # the credentials really are configured through the neutral names ...
    assert StorageConfig.get_for_connection().access_key == access
    assert StorageConfig.get_for_connection().secret_key == secret

    # ... a storage error (blank endpoint) is reported without them, in the returned term and in the log
    log =
      capture_log(fn ->
        send(self(), {:result, StorageConfig.request_target()})
        send(self(), {:view, StorageConfig.get()})
        send(self(), {:boot, raised(fn -> read_runtime() end)})
      end)

    assert_received {:result, result}
    assert_received {:view, view}
    assert_received {:boot, boot_error}

    assert result == {:error, :storage_endpoint_blank}

    # the startup configuration (runtime.exs) aborts on the blank neutral endpoint and names the neutral variable only
    assert boot_error != nil, "boot must abort on a blank NEBU_MEDIA_STORAGE_ENDPOINT"
    assert Exception.message(boot_error) =~ "NEBU_MEDIA_STORAGE_ENDPOINT"

    for text <- [log, inspect(result), inspect(view), Exception.message(boot_error)], value <- [access, secret] do
      refute text =~ value
    end

    # a successful startup read does not log or echo them either
    System.put_env("NEBU_MEDIA_STORAGE_ENDPOINT", "store.internal:9100")

    ok_log =
      capture_log(fn ->
        read_runtime()
        send(self(), {:target, StorageConfig.request_target()})
      end)

    assert_received {:target, {:ok, target}}
    assert target.overrides[:host] == "store.internal"
    refute ok_log =~ access
    refute ok_log =~ secret
    refute inspect(StorageConfig.get()) =~ secret
    refute inspect(StorageConfig.get()) =~ access
  end
end
