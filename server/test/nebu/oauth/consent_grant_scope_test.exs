defmodule Nebu.OAuth.ConsentGrantScopeTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003), scenarios 2, 3 and 7, pure part (no database): what "the same scope" means and how `prompt=consent`
  is parsed.

  Decisions pinned here:

    * The remembered scope is the GRANTED (already narrowed) scope WITHOUT the per-login `<prefix>device:<id>` token: a client such as
      matrix-js-sdk or FluffyChat generates a new device id for every login, so a device id inside the comparison would make "second login skips
      consent" impossible. The device is still bound as today (device holder check, `device_id` of the code); it is just not part of the consent.
    * Tokens are compared literally: the Matrix prefix (stable / unstable) is part of the token. A client that switches the prefix is asked again
      (conservative: any difference asks).
    * `covers?/2` is a plain subset rule on normalised tokens; an empty requested scope is never covered (fail closed).
    * `prompt` values are the space separated tokens of the parameter, case sensitive (OIDC Core 3.1.2.1): `consent` anywhere among them forces the
      consent screen; `consentx` and `CONSENT` do not.
  """
  use ExUnit.Case, async: true

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  @u T.unstable_prefix()
  @s T.stable_prefix()

  defp normalize(scope), do: G.call(:normalize_scope, [scope])
  defp covers?(granted, requested), do: G.call(:covers?, [granted, requested])

  describe "normalize_scope/1" do
    test "drops the device token, sorts, joins with one space (unstable prefix)" do
      assert normalize("openid #{@u}api:* #{@u}device:AbCdEfGhIj") == "openid #{@u}api:*"
    end

    test "drops the device token (stable prefix)" do
      assert normalize("#{@s}api:* #{@s}device:XYZ123") == "#{@s}api:*"
    end

    test "the order of the request tokens does not matter" do
      a = normalize("openid #{@u}api:* #{@u}device:D1")
      b = normalize("#{@u}device:D1 #{@u}api:* openid")
      c = normalize("#{@u}api:*   openid #{@u}device:D1")
      assert a == b and b == c
    end

    test "duplicates collapse" do
      assert normalize("openid openid #{@u}api:* #{@u}api:* #{@u}device:D1") == "openid #{@u}api:*"
    end

    test "two logins that differ only in the device id normalise to the SAME string, and no device id survives" do
      a = normalize("openid #{@u}api:* #{@u}device:FIRSTDEVICE")
      b = normalize("openid #{@u}api:* #{@u}device:SECONDDEVICE")
      assert a == b
      refute a =~ "DEVICE"
      refute a =~ "device:"
    end

    test "tokens are sorted ascending, so the openid token comes first" do
      assert normalize("#{@u}api:* openid") == "openid #{@u}api:*"
    end

    test "openid is a token like any other: with and without it differ" do
      refute normalize("openid #{@u}api:* #{@u}device:D") == normalize("#{@u}api:* #{@u}device:D")
    end

    test "nil and the empty string normalise to the empty string" do
      assert normalize(nil) == ""
      assert normalize("") == ""
      assert normalize("   ") == ""
    end

    test "unknown tokens are kept (the function never invents a narrowing; the request parser already dropped them)" do
      assert normalize("profile openid #{@u}api:* #{@u}device:D") == "openid profile #{@u}api:*"
    end
  end

  describe "covers?/2" do
    @granted "openid #{@u}api:*"

    test "the same scope is covered" do
      assert covers?(@granted, "openid #{@u}api:* #{@u}device:NEWDEVICE")
      assert covers?(@granted, @granted)
    end

    test "a narrower request is covered" do
      assert covers?(@granted, "#{@u}api:* #{@u}device:NEWDEVICE")
    end

    test "a broader request is NOT covered (scenario 3: the consent screen is shown again)" do
      refute covers?("#{@u}api:*", "openid #{@u}api:* #{@u}device:D")
      # the pure function never invents a narrowing. Through HTTP the scope parser drops `profile` / `email` BEFORE this check, so they cannot widen a
      # request (story Decisions, scenario 3): what widens is `openid` or another Matrix prefix (consent_grant_flow_test.exs, scenario 3)
      refute covers?(@granted,"openid profile email #{@u}api:* #{@u}device:D")
    end

    test "a different Matrix prefix is NOT covered" do
      refute covers?(@granted, "openid #{@s}api:* #{@s}device:D")
    end

    test "order and device do not matter" do
      assert covers?(@granted, "#{@u}device:Z #{@u}api:* openid")
    end

    test "an empty or missing requested scope is never covered; nothing is covered by an empty or missing grant" do
      refute covers?(@granted, "")
      refute covers?(@granted, nil)
      refute covers?("", "openid #{@u}api:* #{@u}device:D")
      refute covers?(nil, "openid #{@u}api:* #{@u}device:D")
    end

    test "a request that is only a device token is not covered (nothing to grant)" do
      refute covers?(@granted, "#{@u}device:D")
    end
  end

  describe "AuthorizeRequest.validate/2 carries force_consent (scenario 7)" do
    defp validate(prompt) do
      overrides = if prompt == :absent, do: %{}, else: %{"prompt" => prompt}
      pairs = T.authorize_params("cid", G.https(), overrides)
      Nebu.OAuth.AuthorizeRequest.validate(pairs, G.https())
    end

    test "absent prompt does not force consent" do
      assert {:ok, %{force_consent: false}} = validate(:absent)
    end

    for {prompt, expected} <- [
          {"consent", true},
          {"login consent", true},
          {"consent login", true},
          {"select_account consent login", true},
          # cycle 1 (Kassandra LOW #2): `login` asks for a RE-AUTHENTICATION; the consent screen is the guard, so it forces the screen like `consent`
          # (SUPERSEDES the cycle 0 row {"login", false})
          {"login", true},
          {"select_account login", true},
          {"login select_account", true},
          {"create login", true},
          {"select_account", false},
          {"loginx", false},
          {"xlogin", false},
          {"LOGIN", false},
          {"Login", false},
          {"consentx", false},
          {"xconsent", false},
          {"CONSENT", false},
          {"Consent", false},
          {"", false}
        ] do
      test "prompt #{inspect(prompt)} => force_consent #{expected}" do
        assert {:ok, %{force_consent: unquote(expected)}} = validate(unquote(prompt))
      end
    end

    test "prompt=create still reports create; prompt='create consent' reports BOTH" do
      assert {:ok, %{prompt: "create", force_consent: false}} = validate("create")
      assert {:ok, %{prompt: "create", force_consent: true}} = validate("create consent")
      assert {:ok, %{prompt: "create", force_consent: true}} = validate("create login")
    end

    test "prompt=login still reports `prompt: nil` (it is not forwarded to the IdP leg), only the force flag is new" do
      assert {:ok, %{prompt: nil, force_consent: true}} = validate("login")
      assert {:ok, %{prompt: nil, force_consent: true}} = validate("login consent")
    end

    test "prompt=consent does not change what the validator answered before (`prompt: nil`, same other fields)" do
      pairs = T.authorize_params("cid", G.https(), %{})
      assert {:ok, base} = Nebu.OAuth.AuthorizeRequest.validate(pairs, G.https())
      assert {:ok, with_consent} = Nebu.OAuth.AuthorizeRequest.validate(pairs ++ [{"prompt", "consent"}], G.https())
      assert Map.delete(with_consent, :force_consent) == Map.delete(base, :force_consent)
      assert with_consent.prompt == nil
    end

    test "prompt=none stays login_required, and none combined with consent stays invalid_request" do
      assert {:error, "login_required", _} = validate("none")
      assert {:error, "invalid_request", _} = validate("none consent")
      assert {:error, "invalid_request", _} = validate("consent none")
      # cycle 1: prompt=none alone is unchanged, and `none login` is still invalid_request (OIDC Core 3.1.2.1)
      assert {:error, "invalid_request", _} = validate("none login")
      assert {:error, "invalid_request", _} = validate("login none")
    end
  end
end
