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

  ## Story `oauth-pages-redesign/01-device-naming-chain` (REQ-2026-016)

  The name is decided in this order, first usable source wins (a name the client sets itself through `PUT /devices/{id}` always replaces the result later):

    1. the sanitised `client_name` of the approved client, unless it is generic (`generic_names/0`, case-insensitive, trimmed): `"<base> (<suffix>)"`;
    2. the host of the registered `client_uri` (https only, lower case, no port): `"<host> (<suffix>)"`;
    3. a name the user typed on the Allow page (`typed/1`): stored exactly as typed after sanitising, WITHOUT a suffix.

  `derive/2` is steps 1 and 2, `plan/3` adds what the device already carries (shown on the Allow page; the remembered-Allow decision asks the same question),
  `for_client/3` is the final decision at the token endpoint. When nothing is usable and nothing was typed the plain `"OAuth client (<suffix>)"` remains.

  Cosmetic trade-offs, accepted: the zero width joiner is dropped (format character), so ZWJ emoji sequences split into separate emoji; the cut at 64 code points
  can split a combining sequence or a flag pair; there is no Unicode normalisation (NFC); VT, FF and NEL are dropped, not turned into a space.
  """

  alias Nebu.OAuth.ClientStore

  @fallback "OAuth client"
  @max_base 64
  @suffix_len 8
  # Names of apps that tell nothing (compared case-insensitive after sanitising and trimming).
  @generic ["oauth client", "client", "app", "application", "unknown", "test"]
  # The raw typed value is cut before any regex runs (a hostile body is bounded by the form parser to 16 KiB anyway).
  @max_typed_raw 512
  @host_regex ~r/\A[a-z0-9]([a-z0-9.\-]*[a-z0-9])?\z/

  @doc "The client names that are too generic to name a device (lower case)."
  @spec generic_names() :: [String.t()]
  def generic_names, do: @generic

  @doc """
  Steps 1 and 2 of the chain for the registered metadata of an approved client: `{:ok, "<base> (<suffix>)"}` from a usable `client_name`, else from the
  https host of `client_uri`, else `:ask`. Pure, never raises.
  """
  @spec derive(term(), term()) :: {:ok, String.t()} | :ask
  def derive(%{} = metadata, device_id) do
    case usable_client_name(metadata["client_name"]) do
      {:ok, base} ->
        {:ok, base <> " (" <> suffix(device_id) <> ")"}

      :none ->
        case website_host(metadata["client_uri"]) do
          {:ok, host} -> {:ok, host <> " (" <> suffix(device_id) <> ")"}
          :none -> :ask
        end
    end
  end

  def derive(_metadata, _device_id), do: :ask

  @doc """
  What the device will be called, for the Allow page and the remembered-Allow decision: `{:existing, name}` when the device already carries a name (it is never
  overwritten), `{:derived, name}` from the client record, or `:ask` (the user must type a name). `existing` is the stored display name or nil.
  Any stored string counts as a name, a blank one (`""`, whitespace only) included: it was SET, so it is returned verbatim and never replaced
  (story matrix-put-device-keeps-display-name). Only nil (or a non-string) means "no name".
  """
  @spec plan(term(), term(), term()) :: {:existing, String.t()} | {:derived, String.t()} | :ask
  def plan(metadata, device_id, existing) do
    if is_binary(existing) do
      {:existing, existing}
    else
      case derive(metadata, device_id) do
        {:ok, name} -> {:derived, name}
        :ask -> :ask
      end
    end
  end

  @doc """
  A name the user typed: `{:ok, name}` sanitised exactly like a client name (bounded to `max_base_length/0` code points), or `:none` when nothing visible is
  left or the value is no string. No suffix is added.
  """
  @spec typed(term()) :: {:ok, String.t()} | :none
  def typed(raw) when is_binary(raw) do
    if String.valid?(raw) do
      case raw |> String.slice(0, @max_typed_raw) |> clean() do
        "" -> :none
        name -> {:ok, name}
      end
    else
      :none
    end
  end

  def typed(_raw), do: :none

  @doc "The base used when no usable client name exists."
  @spec fallback_base() :: String.t()
  def fallback_base, do: @fallback

  @doc "The maximum length of the base, in Unicode code points."
  @spec max_base_length() :: pos_integer()
  def max_base_length, do: @max_base

  @doc """
  The name for a login of `client_id` on `device_id` (reads the client record once; never raises): the name the user `typed` on the Allow page (stored by the
  code row; nil = none), else the derived name of the approved client, else the plain `"OAuth client (<suffix>)"`.
  """
  @spec for_client(term(), term(), term()) :: String.t()
  def for_client(client_id, device_id, typed \\ nil) do
    case typed(typed) do
      {:ok, name} ->
        name

      :none ->
        case derive(approved_metadata(client_id), device_id) do
          {:ok, name} -> name
          :ask -> default_name(nil, device_id)
        end
    end
  rescue
    _ -> default_name(nil, device_id)
  catch
    _, _ -> default_name(nil, device_id)
  end

  @doc "`\"<base> (<suffix>)\"` for a claimed client name and a device id (any terms)."
  @spec default_name(term(), term()) :: String.t()
  def default_name(client_name, device_id), do: base(client_name) <> " (" <> suffix(device_id) <> ")"

  defp approved_metadata(client_id) when is_binary(client_id) do
    case ClientStore.fetch_by_client_id(client_id) do
      {:ok, %{status: "approved", metadata: %{} = metadata}} -> metadata
      _ -> nil
    end
  end

  defp approved_metadata(_), do: nil

  defp usable_client_name(name) do
    case clean(name) do
      "" -> :none
      clean -> if String.downcase(clean) in @generic, do: :none, else: {:ok, clean}
    end
  end

  defp website_host(uri) when is_binary(uri) do
    with true <- String.valid?(uri),
         %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(String.trim(uri)),
         host = String.downcase(host),
         true <- Regex.match?(@host_regex, host) do
      {:ok, host |> String.codepoints() |> Enum.take(@max_base) |> Enum.join() |> String.trim_trailing(".")}
    else
      _ -> :none
    end
  end

  defp website_host(_uri), do: :none

  defp base(name) do
    case clean(name) do
      "" -> @fallback
      clean -> clean
    end
  end

  # The sanitised text of a name, "" when nothing usable is left (or no valid string).
  defp clean(name) when is_binary(name) do
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
    else
      ""
    end
  end

  defp clean(_), do: ""

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
