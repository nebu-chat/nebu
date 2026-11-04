defmodule Nebu.OAuth.DeviceNameTest do
  @moduledoc """
  Story `oauth-device-default-display-name` (REQ-2026-004), the PURE part (no database, runs in the unit job): `Nebu.OAuth.DeviceName.default_name/2`,
  the rules of the story's Gherkin comments as a table.

  Decisions pinned here (story `## Decisions`):

    * The name is `"<base> (<suffix>)"`. The base is the claimed `client_name` after sanitising, the plain `"OAuth client"` when nothing usable is left.
    * Sanitising (in this order): not valid UTF-8 or not a string => fallback; markup tags `<...>` are removed with their brackets (their text stays), every
      remaining `<` / `>` is dropped (so no markup characters survive), tab / newline / carriage return and Unicode space separators become one space, every other
      control character, format character (bidi overrides, zero width), line / paragraph separator, private-use and surrogate code point is dropped, runs of
      spaces collapse to one, the ends are trimmed. `&`, quotes, letters of every script, accents and emoji are KEPT (a legitimate app name may contain them;
      the name is plain text, a client that renders it as HTML must escape it, as for any display name).
    * Bound: at most `max_base_length/0` (= 64) CODE POINTS (not graphemes: a run of combining marks is one grapheme and would be unbounded); trimmed again
      after the cut, so the base never ends in a space.
    * Suffix: the LAST 8 characters of the device id after dropping every character outside `[A-Za-z0-9._-]` (a device id may legally contain `<`, `>`,
      `"`, `&`, `(`, `)`: the scope charset admits them); shorter ids are used whole. When nothing is left the suffix is the first 8 hex characters of the
      SHA-256 of the id, upper case. The suffix is therefore always safe text, never longer than 8 characters.
  """
  use ExUnit.Case, async: true

  alias Nebu.OAuth.DeviceNameTestSupport, as: D

  defp name(client_name, device_id \\ "ABCD1234"), do: D.default_name(client_name, device_id)
  defp base(client_name), do: D.base_of(name(client_name))

  describe "the contract exists" do
    test "the module exports default_name/2, for_client/2, max_base_length/0 and fallback_base/0; the numbers are pinned" do
      assert Code.ensure_loaded?(D.mod())
      for {f, a} <- [default_name: 2, for_client: 2, max_base_length: 0, fallback_base: 0], do: assert(function_exported?(D.mod(), f, a), "#{f}/#{a}")
      assert D.call(:max_base_length, []) == 64
      assert D.call(:fallback_base, []) == "OAuth client"
    end
  end

  describe "scenario 1 - client name plus a short suffix of the device id" do
    test "a plain client name and the device id of the story" do
      assert name("FluffyChat", "ABCD1234") == "FluffyChat (ABCD1234)"
    end

    test "a longer device id contributes its LAST 8 characters, a shorter one is used whole" do
      assert name("FluffyChat", "AbCdEfGhIj") == "FluffyChat (CdEfGhIj)"
      assert name("FluffyChat", "SHORT") == "FluffyChat (SHORT)"
      assert name("FluffyChat", "X") == "FluffyChat (X)"
      assert name("FluffyChat", String.duplicate("A", 200) <> "12345678") == "FluffyChat (12345678)"
    end

    test "device ids that differ only in the front part (a structured id) are still told apart by the end" do
      assert name("App", "ios-prefix-0000000A") != name("App", "ios-prefix-0000000B")
    end

    test "legitimate names are kept: spaces inside, accents, other scripts, emoji, ampersand and quotes" do
      assert base("Element Web") == "Element Web"
      assert base("Café Chat") == "Café Chat"
      assert base("日本語アプリ") == "日本語アプリ"
      assert base("Chat \u{1F600}") == "Chat \u{1F600}"
      assert base("AT&T Messenger") == "AT&T Messenger"
      assert base("O'Reilly \"Chat\"") == "O'Reilly \"Chat\""
    end
  end

  describe "scenario 3 - markup and control characters" do
    test "the story's example: tags go, the control character goes, the text stays" do
      assert name("<b>Evil\u0007Client</b>", "ABCD1234") == "EvilClient (ABCD1234)"
    end

    test "a script element loses its tags (its text is harmless plain text), no angle bracket survives anywhere" do
      assert base("<script>alert(1)</script>") == "alert(1)"
      assert base("a <b>bold</b> app") == "a bold app"
      assert base("<img src=x onerror=alert(1)>Chat") == "Chat"
      assert base("<<b>script>x") == "scriptx"
      assert base("a < b") == "a b"
      assert base("unclosed <script") == "unclosed script"

      for hostile <- ["<script>", "</div>", "a>b", "<<<>>>", "<a href=\"x\">y</a>"], do: refute(name(hostile) =~ ~r/[<>]/, "no markup in #{inspect(hostile)}")
    end

    test "tab, newline and carriage return become one space; other control characters, bidi overrides, zero width, separators and private use are dropped" do
      assert base("Fluffy\nChat\t2\r\n3") == "Fluffy Chat 2 3"
      assert base("Bell\u0007Name") == "BellName"
      assert base("Nul\u0000Name") == "NulName"
      assert base("Esc\u001B[31mName") == "Esc[31mName"
      assert base("Del\u007FName") == "DelName"
      assert base("C1\u0085Name") == "C1Name"
      assert base("\u{202E}evil\u{202C}") == "evil"
      assert base("Zero\u{200B}Width\u{200D}\u{2060}\u{FEFF}") == "ZeroWidth"
      assert base("Soft\u{AD}Hyphen") == "SoftHyphen"
      assert base("Line\u{2028}Sep\u{2029}Para") == "LineSepPara"
      assert base("Private\u{E000}Use") == "PrivateUse"
    end

    test "Unicode space separators count as a space; runs collapse; the ends are trimmed" do
      assert base("NBSP\u{A0}name") == "NBSP name"
      assert base("wide\u{3000}space") == "wide space"
      assert base("  padded   name  ") == "padded name"
      assert base("\n\tlead and trail\r\n") == "lead and trail"
    end

    test "nothing hostile survives in any of these, whatever the mix" do
      mixed = [
        "<b>Evil\u0007Client</b>",
        "\u{202E}<i>x</i>\u0000\u{200B}",
        "a\u{2028}b\u{2029}c\u0085d",
        "<scr\u0007ipt>alert(1)</scr\u0007ipt>",
        "x" <> String.duplicate("\u{301}", 80),
        "\u{D7FF}\u{E000}\u{FFFE}"
      ]

      for input <- mixed do
        out = name(input)
        refute D.hostile?(out), "hostile characters survived in #{inspect(out)} (from #{inspect(input)})"
      end
    end
  end

  describe "scenario 4 - the base is bounded" do
    test "an overlong ASCII name is cut to the maximum, the suffix is kept" do
      out = name(String.duplicate("A", 500), "ABCD1234")
      assert out == String.duplicate("A", 64) <> " (ABCD1234)"
    end

    test "the bound counts code points: multi-byte characters and a run of combining marks are bounded as well" do
      assert D.base_of(name(String.duplicate("日", 500))) == String.duplicate("日", 64)
      zalgo = "A" <> String.duplicate("\u{301}", 500)
      assert D.codepoints(base(zalgo)) <= 64
      assert name(zalgo) =~ " (ABCD1234)"
      assert byte_size(name(String.duplicate("\u{1F600}", 500))) <= 64 * 4 + 20
    end

    test "a name of exactly the maximum is untouched; one more is cut; a cut never leaves a trailing space" do
      exact = String.duplicate("B", 64)
      assert base(exact) == exact
      assert base(exact <> "C") == exact
      cut_at_space = String.duplicate("A", 63) <> " " <> String.duplicate("B", 10)
      assert base(cut_at_space) == String.duplicate("A", 63)
    end

    test "the cut happens AFTER the sanitising: markup does not eat the budget" do
      assert base("<b>" <> String.duplicate("A", 64) <> "</b>") == String.duplicate("A", 64)
      assert base(String.duplicate("\u0007", 100) <> "Short") == "Short"
    end

    test "the whole name is bounded (base <= 64 code points plus the suffix)" do
      for id <- ["A", "ABCD1234", String.duplicate("Z", 255)] do
        assert D.codepoints(name(String.duplicate("N", 1000), id)) <= 64 + 11
      end
    end
  end

  describe "cycle 1 - invisible but not empty names (U+3164, U+FFA0, U+115F, U+1160, U+2800, U+034F, variation selectors, marks without a base)" do
    @invisible ["\u{3164}", "\u{FFA0}", "\u{115F}", "\u{1160}", "\u{2800}", "\u{034F}", "\u{FE00}", "\u{FE08}", "\u{FE0F}"]

    test "a name made only of such a character (alone, repeated, mixed with spaces) falls back to the plain base" do
      for ch <- @invisible do
        assert name(ch, "ABCD1234") == "OAuth client (ABCD1234)", "for U+" <> Integer.to_string(hd(String.to_charlist(ch)), 16)
        assert name(String.duplicate(ch, 5), "ABCD1234") == "OAuth client (ABCD1234)"
        assert name(" " <> ch <> " " <> ch <> " ", "ABCD1234") == "OAuth client (ABCD1234)"
      end

      assert name(Enum.join(@invisible), "ABCD1234") == "OAuth client (ABCD1234)"
      assert name(Enum.join(@invisible, " "), "ABCD1234") == "OAuth client (ABCD1234)"
    end

    test "combining marks without a base letter only: the plain base" do
      for input <- ["\u{0301}", "\u{0301}" <> "\u{0302}" <> "\u{0308}", " " <> "\u{0301}" <> " ", "\u{0301}" <> " " <> "\u{0302}", "\u{20DD}", "\u{0301}" <> "\u{3164}"] do
        assert name(input, "ABCD1234") == "OAuth client (ABCD1234)", "for " <> inspect(input)
      end
    end

    test "visible letters mixed with them keep the letters (and only the letters)" do
      assert base("Chat" <> "\u{3164}" <> "App") == "ChatApp"
      assert base("\u{2800}" <> "Fluffy" <> "\u{FFA0}") == "Fluffy"
      assert base("\u{115F}" <> "\u{1160}" <> "Fluffy" <> "\u{1160}") == "Fluffy"
      assert base("Fluffy" <> "\u{034F}" <> "Chat") == "FluffyChat"
      assert base("\u{FE0F}" <> "Fluffy") == "Fluffy"
      assert base("Fluffy " <> "\u{FE0F}") == "Fluffy"
      assert base("Fluffy " <> "\u{3164}" <> " Chat") == "Fluffy Chat"
    end

    test "every variation selector U+FE00..U+FE0F is dropped, also between letters (a text letter has no variation)" do
      for cp <- 0xFE00..0xFE0F do
        vs = <<cp::utf8>>
        assert base("Fluffy" <> vs <> "Chat") == "FluffyChat", "for U+" <> Integer.to_string(cp, 16)
        assert name(vs, "ABCD1234") == "OAuth client (ABCD1234)"
      end
    end

    test "a combining mark without a base letter is dropped (at the start, after a space); a mark after a letter is kept" do
      assert base("\u{0301}" <> "Chat") == "Chat"
      assert base("Chat " <> "\u{0301}" <> "App") == "Chat App"
      assert base("Chat " <> "\u{0301}" <> "\u{0302}" <> " App") == "Chat App"
      assert base("Cafe" <> "\u{0301}") == "Cafe" <> "\u{0301}"
      assert base("Cafe" <> "\u{0301}" <> " Chat") == "Cafe" <> "\u{0301}" <> " Chat"
    end

    test "every output has a visible character in its base, whatever the mix" do
      inputs =
        Enum.flat_map(@invisible, fn ch -> [ch, "x" <> ch, ch <> "x", ch <> "\u{0301}", "\u{0301}" <> ch <> "\u{0301}"] end) ++
          ["\u{0301}" <> "\u{FE0F}", "\u{20DD}" <> " " <> "\u{2800}"]

      for input <- inputs do
        b = base(input)
        assert b =~ ~r/[\p{L}\p{N}\p{P}\p{S}]/u, "no visible character left in " <> inspect(b) <> " for " <> inspect(input)
      end
    end
  end

  describe "empty, unusable and absent client names fall back to the plain base" do
    test "nil, an empty string, blanks, markup only, control characters only" do
      for input <- [nil, "", "   ", "\n\t", "<b></b>", "<>", "<", "\u0007\u0008", "\u{200B}\u{200B}", "\u{202E}"] do
        assert name(input, "ABCD1234") == "OAuth client (ABCD1234)", "for #{inspect(input)}"
      end
    end

    test "not a string at all, or not valid UTF-8" do
      for input <- [42, :atom, %{"client_name" => "x"}, ["list"], <<0xFF, 0xFE>>, "abc" <> <<0xFF>>] do
        assert name(input, "ABCD1234") == "OAuth client (ABCD1234)", "for #{inspect(input)}"
      end
    end
  end

  describe "the suffix is always safe text" do
    test "characters a device id may legally contain are dropped from the suffix" do
      assert name("App", "ab<c>de") == "App (abcde)"
      assert name("App", "x\"y'z&1") == "App (xyz1)"
      assert name("App", "id)(evil") == "App (idevil)"
      assert name("App", "a.b_c-d") == "App (a.b_c-d)"
    end

    test "an id without any safe character gets a deterministic 8 character hex suffix, different ids differ" do
      out = name("App", "<<<>>>")
      assert out =~ ~r/\AApp \([0-9A-F]{8}\)\z/
      assert out == name("App", "<<<>>>")
      assert out != name("App", "!!!!!!")
      assert name("App", "<<<>>>") == "App (" <> (:crypto.hash(:sha256, "<<<>>>") |> Base.encode16() |> binary_part(0, 8)) <> ")"
    end

    test "the suffix never contains markup, quotes, ampersands or parentheses of its own, for a spread of hostile ids" do
      for id <- ["<script>alert(1)</script>", "\"><svg/onload=alert(1)>", "&amp;&lt;", "'); DROP TABLE devices;--", "((((((((", String.duplicate("<", 255)] do
        out = name("App", id)
        assert [_, suffix] = Regex.run(~r/ \(([^()]*)\)\z/, out), "name must end in one parenthesised suffix: #{inspect(out)}"
        refute suffix =~ ~r/[<>"'&()\s]/
        assert String.length(suffix) in 1..8
      end
    end
  end

  describe "never raises" do
    test "any combination of terms answers a string" do
      terms = [nil, 1, 1.5, :a, "", "x", <<255>>, [], %{}, {1, 2}, self()]

      for c <- terms, d <- terms do
        assert is_binary(D.default_name(c, d))
      end
    end
  end
end
