defmodule Nebu.Web.MediaThumbnailTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC7 (thumbnail).

  GET /_matrix/media/v3/thumbnail/{serverName}/{mediaId}?width=&height=&method=:
    * returns a thumbnail image to a room member (Image hex lib resize, or — for
      a small original — streams the original). For this red test we assert the
      RESPONSE CONTRACT (200, image bytes, Content-Type image/*) rather than exact
      pixel dimensions, which depend on the chosen Image library.
    * Content-Disposition MUST be present (oracle §1, same as download) and is
      `inline` for the image allowlist.
    * X-Content-Type-Options: nosniff.
    * a non-member is rejected (403 M_FORBIDDEN — same Nebu extension as download).

  ## Why this MUST FAIL now

  No thumbnail route exists; the request falls through to `match _` → 404 plain
  text. The 200 + image Content-Type + Content-Disposition contract is not
  produced until `Nebu.Media` implements the thumbnail endpoint.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  # A minimal valid-ish PNG header + payload. The dev's Image lib must accept
  # real image bytes; this fixture is a stand-in stored encrypted. The contract
  # assertions (status/headers) do not depend on the decode succeeding for a
  # tiny image — AC7 permits streaming the original when it is small.
  @png_magic <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @plaintext @png_magic <> :binary.copy(<<0>>, 64)
  @media_id "thumbmedia"
  @room_id "!room:test.local"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)

    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    row =
      S.media_row(
        media_id: @media_id,
        content_type: "image/png",
        file_size: byte_size(@plaintext),
        aes_key_hex: key_hex,
        nonce_hex: nonce_hex,
        room_id: @room_id,
        storage_key: @media_id
      )

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)
    Application.put_env(:nebu_http, :media_lookup_fun, fn _s, id -> if id == @media_id, do: {:ok, row}, else: {:error, :not_found} end)
    Application.put_env(:nebu_http, :media_storage_get_fun, fn _k -> {:ok, ciphertext} end)
    Application.put_env(:nebu_http, :media_member_fun, fn _r, _u -> true end)

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

  defp thumbnail(query, token) do
    conn(:get, "/_matrix/media/v3/thumbnail/#{S.server_name()}/#{@media_id}?" <> query)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(S.router_opts())
  end

  # ── AC7 — thumbnail returned ───────────────────────────────────────────────

  test "member GET thumbnail → 200 with an image Content-Type and bytes", %{token: token} do
    conn = thumbnail("width=64&height=64&method=scale", token)

    assert conn.status == 200,
           "thumbnail must return 200, got #{conn.status} — thumbnail route not implemented"

    ct = S.header(conn, "content-type")
    # media-download-content-type-and-filename (AC5): exactly the stored thumbnail
    # type, no appended `; charset=utf-8` (was `starts_with?("image/")`).
    assert ct == "image/png", "thumbnail Content-Type must be exactly image/png, got #{inspect(ct)}"

    assert byte_size(conn.resp_body) > 0, "thumbnail response must carry image bytes"
  end

  test "thumbnail response carries Content-Disposition (inline) and nosniff", %{token: token} do
    conn = thumbnail("width=64&height=64&method=crop", token)

    cd = S.header(conn, "content-disposition")
    assert cd != "", "Content-Disposition MUST be present on thumbnail (oracle §1)"
    assert String.starts_with?(cd, "inline")

    # AC5: thumbnails SHOULD carry a filename (e.g. thumbnail.png), never the media_id.
    assert String.contains?(cd, ~s(filename="thumbnail.png")), "got #{inspect(cd)}"
    refute String.contains?(cd, @media_id)

    assert S.header(conn, "x-content-type-options") == "nosniff"
  end

  # ── F-4 (MEDIUM) — thumbnail serves with CSP/sandbox + CORP (parity w/ download) ─
  #
  # serve_inline_image/4 (thumbnail) must set the SAME CSP sandbox header and
  # cross-origin-resource-policy that serve_bytes/4 (download) sets, so inline
  # decrypted bytes get a consistent content-serving posture (defense in depth).

  test "thumbnail response carries the CSP sandbox + CORP headers", %{token: token} do
    conn = thumbnail("width=64&height=64&method=scale", token)

    csp = S.header(conn, "content-security-policy")
    assert csp != "", "thumbnail MUST set Content-Security-Policy (F-4 parity with download)"
    assert String.contains?(csp, "sandbox")
    assert String.contains?(csp, "default-src 'none'")

    assert S.header(conn, "cross-origin-resource-policy") == "cross-origin"
  end

  # ── access control parity with download ────────────────────────────────────

  test "non-member thumbnail → 403 M_FORBIDDEN", %{token: token} do
    Application.put_env(:nebu_http, :media_member_fun, fn _r, _u -> false end)

    conn = thumbnail("width=64&height=64", token)

    assert conn.status == 403
    assert S.json(conn)["errcode"] == "M_FORBIDDEN"
  end
end
