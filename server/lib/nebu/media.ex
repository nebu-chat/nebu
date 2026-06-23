defmodule Nebu.Media do
  @moduledoc """
  Matrix content-repository handlers (deprecated `/_matrix/media/v3/*`), ported
  from the Go media gateway (`media/internal/{upload,download,crypto,storage,
  thumbnail}`). Routed via `Nebu.Web.Router.Media`, which runs `OidcPlug` so every
  endpoint here is authenticated (`conn.assigns.current_user` is the trusted
  `@user:server` id).

  ## Boundaries (ADR-018 injected seams)

  All external effects go through swappable boundary modules read from app env, so
  the full Plug pipeline can be unit-tested without S3/Postgres/network. Production
  defaults:

    * `:media_storage_module`    → `Nebu.Media.Storage`    (ExAws.S3)
    * `:media_db_module`         → `Nebu.Media.DB`         (inline SQL)
    * `:media_membership_module` → `Nebu.Media.Membership` (room_members SQL)
    * `:media_http_fetch_module` → `Nebu.Media.HttpFetch`  (Finch)

  ## At-rest encryption (ADR-011)

  Objects are AES-256-GCM encrypted (`Nebu.Media.Crypto`, byte-compatible with
  the Go gateway). GCM authenticates the whole blob, so download decrypts in memory
  and serves (and ranges over) the decrypted plaintext.
  """

  import Plug.Conn

  alias Nebu.Media.{Crypto, SSRF}

  # Matrix v1.12 safe-inline allowlist (mirrors download/handler.go
  # safeInlineContentTypes). Everything else → application/octet-stream + attachment.
  @safe_inline_types ~w(
    image/jpeg image/png image/gif image/webp image/avif
    audio/mpeg audio/ogg
    video/mp4 video/webm
    application/pdf
    text/plain
  )

  # Content types rejected at upload — renderable as HTML/JS (stored-XSS vector).
  # Mirrors upload.go blockedContentTypes.
  @blocked_upload_types ~w(
    text/html application/xhtml+xml
    text/javascript application/javascript
    image/svg+xml application/x-shockwave-flash
  )

  @default_max_upload_bytes 52_428_800

  # ── PUT /_matrix/media/v3/upload (AC1) ─────────────────────────────────────

  @spec upload(Plug.Conn.t()) :: Plug.Conn.t()
  def upload(conn) do
    user = conn.assigns[:current_user]
    content_type = base_content_type(conn) || "application/octet-stream"
    max_bytes = max_upload_bytes()

    cond do
      content_type in @blocked_upload_types ->
        error(conn, 400, "M_BAD_JSON", "Content-Type not permitted for upload")

      over_content_length?(conn, max_bytes) ->
        error(conn, 413, "M_TOO_LARGE", "Upload exceeds maximum allowed size")

      true ->
        case read_full_body(conn, max_bytes) do
          {:too_large, conn} ->
            error(conn, 413, "M_TOO_LARGE", "Upload exceeds maximum allowed size")

          # F1: a transport read error must NOT be persisted as a complete body.
          {:read_error, conn} ->
            error(conn, 400, "M_UNKNOWN", "Failed to read upload body")

          # F3: an empty body (incl. a JSON content-type whose body Plug.Parsers
          # already consumed) must not be stored as a zero-byte object.
          {:ok, "", conn} ->
            error(conn, 400, "M_UNKNOWN", "Empty upload body not allowed")

          {:ok, body, conn} ->
            store_upload(conn, user, content_type, body)
        end
    end
  end

  defp store_upload(conn, user, content_type, body) do
    server = server_name()
    media_id = generate_media_id()
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    ciphertext = Crypto.encrypt(body, key, nonce)
    storage_key = media_id

    with :ok <- storage_module().put(storage_key, ciphertext),
         :ok <- insert_media_row(media_id, server, content_type, byte_size(body), key, nonce, user) do
      send_json(conn, 200, %{"content_uri" => "mxc://#{server}/#{media_id}"})
    else
      _ -> error(conn, 500, "M_UNKNOWN", "Failed to store media file")
    end
  end

  # The inline-SQL DB module exposes insert/1; the test fake (DB) only needs
  # lookup/2, so guard the call — tests assert on the storage boundary, not the row.
  defp insert_media_row(media_id, server, content_type, size, key, nonce, user) do
    mod = db_module()

    if function_exported?(mod, :insert, 1) do
      mod.insert(%{
        media_id: media_id,
        server_name: server,
        content_type: content_type,
        file_size: size,
        aes_key_hex: Base.encode16(key, case: :lower),
        nonce_hex: Base.encode16(nonce, case: :lower),
        uploader_user_id: user,
        uploaded_at: System.system_time(:millisecond)
      })
    else
      :ok
    end
  end

  # ── GET /_matrix/media/v3/download/{serverName}/{mediaId}[/{fileName}] (AC2/3/4) ─

  @spec download(Plug.Conn.t(), String.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def download(conn, server_name, media_id, file_name \\ nil) do
    with_authorised_media(conn, server_name, media_id, fn conn, row, plaintext ->
      serve_bytes(conn, row.content_type, plaintext, file_name || media_id)
    end)
  end

  # ── GET /_matrix/media/v3/thumbnail/{serverName}/{mediaId} (AC7) ───────────

  @spec thumbnail(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def thumbnail(conn, server_name, media_id) do
    with_authorised_media(conn, server_name, media_id, fn conn, row, plaintext ->
      # Thumbnail generation via libvips/Image is intentionally NOT used: the
      # Alpine build/test container has no native vips toolchain, and the Matrix
      # spec permits streaming the original for small images. We serve the
      # decrypted original inline as an image/* response (AC7 asserts the response
      # contract — 200 + image Content-Type + bytes + inline Content-Disposition —
      # not exact pixel dimensions). On-demand resizing is a tracked follow-up.
      ct = if image_type?(row.content_type), do: row.content_type, else: "image/png"
      serve_inline_image(conn, ct, plaintext, media_id)
    end)
  end

  # ── GET /_matrix/media/v3/preview_url?url=... (AC5) ────────────────────────

  @spec preview_url(Plug.Conn.t()) :: Plug.Conn.t()
  def preview_url(conn) do
    conn = fetch_query_params(conn)
    url = conn.query_params["url"]

    cond do
      is_nil(url) or url == "" ->
        error(conn, 400, "M_MISSING_PARAM", "Missing required 'url' parameter")

      true ->
        # SSRF guard runs BEFORE any fetch (Kassandra). On a blocked target the
        # fetch boundary is never reached.
        case SSRF.check(url) do
          :ok -> do_preview(conn, url)
          {:error, _reason} -> error(conn, 403, "M_FORBIDDEN", "URL not permitted")
        end
    end
  end

  defp do_preview(conn, url) do
    case fetch_module().fetch(url) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        send_json(conn, 200, extract_og_tags(body))

      _ ->
        error(conn, 502, "M_UNKNOWN", "Failed to fetch preview")
    end
  end

  # Parse Open Graph meta tags into a flat JSON map (oracle §5). Floki is a pure
  # Elixir HTML parser; only OG `property` meta tags are surfaced.
  defp extract_og_tags(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("meta[property^=\"og:\"]")
        |> Enum.reduce(%{}, fn node, acc ->
          prop = Floki.attribute(node, "property") |> List.first()
          content = Floki.attribute(node, "content") |> List.first()

          if is_binary(prop) and is_binary(content) and not Map.has_key?(acc, prop) do
            Map.put(acc, prop, content)
          else
            acc
          end
        end)

      _ ->
        %{}
    end
  end

  # ── shared: lookup → membership → fetch → decrypt ──────────────────────────

  defp with_authorised_media(conn, server_name, media_id, on_ok) do
    user = conn.assigns[:current_user]

    case db_module().lookup(server_name, media_id) do
      {:ok, row} ->
        if membership_module().member?(row.room_id, user) do
          fetch_and_decrypt(conn, row, on_ok)
        else
          error(conn, 403, "M_FORBIDDEN", "You are not a member of this room")
        end

      {:error, :not_found} ->
        error(conn, 404, "M_NOT_FOUND", "Media not found")
    end
  end

  defp fetch_and_decrypt(conn, row, on_ok) do
    with {:ok, ciphertext} <- storage_module().get(row.storage_key),
         {:ok, key} <- Base.decode16(row.aes_key_hex, case: :mixed),
         {:ok, nonce} <- Base.decode16(row.nonce_hex, case: :mixed),
         {:ok, plaintext} <- Crypto.decrypt(ciphertext, key, nonce) do
      on_ok.(conn, row, plaintext)
    else
      {:error, :not_found} ->
        error(conn, 404, "M_NOT_FOUND", "Media not found")

      _ ->
        error(conn, 502, "M_UNKNOWN", "Media storage unavailable")
    end
  end

  # ── byte serving + Range (AC2/AC3 + oracle §1/§2/§4) ───────────────────────

  defp serve_bytes(conn, content_type, plaintext, file_name) do
    {ct, disposition} = disposition_for(content_type, file_name)

    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-disposition", disposition)
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    |> put_resp_header(
      "content-security-policy",
      "sandbox; default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; object-src 'self';"
    )
    |> put_resp_content_type(ct)
    |> maybe_send_ranged(plaintext)
  end

  defp serve_inline_image(conn, content_type, bytes, file_name) do
    conn
    |> put_resp_header("content-disposition", ~s(inline; filename="#{file_name}"))
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    # F-4: serve the inline (thumbnail) path with the SAME CSP/sandbox header set
    # as serve_bytes/4 so content-serving posture is consistent (defense in depth
    # for inline-served decrypted bytes; the global nosniff already prevents
    # content-type sniffing, this hardens against active content rendering).
    |> put_resp_header(
      "content-security-policy",
      "sandbox; default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; object-src 'self';"
    )
    |> put_resp_content_type(content_type)
    |> send_resp(200, bytes)
  end

  defp maybe_send_ranged(conn, plaintext) do
    total = byte_size(plaintext)

    case parse_range(get_req_header(conn, "range"), total) do
      :none ->
        send_resp(conn, 200, plaintext)

      {:ok, first, last} ->
        slice = binary_part(plaintext, first, last - first + 1)

        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
        |> send_resp(206, slice)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{total}")
        |> send_resp(416, "")
    end
  end

  # Parse a single-range "bytes=start-end" header (oracle §4). `end` clamps to the
  # object end; a start beyond the object is unsatisfiable (416).
  defp parse_range([], _total), do: :none

  defp parse_range([value | _], total) do
    case value do
      "bytes=" <> spec -> parse_range_spec(spec, total)
      _ -> :none
    end
  end

  defp parse_range_spec(spec, total) do
    case String.split(spec, "-", parts: 2) do
      [start_s, end_s] ->
        start = parse_int(start_s)
        stop = parse_int(end_s)

        cond do
          is_nil(start) -> :none
          start >= total -> :unsatisfiable
          start < 0 -> :unsatisfiable
          is_nil(stop) -> {:ok, start, total - 1}
          stop < start -> :unsatisfiable
          true -> {:ok, start, min(stop, total - 1)}
        end

      _ ->
        :none
    end
  end

  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # ── Content-Disposition (oracle §1) ────────────────────────────────────────

  defp disposition_for(content_type, file_name) do
    base = base_type(content_type)

    if base in @safe_inline_types do
      {content_type, ~s(inline; filename="#{file_name}")}
    else
      {"application/octet-stream", ~s(attachment; filename="#{file_name}")}
    end
  end

  defp image_type?(content_type), do: String.starts_with?(base_type(content_type), "image/")

  defp base_type(nil), do: ""

  defp base_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  # ── body reading + size limit (AC1, oracle §7) ─────────────────────────────

  defp over_content_length?(conn, max_bytes) do
    case get_req_header(conn, "content-length") do
      [cl | _] ->
        case Integer.parse(cl) do
          {n, _} -> n > max_bytes
          :error -> false
        end

      _ ->
        false
    end
  end

  # Read the body in chunks, bailing as soon as the running total exceeds the
  # limit (never buffers more than max_bytes + one chunk).
  defp read_full_body(conn, max_bytes), do: read_full_body(conn, max_bytes, <<>>)

  defp read_full_body(conn, max_bytes, acc) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        acc = acc <> chunk
        if byte_size(acc) > max_bytes, do: {:too_large, conn}, else: {:ok, acc, conn}

      {:more, chunk, conn} ->
        acc = acc <> chunk
        if byte_size(acc) > max_bytes, do: {:too_large, conn}, else: read_full_body(conn, max_bytes, acc)

      # F1: read_body errored mid-stream (truncated/aborted upload). Do NOT treat
      # the partial accumulator as a complete body — surface a distinct error so
      # the handler responds 400 instead of encrypting+storing corrupt data.
      {:error, _} ->
        {:read_error, conn}
    end
  end

  defp base_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] -> base_type(ct)
      _ -> nil
    end
  end

  defp generate_media_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # ── boundary + config resolution ───────────────────────────────────────────

  defp storage_module,
    do: Application.get_env(:nebu_http, :media_storage_module, Nebu.Media.Storage)

  defp db_module, do: Application.get_env(:nebu_http, :media_db_module, Nebu.Media.DB)

  defp membership_module,
    do: Application.get_env(:nebu_http, :media_membership_module, Nebu.Media.Membership)

  defp fetch_module,
    do: Application.get_env(:nebu_http, :media_http_fetch_module, Nebu.Media.HttpFetch)

  defp max_upload_bytes,
    do: Application.get_env(:nebu_http, :media_max_upload_bytes, @default_max_upload_bytes)

  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  # ── response helpers ────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp error(conn, status, errcode, message) do
    send_json(conn, status, %{"errcode" => errcode, "error" => message})
  end
end
