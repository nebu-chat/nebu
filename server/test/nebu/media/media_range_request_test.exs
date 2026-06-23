defmodule Nebu.Web.MediaRangeRequestTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC3 (Range requests).

  Story-declared test: Range bytes=0-99 → 206, 100 bytes, Content-Range header.

  Oracle §4:
    * `Range: bytes=<start>-<end>` → 206 Partial Content with
      `Content-Range: bytes <start>-<end>/<total>` and `Accept-Ranges: bytes`.
    * unsatisfiable range → 416 Range Not Satisfiable.

  Range is served from the DECRYPTED in-memory bytes (full streaming is
  constrained by GCM; serving from decrypted bytes is acceptable per AC2).

  ## Why this MUST FAIL now

  No media download route exists, so a ranged GET falls through to the
  top-level `match _` → 404 (200/206/416 expectations all fail).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  # 256 distinct bytes so byte ranges are easy to verify.
  @plaintext for(b <- 0..255, into: <<>>, do: <<b>>)
  @total byte_size(@plaintext)
  @media_id "rangemedia"
  @room_id "!room:test.local"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)

    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    row =
      S.media_row(
        media_id: @media_id,
        content_type: "application/octet-stream",
        file_size: @total,
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

  defp get_range(range_value, token) do
    conn(:get, "/_matrix/media/v3/download/#{S.server_name()}/#{@media_id}")
    |> put_req_header("range", range_value)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(S.router_opts())
  end

  # ── AC3 — bytes=0-99 → 206, 100 bytes, Content-Range ───────────────────────

  test "Range: bytes=0-99 → 206 Partial Content with first 100 bytes + Content-Range", %{token: token} do
    conn = get_range("bytes=0-99", token)

    assert conn.status == 206,
           "a satisfiable Range must return 206, got #{conn.status} — range handling not implemented"

    assert byte_size(conn.resp_body) == 100
    assert conn.resp_body == binary_part(@plaintext, 0, 100)

    assert S.header(conn, "content-range") == "bytes 0-99/#{@total}"
    assert S.header(conn, "accept-ranges") == "bytes"
  end

  test "Range: bytes=0-1023 against a 256-byte object clamps to the object end → 206", %{token: token} do
    # bytes=0-1023 with only 256 bytes available: end clamps to total-1 (255).
    conn = get_range("bytes=0-1023", token)

    assert conn.status == 206
    assert byte_size(conn.resp_body) == @total
    assert S.header(conn, "content-range") == "bytes 0-#{@total - 1}/#{@total}"
  end

  # ── oracle §4 — unsatisfiable range → 416 ──────────────────────────────────

  test "unsatisfiable Range (start beyond end of object) → 416", %{token: token} do
    conn = get_range("bytes=99999-100000", token)

    assert conn.status == 416,
           "an unsatisfiable Range must return 416 Range Not Satisfiable, got #{conn.status}"
  end
end
