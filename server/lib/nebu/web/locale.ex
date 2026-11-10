defmodule Nebu.Web.Locale do
  @moduledoc """
  Language choice for the standalone Nebu pages (story oauth-pages-redesign/02): the first language
  of the `Accept-Language` header that is `de` or `en`, otherwise English.

  Rules:
    * Region tags count (`de-AT` is German); matching is case-insensitive.
    * q-values are honoured (highest q wins, ties go to the earlier entry); `q=0` means "not
      acceptable". An entry with a malformed q-value is ignored as a whole.
    * No cookie, no `?lang=`, no switch. The header value is parsed and NEVER echoed anywhere.
    * Anything unparsable falls back to `:en`; the header is bounded (1 KiB, 50 entries) so a huge
      value costs nothing.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @type t :: :en | :de

  @max_bytes 1024
  @max_entries 50
  @tag_re ~r/\A[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*\z/
  @q_re ~r/\A([01])(?:\.(\d{0,3}))?\z/

  @doc "The page language for this request: `:de` or `:en`."
  @spec from_conn(Plug.Conn.t()) :: t()
  def from_conn(%Plug.Conn{} = conn) do
    conn |> get_req_header("accept-language") |> Enum.join(",") |> from_header()
  end

  @doc "The page language for a raw `Accept-Language` value."
  @spec from_header(term()) :: t()
  def from_header(value) when is_binary(value) do
    candidates =
      value
      |> bound()
      |> String.split(",")
      |> Enum.take(@max_entries)
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} -> parse_entry(entry, index) end)

    case candidates do
      [] ->
        :en

      list ->
        {lang, _q, _index} = Enum.min_by(list, fn {_lang, q, index} -> {-q, index} end)
        lang
    end
  end

  def from_header(_other), do: :en

  # An over-long value is cut and its (possibly partial) last entry dropped.
  defp bound(value) when byte_size(value) > @max_bytes do
    value
    |> binary_part(0, @max_bytes)
    |> String.split(",")
    |> Enum.drop(-1)
    |> Enum.join(",")
  end

  defp bound(value), do: value

  defp parse_entry(entry, index) do
    [tag | params] = entry |> String.split(";") |> Enum.map(&String.trim/1)

    with true <- Regex.match?(@tag_re, tag),
         {:ok, q} <- parse_q(params),
         true <- q > 0,
         lang when lang in [:de, :en] <- primary(tag) do
      [{lang, q, index}]
    else
      _ -> []
    end
  end

  defp primary(tag) do
    case tag |> String.split("-", parts: 2) |> hd() |> String.downcase() do
      "de" -> :de
      "en" -> :en
      _ -> nil
    end
  end

  # q in thousandths; no q parameter means 1.0, a malformed one invalidates the entry.
  defp parse_q(params) do
    case Enum.find(params, &Regex.match?(~r/\Aq\s*=/i, &1)) do
      nil -> {:ok, 1000}
      param -> param |> String.split("=", parts: 2) |> List.last() |> String.trim() |> q_value()
    end
  end

  defp q_value(text) do
    case Regex.run(@q_re, text) do
      [_, int] -> within(String.to_integer(int) * 1000)
      [_, int, frac] -> within(String.to_integer(int) * 1000 + frac_value(frac))
      _ -> :error
    end
  end

  defp frac_value(""), do: 0
  defp frac_value(frac), do: frac |> String.pad_trailing(3, "0") |> String.to_integer()

  defp within(n) when n <= 1000, do: {:ok, n}
  defp within(_), do: :error
end
