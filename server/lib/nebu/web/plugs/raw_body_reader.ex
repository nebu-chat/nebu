defmodule Nebu.Web.Plugs.RawBodyReader do
  @moduledoc """
  `Plug.Parsers` `:body_reader` that additionally keeps the RAW request body in
  `conn.assigns[:raw_body]` for the account-data PUT routes and the room-tag PUT routes only
  (`PUT .../user/{u}/account_data/{type}`, `PUT .../user/{u}/rooms/{r}/account_data/{type}`,
  `PUT .../user/{u}/rooms/{r}/tags[/{tag}]`).

  Account data is opaque client content (ADR-011) that must round-trip byte-exact; the
  parsed `body_params` map would lose key order/whitespace. Caching is restricted to
  those routes (bounded by the 1 MB parser cap) so no other request pays the memory.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        if opaque_content_put?(conn),
          do: {:ok, body, Plug.Conn.assign(conn, :raw_body, body)},
          else: {:ok, body, conn}

      other ->
        other
    end
  end

  @doc """
  True for the EXACT account-data path shapes (global and room scope), any method:

      /_matrix/client/{version}/user/{u}/account_data/{type}
      /_matrix/client/{version}/user/{u}/rooms/{r}/account_data/{type}

  Deliberately NOT "any path with an `account_data` segment": a room id, state key,
  event type or txn id may be literally `account_data` and must not opt a route into the
  account-data body handling. Shared by `JsonBody`, this reader and the `RequestLogger`
  so the three can never drift apart.

  Accepts either a path string (`conn.request_path`) or a list of raw segments
  (`conn.path_info`). Segments are normalized EXACTLY like `Plug.Router` does before it
  matches a route: empty segments are dropped (`//`, trailing slash) and every segment is
  `URI.decode`d (so `%61ccount_data` is `account_data`). Invalid percent-encoding never
  raises; the raw segment is kept (the router rejects such a path itself).
  """
  @spec account_data_shape?(String.t() | [String.t()]) :: boolean()
  def account_data_shape?(path) when is_binary(path), do: path |> String.split("/") |> account_data_shape?()

  def account_data_shape?(segments) when is_list(segments) do
    segments
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&safe_decode/1)
    |> shape?()
  end

  defp shape?(["_matrix", "client", _version, "user", _u, "account_data", _type]), do: true
  defp shape?(["_matrix", "client", _version, "user", _u, "rooms", _r, "account_data", _type]), do: true
  defp shape?(_), do: false

  @doc """
  True for the EXACT room-tag path shapes (any method), normalized like `account_data_shape?/1`:

      /_matrix/client/{version}/user/{u}/rooms/{r}/tags
      /_matrix/client/{version}/user/{u}/rooms/{r}/tags/{tag}
  """
  @spec room_tags_shape?(String.t() | [String.t()]) :: boolean()
  def room_tags_shape?(path) when is_binary(path), do: path |> String.split("/") |> room_tags_shape?()

  def room_tags_shape?(segments) when is_list(segments) do
    segments
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&safe_decode/1)
    |> tags_shape?()
  end

  defp tags_shape?(["_matrix", "client", _version, "user", _u, "rooms", _r, "tags"]), do: true
  defp tags_shape?(["_matrix", "client", _version, "user", _u, "rooms", _r, "tags", _tag]), do: true
  defp tags_shape?(_), do: false

  @doc """
  True for every route whose bodies are opaque USER CONTENT that must never be logged:
  the account-data shapes and the room-tag shapes. Used by the `RequestLogger`.
  """
  @spec opaque_content_shape?(String.t() | [String.t()]) :: boolean()
  def opaque_content_shape?(path), do: account_data_shape?(path) or room_tags_shape?(path)

  @doc """
  True for every path under `/_matrix/client/{version}/room_keys` (the server-side key backup, story server-side-key-backup), any method, normalized like
  `account_data_shape?/1`. Their bodies (`auth_data`, `session_data`) are client-encrypted USER CONTENT: the `RequestLogger` never captures them. Deliberately
  NOT part of `opaque_content_shape?/1` / `opaque_content_put?/1`: the raw body is not cached and an oversize body is answered by `JsonBody` itself.
  """
  @spec room_keys_shape?(String.t() | [String.t()]) :: boolean()
  def room_keys_shape?(path) when is_binary(path), do: path |> String.split("/") |> room_keys_shape?()

  def room_keys_shape?(segments) when is_list(segments) do
    case segments |> Enum.reject(&(&1 == "")) |> Enum.map(&safe_decode/1) do
      ["_matrix", "client", _version, "room_keys" | _] -> true
      _ -> false
    end
  end

  @doc """
  True for every path under `/_matrix/client/{version}/sendToDevice` (story to-device-messaging), any method, normalized like `account_data_shape?/1`.
  The message contents are client-encrypted (Olm) or key material: the `RequestLogger` never captures them.
  """
  @spec to_device_shape?(String.t() | [String.t()]) :: boolean()
  def to_device_shape?(path) when is_binary(path), do: path |> String.split("/") |> to_device_shape?()

  def to_device_shape?(segments) when is_list(segments) do
    case segments |> Enum.reject(&(&1 == "")) |> Enum.map(&safe_decode/1) do
      ["_matrix", "client", _version, "sendToDevice" | _] -> true
      _ -> false
    end
  end

  @doc """
  True for `POST /_matrix/client/{version}/keys/claim`, `.../keys/upload` (story device-key-directory), `.../keys/query`, `.../keys/signatures/upload`
  (story key-query-hardening, D11) and `.../keys/device_signing/upload` (story e2ee-compliance-channel-guard, D4: master / self-signing / user-signing keys), any method, normalized like `account_data_shape?/1`. The bodies carry KEY MATERIAL (one-time keys, fallback keys, device keys, signatures; the claim answer hands the keys out): the
  `RequestLogger` never captures a request or a response body of these routes.
  """
  @spec key_material_shape?(String.t() | [String.t()]) :: boolean()
  def key_material_shape?(path) when is_binary(path), do: path |> String.split("/") |> key_material_shape?()

  def key_material_shape?(segments) when is_list(segments) do
    case segments |> Enum.reject(&(&1 == "")) |> Enum.map(&safe_decode/1) do
      ["_matrix", "client", _version, "keys", name] when name in ["claim", "upload", "query"] -> true
      ["_matrix", "client", _version, "keys", "signatures", "upload"] -> true
      ["_matrix", "client", _version, "keys", "device_signing", "upload"] -> true
      _ -> false
    end
  end

  @doc "True for `GET /_matrix/client/{version}/keys/changes`: its query carries sync tokens (the `RequestLogger` logs the parameter names only)."
  @spec key_changes_shape?(String.t() | [String.t()]) :: boolean()
  def key_changes_shape?(path) when is_binary(path), do: path |> String.split("/") |> key_changes_shape?()

  def key_changes_shape?(segments) when is_list(segments) do
    case segments |> Enum.reject(&(&1 == "")) |> Enum.map(&safe_decode/1) do
      ["_matrix", "client", _version, "keys", "changes"] -> true
      _ -> false
    end
  end

  @doc "True for a `PUT` on an account-data or room-tag path shape (raw body kept, 413 rendered by the handler)."
  @spec opaque_content_put?(Plug.Conn.t()) :: boolean()
  def opaque_content_put?(%Plug.Conn{method: "PUT", path_info: path_info}), do: opaque_content_shape?(path_info)
  def opaque_content_put?(_conn), do: false

  defp safe_decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end
end
