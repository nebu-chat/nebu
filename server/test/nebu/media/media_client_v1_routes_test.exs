defmodule Nebu.Web.MediaClientV1RoutesTest do
  @moduledoc """
  RED-phase ATDD tests for `bugfix-fix-matrix-client-v1-media-routes` —
  AC1-AC7.

  Element Web (spec v1.11+ aware) does not call the deprecated
  `/_matrix/media/v3/download|thumbnail` endpoints for authenticated media —
  it calls `/_matrix/client/v1/media/download` and
  `/_matrix/client/v1/media/thumbnail`. Nebu currently has NO route registered
  for the `/_matrix/client/v1/media/*` prefix at all: `router.ex` forwards
  only `/_matrix/media` (v3) to `Nebu.Web.Router.Media`, and the generic
  `/_matrix` catch-all forwards everything else (including
  `/_matrix/client/v1/media/...`) to `Nebu.Web.Router.Protected`, which has no
  matching route and falls through to its own `match _` 404.

  ## Why this MUST FAIL now

  Every request below to `/_matrix/client/v1/media/...` currently 404s (via
  `Nebu.Web.Router.Protected`'s catch-all, NOT the JSON `M_NOT_FOUND` envelope
  that `Nebu.Web.Router.Media`'s `match _` produces) — so status/body/header
  assertions all fail until the routing fix (new `get "/v1/..."` routes in
  `media.ex` and/or a new forward in `router.ex`) lands. No implementation
  code is touched by this file.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import Bitwise

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @download_plaintext "the-quick-brown-fox-jumps-over-the-lazy-dog-image-bytes"
  @download_media_id "v1dlmedia"
  @png_magic <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @thumb_plaintext @png_magic <> :binary.copy(<<0>>, 64)
  @thumb_media_id "v1thumbmedia"
  @room_id "!room:test.local"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)

    {dl_ciphertext, dl_key_hex, dl_nonce_hex} = S.encrypt_like_go(@download_plaintext)
    {thumb_ciphertext, thumb_key_hex, thumb_nonce_hex} = S.encrypt_like_go(@thumb_plaintext)

    dl_row =
      S.media_row(
        media_id: @download_media_id,
        content_type: "image/jpeg",
        file_size: byte_size(@download_plaintext),
        aes_key_hex: dl_key_hex,
        nonce_hex: dl_nonce_hex,
        room_id: @room_id,
        storage_key: @download_media_id
      )

    thumb_row =
      S.media_row(
        media_id: @thumb_media_id,
        content_type: "image/png",
        file_size: byte_size(@thumb_plaintext),
        aes_key_hex: thumb_key_hex,
        nonce_hex: thumb_nonce_hex,
        room_id: @room_id,
        storage_key: @thumb_media_id
      )

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

    Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
      cond do
        server == S.server_name() and id == @download_media_id -> {:ok, dl_row}
        server == S.server_name() and id == @thumb_media_id -> {:ok, thumb_row}
        true -> {:error, :not_found}
      end
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn key ->
      case key do
        @download_media_id -> {:ok, dl_ciphertext}
        @thumb_media_id -> {:ok, thumb_ciphertext}
        _ -> {:error, :not_found}
      end
    end)

    # kai is a member of the room → allowed for all fixtures above.
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

    {:ok, token: token, user_id: uid, priv_jwk: priv}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp get(path, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp v1_download_path, do: "/_matrix/client/v1/media/download/#{S.server_name()}/#{@download_media_id}"
  defp v1_thumbnail_path, do: "/_matrix/client/v1/media/thumbnail/#{S.server_name()}/#{@thumb_media_id}"

  defp v3_download_path, do: "/_matrix/media/v3/download/#{S.server_name()}/#{@download_media_id}"
  defp v3_thumbnail_path, do: "/_matrix/media/v3/thumbnail/#{S.server_name()}/#{@thumb_media_id}"

  # A structurally-valid JWS with a corrupted signature segment — same
  # technique as oidc_plug_test.exs's `corrupt_signature/1` — so `call_jwt`
  # rejects it with M_UNKNOWN_TOKEN without touching any DB/session store
  # (the token contains a "." so it never falls into the opaque-token path).
  defp invalid_token(token) do
    [header, payload, sig_b64] = String.split(token, ".", parts: 3)

    sig = Base.url_decode64!(sig_b64, padding: false)
    <<first, rest::binary>> = sig
    flipped = <<bxor(first, 0x01), rest::binary>>
    tampered_sig = Base.url_encode64(flipped, padding: false)

    Enum.join([header, payload, tampered_sig], ".")
  end

  # ── AC1 — authenticated v1 download (no filename) → 200 + decrypted bytes ──

  test "AC1: GET /_matrix/client/v1/media/download/:server_name/:media_id → 200 with decrypted bytes",
       %{token: token} do
    conn = get(v1_download_path(), S.auth(token))

    assert conn.status == 200,
           "v1 download must reach Nebu.Media.download/2 and return 200, got #{conn.status}"

    assert conn.resp_body == @download_plaintext,
           "v1 download must serve the AES-256-GCM-decrypted original bytes, same as v3"
  end

  # ── AC2 — authenticated v1 download, filename variant ──────────────────────

  test "AC2: GET /_matrix/client/v1/media/download/:server_name/:media_id/:file_name → 200 with Content-Disposition filename",
       %{token: token} do
    conn = get(v1_download_path() <> "/cat.jpg", S.auth(token))

    assert conn.status == 200,
           "v1 download/{fileName} must reach Nebu.Media.download/3 and return 200, got #{conn.status}"

    assert conn.resp_body == @download_plaintext

    cd = S.header(conn, "content-disposition")

    assert cd != "",
           "Content-Disposition must be present on the v1 download/{fileName} response"

    assert String.contains?(cd, "cat.jpg"),
           "the URL-provided file_name must appear in Content-Disposition, got #{inspect(cd)}"
  end

  # ── AC3 — authenticated v1 thumbnail → 200 with image bytes ─────────────────

  test "AC3: GET /_matrix/client/v1/media/thumbnail/:server_name/:media_id → 200 with image bytes",
       %{token: token} do
    conn = get(v1_thumbnail_path() <> "?width=800&height=600&method=scale&allow_redirect=true", S.auth(token))

    assert conn.status == 200,
           "v1 thumbnail must reach Nebu.Media.thumbnail/3 and return 200, got #{conn.status}"

    ct = S.header(conn, "content-type")
    assert String.starts_with?(ct, "image/"), "v1 thumbnail Content-Type must be image/*, got #{inspect(ct)}"

    assert byte_size(conn.resp_body) > 0, "v1 thumbnail response must carry image bytes"
  end

  # ── AC4 — 401 M_MISSING_TOKEN without a token, all three routes ────────────

  describe "AC4: missing Authorization header → 401 M_MISSING_TOKEN" do
    test "v1 download (no filename)" do
      conn = get(v1_download_path())

      assert conn.status == 401
      assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "v1 download (with filename)" do
      conn = get(v1_download_path() <> "/cat.jpg")

      assert conn.status == 401
      assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "v1 thumbnail" do
      conn = get(v1_thumbnail_path())

      assert conn.status == 401
      assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  # ── AC5 — 401 M_UNKNOWN_TOKEN with an invalid/tampered token, all three ────

  describe "AC5: invalid/tampered Bearer token → 401 M_UNKNOWN_TOKEN" do
    test "v1 download (no filename)", %{token: token} do
      conn = get(v1_download_path(), S.auth(invalid_token(token)))

      assert conn.status == 401
      assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "v1 download (with filename)", %{token: token} do
      conn = get(v1_download_path() <> "/cat.jpg", S.auth(invalid_token(token)))

      assert conn.status == 401
      assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "v1 thumbnail", %{token: token} do
      conn = get(v1_thumbnail_path(), S.auth(invalid_token(token)))

      assert conn.status == 401
      assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  # ── AC7 — CSP/CORP headers present on the v1 routes ─────────────────────────

  test "AC7: v1 download response carries content-security-policy and cross-origin-resource-policy",
       %{token: token} do
    conn = get(v1_download_path(), S.auth(token))

    assert conn.status == 200

    csp = S.header(conn, "content-security-policy")
    assert csp != "", "v1 download MUST set Content-Security-Policy, same as v3 download"

    assert S.header(conn, "cross-origin-resource-policy") == "cross-origin"
  end

  test "AC7: v1 thumbnail response carries content-security-policy and cross-origin-resource-policy",
       %{token: token} do
    conn = get(v1_thumbnail_path(), S.auth(token))

    assert conn.status == 200

    csp = S.header(conn, "content-security-policy")
    assert csp != "", "v1 thumbnail MUST set Content-Security-Policy, same as v3 thumbnail"

    assert S.header(conn, "cross-origin-resource-policy") == "cross-origin"
  end

  # ── AC6 — regression guard: existing v3 routes are unaffected ──────────────
  #
  # The dedicated v3 test files (media_download_test.exs, media_thumbnail_test.exs,
  # media_access_control_test.exs, media_range_request_test.exs) already cover the
  # v3 behavior in depth. These two smoke assertions just confirm — from THIS
  # story's fixtures — that adding the v1 routes does not disturb the v3 ones.

  test "AC6 smoke: v3 download route still works unmodified", %{token: token} do
    conn = get(v3_download_path(), S.auth(token))

    assert conn.status == 200
    assert conn.resp_body == @download_plaintext
  end

  test "AC6 smoke: v3 thumbnail route still works unmodified", %{token: token} do
    conn = get(v3_thumbnail_path(), S.auth(token))

    assert conn.status == 200
    ct = S.header(conn, "content-type")
    assert String.starts_with?(ct, "image/")
  end
end
