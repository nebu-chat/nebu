defmodule Nebu.Media.StorageAdminTargetSupport do
  @moduledoc """
  Test support for story `media-storage-uses-admin-config` (epic `media-storage-admin-target`).

  Provides

    * `start_stub/1` — a REAL local HTTP listener (127.0.0.1, ephemeral port) that plays the part of an S3 endpoint: it
      records every request (method, request target, lowercase headers, body size) and sends it to its owner, and
      answers with a valid S3-ish response (GET object bytes, PUT 200, DELETE 204, server-side copy XML, or a fixed
      status such as 403). It never echoes credentials.
    * `RecordingClient` — an `ExAws` HTTP client (`config :ex_aws, :http_client`) that performs NO network I/O and
      reports `{:http_request, method, url, headers}` to the pid in `:nebu_test_recording_pid`.
    * scoped env helpers (`put_env_scoped/3`, `delete_env_scoped/2`) that restore on exit, and
    * builders for a saved `media_storage_config` row (`saved_row/1`, string-keyed, secrets `SecretBox`-encrypted)
      and installers for the `StorageConfig` seams (`install_row/1`, `install_env/1`).

  The "operational" S3 calls of `Nebu.Media.Storage` must be addressed from `Nebu.Media.StorageConfig` at call time. To
  make a wrong fallback visible, `decoy_boot_env!/1` points the BOOT-TIME app env (`:ex_aws`, `:ex_aws, :s3`,
  `:nebu_http, :media_bucket` / `:media_archive_bucket`) at a decoy stub that must receive nothing.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Nebu.Web.SecretBox

  @at_rest_secret "media-storage-admin-target-test-at-rest-secret"

  # ── scoped env ─────────────────────────────────────────────────────────────

  @doc "Puts `value` under `{app, key}` and restores the previous value (or absence) when the test exits."
  def put_env_scoped(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)

    :ok
  end

  @doc "Removes `{app, key}` for the duration of the test (restored on exit)."
  def delete_env_scoped(app, key) do
    previous = Application.fetch_env(app, key)
    Application.delete_env(app, key)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)

    :ok
  end

  @doc "Sets (`value`) or clears (`nil`) an OS env var for the duration of the test (restored on exit)."
  def put_os_env_scoped(name, value) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)

    :ok
  end

  @doc "A `SecretBox`-shaped blob that does not decrypt (a corrupted stored secret): valid hex, wrong tag."
  def corrupt_ciphertext, do: String.duplicate("ab", 48)

  @doc "Writes `content` to a temp file (removed when the test exits) and returns its path (a `*_FILE` secret)."
  def write_secret_file!(content) do
    path = Path.join(System.tmp_dir!(), "nebu-mstor-secret-#{System.unique_integer([:positive])}")
    File.write!(path, content <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  @doc """
  Common isolation for every test of the story: no cached/boot-started `StorageConfig` instance (it is read-through
  then), a working at-rest secret for `SecretBox`, no storage seams left over, bounded hackney timeouts and a single
  attempt per request (a refused request must fail the test fast), and the default `ExAws` HTTP client.
  """
  def isolate! do
    # Registered FIRST, so it runs LAST (after every scoped env is restored): the supervised cache holder is brought
    # back (it is a :transient child, a :normal stop would leave it down for every later test module).
    on_exit(fn ->
      try do
        Nebu.Media.StorageConfig.start_link()
      catch
        :exit, _ -> :ok
      end
    end)

    if pid = Process.whereis(Nebu.Media.StorageConfig) do
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end

    put_env_scoped(:nebu_http, :admin_secret_at_rest, @at_rest_secret)

    for key <- [
          :media_storage_config_source,
          :media_storage_config_loader,
          :media_storage_config_writer,
          :media_storage_env_reader,
          :media_storage_module,
          :media_bucket,
          :media_archive_bucket
        ] do
      delete_env_scoped(:nebu_http, key)
    end

    put_env_scoped(:ex_aws, :retries, max_attempts: 1, base_backoff_in_ms: 1, max_backoff_in_ms: 1)
    put_env_scoped(:ex_aws, :hackney_opts, recv_timeout: 5_000, connect_timeout: 2_000)
    delete_env_scoped(:ex_aws, :http_client)
    delete_env_scoped(:ex_aws, :debug_requests)
    :ok
  end

  # ── StorageConfig seams ────────────────────────────────────────────────────

  @doc """
  A saved `media_storage_config` row as the loader seam returns it (string-keyed). `attrs` (atom keys): `:endpoint`,
  `:use_ssl`, `:region`, `:bucket`, `:archive_bucket`, `:access_key`, `:secret_key` (encrypted here). Absent keys are
  absent from the row (= column NULL).
  """
  def saved_row(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {:access_key, v}, acc -> Map.put(acc, "access_key_encrypted", SecretBox.encrypt(v))
      {:secret_key, v}, acc -> Map.put(acc, "secret_key_encrypted", SecretBox.encrypt(v))
      {k, v}, acc -> Map.put(acc, Atom.to_string(k), v)
    end)
  end

  @doc "Installs `row` (a `saved_row/1` map or `nil` = nothing saved) as the persisted row. A NEW closure per call."
  def install_row(row) do
    put_env_scoped(:nebu_http, :media_storage_config_loader, fn -> row end)
  end

  @doc "Installs the string-keyed map standing in for the `NEBU_MINIO_*` / `NEBU_S3_REGION` OS env vars."
  def install_env(env) when is_map(env) do
    put_env_scoped(:nebu_http, :media_storage_env_reader, fn -> env end)
  end

  @doc """
  Points the BOOT-TIME connection app env (what `config/runtime.exs` writes: `:ex_aws` and `:ex_aws, :s3`) at `decoy`
  (a `start_stub/1` map). A correct implementation never lets a request reach `decoy`.
  """
  def decoy_boot_env!(decoy) do
    put_env_scoped(:ex_aws, :access_key_id, "DECOYBOOTACCESSKEY")
    put_env_scoped(:ex_aws, :secret_access_key, "decoy-boot-secret-key-not-real")
    put_env_scoped(:ex_aws, :region, "decoy-region-1")

    put_env_scoped(:ex_aws, :s3,
      scheme: "http://",
      host: "127.0.0.1",
      port: decoy.port,
      region: "decoy-region-1"
    )

    :ok
  end

  @doc "Boot-time bucket names that differ from every saved / env value of a test (see `decoy_boot_env!/1`)."
  def decoy_boot_buckets! do
    put_env_scoped(:nebu_http, :media_bucket, "decoy-boot-bucket")
    put_env_scoped(:nebu_http, :media_archive_bucket, "decoy-boot-archive-bucket")
    :ok
  end

  # ── the five operational calls ─────────────────────────────────────────────

  @doc """
  The five operational calls of `Nebu.Media.Storage` as `{name, fun, expect}`. `expect`: `:method`, `:bucket`
  (`:primary` | `:archive`, the bucket the request path must start with), `:key`, `:result` (what `fun` returns against
  the default stub). `put_object_copy` is called the way `MediaArchiveWorker` does: with `Storage.archive_bucket()`.
  """
  def operations do
    alias Nebu.Media.Storage

    [
      {:put, fn -> Storage.put("obj-put", "payload-bytes") end, %{method: "PUT", bucket: :primary, key: "obj-put", result: :ok}},
      {:get, fn -> Storage.get("obj-get") end, %{method: "GET", bucket: :primary, key: "obj-get", result: {:ok, "stub-object-bytes"}}},
      {:delete, fn -> Storage.delete("obj-del") end, %{method: "DELETE", bucket: :primary, key: "obj-del", result: :ok}},
      {:put_object_copy, fn -> Storage.put_object_copy("obj-copy", Storage.archive_bucket()) end,
       %{method: "PUT", bucket: :archive, key: "obj-copy", result: :ok}},
      {:get_from_archive, fn -> Storage.get_from_archive("obj-arch") end,
       %{method: "GET", bucket: :archive, key: "obj-arch", result: {:ok, "stub-object-bytes"}}}
    ]
  end

  @doc "Waits for the next request recorded by stub `tag`."
  def next_request!(tag, timeout \\ 2_000) do
    receive do
      {:s3_request, ^tag, req} -> req
    after
      timeout -> raise "stub #{inspect(tag)} received no request within #{timeout} ms"
    end
  end

  # ── upload through the real router with the REAL storage module ────────────

  @doc """
  Prepares a `POST /_matrix/media/v3/upload` through `Nebu.Web.Router` that uses the REAL `Nebu.Media.Storage` (the
  `:media_storage_module` seam stays unset); DB / state machine / scan enqueue are the usual media fakes. Returns the
  bearer token for `post_upload/2`.
  """
  def upload_setup! do
    alias Nebu.Web.MediaFakes
    alias Nebu.Web.MediaTestSupport, as: S

    priv = S.setup_oidc_keys()
    {_uid, token} = S.bearer_for("uploader", priv)

    put_env_scoped(:nebu_http, :media_db_module, MediaFakes.DB)
    put_env_scoped(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    put_env_scoped(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)
    put_env_scoped(:nebu_http, :rate_limit_disabled, true)
    token
  end

  @doc "Runs an authenticated JPEG upload through the router and returns the `Plug.Conn`."
  def post_upload(token, body \\ "\xFF\xD8\xFF\xE0jpeg-bytes") do
    alias Nebu.Web.MediaTestSupport, as: S

    conn = Plug.Test.conn(:post, "/_matrix/media/v3/upload", body) |> Map.put(:req_headers, [])

    conn =
      Enum.reduce([{"content-type", "image/jpeg"} | S.auth(token)], conn, fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  @doc """
  Prepares the async companion `PUT /_matrix/media/v3/upload/{server}/{mediaId}` (a `:reserved` row owned by the
  caller) with the REAL `Nebu.Media.Storage`. Returns `%{token, media_id}`; use `put_async_upload/2`.
  """
  def async_upload_setup! do
    alias Nebu.Web.MediaFakes
    alias Nebu.Web.MediaTestSupport, as: S

    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("uploader", priv)

    put_env_scoped(:nebu_http, :media_db_module, MediaFakes.DB)
    put_env_scoped(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    put_env_scoped(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)
    put_env_scoped(:nebu_http, :rate_limit_disabled, true)

    put_env_scoped(:nebu_http, :media_lookup_reservation_fun, fn _server, _id ->
      {:ok, %{uploader_user_id: uid, state: :reserved, uploaded_at: System.system_time(:millisecond)}}
    end)

    %{token: token, media_id: "async-target-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  @doc "Runs the async `PUT .../upload/{server}/{mediaId}` through the router and returns the `Plug.Conn`."
  def put_async_upload(%{token: token, media_id: media_id}, body \\ "async-bytes") do
    alias Nebu.Web.MediaTestSupport, as: S

    conn =
      Plug.Test.conn(:put, "/_matrix/media/v3/upload/#{S.server_name()}/#{media_id}", body)
      |> Map.put(:req_headers, [])

    conn =
      Enum.reduce([{"content-type", "application/octet-stream"} | S.auth(token)], conn, fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  @doc """
  Prepares `GET /_matrix/media/v3/download/{server}/{mediaId}` for a released, room-member-readable media row whose
  object is read by the REAL `Nebu.Media.Storage`. Returns `%{token, path, ciphertext, plaintext}` (`ciphertext` is
  what the stored object must contain for a successful download).
  """
  def download_setup!(plaintext \\ "download-plaintext-bytes") do
    alias Nebu.Web.MediaFakes
    alias Nebu.Web.MediaTestSupport, as: S

    media_id = "dl-target-" <> Integer.to_string(System.unique_integer([:positive]))
    room_id = "!room:test.local"
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)
    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(plaintext)

    row =
      S.media_row(
        media_id: media_id,
        content_type: "image/jpeg",
        file_size: byte_size(plaintext),
        aes_key_hex: key_hex,
        nonce_hex: nonce_hex,
        room_id: room_id,
        storage_key: media_id
      )

    put_env_scoped(:nebu_http, :media_db_module, MediaFakes.DB)
    put_env_scoped(:nebu_http, :media_membership_module, MediaFakes.Membership)
    put_env_scoped(:nebu_http, :rate_limit_disabled, true)

    put_env_scoped(:nebu_http, :media_lookup_fun, fn server, id ->
      if server == S.server_name() and id == media_id, do: {:ok, row}, else: {:error, :not_found}
    end)

    put_env_scoped(:nebu_http, :media_member_fun, fn room, user -> room == room_id and user == uid end)

    %{token: token, path: "/_matrix/media/v3/download/#{S.server_name()}/#{media_id}", ciphertext: ciphertext, plaintext: plaintext, media_id: media_id}
  end

  @doc "Runs the authenticated download through the router and returns the `Plug.Conn`."
  def get_download(%{token: token, path: path}) do
    alias Nebu.Web.MediaTestSupport, as: S

    conn = Plug.Test.conn(:get, path)
    conn = Enum.reduce(S.auth(token), conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # ── fake HTTP client (no network) ──────────────────────────────────────────

  defmodule RecordingClient do
    @moduledoc "ExAws HTTP client double: records the request, answers 200, performs no network I/O."

    def request(method, url, body, headers, _http_opts) do
      case Application.get_env(:nebu_test_support, :recording_pid) do
        pid when is_pid(pid) -> send(pid, {:http_request, method, url, headers, byte_size(to_string(body))})
        _ -> :ok
      end

      {:ok, %{status_code: 200, headers: [], body: reply_body(method, url, headers)}}
    end

    defp reply_body(:put, _url, headers) do
      if Enum.any?(headers, fn {k, _} -> String.downcase(k) == "x-amz-copy-source" end), do: Nebu.Media.StorageAdminTargetSupport.copy_xml(), else: ""
    end

    defp reply_body(:get, _url, _headers), do: "fake-object-bytes"
    defp reply_body(_method, _url, _headers), do: ""
  end

  @doc "Installs `RecordingClient` as the ExAws HTTP client; requests are reported to the calling test process."
  def use_recording_client! do
    put_env_scoped(:ex_aws, :http_client, RecordingClient)
    put_env_scoped(:nebu_test_support, :recording_pid, self())
  end

  @doc false
  def copy_xml do
    ~s(<?xml version="1.0" encoding="UTF-8"?><CopyObjectResult><LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>"abc"</ETag></CopyObjectResult>)
  end

  # ── real HTTP stub ─────────────────────────────────────────────────────────

  @doc """
  Starts a stub S3 endpoint on 127.0.0.1 (ephemeral port). Options: `:tag` (default `:stub`), `:owner` (default
  `self()`), `:status` (fixed status for every request, e.g. 403 / 404; default per method), `:get_body` (the bytes a
  GET answers with, default `"stub-object-bytes"`), `:error_body` (the body of a forced error status, default an
  S3-style error XML without credentials). The owner receives

    * `{:s3_accepted, tag}` — a TCP connection was accepted;
    * `{:s3_request, tag, %{method, target, headers, body_size}}` — a complete request (`headers`: lowercase name => value).

  Returns `%{pid, port, tag}`; the stub is killed when the test exits.
  """
  def start_stub(opts \\ []) do
    tag = Keyword.get(opts, :tag, :stub)
    owner = Keyword.get(opts, :owner, self())
    status = {Keyword.get(opts, :status), Keyword.get(opts, :get_body), Keyword.get(opts, :error_body)}
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
        {:ok, {_, port}} = :inet.sockname(listen)
        send(parent, {ref, port})
        accept_loop(listen, tag, owner, status)
      end)

    port =
      receive do
        {^ref, port} -> port
      after
        5_000 -> raise "stub did not start"
      end

    on_exit(fn -> Process.exit(pid, :kill) end)
    %{pid: pid, port: port, tag: tag}
  end

  @doc "A 127.0.0.1 port nothing listens on (connection refused)."
  def closed_port do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(l)
    :gen_tcp.close(l)
    port
  end

  @doc "`\"127.0.0.1:PORT\"` for a stub."
  def endpoint(%{port: port}), do: "127.0.0.1:#{port}"

  @doc "`{access_key_id, region}` from the SigV4 `Authorization` header of a recorded stub request, or `nil`."
  def credential_scope(%{headers: headers}) do
    with auth when is_binary(auth) <- Map.get(headers, "authorization"),
         [_, scope] <- Regex.run(~r/Credential=([^,\s]+)/, auth),
         [akid, _date, region, _service, _term] <- String.split(scope, "/") do
      {akid, region}
    else
      _ -> nil
    end
  end

  defp accept_loop(listen, tag, owner, status) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        send(owner, {:s3_accepted, tag})
        handler = spawn(fn -> handle(sock, tag, owner, status) end)
        :gen_tcp.controlling_process(sock, handler)
        accept_loop(listen, tag, owner, status)

      {:error, _} ->
        :ok
    end
  end

  defp handle(sock, tag, owner, status) do
    with {:ok, head, rest} <- read_head(sock, ""),
         [request_line | header_lines] <- String.split(head, "\r\n"),
         [method, target | _] <- String.split(request_line, " ") do
      headers =
        for line <- header_lines, [k, v] <- [String.split(line, ":", parts: 2)], into: %{} do
          {String.downcase(String.trim(k)), String.trim(v)}
        end

      if headers["expect"] == "100-continue", do: :gen_tcp.send(sock, "HTTP/1.1 100 Continue\r\n\r\n")
      body_size = read_body(sock, headers, rest)

      send(owner, {:s3_request, tag, %{method: method, target: target, headers: headers, body_size: body_size}})
      :gen_tcp.send(sock, response(method, headers, status))
    end

    :gen_tcp.close(sock)
  end

  defp read_head(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      _ ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} -> read_head(sock, acc <> data)
          _ -> :closed
        end
    end
  end

  defp read_body(sock, headers, rest) do
    cond do
      headers["transfer-encoding"] == "chunked" -> read_chunked(sock, rest)
      true -> read_n(sock, String.to_integer(Map.get(headers, "content-length", "0")), rest)
    end
  end

  defp read_n(_sock, n, acc) when byte_size(acc) >= n, do: byte_size(acc)

  defp read_n(sock, n, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> read_n(sock, n, acc <> data)
      _ -> byte_size(acc)
    end
  end

  defp read_chunked(sock, acc) do
    if String.ends_with?(acc, "0\r\n\r\n") do
      byte_size(acc)
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> read_chunked(sock, acc <> data)
        _ -> byte_size(acc)
      end
    end
  end

  defp response(method, headers, {forced_status, get_body, error_body}) do
    {code, extra, body} =
      case {forced_status, method} do
        {403, _} -> {403, [], error_body || ~s(<?xml version="1.0"?><Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>)}
        {404, _} -> {404, [], error_body || ~s(<?xml version="1.0"?><Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>)}
        {s, _} when is_integer(s) -> {s, [], error_body || ""}
        {nil, "GET"} -> {200, [{"content-type", "application/octet-stream"}], get_body || "stub-object-bytes"}
        {nil, "DELETE"} -> {204, [], ""}
        {nil, "PUT"} -> if Map.has_key?(headers, "x-amz-copy-source"), do: {200, [{"content-type", "application/xml"}], copy_xml()}, else: {200, [{"etag", ~s("stub")}], ""}
        {nil, _} -> {200, [], ""}
      end

    reason = %{200 => "OK", 204 => "No Content", 403 => "Forbidden", 404 => "Not Found", 500 => "Internal Server Error"} |> Map.get(code, "Status")

    lines =
      ["HTTP/1.1 #{code} #{reason}", "content-length: #{byte_size(body)}", "connection: close"] ++
        Enum.map(extra, fn {k, v} -> "#{k}: #{v}" end)

    Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body
  end
end
