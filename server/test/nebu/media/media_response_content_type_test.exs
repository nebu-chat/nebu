defmodule Nebu.Web.MediaResponseContentTypeTest do
  @moduledoc """
  Acceptance tests for `media-download-content-type-and-filename`
  (matrix-spec-gaps, Matrix spec v1.12+ content repository):

    * AC1 — download returns the stored upload Content-Type UNCHANGED (no
      octet-stream rewriting for audio/mp4, video/quicktime, zip, tar, heic;
      no `; charset=utf-8` appended; missing/unparseable -> octet-stream;
      text/* never gets a wrong utf-8 charset).
    * AC2 — Content-Disposition `inline` ONLY for the spec inline list,
      everything else (incl. application/pdf) `attachment`.
    * AC3 — legacy rows of renderable types (text/html, xhtml, xml, svg, js, swf)
      are neutralised: application/octet-stream + attachment. The upload
      blocklist (400) stays unchanged.
    * AC4 — filename: persisted on sync AND async upload, read back by
      `Nebu.Media.DB.lookup/2`, `{fileName}` path priority, no `filename`
      parameter when nothing is known (never the media_id), `"`/`\\` escaping,
      `filename*=UTF-8''` for non-ASCII, CR/LF/control chars never reach the header.
    * AC5 — thumbnails only for jpeg/png/apng/gif/webp with exactly that type,
      inline + filename; everything else -> 400 M_UNKNOWN; never image/png for
      non-images.
    * AC6 — regression guards (nosniff, CSP, CORP, 404, 403, 451, 206/416).

  ## Why this MUST FAIL now (against server/lib/nebu/media.ex)

    * `disposition_for/2` rewrites every non-`@safe_inline_types` type to
      application/octet-stream and `put_resp_content_type/2` appends
      `; charset=utf-8` to everything (AC1/AC2/AC3).
    * `serve_bytes(..., file_name || media_id)` uses the media_id as filename and
      interpolates it unescaped; `Nebu.Media.DB.lookup/2` does not read the
      `filename` column; the sync upload passes `nil` as filename (AC4).
    * `thumbnail/4` serves ANY type, relabelling non-images as `image/png`, with
      the media_id as filename (AC5).

  Tests marked "regression guard" in their name pin pre-existing behavior and must stay green.
  Table-driven; uses the same app-env fakes as media_download_test.exs /
  media_async_upload_test.exs (no MinIO / ClamAV / network).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @room_id "!room:test.local"
  @plaintext "response-content-type-fixture-bytes-0123456789-abcdefghijklmnopqrstuvwxyz"

  @v3_download "/_matrix/media/v3/download"
  @v1_download "/_matrix/client/v1/media/download"
  @v3_thumbnail "/_matrix/media/v3/thumbnail"
  @v1_thumbnail "/_matrix/client/v1/media/thumbnail"

  # Spec "Serving inline content" allowlist (AC2).
  @spec_inline ~w(text/css text/plain text/csv application/json application/ld+json
                  image/jpeg image/gif image/png image/apng image/webp image/avif
                  video/mp4 video/webm video/ogg video/quicktime
                  audio/mp4 audio/webm audio/aac audio/mpeg audio/ogg audio/wave audio/wav
                  audio/x-wav audio/x-pn-wav audio/flac audio/x-flac)

  # Types that must be served unchanged but as attachment (not on inline list).
  @spec_attachment ~w(application/pdf application/zip application/x-tar image/heic
                      application/octet-stream application/x-7z-compressed
                      application/vnd.openxmlformats-officedocument.wordprocessingml.document)

  # Renderable/active content types (AC3) — legacy rows only; upload is blocked (400).
  @renderable ~w(text/html application/xhtml+xml text/xml application/xml image/svg+xml
                 text/javascript application/javascript application/x-shockwave-flash)

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)
    test_pid = self()

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)
    Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)
    Application.put_env(:nebu_http, :media_member_fun, fn room, user -> room == @room_id and user == uid end)

    # Upload-side capture seams (AC4 sync/async + AC1 stored type).
    Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
      send(test_pid, {:stored, key, bytes})
      :ok
    end)

    Application.put_env(:nebu_http, :media_persist_upload_fun, fn fields ->
      send(test_pid, {:persisted, fields})
      :ok
    end)

    Application.put_env(:nebu_http, :media_state_machine_transition_fun, fn _id, to, _actor, _meta ->
      {:ok, to}
    end)

    Application.put_env(:nebu_http, :media_scan_enqueue_fun, fn _id -> :ok end)

    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      for k <- [
            :media_db_module,
            :media_storage_module,
            :media_membership_module,
            :media_state_machine_module,
            :media_scan_enqueue_module,
            :media_member_fun,
            :media_lookup_fun,
            :media_storage_get_fun,
            :media_storage_put_fun,
            :media_persist_upload_fun,
            :media_state_machine_transition_fun,
            :media_scan_enqueue_fun,
            :media_lookup_reservation_fun
          ],
          do: Application.delete_env(:nebu_http, k)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Installs ONE media row (stored content type / filename / state) behind the
  # lookup + storage fakes and returns its media_id.
  defp install(content_type, opts \\ []) do
    media_id = "rct" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    row =
      [
        media_id: media_id,
        content_type: content_type,
        file_size: byte_size(@plaintext),
        aes_key_hex: key_hex,
        nonce_hex: nonce_hex,
        room_id: @room_id,
        storage_key: media_id,
        state: Keyword.get(opts, :state, :released)
      ]
      |> S.media_row()
      |> Map.put(:filename, Keyword.get(opts, :filename))

    Application.put_env(:nebu_http, :media_lookup_fun, fn _s, id ->
      if id == media_id, do: {:ok, row}, else: {:error, :not_found}
    end)

    Application.put_env(:nebu_http, :media_storage_get_fun, fn _k -> {:ok, ciphertext} end)
    media_id
  end

  defp get(path, token, extra \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(S.auth(token) ++ extra, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp download(base, media_id, token, suffix \\ "", extra \\ []),
    do: get("#{base}/#{S.server_name()}/#{media_id}#{suffix}", token, extra)

  defp thumbnail(base, media_id, token),
    do: get("#{base}/#{S.server_name()}/#{media_id}?width=64&height=64&method=scale", token)

  defp ct(conn), do: S.header(conn, "content-type")
  defp cd(conn), do: S.header(conn, "content-disposition")

  defp disposition_type(conn), do: conn |> cd() |> String.split(";") |> hd() |> String.trim()

  defp post_upload(body, headers, query \\ "") do
    path = "/_matrix/media/v3/upload" <> if(query == "", do: "", else: "?" <> query)
    conn = conn(:post, path, body) |> Map.put(:req_headers, [])
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp put_async(media_id, body, headers, query) do
    path = "/_matrix/media/v3/upload/#{S.server_name()}/#{media_id}?" <> query
    conn = conn(:put, path, body) |> Map.put(:req_headers, [])
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp seed_reservation(uploader_user_id) do
    Application.put_env(:nebu_http, :media_lookup_reservation_fun, fn _s, _m ->
      {:ok, %{uploader_user_id: uploader_user_id, state: :reserved, uploaded_at: System.system_time(:millisecond)}}
    end)
  end

  defp percent_encode(s), do: URI.encode(s, &URI.char_unreserved?/1)

  # Recovers the filename(s) a client could derive from a Content-Disposition
  # value: the (unescaped) quoted-string `filename="..."` and, when present,
  # the percent-decoded `filename*=UTF-8''...`. Fails if the quoted-string is
  # not well-formed (quote breakout / extra parameters).
  defp recover_filenames(header) do
    [_disp | params] = String.split(header, "; ", parts: 2)

    quoted =
      case Regex.run(~r/\Afilename="((?:[^"\\]|\\.)*)"(?:; filename\*=UTF-8''([A-Za-z0-9%._~-]*))?\z/s, Enum.join(params)) do
        [_, q] -> [Regex.replace(~r/\\(.)/s, q, "\\1")]
        [_, q, ext] -> [Regex.replace(~r/\\(.)/s, q, "\\1"), URI.decode(ext)]
        nil -> flunk("Content-Disposition parameters malformed / breakout: #{inspect(header)}")
      end

    quoted
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 + AC2 — Content-Type preserved, disposition from the spec list
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: stored type is served unchanged, disposition per spec inline list" do
    for type <- @spec_inline do
      test "#{type} -> exact Content-Type (no charset) + inline", %{token: token} do
        type = unquote(type)
        id = install(type)

        for base <- [@v3_download, @v1_download] do
          conn = download(base, id, token)
          assert conn.status == 200, "#{base}: expected 200, got #{conn.status}"
          assert ct(conn) == type, "#{base}: Content-Type must be exactly #{inspect(type)}, got #{inspect(ct(conn))}"
          assert disposition_type(conn) == "inline", "#{type} is on the spec inline list; got #{inspect(cd(conn))}"
          assert conn.resp_body == @plaintext
        end
      end
    end

    for type <- @spec_attachment do
      test "#{type} -> exact Content-Type (no octet-stream rewrite) + attachment", %{token: token} do
        type = unquote(type)
        id = install(type)

        for base <- [@v3_download, @v1_download] do
          conn = download(base, id, token)
          assert conn.status == 200
          assert ct(conn) == type, "#{base}: Content-Type must be exactly #{inspect(type)}, got #{inspect(ct(conn))}"

          assert disposition_type(conn) == "attachment",
                 "#{type} is NOT on the spec inline list -> attachment; got #{inspect(cd(conn))}"

          assert conn.resp_body == @plaintext
        end
      end
    end

    test "application/pdf is attachment, not inline (spec inline list excludes PDF)", %{token: token} do
      id = install("application/pdf")
      conn = download(@v3_download, id, token)
      assert disposition_type(conn) == "attachment"
      assert ct(conn) == "application/pdf"
    end

    test "audio/mp4 and video/quicktime are NOT rewritten to octet-stream", %{token: token} do
      for type <- ["audio/mp4", "video/quicktime"] do
        conn = download(@v3_download, install(type), token)
        assert ct(conn) == type
        refute String.contains?(ct(conn), "octet-stream")
      end
    end

    test "no `; charset=utf-8` is appended to any non-text type", %{token: token} do
      for type <- ["image/png", "audio/mpeg", "application/json", "application/pdf", "video/mp4"] do
        conn = download(@v3_download, install(type), token)
        refute String.contains?(ct(conn), "charset"), "#{type} must not get a charset, got #{inspect(ct(conn))}"
      end
    end

    # Missing / unparseable stored type -> application/octet-stream + attachment.
    for {label, stored} <- [{"nil", nil}, {"empty string", ""}, {"no slash", "garbage"}, {"only whitespace", "   "}] do
      test "missing/unparseable stored type (#{label}) -> exactly application/octet-stream + attachment",
           %{token: token} do
        id = install(unquote(stored))

        for base <- [@v3_download, @v1_download] do
          conn = download(base, id, token)
          assert conn.status == 200
          assert ct(conn) == "application/octet-stream", "got #{inspect(ct(conn))}"
          assert disposition_type(conn) == "attachment"
        end
      end
    end

    test "text/plain stored bare -> exactly text/plain (no wrong utf-8 charset) + inline", %{token: token} do
      id = install("text/plain")
      conn = download(@v3_download, id, token)
      assert ct(conn) == "text/plain", "bare text/plain must be served bare, got #{inspect(ct(conn))}"
      assert disposition_type(conn) == "inline"
    end

    test "text/plain stored with charset=iso-8859-1 -> original charset or bare type, NEVER utf-8",
         %{token: token} do
      id = install("text/plain; charset=iso-8859-1")
      conn = download(@v3_download, id, token)

      assert ct(conn) in ["text/plain; charset=iso-8859-1", "text/plain"],
             "text/* may keep the ORIGINAL charset or be bare, never a wrong utf-8; got #{inspect(ct(conn))}"

      refute String.contains?(String.downcase(ct(conn)), "utf-8")
      assert disposition_type(conn) == "inline"
    end

    test "text/csv and text/css stored bare -> no charset appended", %{token: token} do
      for type <- ["text/csv", "text/css"] do
        conn = download(@v3_download, install(type), token)
        assert ct(conn) == type
      end
    end

    test "disposition is computed from the type actually served (case-insensitive stored type)", %{token: token} do
      id = install("IMAGE/PNG")
      conn = download(@v3_download, id, token)
      assert String.downcase(ct(conn)) == "image/png"
      assert disposition_type(conn) == "inline"
    end
  end

  describe "AC1: upload keeps the original type (sync + async persist)" do
    for type <- ["image/heic", "audio/mp4", "video/quicktime", "application/zip", "application/x-tar", "application/pdf", "text/csv"] do
      test "sync upload of #{type} persists exactly that content_type (regression guard)", %{token: token} do
        type = unquote(type)
        conn = post_upload("some-bytes-123", [{"content-type", type} | S.auth(token)])
        assert conn.status == 200, "got #{conn.status}: #{inspect(conn.resp_body)}"
        assert_received {:persisted, fields}
        assert fields.content_type == type
      end
    end

    test "sync upload of text/plain; charset=iso-8859-1 never ends up as utf-8", %{token: token} do
      conn = post_upload("latin1 \xE4\xF6\xFC", [{"content-type", "text/plain; charset=iso-8859-1"} | S.auth(token)])
      assert conn.status == 200
      assert_received {:persisted, fields}
      assert fields.content_type in ["text/plain; charset=iso-8859-1", "text/plain"]
    end

    test "sync upload without a Content-Type header persists application/octet-stream (regression guard)",
         %{token: token} do
      conn = post_upload("some-bytes", Enum.reject(S.auth(token), &match?({"content-type", _}, &1)))
      assert conn.status == 200
      assert_received {:persisted, fields}
      assert fields.content_type == "application/octet-stream"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 — renderable/legacy types neutralised; upload blocklist unchanged
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: renderable types are served as octet-stream + attachment" do
    for type <- @renderable do
      test "legacy row #{type} -> application/octet-stream + attachment (never inline/renderable)",
           %{token: token} do
        id = install(unquote(type))

        for base <- [@v3_download, @v1_download] do
          conn = download(base, id, token)
          assert conn.status == 200
          assert ct(conn) == "application/octet-stream", "got #{inspect(ct(conn))}"
          assert disposition_type(conn) == "attachment"
        end
      end

      test "legacy row #{type} with parameters/upper-case is neutralised too", %{token: token} do
        id = install(String.upcase(unquote(type)) <> "; charset=utf-8")
        conn = download(@v3_download, id, token)
        assert ct(conn) == "application/octet-stream", "got #{inspect(ct(conn))}"
        assert disposition_type(conn) == "attachment"
      end
    end

    for type <- ["text/html", "application/xhtml+xml", "text/javascript", "application/javascript", "image/svg+xml", "application/x-shockwave-flash"] do
      test "upload blocklist unchanged (regression guard): POST upload #{type} -> 400, nothing stored",
           %{token: token} do
        conn = post_upload("<html></html>", [{"content-type", unquote(type)} | S.auth(token)])
        assert conn.status == 400, "got #{conn.status}"
        refute_received {:stored, _, _}
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 — filename
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: filename delivered in Content-Disposition" do
    test "stored upload filename is delivered (v3 + v1)", %{token: token} do
      id = install("application/pdf", filename: "a b.pdf")

      for base <- [@v3_download, @v1_download] do
        conn = download(base, id, token)
        assert String.starts_with?(cd(conn), ~s(attachment; filename="a b.pdf")), "#{base}: got #{inspect(cd(conn))}"
        assert "a b.pdf" in recover_filenames(cd(conn))
      end
    end

    test "inline type with stored filename -> inline; filename=...", %{token: token} do
      id = install("image/png", filename: "cat.png")
      conn = download(@v3_download, id, token)
      assert String.starts_with?(cd(conn), ~s(inline; filename="cat.png"))
      assert "cat.png" in recover_filenames(cd(conn))
    end

    test "{fileName} path segment wins over the stored upload filename", %{token: token} do
      id = install("application/pdf", filename: "stored.pdf")

      for base <- [@v3_download, @v1_download] do
        conn = download(base, id, token, "/override.pdf")
        assert conn.status == 200
        assert String.contains?(cd(conn), ~s(filename="override.pdf")), "got #{inspect(cd(conn))}"
        refute String.contains?(cd(conn), "stored.pdf")
      end
    end

    test "{fileName} path segment is used when no filename is stored", %{token: token} do
      id = install("image/png", filename: nil)
      conn = download(@v3_download, id, token, "/cat.png")
      assert String.starts_with?(cd(conn), ~s(inline; filename="cat.png"))
      assert "cat.png" in recover_filenames(cd(conn))
    end

    test "no stored filename and no path filename -> NO filename parameter at all (never media_id)",
         %{token: token} do
      for {type, expected} <- [{"image/png", "inline"}, {"application/pdf", "attachment"}, {"application/zip", "attachment"}] do
        id = install(type, filename: nil)

        for base <- [@v3_download, @v1_download] do
          conn = download(base, id, token)
          assert conn.status == 200
          assert cd(conn) == expected, "#{type}: expected bare #{inspect(expected)}, got #{inspect(cd(conn))}"
          refute String.contains?(cd(conn), id), "media_id must never be used as the filename"
        end
      end
    end

    test "empty stored filename is treated as absent (no filename parameter)", %{token: token} do
      id = install("application/pdf", filename: "")
      assert cd(download(@v3_download, id, token)) == "attachment"
    end

    test "double quote in filename is backslash-escaped", %{token: token} do
      id = install("application/pdf", filename: ~s(a"b.pdf))
      conn = download(@v3_download, id, token)
      # Any RFC-conformant encoding is fine (escaped quote in the quoted-string
      # and/or exact name in filename*); no breakout, original name recoverable.
      assert ~s(a"b.pdf) in recover_filenames(cd(conn)), "got #{inspect(cd(conn))}"
    end

    test "backslash in filename is escaped", %{token: token} do
      id = install("application/pdf", filename: ~S(a\b.pdf))
      conn = download(@v3_download, id, token)
      assert ~S(a\b.pdf) in recover_filenames(cd(conn)), "got #{inspect(cd(conn))}"
    end

    test "quote in the {fileName} path segment cannot break out of the header value", %{token: token} do
      id = install("application/pdf")
      conn = download(@v3_download, id, token, "/" <> percent_encode(~s(x".pdf; evil="1)))
      assert conn.status == 200
      # parses as ONE quoted-string (no breakout / extra params) and the exact
      # original name is recoverable via escaped quoted-string or filename*.
      assert ~s(x".pdf; evil="1) in recover_filenames(cd(conn)), "got #{inspect(cd(conn))}"
      refute String.contains?(cd(conn), ~s(filename="x".pdf))
    end

    test "non-ASCII filename -> ASCII-safe filename= plus filename*=UTF-8'' percent-encoded", %{token: token} do
      name = "Übersicht-日本.pdf"
      id = install("application/pdf", filename: name)

      for base <- [@v3_download, @v1_download] do
        conn = download(base, id, token)
        header = cd(conn)
        assert String.contains?(header, "filename*=UTF-8''" <> percent_encode(name)), "got #{inspect(header)}"
        assert String.contains?(header, ~s(filename=")), "ASCII fallback filename= must be present, got #{inspect(header)}"
        assert header |> :binary.bin_to_list() |> Enum.all?(&(&1 in 32..126)), "raw non-ASCII bytes in header: #{inspect(header)}"
      end
    end

    test "non-ASCII {fileName} path segment is encoded the same way", %{token: token} do
      id = install("application/pdf")
      name = "Ärger.pdf"
      conn = download(@v3_download, id, token, "/" <> percent_encode(name))
      assert conn.status == 200
      assert String.contains?(cd(conn), "filename*=UTF-8''" <> percent_encode(name)), "got #{inspect(cd(conn))}"
    end

    test "CR/LF in the {fileName} path segment can never reach the header (header injection)",
         %{token: token} do
      id = install("application/pdf")
      evil = "a.pdf\r\nSet-Cookie: pwned=1"
      conn = download(@v3_download, id, token, "/" <> percent_encode(evil))

      assert conn.status in [200, 400], "got #{conn.status}"

      for {k, v} <- conn.resp_headers do
        refute String.contains?(v, "\r") or String.contains?(v, "\n"), "CR/LF in header #{k}: #{inspect(v)}"
      end

      refute Enum.any?(conn.resp_headers, fn {k, _} -> k == "set-cookie" end)
    end

    # Asymmetry on purpose: for the STORED filename only 200 is acceptable (a
    # download must not fail with 400 because of previously stored data), while
    # the request-supplied {fileName} variant above may be sanitized (200) or
    # rejected (400).
    test "CR/LF and control characters in the STORED filename never reach the header", %{token: token} do
      id = install("application/pdf", filename: "a\r\nX-Injected: 1\x00\x1F\x7F.pdf")
      conn = download(@v3_download, id, token)
      assert conn.status == 200

      for {k, v} <- conn.resp_headers do
        refute v |> :binary.bin_to_list() |> Enum.any?(&(&1 < 32 or &1 == 127)), "control char in header #{k}: #{inspect(v)}"
      end

      refute Enum.any?(conn.resp_headers, fn {k, _} -> k == "x-injected" end)
    end

    test "%00 / %1F control characters in the {fileName} path segment never reach the header",
         %{token: token} do
      id = install("application/pdf")
      conn = download(@v3_download, id, token, "/a%00b%1Fc.pdf")
      assert conn.status in [200, 400]

      for {k, v} <- conn.resp_headers do
        refute v |> :binary.bin_to_list() |> Enum.any?(&(&1 < 32 or &1 == 127)), "control char in header #{k}: #{inspect(v)}"
      end
    end
  end

  describe "AC4: filename is persisted on upload" do
    test "sync POST upload with ?filename=a b.pdf persists the filename", %{token: token} do
      conn = post_upload("pdf-bytes-123", [{"content-type", "application/pdf"} | S.auth(token)], "filename=" <> percent_encode("a b.pdf"))
      assert conn.status == 200, "got #{conn.status}: #{inspect(conn.resp_body)}"
      assert_received {:persisted, fields}
      assert fields.filename == "a b.pdf", "sync upload must persist the filename, got #{inspect(fields.filename)}"
    end

    test "sync POST upload with non-ASCII ?filename= persists it verbatim (no mangling)", %{token: token} do
      name = "Übersicht.pdf"
      conn = post_upload("pdf-bytes", [{"content-type", "application/pdf"} | S.auth(token)], "filename=" <> percent_encode(name))
      assert conn.status == 200
      assert_received {:persisted, fields}
      assert fields.filename == name
    end

    test "sync POST upload without ?filename= persists nil (regression guard)", %{token: token} do
      conn = post_upload("pdf-bytes", [{"content-type", "application/pdf"} | S.auth(token)])
      assert conn.status == 200
      assert_received {:persisted, fields}
      assert fields.filename == nil
    end

    test "async PUT upload with ?filename= persists it (reserved path, regression guard)",
         %{token: token, user_id: uid} do
      seed_reservation(uid)
      mid = "async-rct-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

      conn =
        put_async(mid, "bytes-for-async", [{"content-type", "application/pdf"} | S.auth(token)], "filename=" <> percent_encode("Bericht Ü.pdf"))

      assert conn.status == 200, "got #{conn.status}: #{inspect(conn.resp_body)}"
      assert_received {:persisted, fields}
      assert fields.filename == "Bericht Ü.pdf"
      assert fields.content_type == "application/pdf"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 — thumbnails
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: thumbnail types" do
    for {type, exts} <- [
          {"image/png", ["png"]},
          {"image/jpeg", ["jpg", "jpeg"]},
          {"image/apng", ["apng", "png"]},
          {"image/gif", ["gif"]},
          {"image/webp", ["webp"]}
        ] do
      test "#{type} -> same Content-Type + inline + thumbnail filename (v3 + v1)", %{token: token} do
        type = unquote(type)
        exts = unquote(exts)
        id = install(type, filename: nil)

        for base <- [@v3_thumbnail, @v1_thumbnail] do
          conn = thumbnail(base, id, token)
          assert conn.status == 200, "#{base}: got #{conn.status}"
          assert ct(conn) == type, "thumbnail Content-Type must be exactly #{type}, got #{inspect(ct(conn))}"
          assert disposition_type(conn) == "inline"

          assert Regex.match?(~r/filename="[^"]*\.(#{Enum.join(exts, "|")})"/, cd(conn)),
                 "thumbnail needs a filename with extension #{inspect(exts)}, got #{inspect(cd(conn))}"

          refute String.contains?(cd(conn), id), "media_id must not be the thumbnail filename"
        end
      end
    end

    test "thumbnail Content-Type carries no charset parameter", %{token: token} do
      conn = thumbnail(@v3_thumbnail, install("image/png"), token)
      refute String.contains?(ct(conn), "charset"), "got #{inspect(ct(conn))}"
    end

    test "thumbnail of an image with a stored filename still gets a (thumbnail) filename", %{token: token} do
      id = install("image/jpeg", filename: "holiday.jpg")
      conn = thumbnail(@v3_thumbnail, id, token)
      assert conn.status == 200
      assert String.contains?(cd(conn), "filename="), "got #{inspect(cd(conn))}"
    end

    for type <- ["application/pdf", "application/zip", "image/heic", "image/avif", "image/bmp",
                 "audio/mpeg", "video/mp4", "text/plain", "application/octet-stream",
                 "image/svg+xml", "text/html", "image/tiff"] do
      test "non-thumbnailable #{type} -> 400 M_UNKNOWN, never relabelled image/png", %{token: token} do
        id = install(unquote(type))

        for base <- [@v3_thumbnail, @v1_thumbnail] do
          conn = thumbnail(base, id, token)
          assert conn.status == 400, "#{base}: got #{conn.status} (#{inspect(ct(conn))})"
          assert S.json(conn)["errcode"] == "M_UNKNOWN"
          refute String.starts_with?(ct(conn), "image/"), "must not serve a non-image as an image, got #{inspect(ct(conn))}"
          refute conn.resp_body == @plaintext, "original bytes must not be returned as a thumbnail"
        end
      end
    end

    test "thumbnail with missing stored type -> 400 M_UNKNOWN", %{token: token} do
      conn = thumbnail(@v3_thumbnail, install(nil), token)
      assert conn.status == 400
      assert S.json(conn)["errcode"] == "M_UNKNOWN"
    end

    test "regression guard: thumbnail of unknown media -> 404 M_NOT_FOUND", %{token: token} do
      install("image/png")
      conn = thumbnail(@v3_thumbnail, "does-not-exist", token)
      assert conn.status == 404
      assert S.json(conn)["errcode"] == "M_NOT_FOUND"
    end

    # Design note (M5): membership (403) is checked BEFORE the type check (400),
    # so a non-member cannot probe a media item's type. Not derivable from the
    # ACs, kept deliberately.
    test "regression guard: thumbnail by non-member -> 403 M_FORBIDDEN (also for non-thumbnailable types)",
         %{token: token} do
      Application.put_env(:nebu_http, :media_member_fun, fn _r, _u -> false end)

      for type <- ["image/png", "application/pdf"] do
        conn = thumbnail(@v3_thumbnail, install(type), token)
        assert conn.status == 403, "#{type}: got #{conn.status}"
        assert S.json(conn)["errcode"] == "M_FORBIDDEN"
      end
    end

    test "regression guard: thumbnail headers keep nosniff, CSP sandbox, CORP", %{token: token} do
      conn = thumbnail(@v3_thumbnail, install("image/png"), token)
      assert S.header(conn, "x-content-type-options") == "nosniff"
      assert String.contains?(S.header(conn, "content-security-policy"), "sandbox")
      assert S.header(conn, "cross-origin-resource-policy") == "cross-origin"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6 — no regression on download headers / error paths
  # ══════════════════════════════════════════════════════════════════════

  describe "AC6: regression guards" do
    test "download keeps nosniff, CSP sandbox, CORP and accept-ranges for inline AND attachment types",
         %{token: token} do
      for type <- ["image/png", "application/pdf", "application/zip", "text/html"] do
        conn = download(@v3_download, install(type), token)
        assert conn.status == 200
        assert S.header(conn, "x-content-type-options") == "nosniff"

        csp = S.header(conn, "content-security-policy")
        assert String.contains?(csp, "sandbox")
        assert String.contains?(csp, "default-src 'none'")
        assert String.contains?(csp, "script-src 'none'")

        assert S.header(conn, "cross-origin-resource-policy") == "cross-origin"
        assert S.header(conn, "accept-ranges") == "bytes"
      end
    end

    test "unknown media -> 404 M_NOT_FOUND", %{token: token} do
      install("image/png")
      conn = download(@v3_download, "does-not-exist", token)
      assert conn.status == 404
      assert S.json(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "non-member -> 403 M_FORBIDDEN", %{token: token} do
      id = install("image/png")
      Application.put_env(:nebu_http, :media_member_fun, fn _r, _u -> false end)
      conn = download(@v3_download, id, token)
      assert conn.status == 403
      assert S.json(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "state :quarantined -> 451 M_NOT_YET_UPLOADED (ADR-026)", %{token: token} do
      id = install("application/pdf", state: :quarantined)
      conn = download(@v3_download, id, token)
      assert conn.status == 451
      assert S.json(conn)["errcode"] == "M_NOT_YET_UPLOADED"
    end

    test "Range 206 serves the slice with the ORIGINAL Content-Type + Content-Range", %{token: token} do
      id = install("audio/mp4")
      conn = download(@v3_download, id, token, "", [{"range", "bytes=0-9"}])
      assert conn.status == 206
      assert conn.resp_body == binary_part(@plaintext, 0, 10)
      assert S.header(conn, "content-range") == "bytes 0-9/#{byte_size(@plaintext)}"
      assert ct(conn) == "audio/mp4", "ranged response must keep the original type, got #{inspect(ct(conn))}"
      assert disposition_type(conn) == "inline"
    end

    test "unsatisfiable Range -> 416", %{token: token} do
      id = install("audio/mp4")
      conn = download(@v3_download, id, token, "", [{"range", "bytes=99999-100000"}])
      assert conn.status == 416
    end

    test "full 200 body length equals the stored plaintext length (Content-Length basis)", %{token: token} do
      conn = download(@v3_download, install("application/zip"), token)
      assert conn.status == 200
      assert byte_size(conn.resp_body) == byte_size(@plaintext)

      # KNOWN GAP (M4): Plug.Test adapters set no content-length header, so the
      # missing-header branch below is accepted; the real Content-Length is only
      # covered in CI/e2e. This only guards the body length.
      case Plug.Conn.get_resp_header(conn, "content-length") do
        [] -> :ok
        [len | _] -> assert len == Integer.to_string(byte_size(@plaintext))
      end
    end
  end
  # ══════════════════════════════════════════════════════════════════════
  # Review cycle 1 — hardening (Kassandra F-1..F-3, review M1..M4, INFO)
  # ══════════════════════════════════════════════════════════════════════

  # Whole families of active content (WHATWG "XML MIME type" / "JavaScript
  # MIME type" + a few historic script-ish carriers) are neutralised by
  # CATEGORY, not by exact-match enumeration (Kassandra F-1).
  @neutralized_families ~w(
    application/rss+xml application/atom+xml application/mathml+xml
    application/xslt+xml application/rdf+xml application/vnd.wap.xhtml+xml
    application/x-custom+xml text/xsl multipart/x-mixed-replace
    application/ecmascript application/x-ecmascript application/x-javascript
    text/ecmascript text/javascript1.0 text/javascript1.1 text/javascript1.2
    text/javascript1.3 text/javascript1.4 text/javascript1.5 text/jscript
    text/livescript text/x-ecmascript text/x-javascript
    application/wasm text/x-component text/cache-manifest
  )

  describe "cycle 1 F-1: active-content families are neutralised by category" do
    for type <- @neutralized_families do
      test "legacy row #{type} -> application/octet-stream + attachment", %{token: token} do
        id = install(unquote(type))

        for base <- [@v3_download, @v1_download] do
          conn = download(base, id, token)
          assert conn.status == 200
          assert ct(conn) == "application/octet-stream"
          assert disposition_type(conn) == "attachment"
        end
      end

      test "legacy row #{type} with params/upper-case is neutralised too", %{token: token} do
        id = install(String.upcase(unquote(type)) <> " ; charset=utf-8")
        conn = download(@v3_download, id, token)
        assert ct(conn) == "application/octet-stream"
        assert disposition_type(conn) == "attachment"
      end
    end

    test "the +xml suffix rule never hits a spec-inline type", _ do
      refute Enum.any?(@spec_inline, &String.ends_with?(&1, "+xml"))
      assert length(@spec_inline) == 26
    end

    test "application/ld+json (+json) stays inline with its own type", %{token: token} do
      id = install("application/ld+json")
      conn = download(@v3_download, id, token)
      assert ct(conn) == "application/ld+json"
      assert disposition_type(conn) == "inline"
    end

    test "upload blocklist decision: JS-family types beyond the original 6 are NOT blocked at upload (download neutralises them)",
         %{token: token} do
      conn = post_upload("x", [{"content-type", "application/ecmascript"} | S.auth(token)])
      assert conn.status == 200
      assert_received {:persisted, fields}
      assert fields.content_type == "application/ecmascript"
    end
  end

  describe "cycle 1 M2: filename query param is normalised on BOTH upload paths" do
    for {label, query} <- [{"map value", "filename[a]=b"}, {"empty value", "filename="}, {"list value", "filename[]=x"}] do
      test "sync upload ?#{label} -> stored nil, no 500", %{token: token} do
        conn = post_upload("pdf", [{"content-type", "application/pdf"} | S.auth(token)], unquote(query))
        assert conn.status == 200, "got #{conn.status}: #{inspect(conn.resp_body)}"
        assert_received {:persisted, fields}
        assert fields.filename == nil
      end

      test "async upload ?#{label} -> stored nil, no 500", %{token: token, user_id: uid} do
        seed_reservation(uid)
        mid = "async-m2-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
        conn = put_async(mid, "bytes", [{"content-type", "application/pdf"} | S.auth(token)], unquote(query))
        assert conn.status == 200, "got #{conn.status}: #{inspect(conn.resp_body)}"
        assert_received {:persisted, fields}
        assert fields.filename == nil
      end
    end
  end

  describe "cycle 1 M3: filename length cap (255 bytes, codepoint boundary)" do
    defp both_upload_paths(token, uid, query) do
      sync = post_upload("pdf", [{"content-type", "application/pdf"} | S.auth(token)], query)
      assert sync.status == 200
      assert_received {:persisted, sync_fields}

      seed_reservation(uid)
      mid = "async-m3-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      async = put_async(mid, "bytes", [{"content-type", "application/pdf"} | S.auth(token)], query)
      assert async.status == 200
      assert_received {:persisted, async_fields}
      [sync_fields.filename, async_fields.filename]
    end

    test "10 KB ASCII filename is stored truncated to 255 bytes (sync + async)", %{token: token, user_id: uid} do
      name = String.duplicate("a", 10_000)

      for stored <- both_upload_paths(token, uid, "filename=" <> name) do
        assert byte_size(stored) == 255
      end
    end

    test "10 KB multibyte filename is truncated on a codepoint boundary (sync + async)", %{token: token, user_id: uid} do
      name = String.duplicate("日", 3_400)

      for stored <- both_upload_paths(token, uid, "filename=" <> percent_encode(name)) do
        assert byte_size(stored) <= 255
        assert byte_size(stored) == 255
        assert String.valid?(stored)
        assert String.starts_with?(name, stored)
      end
    end

    test "boundary: a 4-byte codepoint straddling byte 255 is dropped whole", %{token: token, user_id: uid} do
      name = String.duplicate("a", 254) <> "😀"

      for stored <- both_upload_paths(token, uid, "filename=" <> percent_encode(name)) do
        assert stored == String.duplicate("a", 254)
      end
    end

    test "a name of exactly 255 bytes is kept untouched", %{token: token, user_id: uid} do
      name = String.duplicate("b", 255)
      assert both_upload_paths(token, uid, "filename=" <> name) == [name, name]
    end

    test "output cap: a legacy 10 KB stored filename yields a bounded Content-Disposition", %{token: token} do
      for name <- [String.duplicate("a", 10_000), String.duplicate("日", 3_400)] do
        id = install("application/pdf", filename: name)
        conn = download(@v3_download, id, token)
        assert conn.status == 200
        assert byte_size(cd(conn)) < 1_300, "Content-Disposition is #{byte_size(cd(conn))} bytes"
      end
    end

    test "output cap: a 10 KB {fileName} path segment yields a bounded Content-Disposition", %{token: token} do
      id = install("application/pdf")

      for name <- [String.duplicate("a", 5_000), String.duplicate("日", 1_500)] do
        conn = download(@v3_download, id, token, "/" <> percent_encode(name))
        assert conn.status == 200
        assert byte_size(cd(conn)) < 1_300, "Content-Disposition is #{byte_size(cd(conn))} bytes"
      end
    end
  end

  describe "cycle 1 M4: bidi / invisible format characters are stripped" do
    ranges = [0x061C..0x061C, 0x200B..0x200F, 0x202A..0x202E, 0x2066..0x2069, 0xFEFF..0xFEFF]

    for cp <- Enum.flat_map(ranges, &Enum.to_list/1) do
      test "U+#{Integer.to_string(cp, 16)} is stripped from the stored filename", %{token: token} do
        id = install("application/pdf", filename: "inv" <> <<unquote(cp)::utf8>> <> "oice.pdf")
        conn = download(@v3_download, id, token)
        assert cd(conn) == ~s(attachment; filename="invoice.pdf")
      end
    end

    test "RLO spoofing name cannot reorder the visible extension (stored + path segment)", %{token: token} do
      id = install("application/pdf", filename: "invoice\u202Efdp.exe")
      assert cd(download(@v3_download, id, token)) == ~s(attachment; filename="invoicefdp.exe")

      id2 = install("application/pdf")
      conn = download(@v3_download, id2, token, "/" <> percent_encode("invoice\u202Efdp.exe"))
      assert cd(conn) == ~s(attachment; filename="invoicefdp.exe")
    end

    test "a name made only of format characters yields no filename parameter", %{token: token} do
      id = install("application/pdf", filename: "\u202E\u200B\uFEFF")
      assert cd(download(@v3_download, id, token)) == "attachment"
    end

    test "Nebu.Media.display_filename/1 (admin list) shows the sanitized name" do
      assert Nebu.Media.display_filename("invoice\u202Efdp.exe") == "invoicefdp.exe"
      assert Nebu.Media.display_filename("a\r\nb.pdf") == "ab.pdf"
      assert Nebu.Media.display_filename(String.duplicate("a", 1_000)) == String.duplicate("a", 255)
      assert Nebu.Media.display_filename("\u202E") == nil
      assert Nebu.Media.display_filename(nil) == nil
    end
  end

  describe "cycle 1 cosmetics" do
    test "non-ASCII fallback uses ONE underscore per codepoint, not per byte", %{token: token} do
      id = install("application/pdf", filename: "für.pdf")
      assert cd(download(@v3_download, id, token)) == ~s(attachment; filename="f_r.pdf"; filename*=UTF-8''f%C3%BCr.pdf)
    end

    test "4-byte codepoint yields a single underscore in the fallback", %{token: token} do
      id = install("application/pdf", filename: "a😀.pdf")
      assert String.starts_with?(cd(download(@v3_download, id, token)), ~s(attachment; filename="a_.pdf"; filename*=))
    end

    test "an empty {fileName} path segment falls back to the stored filename", %{token: token} do
      id = install("application/pdf", filename: "stored.pdf")
      conn = download(@v3_download, id, token, "/")
      assert conn.status == 200
      assert cd(conn) == ~s(attachment; filename="stored.pdf")
    end

    test "a path segment that sanitizes to empty falls back to the stored filename", %{token: token} do
      id = install("application/pdf", filename: "stored.pdf")
      conn = download(@v3_download, id, token, "/%E2%80%AE")
      assert conn.status == 200
      assert cd(conn) == ~s(attachment; filename="stored.pdf")
    end
  end

end

defmodule Nebu.Media.ResponseFilenameLookupTest do
  @moduledoc """
  AC4 (real Postgres, `:integration`): `Nebu.Media.DB.lookup/2` must read the
  `media_files.filename` column (migration 000025 already provides it — no new
  migration needed). `@sql_lookup` selects it, so the key is present in the
  returned row map.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Media.DB
  alias Nebu.Media.StateMachine

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  defp media_id(suffix), do: "rct_lookup_#{@run_id}_#{suffix}"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (see quick.sh / make test-integration)")
    end

    :ok
  end

  defp persist!(id, filename) do
    on_exit(fn ->
      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_state_transitions WHERE media_id = $1", [id])
      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_files WHERE media_id = $1", [id])
    end)

    {:ok, ^id} =
      StateMachine.create_quarantined(%{media_id: id, server_name: "test.local", uploader_user_id: "@uploader:test.local"})

    :ok =
      DB.persist_upload(%{
        media_id: id,
        storage_key: "storage/#{id}",
        file_hash: "sha256-fixture-#{id}",
        compressed: false,
        content_type: "application/pdf",
        filename: filename,
        aes_key_hex: String.duplicate("ab", 32),
        nonce_hex: String.duplicate("cd", 12),
        file_size: 123
      })
  end

  test "lookup/2 returns the persisted upload filename" do
    id = media_id("named")
    persist!(id, "Bericht Ü \"1\".pdf")

    assert {:ok, row} = DB.lookup("test.local", id)

    assert Map.has_key?(row, :filename),
           "Nebu.Media.DB.lookup/2 must return a :filename key — @sql_lookup does not select media_files.filename"

    assert Enum.into(row, %{})[:filename] == "Bericht Ü \"1\".pdf"
  end

  test "lookup/2 returns filename nil for an upload without a filename" do
    id = media_id("unnamed")
    persist!(id, nil)

    assert {:ok, row} = DB.lookup("test.local", id)
    assert Map.has_key?(row, :filename), "lookup/2 must return a :filename key (nil when none was uploaded)"
    assert Enum.into(row, %{})[:filename] == nil
  end
end
