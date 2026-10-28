defmodule Nebu.OAuth.OAuthAuthorizeScopeTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC4b (D6-D8, D23):
  the pure scope parser `Nebu.OAuth.Scope` (no DB, no conn).

  ## Contract pinned here (ATDD Decisions (story 2), story file)

      Nebu.OAuth.Scope.parse(scope :: String.t() | nil) ::
        {:ok, %{scope: String.t(),          # granted scope: "[openid ]<p>api:* <p>device:<id>"
                prefix: String.t(),         # "urn:matrix:client:" | "urn:matrix:org.matrix.msc2967.client:"
                device_id: String.t(),
                openid: boolean()}}
        | {:error, :invalid_scope}

      Nebu.OAuth.Scope.valid_device_id?(binary) :: boolean   # D8, 1..255 bytes of %x21/%x23-5B/%x5D-7E
      Nebu.OAuth.Scope.prefixes() :: [stable, unstable]

  Fails today because `Nebu.OAuth.Scope` does not exist (UndefinedFunctionError).
  Crash/restart — NOT APPLICABLE (pure function).
  """
  use ExUnit.Case, async: true

  # Indirection: no compile-time dependency on the not-yet-existing module (--warnings-as-errors).
  @scope Nebu.OAuth.Scope
  defp parse(s), do: apply(@scope, :parse, [s])
  defp valid_device_id?(id), do: apply(@scope, :valid_device_id?, [id])

  @s "urn:matrix:client:"
  @u "urn:matrix:org.matrix.msc2967.client:"

  describe "AC4b — the real client strings (both prefixes)" do
    test "matrix-js-sdk 41.3.0 EXACT string (openid + unstable prefix) is accepted, openid kept (D23)" do
      assert {:ok, r} =
               parse("openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj")

      assert r.scope == "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj"
      assert r.prefix == @u
      assert r.device_id == "AbCdEfGhIj"
      assert r.openid == true
    end

    test "Dart SDK string (unstable prefix, no openid)" do
      assert {:ok, r} =
               parse("urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:ABCDEFGHIJ")

      assert r.scope == "urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:ABCDEFGHIJ"
      assert r.prefix == @u
      assert r.device_id == "ABCDEFGHIJ"
      assert r.openid == false
    end

    test "generic stable-prefix case" do
      assert {:ok, r} = parse("urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj")
      assert r.scope == "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj"
      assert r.prefix == @s
      assert r.device_id == "AbCdEfGhIj"
      assert r.openid == false
    end

    test "prefixes/0 lists exactly the stable and the unstable prefix" do
      assert Enum.sort(apply(@scope, :prefixes, [])) == Enum.sort([@s, @u])
    end
  end

  describe "AC4b — granted scope is normalized and echoes the REQUEST's prefix" do
    test "token order in the request does not matter: api:* first, then device" do
      assert {:ok, %{scope: "urn:matrix:client:api:* urn:matrix:client:device:D1"}} =
               parse("urn:matrix:client:device:D1 urn:matrix:client:api:*")

      assert {:ok, %{scope: "openid " <> @u <> "api:* " <> @u <> "device:D1"}} =
               parse(@u <> "device:D1 openid " <> @u <> "api:*")
    end

    test "empty tokens (double spaces, leading/trailing space) are dropped" do
      assert {:ok, %{scope: "urn:matrix:client:api:* urn:matrix:client:device:D1"}} =
               parse("  urn:matrix:client:api:*   urn:matrix:client:device:D1 ")
    end

    test "unknown tokens are ignored and never echoed (D7)" do
      assert {:ok, r} =
               parse(
                 "profile email urn:matrix:client:com.example.msc1234:foo urn:matrix:client:api:read:* " <>
                   "urn:matrix:client:api:* urn:matrix:client:device:D1 offline_access"
               )

      assert r.scope == "urn:matrix:client:api:* urn:matrix:client:device:D1"
      refute r.scope =~ "profile"
      refute r.scope =~ "api:read"
      refute r.scope =~ "msc1234"
      assert r.openid == false
    end

    test "openid alone is not unknown: it is kept and flagged (D23)" do
      assert {:ok, %{openid: true, scope: "openid urn:matrix:client:api:* urn:matrix:client:device:D1"}} =
               parse("urn:matrix:client:api:* openid urn:matrix:client:device:D1")
    end
  end

  describe "AC4b — invalid_scope" do
    test "missing / empty / whitespace-only scope" do
      for s <- [nil, "", " ", "   "], do: assert(parse(s) == {:error, :invalid_scope}, inspect(s))
    end

    test "scope longer than 2048 bytes" do
      filler = String.duplicate("x", 2048)
      assert parse("urn:matrix:client:api:* urn:matrix:client:device:D1 " <> filler) == {:error, :invalid_scope}
    end

    test "zero device tokens" do
      assert parse("urn:matrix:client:api:*") == {:error, :invalid_scope}
      assert parse("openid " <> @u <> "api:*") == {:error, :invalid_scope}
    end

    test "two DISTINCT device tokens" do
      assert parse("urn:matrix:client:api:* urn:matrix:client:device:A urn:matrix:client:device:B") ==
               {:error, :invalid_scope}
    end

    test "two IDENTICAL device tokens (occurrences are counted, D8)" do
      assert parse("urn:matrix:client:api:* urn:matrix:client:device:A urn:matrix:client:device:A") ==
               {:error, :invalid_scope}
    end

    test "api:* missing (Nebu policy D6), also when only an unknown api: variant is present" do
      assert parse("urn:matrix:client:device:A") == {:error, :invalid_scope}
      assert parse("urn:matrix:client:api:read:* urn:matrix:client:device:A") == {:error, :invalid_scope}
      assert parse("openid " <> @u <> "device:A") == {:error, :invalid_scope}
    end

    test "mixed prefixes (stable api:* + unstable device and vice versa) are rejected (Nebu policy D7)" do
      assert parse(@s <> "api:* " <> @u <> "device:X") == {:error, :invalid_scope}
      assert parse(@u <> "api:* " <> @s <> "device:X") == {:error, :invalid_scope}
    end

    test "api:* of one prefix and device tokens of BOTH prefixes are rejected (mixed + 2 devices)" do
      assert parse(@s <> "api:* " <> @s <> "device:X " <> @u <> "device:X") == {:error, :invalid_scope}
    end

    test "a token outside the RFC 6749 3.3 charset makes the whole request invalid_scope" do
      for bad <- [~s(pro"file), "back\\slash", "tab\there", "del\x7F", "nonascii-é", "ctrl\x01"] do
        assert parse("urn:matrix:client:api:* urn:matrix:client:device:D1 " <> bad) == {:error, :invalid_scope},
               "token #{inspect(bad)} must be rejected"
      end
    end

    test "an empty device id (`device:`) is rejected" do
      assert parse("urn:matrix:client:api:* urn:matrix:client:device:") == {:error, :invalid_scope}
    end
  end

  describe "D8 — device-id validator (RFC 6749 3.3 charset, 1..255 bytes, no minimum beyond 1)" do
    test "boundary characters ! # [ ] ~ and a 1-char id are accepted" do
      for id <- ["!", "#", "[", "]", "~", "a", "A!#[]~z", "AbCdEfGhIj", String.duplicate("Z", 255)] do
        assert valid_device_id?(id), "#{inspect(id)} must be accepted"
      end
    end

    test "space, double quote, backslash, DEL, control chars and non-ASCII are rejected" do
      for id <- ["a b", ~s(a"b), "a\\b", "a\x7Fb", "a\x00b", "a\nb", "é", "日本"] do
        refute valid_device_id?(id), "#{inspect(id)} must be rejected"
      end
    end

    test "empty and 256-byte ids are rejected; 255 bytes is the maximum" do
      refute valid_device_id?("")
      assert valid_device_id?(String.duplicate("a", 255))
      refute valid_device_id?(String.duplicate("a", 256))
    end

    test "through the parser: 255-byte device id accepted, 256-byte rejected (must-test 30)" do
      ok = String.duplicate("d", 255)
      assert {:ok, %{device_id: ^ok}} = parse(@u <> "api:* " <> @u <> "device:" <> ok)
      assert parse(@u <> "api:* " <> @u <> "device:" <> String.duplicate("d", 256)) == {:error, :invalid_scope}
    end

    test "through the parser: charset boundary device ids" do
      assert {:ok, %{device_id: "A!#[]~"}} = parse(@s <> "api:* " <> @s <> "device:A!#[]~")
      assert parse(@s <> "api:* " <> @s <> ~s(device:A"B)) == {:error, :invalid_scope}
      assert parse(@s <> "api:* " <> @s <> "device:A\\B") == {:error, :invalid_scope}
      assert parse(@s <> "api:* " <> @s <> "device:Aé") == {:error, :invalid_scope}
    end

    test "Nebu.Matrix.DeviceId.valid?/1 is NOT the validator (it admits \" and \\, D8)" do
      # Guard against a regression to the looser Matrix helper.
      refute valid_device_id?(~s(quo"te))
      refute valid_device_id?("back\\slash")
    end
  end
end
