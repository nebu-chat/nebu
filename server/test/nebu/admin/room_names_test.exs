defmodule Nebu.Admin.RoomNamesTest do
  @moduledoc """
  Unit tests (no DB) of the pure part of `Nebu.Admin.RoomNames` — story admin-rooms-fallback-name,
  AC1-AC6 and AC8. The rendered pages are covered by `Nebu.Admin.RoomsFallbackNameTest` (integration).
  """
  use ExUnit.Case, async: true

  alias Nebu.Admin.RoomNames

  defp room(attrs), do: Map.merge(%{room_id: "!r:test.local", name: ""}, Map.new(attrs))

  describe "display_name/1" do
    test "an explicit name is returned verbatim, whatever the members" do
      assert RoomNames.display_name(room(name: "Team Standup", member_count: 9, member_names: ["A"])) ==
               "Team Standup"

      assert RoomNames.display_name(room(name: "  padded  ")) == "  padded  "
    end

    test "1 to 4 members are joined with ' & '" do
      assert RoomNames.display_name(room(member_count: 1, member_names: ["Solo"])) == "Solo"
      assert RoomNames.display_name(room(member_count: 2, member_names: ["Alice", "Bob"])) == "Alice & Bob"

      assert RoomNames.display_name(room(member_count: 4, member_names: ~w(A B C D))) == "A & B & C & D"
    end

    test "more than 4 members give a count, never the names" do
      assert RoomNames.display_name(room(member_count: 5, member_names: [])) == "(5 members)"
      assert RoomNames.display_name(room(member_count: 120, member_names: ~w(A B C D))) == "(120 members)"
    end

    test "no members give '(empty room)'" do
      assert RoomNames.display_name(room(member_count: 0, member_names: [])) == "(empty room)"
    end

    test "blank or whitespace-only name counts as unnamed" do
      assert RoomNames.display_name(room(name: "   ", member_count: 0)) == "(empty room)"
      assert RoomNames.display_name(room(name: nil, member_count: 2, member_names: ["A", "B"])) == "A & B"
    end

    test "without member information the room id is shown (as before)" do
      assert RoomNames.display_name(room([])) == "!r:test.local"
      assert RoomNames.display_name(room(member_count: 2)) == "!r:test.local"
      assert RoomNames.display_name(room(member_count: 2, member_names: [])) == "!r:test.local"
    end

    test "the whole fallback is capped at 120 characters" do
      names = for i <- 1..4, do: String.duplicate("x", 32) <> to_string(i)
      text = RoomNames.display_name(room(member_count: 4, member_names: names))

      assert String.length(text) == 120
      assert String.ends_with?(text, "…")
    end
  end

  describe "member_label/2" do
    test "uses the display name" do
      assert RoomNames.member_label("@alice:test.local", "Alice") == "Alice"
    end

    test "falls back to the localpart for a missing, NULL or blank display name" do
      assert RoomNames.member_label("@bob:test.local", nil) == "bob"
      assert RoomNames.member_label("@bob:test.local", "") == "bob"
      assert RoomNames.member_label("@bob:test.local", "  \n\t ") == "bob"
      assert RoomNames.member_label("@bob:test.local", "\u202E\u0007") == "bob"
    end

    test "a user id without '@' or ':' still yields a name" do
      assert RoomNames.member_label("carol", nil) == "carol"
      assert RoomNames.member_label("@dave", nil) == "dave"
      assert RoomNames.member_label("@:test.local", nil) == "@:test.local"
    end

    test "never returns an empty string" do
      assert RoomNames.member_label("", "") == "(unknown)"
      assert RoomNames.member_label("@\u202E:x", nil) == "@:x"
    end

    test "strips control, bidi and zero-width characters and collapses whitespace" do
      assert RoomNames.member_label("@u:x", "Bo\u202Eb\u0007 \n  x\u200B\uFEFF") == "Bob x"
      assert RoomNames.member_label("@u:x", "a\u2066b\u2069c\u200Ed\u200Fe") == "abcde"
    end

    test "also strips U+061C, soft hyphen and word joiner / invisible operators" do
      assert RoomNames.member_label("@u:x", "a\u061Cb\u00ADc\u2060d\u2064e") == "abcde"
    end

    test "shortens runs of combining marks (Zalgo) so the text stays bounded" do
      zalgo = "a" <> String.duplicate("\u0301", 500)
      label = RoomNames.member_label("@u:x", zalgo)

      assert label == "a" <> String.duplicate("\u0301", 3)
      assert byte_size(label) < 16
      assert RoomNames.member_label("@u:x", "e\u0301") == "e\u0301"
    end

    test "bounds the size even when characters chain into a single grapheme" do
      zwj = "a" <> String.duplicate("\u200D", 100_000)
      emoji_mods = "a" <> String.duplicate("\u{1F3FB}", 50_000)
      tags = "a" <> String.duplicate("\u{E0041}", 50_000)

      for hostile <- [zwj, emoji_mods, tags] do
        label = RoomNames.member_label("@u:x", hostile)
        assert byte_size(label) <= 512
        assert String.valid?(label)
      end
    end

    test "a cut inside a multi-byte character leaves valid UTF-8" do
      label = RoomNames.member_label("@u:x", String.duplicate("\u{1F642}", 400))
      assert String.valid?(label)
      assert byte_size(label) <= 512
    end

    test "collapses whitespace again after dropping invisible characters" do
      assert RoomNames.member_label("@u:x", "a \u200B b") == "a b"
    end

    test "keeps markup as text (escaping is the template's job) and does not trim inside" do
      assert RoomNames.member_label("@u:x", "<script>alert(1)</script>") == "<script>alert(1)</script>"
    end

    test "caps a name at 32 characters including the ellipsis" do
      label = RoomNames.member_label("@u:x", String.duplicate("y", 300))

      assert String.length(label) == 32
      assert String.ends_with?(label, "…")
      assert RoomNames.member_label("@u:x", String.duplicate("y", 32)) == String.duplicate("y", 32)
    end

    test "counts graphemes, not bytes" do
      emoji = String.duplicate("🙂", 40)
      assert String.length(RoomNames.member_label("@u:x", emoji)) == 32
    end
  end

  describe "sanitize/1" do
    test "handles nil, non-binaries and invalid UTF-8" do
      assert RoomNames.sanitize(nil) == ""
      assert RoomNames.sanitize(<<0xFF, 0xFE>>) == ""
      assert RoomNames.sanitize(42) == ""
    end
  end

  # story admin-room-names-sanitiser-gaps
  describe "AC1 — invisible-only display names fall back to the localpart" do
    @invisible_only [
      {"ZWJ", "\u200D\u200D"},
      {"ZWNJ", "\u200C"},
      {"ZWJ and ZWNJ mixed", "\u200D\u200C\u200D"},
      {"Hangul filler U+3164", "\u3164\u3164"},
      {"Hangul choseong filler U+115F", "\u115F"},
      {"Hangul jungseong filler U+1160", "\u1160"},
      {"halfwidth Hangul filler U+FFA0", "\uFFA0\uFFA0"},
      {"braille blank U+2800", "\u2800\u2800"},
      {"musical null notehead U+1D159", "\u{1D159}"},
      {"tag characters", "\u{E0041}\u{E0042}\u{E007F}"},
      {"lone U+E0000", "\u{E0000}"},
      {"interlinear annotation marks", "\uFFF9\uFFFA\uFFFB"},
      {"combining marks only", String.duplicate("\u0301", 5)},
      {"invisible characters mixed with spaces", " \u200D \u3164 \u2800 \u0301 "}
    ]

    # one test per bad input class, so a failure names the class
    for {label, input} <- @invisible_only do
      test "#{label} only: sanitize/1 gives an empty string, member_label/2 the localpart" do
        input = unquote(input)

        assert RoomNames.sanitize(input) == ""
        assert RoomNames.member_label("@bob:test.local", input) == "bob"
      end
    end

    test "invisible format characters inside real text are dropped" do
      assert RoomNames.sanitize("a\uFFF9b\uFFFBc") == "abc"
      assert RoomNames.sanitize("a\u{E0041}\u{E007F}b") == "ab"
    end
  end

  describe "AC2 — legitimate names are unchanged" do
    test "ASCII, accented and CJK names" do
      for name <- ["Alice", "Bob Builder", "Zoë Müller", "José", "e\u0301cole", "山田 太郎", "김민준", "Иван"] do
        assert RoomNames.sanitize(name) == name
        assert RoomNames.member_label("@u:x", name) == name
      end
    end

    test "emoji ZWJ sequences keep their joiners" do
      family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"
      assert RoomNames.sanitize(family) == family
      assert RoomNames.sanitize("Mum " <> family) == "Mum " <> family
      assert RoomNames.member_label("@u:x", family) == family
    end

    test "a plain emoji or symbol name is not mistaken for an invisible one" do
      assert RoomNames.sanitize("\u{1F642}") == "\u{1F642}"
      assert RoomNames.sanitize("\u2764\uFE0F") == "\u2764\uFE0F"
      assert RoomNames.sanitize("!!!") == "!!!"
      assert RoomNames.sanitize("42") == "42"
    end

    test "Persian text keeps its ZWNJ" do
      persian = "\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645"
      assert RoomNames.sanitize(persian) == persian
      assert RoomNames.member_label("@u:x", persian) == persian
    end

    test "Indic text keeps virama + ZWJ / ZWNJ" do
      # Malayalam chillu form and Hindi half-form control characters
      malayalam = "\u0D7B\u0D4D\u200D"
      hindi = "\u0915\u094D\u200D\u0937"
      assert RoomNames.sanitize("\u0D28\u0D4D\u200D\u0D1F") == "\u0D28\u0D4D\u200D\u0D1F"
      assert RoomNames.sanitize(hindi) == hindi
      assert RoomNames.sanitize("a" <> malayalam) == "a" <> malayalam
    end
  end

  describe "AC3 — the combining-mark limit holds across ZWJ / ZWNJ" do
    test "marks interleaved with ZWJ are counted as one run" do
      hostile = "a" <> String.duplicate(String.duplicate("\u0301", 4) <> "\u200D", 200)
      label = RoomNames.sanitize(hostile)

      marks = label |> String.replace(~r/[^\p{M}]/u, "") |> String.length()
      assert marks <= 3
      assert byte_size(label) < 32
      assert String.starts_with?(label, "a\u0301\u0301\u0301")
    end

    test "marks interleaved with ZWNJ or with a ZWJ after every mark are counted as one run" do
      for joiner <- ["\u200C", "\u200D"] do
        hostile = "a" <> String.duplicate("\u0301" <> joiner, 300)
        label = RoomNames.member_label("@u:x", hostile)

        marks = label |> String.replace(~r/[^\p{M}]/u, "") |> String.length()
        assert marks <= 3, "joiner #{inspect(joiner)}: #{marks} marks left"
        assert byte_size(label) < 32
      end
    end

    test "runs of joiners collapse to one" do
      assert RoomNames.sanitize("a" <> String.duplicate("\u200D", 100) <> "b") == "a\u200Db"
    end

    test "up to 3 marks around a joiner are kept" do
      assert RoomNames.sanitize("a\u0301\u200D\u0301") == "a\u0301\u200D\u0301"
    end
  end

  describe "member_names_by_room/1 and attach_member_names/1 without a lookup" do
    test "an empty id list runs no query (no Repo needed)" do
      assert RoomNames.member_names_by_room([]) == %{}
    end

    test "rooms that need no names run no query and get an empty list" do
      rooms = [
        room(room_id: "!a:x", name: "Named", member_count: 2),
        room(room_id: "!b:x", member_count: 0),
        room(room_id: "!c:x", member_count: 7)
      ]

      assert [%{member_names: []}, %{member_names: []}, %{member_names: []}] =
               RoomNames.attach_member_names(rooms)
    end
  end
end
