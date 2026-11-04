defmodule Nebu.OAuth.DeviceName do
  @moduledoc """
  The default display name of the device an OAuth login creates (story oauth-device-default-display-name, REQ-2026-004).

  `"<base> (<suffix>)"`, e.g. `"FluffyChat (ABCD1234)"`:

    * base: the `client_name` of the APPROVED client record, sanitised and bounded; the plain `"OAuth client"` for a revoked / pending / rejected / unknown client,
      a record without a usable name, an unreadable database;
    * suffix: the last 8 characters of the device id after dropping everything outside `[A-Za-z0-9._-]` (a device id may legally contain markup characters);
      when nothing is left, the first 8 hex characters of the SHA-256 of the id.

  Sanitising of the base: tags `<...>` are removed with their brackets, remaining `<` / `>` are dropped, tab / newline / CR and Unicode space separators
  become one space, other control characters, format characters, line / paragraph separators, private-use and surrogate code points are dropped, runs of spaces
  collapse, the ends are trimmed, invisible-but-not-empty characters (U+3164, U+FFA0, U+115F, U+1160, U+2800, U+034F, U+FE00..U+FE0F) and combining marks without a base letter are dropped; the result is cut to `max_base_length/0` CODE POINTS and trimmed again. The name is plain text.

  The OAuth domain builds the name and hands it to the Matrix domain (`Nebu.Matrix.oauth_issue_session/1`), which writes it only for a device whose name is
  unset. Pure apart from `for_client/2`'s one read; never raises; this module does not log (the debug request logger's `GET /devices` body capture still shows
  device names; see `docs/stories/oauth-session-and-consent/follow-ups.md`).

  Cosmetic trade-offs, accepted: the zero width joiner is dropped (format character), so ZWJ emoji sequences split into separate emoji; the cut at 64 code points
  can split a combining sequence or a flag pair; there is no Unicode normalisation (NFC); VT, FF and NEL are dropped, not turned into a space.
  """

  alias Nebu.OAuth.ClientStore

  @fallback "OAuth client"
  @max_base 64
  @suffix_len 8

  @doc "The base used when no usable client name exists."
  @spec fallback_base() :: String.t()
  def fallback_base, do: @fallback

  @doc "The maximum length of the base, in Unicode code points."
  @spec max_base_length() :: pos_integer()
  def max_base_length, do: @max_base

  @doc "The default name for a login of `client_id` on `device_id` (reads the client record once; never raises)."
  @spec for_client(term(), term()) :: String.t()
  def for_client(client_id, device_id) do
    default_name(approved_name(client_id), device_id)
  rescue
    _ -> default_name(nil, device_id)
  catch
    _, _ -> default_name(nil, device_id)
  end

  @doc "`\"<base> (<suffix>)\"` for a claimed client name and a device id (any terms)."
  @spec default_name(term(), term()) :: String.t()
  def default_name(client_name, device_id), do: base(client_name) <> " (" <> suffix(device_id) <> ")"

  defp approved_name(client_id) when is_binary(client_id) do
    case ClientStore.fetch_by_client_id(client_id) do
      {:ok, %{status: "approved", metadata: %{"client_name" => name}}} -> name
      _ -> nil
    end
  end

  defp approved_name(_), do: nil

  defp base(name) when is_binary(name) do
    if String.valid?(name) do
      name
      |> String.replace(~r/<[^>]*>/u, "")
      |> String.replace(["<", ">"], "")
      |> String.replace(~r/[\t\n\r\p{Zs}]/u, " ")
      |> String.replace(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cs}]/u, "")
      # invisible but not empty: Hangul fillers, Braille blank, combining grapheme joiner, variation selectors
      |> String.replace(~r/[\x{3164}\x{FFA0}\x{115F}\x{1160}\x{2800}\x{034F}\x{FE00}-\x{FE0F}]/u, "")
      |> String.replace(~r/ +/, " ")
      |> String.trim()
      # a combining mark with no base letter (at the start or after a space) is dropped
      |> String.replace(~r/(^| )\p{M}+/u, "\\1")
      |> String.replace(~r/ +/, " ")
      |> String.trim()
      |> String.codepoints()
      |> Enum.take(@max_base)
      |> Enum.join()
      |> String.trim()
      |> case do
        "" -> @fallback
        clean -> clean
      end
    else
      @fallback
    end
  end

  defp base(_), do: @fallback

  defp suffix(device_id) do
    safe = if is_binary(device_id), do: String.replace(device_id, ~r/[^A-Za-z0-9._-]/, ""), else: ""

    case safe do
      "" ->
        raw = if is_binary(device_id), do: device_id, else: ""
        :crypto.hash(:sha256, raw) |> Base.encode16() |> binary_part(0, @suffix_len)

      s ->
        if byte_size(s) > @suffix_len, do: binary_part(s, byte_size(s) - @suffix_len, @suffix_len), else: s
    end
  end
end
