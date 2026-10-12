defmodule Nebu.Web.MediaDownloadTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC2 (download) plus the
  oracle MUSTs that ride on download responses.

  GET /_matrix/media/v3/download/{serverName}/{mediaId}[/{fileName}]:
    * a room member receives the ORIGINAL bytes — the stored blob is AES-256-GCM
      encrypted at rest (ADR-011) and decrypted in memory before serving. The
      membership check is a LOCAL OTP call (no gRPC).
    * Content-Disposition MUST be present (v1.12 MUST, oracle §1). Safe inline
      allowlist (image/jpeg here) → `inline`.
    * Content-Type MUST match the stored type (oracle §2) + X-Content-Type-Options:
      nosniff.
    * unknown media id → 404 M_NOT_FOUND (oracle §6).
    * the `/{fileName}` variant serves the same bytes and reflects the filename in
      Content-Disposition.

  ## Why this MUST FAIL now

  No media download route exists; GET falls through to the top-level `match _`
  → 404 plain text "not found" (no JSON envelope, no media handling), so the
  byte-equality, header, and errcode assertions all fail until `Nebu.Media`
  is implemented.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @plaintext "the-quick-brown-fox-jumps-over-the-lazy-dog-image-bytes"
  @media_id "abc123media"
  @room_id "!room:test.local"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)

    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    row =
      S.media_row(
        media_id: @media_id,
        content_type: "image/jpeg",
        file_size: byte_size(@plaintext),
        aes_key_hex: key_hex,
        nonce_hex: nonce_hex,
        room_id: @room_id,
        storage_key: @media_id
      )

    # Inject boundaries: metadata lookup, storage (serves ciphertext), membership.
    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

    Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
      if server == S.server_name() and id == @media_id, do: {:ok, row}, else: {:error, :not_found}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn key ->
      if key == @media_id, do: {:ok, ciphertext}, else: {:error, :not_found}
    end)

    # kai is a member of the room → allowed.
    Application.put_env(:nebu_http, :media_member_fun, fn room, user ->
      room == @room_id and user == uid
    end)

    on_exit(fn ->
      for k <- [
            :media_db_module,
            :media_storage_module,
            :media_membership_module,
            :media_lookup_fun,
            :media_storage_get_fun,
            :media_member_fun
          ],
          do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, token: token, user_id: uid}
  end

  defp get(path, headers) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp download_path, do: "/_matrix/media/v3/download/#{S.server_name()}/#{@media_id}"

  # ── AC2 — member download returns decrypted original bytes ─────────────────

  test "room member GET download → 200 with the original (decrypted) bytes", %{token: token} do
    conn = get(download_path(), S.auth(token))

    assert conn.status == 200,
           "member download must return 200, got #{conn.status} — media download route not implemented"

    assert conn.resp_body == @plaintext,
           "download must serve the AES-256-GCM-decrypted original bytes (ADR-011)"
  end

  # ── oracle §1/§2 — Content-Disposition + Content-Type + nosniff ────────────

  test "download response carries Content-Disposition (inline for image/jpeg)", %{token: token} do
    conn = get(download_path(), S.auth(token))

    cd = S.header(conn, "content-disposition")

    assert cd != "",
           "Content-Disposition MUST be present on download (Matrix v1.12 MUST, oracle §1)"

    # image/jpeg is on the safe inline allowlist.
    assert String.starts_with?(cd, "inline"),
           "image/jpeg is on the inline allowlist; got Content-Disposition: #{inspect(cd)}"

    # AC4: this upload has no filename -> the `filename` parameter must be
    # excluded (spec MUST); the old behavior leaked the media_id as filename.
    refute String.contains?(cd, @media_id),
           "media_id must never be used as the filename, got #{inspect(cd)}"
    refute String.contains?(cd, "filename"), "no filename known -> no filename parameter, got #{inspect(cd)}"
  end

  test "download response Content-Type matches stored type and carries nosniff", %{token: token} do
    conn = get(download_path(), S.auth(token))

    ct = S.header(conn, "content-type")
    # media-download-content-type-and-filename (AC1): the stored type is served
    # EXACTLY (spec v1.12 MUST) — previously `contains?` tolerated the
    # `; charset=utf-8` Plug appended to every type, which the spec forbids for
    # non-text types. Goes red until put_resp_content_type(ct, nil) lands.
    assert ct == "image/jpeg", "Content-Type must be exactly the stored type, got #{inspect(ct)}"

    assert S.header(conn, "x-content-type-options") == "nosniff"
  end

  # ── /{fileName} variant ────────────────────────────────────────────────────

  test "download/{...}/{fileName} variant serves same bytes and reflects filename", %{token: token} do
    conn = get(download_path() <> "/cat.jpg", S.auth(token))

    assert conn.status == 200
    assert conn.resp_body == @plaintext

    cd = S.header(conn, "content-disposition")
    assert cd != ""
    assert String.contains?(cd, "cat.jpg"),
           "the requested fileName must appear in Content-Disposition, got #{inspect(cd)}"
  end

  # ── oracle §6 — unknown media → 404 M_NOT_FOUND ────────────────────────────

  test "unknown media id → 404 M_NOT_FOUND", %{token: token} do
    conn =
      get("/_matrix/media/v3/download/#{S.server_name()}/does-not-exist", S.auth(token))

    assert conn.status == 404
    assert S.json(conn)["errcode"] == "M_NOT_FOUND"
  end
end
