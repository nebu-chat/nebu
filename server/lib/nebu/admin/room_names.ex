defmodule Nebu.Admin.RoomNames do
  @moduledoc """
  Display name of a room on the admin pages (rooms index and room detail), one shared implementation.

  A room with an explicit `name` is shown verbatim. A room without one gets a fallback computed from its
  joined members, like Matrix clients do (story `admin-rooms-fallback-name`):

    * 0 members            -> `"(empty room)"`
    * 1..4 members         -> the member names joined with `" & "` (`"Alice & Bob"`)
    * more than 4 members  -> `"(N members)"` (never a list of names: bounded text)

  A member is shown by `profiles.displayname`, or by the localpart of the Matrix user id when there is no
  profile row or the display name is blank. When the caller did not load the member information at all
  (no `:member_count`), the raw `room_id` is shown as before.

  Display names are user-controlled. `member_names_by_room/1` therefore strips control, bidi-override, zero-width
  and other invisible format characters, treats a name without any visible character as blank (the localpart is
  shown instead), collapses whitespace and caps every name (32 characters) and the whole fallback (120
  characters). The text is returned unescaped; the HEEx templates escape it on output, it must never be
  rendered raw.

  ADR-018: SQL inline, no repository layer. Only display names / localparts are read: the same data the
  admin member list already shows.
  """

  require Logger

  # Rooms with at most this many joined members are named after their members.
  @name_listing_threshold 4
  @max_member_name_length 32
  @max_name_length 120
  # raw display names are cut to this many bytes before anything else (see truncate_bytes/2)
  @max_input_bytes 512
  @ellipsis "…"

  # One statement for any number of rooms: the first `@name_listing_threshold` joined members of every
  # listed room by a stable order (join time, then user id). `room_members` is read through its primary key
  # (room_id, user_id), `profiles` through its primary key (user_id).
  @sql_member_names """
  SELECT room_id, user_id, displayname
  FROM (
    SELECT rm.room_id, rm.user_id, p.displayname,
           row_number() OVER (PARTITION BY rm.room_id ORDER BY rm.joined_at, rm.user_id) AS rn
    FROM room_members rm
    LEFT JOIN profiles p ON p.user_id = rm.user_id
    WHERE rm.room_id = ANY($1) AND rm.left_at IS NULL
  ) t
  WHERE rn <= $2
  ORDER BY room_id, rn
  """

  @doc """
  The text to show for `room`: a map with `:room_id`, `:name`, and (for the fallback) `:member_count` and
  `:member_names` as set by `attach_member_names/1`.
  """
  @spec display_name(map()) :: String.t()
  def display_name(room) do
    name = Map.get(room, :name)

    if is_binary(name) and String.trim(name) != "" do
      name
    else
      fallback_name(room)
    end
  end

  defp fallback_name(room) do
    count = Map.get(room, :member_count)
    names = Map.get(room, :member_names)

    cond do
      count == 0 -> "(empty room)"
      is_integer(count) and count > @name_listing_threshold -> "(#{count} members)"
      is_list(names) and names != [] -> names |> Enum.join(" & ") |> cap(@max_name_length)
      true -> Map.fetch!(room, :room_id)
    end
  end

  @doc """
  Adds `:member_names` to every room of `rooms` (maps with `:room_id`, `:name`, `:member_count`).

  Rooms that need names (no explicit name, 1..#{@name_listing_threshold} members) are resolved with ONE
  query for the whole list; no query at all when none needs one. A failing query is logged and leaves
  those rooms without names (the page then shows the room id) instead of failing the page.
  """
  @spec attach_member_names([map()]) :: [map()]
  def attach_member_names(rooms) do
    ids = for room <- rooms, needs_names?(room), do: room.room_id
    by_room = member_names_by_room(ids)

    Enum.map(rooms, fn room -> Map.put(room, :member_names, Map.get(by_room, room.room_id, [])) end)
  end

  defp needs_names?(room) do
    count = Map.get(room, :member_count)
    name = Map.get(room, :name)

    (is_nil(name) or String.trim(name) == "") and is_integer(count) and count >= 1 and
      count <= @name_listing_threshold
  end

  @doc """
  `%{room_id => [name]}` with up to #{@name_listing_threshold} sanitised member names per room, in a stable
  order, for all `room_ids` in one query.
  """
  @spec member_names_by_room([String.t()]) :: %{String.t() => [String.t()]}
  def member_names_by_room([]), do: %{}

  def member_names_by_room(room_ids) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_member_names, [room_ids, @name_listing_threshold]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.group_by(fn [room_id, _, _] -> room_id end, fn [_, user_id, displayname] ->
          member_label(user_id, displayname)
        end)

      {:error, error} ->
        Logger.warning("admin rooms: member name lookup failed: #{Exception.message(error)}")
        %{}
    end
  end

  @doc false
  # Name of one member: sanitised display name, else sanitised localpart, else the sanitised user id.
  @spec member_label(String.t(), String.t() | nil) :: String.t()
  def member_label(user_id, displayname) do
    [displayname, localpart(user_id), user_id]
    |> Enum.map(&sanitize/1)
    |> Enum.find("(unknown)", &(&1 != ""))
    |> cap(@max_member_name_length)
  end

  # "@alice:example.org" -> "alice"
  defp localpart(user_id) when is_binary(user_id) do
    user_id |> String.trim_leading("@") |> String.split(":", parts: 2) |> hd()
  end

  defp localpart(_), do: ""

  # Invisible "filler" letters / symbols (Hangul fillers, braille blank, musical null notehead): they are not
  # format characters, but a name made only of them renders blank.
  @filler_chars ~r/[\x{115F}\x{1160}\x{3164}\x{FFA0}\x{2800}\x{1D159}]/u
  # The one thing that makes a name visible: a letter, number, symbol or punctuation character.
  @visible_char ~r/[\p{L}\p{N}\p{S}\p{P}]/u

  @doc false
  # Whitespace runs (incl. newline / tab) become one space. Control characters and ALL invisible format
  # characters (\p{Cf}: bidi overrides / isolates, direction marks, soft hyphen, zero-width space, word joiner /
  # invisible operators, BOM, interlinear annotation marks, tag characters, ...) are dropped, except ZWJ / ZWNJ
  # (U+200D / U+200C), which real text needs (emoji sequences, Persian, Indic scripts). Joiners are collapsed to
  # one in a row and are transparent for the combining-mark limit. A result without any letter, number, symbol or
  # punctuation character (only joiners, fillers, combining marks, ...) is "" so the caller falls back.
  # Known trade-off: dropping the tag characters turns the England / Scotland / Wales flag emoji into a plain
  # black flag, and dropping all of \p{Cf} also removes the rare Arabic number signs (U+0600-0605).
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(value) when is_binary(value) do
    if String.valid?(value) do
      cleaned =
        value
        |> truncate_bytes(@max_input_bytes)
        |> String.replace(~r/\s+/u, " ")
        |> String.replace(~r/\p{Cc}|[\x{E0000}-\x{E007F}]|(?![\x{200C}\x{200D}])\p{Cf}/u, "")
        # a run of joiners is one joiner
        |> String.replace(~r/([\x{200C}\x{200D}])[\x{200C}\x{200D}]+/u, "\\1")
        # at most 3 combining marks per character, counted across joiners: a "Zalgo" grapheme with thousands
        # of marks would pass the grapheme cap but not bound the rendered height / byte size
        |> String.replace(~r/(\p{M}(?:[\x{200C}\x{200D}]?\p{M}){2})(?:[\x{200C}\x{200D}]?\p{M})+/u, "\\1")
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      if visible?(cleaned), do: cleaned, else: ""
    else
      ""
    end
  end

  def sanitize(_), do: ""

  defp visible?(text), do: text |> String.replace(@filler_chars, "") |> String.match?(@visible_char)

  # The grapheme caps below do not bound the size: characters that never start a new grapheme (ZWJ,
  # emoji modifiers, tag characters, combining marks) can chain into one "character" of any length. So the
  # input is first cut to `max` bytes (at a codepoint boundary), which also bounds the regex work.
  defp truncate_bytes(value, max) when byte_size(value) <= max, do: value

  defp truncate_bytes(value, max) do
    # a utf8 generator stops at the first byte sequence that is not a whole codepoint (the cut one)
    for <<cp::utf8 <- binary_part(value, 0, max)>>, into: "", do: <<cp::utf8>>
  end

  # Cut to `max` graphemes including the ellipsis.
  defp cap(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 1) <> @ellipsis
    else
      text
    end
  end
end
