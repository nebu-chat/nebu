defmodule Nebu.Web.MediaDownloadGzipDecompressionTest do
  @moduledoc """
  RED-phase ATDD tests for the `fix-media-download-gzip-decompression` bug fix
  (no story file — bug-fix pipeline run).

  ## The bug

  `Nebu.Media.Storage.compress/1` (server/lib/nebu/media/storage.ex:114,
  ADR-029 "store-smaller-of-two") gzips the plaintext before encryption at
  upload time whenever the gzipped form is smaller than the original, and
  `Nebu.Media.encrypt_compress_and_store/6` (server/lib/nebu/media.ex) records
  this via a `compressed: true` boolean persisted onto the `media_files` row.

  But the download/thumbnail serving path — `Nebu.Media.fetch_and_decrypt/3`
  -> `serve_bytes/4` / `serve_inline_image/4` / `maybe_send_ranged/2`
  (server/lib/nebu/media.ex) — never reads that flag and never calls
  `:zlib.gunzip/1` on the decrypted bytes. So every download of a
  compressed-at-rest object serves the still-gzipped bytes verbatim,
  mislabeled with the original Content-Type and no Content-Encoding header —
  confirmed via curl against the running dev stack: a 68268-byte PNG was
  stored as 68143 gzip-compressed bytes, and every download returned exactly
  those 68143 bytes (valid gzip data that inflates back to the original
  68268 bytes, but never unwrapped server-side). This also explains a
  reported blank/white image preview in a Matrix client: the bytes handed to
  the browser's image decoder are gzip-wrapped, not real image data.

  ## AC2 grounding note — can a thumbnail ever be compressed-at-rest?

  YES. `Nebu.Media.thumbnail/3` does NOT store or fetch a separately-resized
  image — per its own comment (media.ex, "Thumbnail generation via
  libvips/Image is intentionally NOT used ... we serve the decrypted original
  inline"), it calls the EXACT SAME `with_authorised_media/4` ->
  `fetch_and_decrypt/3` path as `download/4`, against the SAME `media_files`
  row (same `storage_key`, same `compressed` flag, same encrypted object).
  There is no separate thumbnail storage anywhere in this codebase. So any
  row that was compressed at upload time is compressed for BOTH the download
  AND the thumbnail route — AC2's test below is not a hypothetical, it
  exercises a real, reachable path through `serve_inline_image/4`.

  ## Why AC1-AC3 below MUST fail now (fake-seam unit tests, no live DB needed)

  No decompression code exists anywhere in `lib/nebu/media.ex` or
  `lib/nebu/media/storage.ex` — `Storage` only exposes `compress/1`, never a
  `decompress/1` or `gunzip`-shaped counterpart. So for a `compressed: true`
  row, `serve_bytes/4` and `serve_inline_image/4` both hand the caller the
  raw (still-gzipped) decrypted bytes, which are byte-for-byte DIFFERENT from
  (and shorter than) the original plaintext these tests assert against.

  ## Why AC4 below MUST fail now (real-Postgres integration test)

  `Nebu.Media.DB.@sql_lookup` (db.ex) SELECTs `media_id, server_name,
  content_type, file_size, aes_key_hex, nonce_hex, uploader_user_id,
  uploaded_at, deleted, state, storage_key, archived_at` — `compressed` is
  simply absent from that column list, and `to_map/1`'s matching 12-field
  clause has no `compressed:` key in the map it builds. So today
  `Nebu.Media.DB.lookup/2`'s returned row map has NO `:compressed` key at
  all, regardless of what is actually stored in the column — this is
  unreachable from the fakes (the fake `MediaFakes.DB.lookup/2` just returns
  whatever map a test hands it) and must be proven against the real SQL.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes
  alias Nebu.Media.Storage

  @room_id "!room:test.local"

  defp get(path, headers) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 — GET /_matrix/client/v1/media/download/:server_name/:media_id (and
  # the legacy /_matrix/media/v3/download/... alias) must serve the ORIGINAL
  # bytes for a compressed-at-rest object, never :zlib.gzip(original).
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: download of a compressed-at-rest file" do
    setup do
      # Highly-compressible fixture (mirrors media_compression_test.exs's own
      # technique) so Storage.compress/1 genuinely picks the gzip branch —
      # this is a real call to the real function, not a hand-rolled stand-in.
      original = String.duplicate("nebu-gzip-bug-fixture-byte ", 4000)
      {store_bytes, compressed?} = Storage.compress(original)

      assert compressed? == true,
             "sanity check: this fixture must genuinely compress smaller, otherwise " <>
               "the test below would not exercise the compressed-at-rest branch at all"

      assert store_bytes != original,
             "sanity check: the stored bytes must differ from the original (that's the " <>
               "whole reason decompression is needed on the way out)"

      media_id = "gzipdl_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

      priv = S.setup_oidc_keys()
      {uid, token} = S.bearer_for("kai", priv)

      {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(store_bytes)

      row =
        S.media_row(
          media_id: media_id,
          content_type: "image/jpeg",
          file_size: byte_size(original),
          aes_key_hex: key_hex,
          nonce_hex: nonce_hex,
          room_id: @room_id,
          storage_key: media_id,
          compressed: true
        )

      Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
      Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
      Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

      Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
        if server == S.server_name() and id == media_id,
          do: {:ok, row},
          else: {:error, :not_found}
      end)

      # The fake storage boundary serves EXACTLY what production S3 would
      # hold: the gzip-then-encrypt bytes, never the plaintext.
      Application.put_env(:nebu_http, :media_storage_get_fun, fn key ->
        if key == media_id, do: {:ok, ciphertext}, else: {:error, :not_found}
      end)

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

      {:ok, token: token, media_id: media_id, original: original, gzipped: store_bytes}
    end

    test "GET /_matrix/client/v1/media/download/:server_name/:media_id → 200 with the ORIGINAL bytes, not the gzipped stored form",
         %{token: token, media_id: media_id, original: original, gzipped: gzipped} do
      path = "/_matrix/client/v1/media/download/#{S.server_name()}/#{media_id}"
      conn = get(path, S.auth(token))

      assert conn.status == 200, "download must return 200, got #{conn.status}"

      refute conn.resp_body == gzipped,
             "BUG REPRODUCED: the response body is the still-gzipped stored bytes " <>
               "(#{byte_size(gzipped)} bytes) — the download path never calls " <>
               ":zlib.gunzip/1 on a compressed: true row"

      assert conn.resp_body == original,
             "download of a compressed-at-rest file must byte-for-byte equal the " <>
               "ORIGINAL uploaded bytes (#{byte_size(original)} bytes), got " <>
               "#{byte_size(conn.resp_body)} bytes"
    end

    test "GET /_matrix/media/v3/download/:server_name/:media_id (legacy alias) → same ORIGINAL-bytes contract",
         %{token: token, media_id: media_id, original: original, gzipped: gzipped} do
      # Nebu.Web.Router.Media and Nebu.Web.Router.ClientV1Media both dispatch
      # to the exact same Nebu.Media.download/2,3 function (see both
      # routers' moduledocs) — this is a cheap parity smoke test proving the
      # bug (and its fix) is not route-specific.
      path = "/_matrix/media/v3/download/#{S.server_name()}/#{media_id}"
      conn = get(path, S.auth(token))

      assert conn.status == 200
      refute conn.resp_body == gzipped
      assert conn.resp_body == original
    end

    # code-review MINOR fix (cycle 1): regression guard for the specific
    # "wrong-slice risk" the original bug report worried about — a Range
    # request against a compressed-at-rest file must be sliced against the
    # ORIGINAL (decompressed) bytes, never the compressed stored form, and
    # `content-range`'s total must likewise reflect the ORIGINAL size.
    test "GET with Range: bytes=0-99 on a compressed-at-rest file → 206 with the correct " <>
           "100-byte slice of the ORIGINAL bytes and content-range against the ORIGINAL total size",
         %{token: token, media_id: media_id, original: original} do
      path = "/_matrix/client/v1/media/download/#{S.server_name()}/#{media_id}"
      conn = get(path, [{"range", "bytes=0-99"} | S.auth(token)])

      assert conn.status == 206,
             "a satisfiable Range request against a compressed-at-rest file must return " <>
               "206, got #{conn.status}"

      expected_slice = binary_part(original, 0, 100)

      assert conn.resp_body == expected_slice,
             "the ranged response body must be the 100-byte slice of the ORIGINAL " <>
               "(decompressed) bytes, not a slice of the compressed stored form"

      assert S.header(conn, "content-range") == "bytes 0-99/#{byte_size(original)}",
             "content-range's total must be the ORIGINAL file's size " <>
               "(#{byte_size(original)}), not the compressed stored size " <>
               "(#{byte_size(conn.resp_body)} sliced from a #{byte_size(original)}-byte " <>
               "original), got #{inspect(S.header(conn, "content-range"))}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 — thumbnail route (serve_inline_image/4) must ALSO decompress: a
  # thumbnail can be served from a compressed-at-rest row (see moduledoc
  # grounding note above — there is no separate thumbnail storage).
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: thumbnail of a compressed-at-rest file" do
    setup do
      png_magic = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      # A long run of zero bytes is both a plausible "mostly-flat image data"
      # stand-in and (crucially) highly gzip-compressible, exactly like
      # media_thumbnail_test.exs's own fixture shape.
      original = png_magic <> :binary.copy(<<0>>, 8000)

      {store_bytes, compressed?} = Storage.compress(original)

      assert compressed? == true,
             "sanity check: this fixture must genuinely compress smaller"

      media_id = "gziptn_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

      priv = S.setup_oidc_keys()
      {uid, token} = S.bearer_for("kai", priv)

      {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(store_bytes)

      row =
        S.media_row(
          media_id: media_id,
          content_type: "image/png",
          file_size: byte_size(original),
          aes_key_hex: key_hex,
          nonce_hex: nonce_hex,
          room_id: @room_id,
          storage_key: media_id,
          compressed: true
        )

      Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
      Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
      Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

      Application.put_env(:nebu_http, :media_lookup_fun, fn _server, id ->
        if id == media_id, do: {:ok, row}, else: {:error, :not_found}
      end)

      Application.put_env(:nebu_http, :media_storage_get_fun, fn key ->
        if key == media_id, do: {:ok, ciphertext}, else: {:error, :not_found}
      end)

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

      {:ok, token: token, media_id: media_id, original: original, gzipped: store_bytes}
    end

    test "GET /_matrix/client/v1/media/thumbnail/:server_name/:media_id → 200 with the ORIGINAL image bytes, not the gzipped stored form",
         %{token: token, media_id: media_id, original: original, gzipped: gzipped} do
      path = "/_matrix/client/v1/media/thumbnail/#{S.server_name()}/#{media_id}"
      conn = get(path, S.auth(token))

      assert conn.status == 200, "thumbnail must return 200, got #{conn.status}"

      refute conn.resp_body == gzipped,
             "BUG REPRODUCED: the thumbnail body is the still-gzipped stored bytes " <>
               "(#{byte_size(gzipped)} bytes) — serve_inline_image/4 never gunzips a " <>
               "compressed: true row either"

      assert conn.resp_body == original,
             "thumbnail of a compressed-at-rest file must byte-for-byte equal the " <>
               "ORIGINAL image bytes (#{byte_size(original)} bytes), got " <>
               "#{byte_size(conn.resp_body)} bytes"
    end

    # code-review MINOR fix (cycle 1): symmetry with AC1's download coverage
    # of both the v1 client route and the legacy v3 alias — Nebu.Web.Router.Media
    # and Nebu.Web.Router.ClientV1Media both dispatch to the exact same
    # Nebu.Media.thumbnail/3 function (see both routers' moduledocs), so this
    # is a cheap parity smoke test proving the fix is not route-specific.
    test "GET /_matrix/media/v3/thumbnail/:server_name/:media_id (legacy alias) → same ORIGINAL-bytes contract",
         %{token: token, media_id: media_id, original: original, gzipped: gzipped} do
      path = "/_matrix/media/v3/thumbnail/#{S.server_name()}/#{media_id}"
      conn = get(path, S.auth(token))

      assert conn.status == 200, "thumbnail must return 200, got #{conn.status}"
      refute conn.resp_body == gzipped
      assert conn.resp_body == original
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 — regression guard: an UNCOMPRESSED (compressed: false) row must
  # keep round-tripping correctly. Guards against a naive fix that always
  # calls :zlib.gunzip/1 regardless of the flag, which would raise/corrupt
  # every non-gzip-shaped file (any binary that doesn't happen to parse as
  # valid gzip framing).
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: download of an UNCOMPRESSED file (non-regression)" do
    setup do
      # Incompressible fixture (mirrors media_compression_test.exs's own
      # technique) — gzip framing overhead means Storage.compress/1 must
      # return compressed?: false for this input.
      original = :crypto.strong_rand_bytes(4096)
      {store_bytes, compressed?} = Storage.compress(original)

      assert compressed? == false,
             "sanity check: this fixture must genuinely NOT compress smaller, so this " <>
               "test exercises the compressed: false branch"

      assert store_bytes == original

      media_id = "gzipno_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

      priv = S.setup_oidc_keys()
      {uid, token} = S.bearer_for("kai", priv)

      {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(store_bytes)

      row =
        S.media_row(
          media_id: media_id,
          content_type: "application/octet-stream",
          file_size: byte_size(original),
          aes_key_hex: key_hex,
          nonce_hex: nonce_hex,
          room_id: @room_id,
          storage_key: media_id,
          compressed: false
        )

      Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
      Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
      Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

      Application.put_env(:nebu_http, :media_lookup_fun, fn _server, id ->
        if id == media_id, do: {:ok, row}, else: {:error, :not_found}
      end)

      Application.put_env(:nebu_http, :media_storage_get_fun, fn key ->
        if key == media_id, do: {:ok, ciphertext}, else: {:error, :not_found}
      end)

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

      {:ok, token: token, media_id: media_id, original: original}
    end

    test "GET download of a compressed: false row still returns the original bytes unmodified " <>
           "(this passes today — do not let a fix that gunzips unconditionally break it)",
         %{token: token, media_id: media_id, original: original} do
      path = "/_matrix/client/v1/media/download/#{S.server_name()}/#{media_id}"
      conn = get(path, S.auth(token))

      assert conn.status == 200
      assert conn.resp_body == original
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 — Nebu.Media.DB.lookup/2's returned row map must include :compressed
  # as a key. This is a real-Postgres test: the fakes can't expose the bug,
  # since MediaFakes.DB.lookup/2 just echoes back whatever map a test hands
  # it — only the real @sql_lookup SELECT list can be wrong.
  # ══════════════════════════════════════════════════════════════════════

  defmodule DBLookupCompressedKeyTest do
    @moduledoc """
    Separate module (still same file's logical scope) so this file's
    `async: false` fake-seam tests above and this integration test's real
    `Nebu.Repo` usage don't share ExUnit.Case setup — mirrors the
    `:integration`-tagged sibling files (e.g. media_db_lookup_for_scan_test.exs).
    """
    use ExUnit.Case, async: false

    @moduletag :integration

    alias Nebu.Media.DB
    alias Nebu.Media.StateMachine

    @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    defp media_id(suffix), do: "gzip_db_lookup_#{@run_id}_#{suffix}"

    setup do
      if Process.whereis(Nebu.Repo) == nil do
        flunk(
          "Nebu.Repo is not started — run with a live PostgreSQL, e.g. `make test-integration`"
        )
      end

      :ok
    end

    test "lookup/2 (the download/thumbnail-path lookup) includes :compressed == true for a row persisted with compressed: true" do
      id = media_id("true")

      {:ok, ^id} =
        StateMachine.create_quarantined(%{
          media_id: id,
          server_name: "test.local",
          uploader_user_id: "@uploader:test.local"
        })

      :ok =
        DB.persist_upload(%{
          media_id: id,
          storage_key: "storage/#{id}",
          file_hash: "sha256-fixture-compressed-true",
          compressed: true,
          content_type: "application/octet-stream",
          filename: "gzip-fixture.bin",
          aes_key_hex: String.duplicate("ab", 32),
          nonce_hex: String.duplicate("cd", 12),
          file_size: 4321
        })

      assert {:ok, row} = DB.lookup("test.local", id)

      assert Map.has_key?(row, :compressed),
             "Nebu.Media.DB.lookup/2's returned row is missing the :compressed key entirely " <>
               "— @sql_lookup's SELECT list does not include the `compressed` column"

      # Value check deliberately routed through a run-time-only lookup rather
      # than `row.compressed` / `Map.get(row, :compressed)`: both of those
      # make Elixir's compiler statically infer `Nebu.Media.DB.lookup/2`'s
      # concrete return shape and emit an "unknown key" compile-time warning
      # for a key @sql_lookup's SELECT list doesn't produce today — which
      # --warnings-as-errors (make test-unit-elixir) turns into a hard
      # compile failure for the WHOLE suite, not just this test. The
      # `Map.has_key?/2` assertion above already proves AC4 (the key is
      # missing); this is a defense-in-depth value check once the key exists.
      assert Enum.into(row, %{})[:compressed] == true
    end

    test "lookup/2 includes :compressed == false for a row persisted with compressed: false" do
      id = media_id("false")

      {:ok, ^id} =
        StateMachine.create_quarantined(%{
          media_id: id,
          server_name: "test.local",
          uploader_user_id: "@uploader:test.local"
        })

      :ok =
        DB.persist_upload(%{
          media_id: id,
          storage_key: "storage/#{id}",
          file_hash: "sha256-fixture-compressed-false",
          compressed: false,
          content_type: "application/octet-stream",
          filename: "plain-fixture.bin",
          aes_key_hex: String.duplicate("ab", 32),
          nonce_hex: String.duplicate("cd", 12),
          file_size: 4321
        })

      assert {:ok, row} = DB.lookup("test.local", id)

      assert Map.has_key?(row, :compressed),
             "Nebu.Media.DB.lookup/2's returned row is missing the :compressed key entirely " <>
               "— @sql_lookup's SELECT list does not include the `compressed` column"

      assert Enum.into(row, %{})[:compressed] == false
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # code-review MINOR fix (cycle 1) — fast, DB-free unit coverage for
  # Nebu.Media.DB.to_map/1's OWN positional mapping. Unlike
  # DBLookupCompressedKeyTest above (real Postgres, :integration-tagged),
  # this hand-builds a 14-element list matching to_map/1's documented
  # column order and calls it directly — no Nebu.Repo required — so it
  # runs under the fast `make test-unit-elixir` gate. NOTE: this does NOT
  # exercise `@sql_lookup` itself — it cannot catch a regression that drops
  # a column from that SELECT list (the hand-built list's arity wouldn't
  # change); only the slower :integration tests above catch that. What
  # this DOES close: a positional mix-up inside to_map/1's own pattern
  # match (e.g. `compressed` accidentally reading a different position),
  # which is why every field is asserted below, not just :compressed.
  # ══════════════════════════════════════════════════════════════════════

  defmodule ToMapColumnMappingTest do
    @moduledoc """
    Fast, DB-free unit test for `Nebu.Media.DB.to_map/1`'s own positional
    column mapping — see this file's moduledoc note above for exactly what
    this does and does not close.
    """
    use ExUnit.Case, async: true

    alias Nebu.Media.DB

    # Matches to_map/1's documented column order: media_id, server_name,
    # content_type, file_size, aes_key_hex, nonce_hex, uploader_user_id,
    # uploaded_at, deleted, state, storage_key, archived_at, compressed, filename.
    defp raw_row(media_id, compressed) do
      [
        media_id,
        "test.local",
        "image/png",
        1234,
        String.duplicate("ab", 32),
        String.duplicate("cd", 12),
        "@uploader:test.local",
        0,
        false,
        "released",
        "storage/#{media_id}",
        nil,
        compressed,
        "report.pdf"
      ]
    end

    test "to_map/1 maps every column to its correct key, compressed: true" do
      assert DB.to_map(raw_row("media-id-compressed-true", true)) == %{
               media_id: "media-id-compressed-true",
               server_name: "test.local",
               content_type: "image/png",
               file_size: 1234,
               aes_key_hex: String.duplicate("ab", 32),
               nonce_hex: String.duplicate("cd", 12),
               uploader_user_id: "@uploader:test.local",
               uploaded_at: 0,
               deleted: false,
               state: :released,
               storage_key: "storage/media-id-compressed-true",
               archived_at: nil,
               compressed: true,
               filename: "report.pdf",
               room_id: nil
             }
    end

    test "to_map/1 maps every column to its correct key, compressed: false" do
      assert DB.to_map(raw_row("media-id-compressed-false", false)) == %{
               media_id: "media-id-compressed-false",
               server_name: "test.local",
               content_type: "image/png",
               file_size: 1234,
               aes_key_hex: String.duplicate("ab", 32),
               nonce_hex: String.duplicate("cd", 12),
               uploader_user_id: "@uploader:test.local",
               uploaded_at: 0,
               deleted: false,
               state: :released,
               storage_key: "storage/media-id-compressed-false",
               archived_at: nil,
               compressed: false,
               filename: "report.pdf",
               room_id: nil
             }
    end
  end
end
