defmodule Nebu.Web.MediaAccessControlTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC4 (access control).

  Story-declared test: non-member download → 403 M_FORBIDDEN.

    * A non-member of the media's room → 403
      `%{"errcode" => "M_FORBIDDEN", "error" => "You are not a member of this room"}`.
      This 403 is a deliberate Nebu EXTENSION (not a Matrix MUST) — the membership
      check is a LOCAL OTP call (`member?/2`) replacing the former gRPC
      CheckMembership. Keep it.
    * Unauthenticated download → 401 (OidcPlug), never reaching the media handler.

  ## Why this MUST FAIL now

  No media download route exists, so a download by a non-member falls through to
  the top-level `match _` → 404 plain text. The 403 / M_FORBIDDEN envelope and
  the 401 gate are not produced until `Nebu.Media` is implemented and the
  membership boundary is wired.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @plaintext "secret-room-attachment"
  @media_id "guarded123"
  @room_id "!private:test.local"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("mallory", priv)

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

    # mallory is NOT a member of @room_id → membership boundary returns false.
    Application.put_env(:nebu_http, :media_member_fun, fn _room, _user -> false end)

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

  defp download_path, do: "/_matrix/media/v3/download/#{S.server_name()}/#{@media_id}"

  # ── AC4 — non-member → 403 M_FORBIDDEN (Nebu extension) ────────────────────

  test "non-member room download → 403 M_FORBIDDEN with the exact Nebu message", %{token: token} do
    conn =
      conn(:get, download_path())
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Router.call(S.router_opts())

    assert conn.status == 403,
           "a non-member download must be rejected with 403, got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_FORBIDDEN"
    assert body["error"] == "You are not a member of this room"

    # And the bytes must NOT leak.
    refute conn.resp_body == @plaintext
  end

  # ── F4 — production room_id: nil path, zero-room user → 403 (fail-closed) ──
  #
  # Production rows carry `room_id: nil` (media_files has no room_id), so the
  # handler calls `member?(nil, user)` which is "member of ANY room". A user in
  # NO rooms must be DENIED (403 M_FORBIDDEN) — the fail-closed zero-room path.

  test "production nil-room media + user who is a member of NO rooms → 403 M_FORBIDDEN", %{
    token: token
  } do
    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    # Production-shaped row: room_id is nil (media_files has no room_id column).
    prod_row =
      S.media_row(
        media_id: @media_id,
        content_type: "image/png",
        file_size: byte_size(@plaintext),
        aes_key_hex: key_hex,
        nonce_hex: nonce_hex,
        room_id: nil,
        storage_key: @media_id
      )

    Application.put_env(:nebu_http, :media_lookup_fun, fn _s, id ->
      if id == @media_id, do: {:ok, prod_row}, else: {:error, :not_found}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn _k -> {:ok, ciphertext} end)

    # Mirror production member?(nil, user): a user in zero rooms → false (deny).
    Application.put_env(:nebu_http, :media_member_fun, fn room_id, _user ->
      assert room_id == nil, "production must call member?/2 with a nil room_id"
      false
    end)

    conn =
      conn(:get, download_path())
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Router.call(S.router_opts())

    assert conn.status == 403,
           "a zero-room user must be denied even on the nil-room production path, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_FORBIDDEN"
    refute conn.resp_body == @plaintext
  end

  # ── unauthenticated → 401 (OidcPlug gate, handler never runs) ──────────────

  test "unauthenticated download → 401 M_MISSING_TOKEN" do
    conn =
      conn(:get, download_path())
      |> Nebu.Web.Router.call(S.router_opts())

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
  end
end
