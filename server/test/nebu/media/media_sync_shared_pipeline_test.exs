defmodule Nebu.Web.MediaSyncSharedPipelineTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/2c-sync-upload-
  shared-pipeline` — AC1/AC2.

  `PUT /_matrix/media/v3/upload` (the classic one-shot sync upload,
  `Nebu.Media.upload/1` -> `store_upload/4`) currently has its OWN hand-rolled
  storage code path: inline `Nebu.Media.Crypto.encrypt/3` (no gzip) + direct
  `storage_module().put/2` + a bespoke `Nebu.Media.DB.insert/1` SQL call —
  entirely independent of the shared hash -> gzip -> AES-256-GCM ->
  `Nebu.Media.Storage.put/2` pipeline story 2b's async PUT handler
  (`Nebu.Media.upload_async/3` -> `validate_and_store_async/4` ->
  `store_and_quarantine/7`, same `server/lib/nebu/media.ex` file) already
  uses, and independent of `Nebu.Media.StateMachine` (Story 1b) entirely.

  ## Why these tests currently FAIL (valid RED)

    * AC2 (shared pipeline): today's sync path does NOT gzip the body before
      encrypting — the async path DOES (Story 12, `Nebu.Media.Storage.compress/1`,
      wired by 2b). For an identical, highly-compressible input body, the
      bytes handed to the storage boundary therefore differ in length between
      the two paths today (sync: `byte_size(body) + 16` GCM-tag bytes, no
      compression; async: the SMALLER gzip-then-encrypt length). The
      "same-length ciphertext for the same input" assertion below fails until
      `store_upload/4` is rewired to call the same shared pipeline function.
    * AC1 (row creation via `Nebu.Media.StateMachine`, never a raw
      `Nebu.Media.DB.insert/1`): today's `store_upload/4` still calls
      `insert_media_row/7` -> `Nebu.Media.DB.insert/1` (guarded by
      `function_exported?/3`, which now returns `true` because this story's
      ATDD pass added a real `insert/1` stub to `Nebu.Web.MediaFakes.DB` —
      see that module's moduledoc). The "insert/1 never called" assertion
      below fails today because it IS still called.

  Both failure modes are genuine RED signals for AC1/AC2 — no implementation
  code for the refactor exists yet.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @sync_path "/_matrix/media/v3/upload"
  @create_path "/_matrix/media/v1/create"
  @async_base_path "/_matrix/media/v3/upload"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("uploader", priv)

    test_pid = self()

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)
    Application.put_env(:nebu_http, :media_permission_module, MediaFakes.Permission)

    Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
      send(test_pid, {:stored, key, bytes})
      :ok
    end)

    Application.put_env(:nebu_http, :media_persist_upload_fun, fn fields ->
      send(test_pid, {:persisted, fields})
      :ok
    end)

    Application.put_env(:nebu_http, :media_db_insert_fun, fn row ->
      send(test_pid, {:db_insert_called, row})
      :ok
    end)

    Application.put_env(:nebu_http, :media_state_machine_create_quarantined_fun, fn attrs ->
      send(test_pid, {:create_quarantined_called, attrs})
      {:ok, Map.fetch!(attrs, :media_id)}
    end)

    Application.put_env(:nebu_http, :media_state_machine_create_fun, fn attrs ->
      send(test_pid, {:state_machine_create_called, attrs})
      {:ok, Map.fetch!(attrs, :media_id)}
    end)

    Application.put_env(:nebu_http, :media_state_machine_transition_fun, fn media_id,
                                                                            to_state,
                                                                            actor,
                                                                            metadata ->
      send(test_pid, {:transition_called, media_id, to_state, actor, metadata})
      {:ok, to_state}
    end)

    Application.put_env(:nebu_http, :media_scan_enqueue_fun, fn media_id ->
      send(test_pid, {:scan_enqueued, media_id})
      :ok
    end)

    Application.put_env(:nebu_http, :media_permission_fun, fn _user -> true end)
    Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 0 end)

    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_scan_enqueue_module)
      Application.delete_env(:nebu_http, :media_permission_module)
      Application.delete_env(:nebu_http, :media_storage_put_fun)
      Application.delete_env(:nebu_http, :media_persist_upload_fun)
      Application.delete_env(:nebu_http, :media_db_insert_fun)
      Application.delete_env(:nebu_http, :media_state_machine_create_quarantined_fun)
      Application.delete_env(:nebu_http, :media_state_machine_create_fun)
      Application.delete_env(:nebu_http, :media_state_machine_transition_fun)
      Application.delete_env(:nebu_http, :media_scan_enqueue_fun)
      Application.delete_env(:nebu_http, :media_permission_fun)
      Application.delete_env(:nebu_http, :media_pending_count_fun)
      Application.delete_env(:nebu_http, :media_max_upload_bytes)
      Application.delete_env(:nebu_http, :media_lookup_reservation_fun)
      Application.delete_env(:nebu_http, :media_storage_config_source)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid}
  end

  defp put_sync(body, headers) do
    conn =
      conn(:post, @sync_path, body)
      |> Map.put(:req_headers, [])

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp post_create(headers) do
    conn =
      conn(:post, @create_path)
      |> Map.put(:req_headers, [])

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp put_async(media_id, body, headers) do
    conn =
      conn(:put, "#{@async_base_path}/#{S.server_name()}/#{media_id}", body)
      |> Map.put(:req_headers, [])

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp seed_reservation(uploader_user_id) do
    Application.put_env(:nebu_http, :media_lookup_reservation_fun, fn _server_name, _media_id ->
      {:ok,
       %{
         uploader_user_id: uploader_user_id,
         state: :reserved,
         uploaded_at: System.system_time(:millisecond)
       }}
    end)
  end

  defp media_id_from_uri(uri, server_name) do
    String.replace_prefix(uri, "mxc://#{server_name}/", "")
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 — shared storage-pipeline function is actually shared
  # ══════════════════════════════════════════════════════════════════════

  test "sync upload and async PUT both invoke Nebu.Media.Storage's put/2 with a " <>
         "Gzip+AES-256-GCM payload of equivalent (same-length) transformation",
       %{token: token, user_id: uid} do
    # Highly compressible body (mirrors 2b's own compression ATDD test) —
    # proves gzip genuinely ran, not merely a pass-through no-op.
    original_body = String.duplicate("A", 8000)

    # ── sync flow ──
    conn_sync =
      put_sync(original_body, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn_sync.status == 200,
           "sync upload must succeed, got #{conn_sync.status} (#{inspect(S.json(conn_sync))})"

    sync_uri = S.json(conn_sync)["content_uri"]
    sync_media_id = media_id_from_uri(sync_uri, S.server_name())

    assert_received {:stored, sync_key, sync_ciphertext}

    assert sync_key == sync_media_id,
           "sync upload's storage_key must be computed via the same Story 11c " <>
             "key-template shape as the async path (default template " <>
             "\"{media_id}\"), got #{inspect(sync_key)}"

    assert byte_size(sync_ciphertext) < byte_size(original_body),
           "sync upload must apply the SAME gzip-before-encrypt pipeline the " <>
             "async PUT handler already uses — an 8000-byte run of a single " <>
             "repeated character MUST compress smaller via gzip, but the " <>
             "stored (encrypted) bytes were NOT smaller than the original " <>
             "(#{byte_size(sync_ciphertext)} >= #{byte_size(original_body)}), " <>
             "meaning store_upload/4 is still using its own uncompressed inline " <>
             "Crypto.encrypt/3 path instead of the shared pipeline function"

    # ── async flow (create + PUT), same input bytes ──
    conn_create = post_create(S.auth(token))
    assert conn_create.status == 200
    async_uri = S.json(conn_create)["content_uri"]
    async_media_id = media_id_from_uri(async_uri, S.server_name())

    assert_received {:state_machine_create_called, %{media_id: ^async_media_id}}

    seed_reservation(uid)

    conn_async =
      put_async(async_media_id, original_body, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn_async.status == 200,
           "async PUT must succeed, got #{conn_async.status} (#{inspect(S.json(conn_async))})"

    assert_received {:stored, async_key, async_ciphertext}
    assert async_key == async_media_id

    assert byte_size(async_ciphertext) < byte_size(original_body),
           "sanity check: the async path (already landed, 2b) must itself compress"

    # The crux of AC2: for the SAME input bytes, the SAME compression
    # algorithm (gzip) run through the SAME AES-256-GCM scheme (no padding,
    # fixed 16-byte tag) must produce the SAME stored-byte LENGTH regardless
    # of which HTTP entry point received the bytes — random per-call
    # key/nonce material means the ciphertext CONTENTS legitimately differ,
    # but the SHAPE (compressed-length + 16-byte tag) must not.
    assert byte_size(sync_ciphertext) == byte_size(async_ciphertext),
           "sync and async uploads of byte-identical input must produce " <>
             "equal-length stored ciphertext (same gzip + same AES-256-GCM " <>
             "framing) — got sync=#{byte_size(sync_ciphertext)} bytes, " <>
             "async=#{byte_size(async_ciphertext)} bytes. A mismatch means " <>
             "the two HTTP entry points are still running two DIFFERENT " <>
             "storage-pipeline implementations, contradicting AC2's " <>
             "'no second implementation of this sequence anywhere in " <>
             "Nebu.Media' requirement"
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 — row creation exclusively through Nebu.Media.StateMachine, never a
  # direct Nebu.Media.DB.insert/1 call
  # ══════════════════════════════════════════════════════════════════════

  test "sync upload does not call Nebu.Media.DB.insert/1 directly — only " <>
         "Nebu.Media.StateMachine's row-creation seam is invoked",
       %{token: token} do
    conn =
      put_sync("some upload bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 200,
           "sync upload must succeed, got #{conn.status} (#{inspect(S.json(conn))})"

    refute_received {:db_insert_called, _row},
                    "store_upload/4 must no longer call Nebu.Media.DB.insert/1 (or the " <>
                      "injected :media_db_module's insert/1) directly — row creation must " <>
                      "go exclusively through Nebu.Media.StateMachine (AC1). A future " <>
                      "regression reintroducing insert_media_row/7's direct SQL insert " <>
                      "would make this assertion fail again."

    assert_received {:create_quarantined_called, attrs},
                    "sync upload must create its media_files row via " <>
                      "Nebu.Media.StateMachine.create_quarantined/1 (the single-step " <>
                      "genesis-into-:quarantined seam), not a raw DB insert"

    assert attrs.media_id != nil
  end
end
