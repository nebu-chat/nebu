defmodule Nebu.OAuth.OAuthTokenRequestTest do
  @moduledoc """
  RED-phase unit tests for story `oauth-token-endpoint` (story 3): the PURE request module
  `Nebu.OAuth.TokenRequest` (T23, AC2 steps 4-6, AC5.4 PKCE, AC9 refresh-token format, AC11 scope
  narrowing; Must #4, #20, #33).

  Pinned API (see "ATDD Decisions (story 3)" in the story):

    * `validate_params(pairs) :: {:ok, %{name => value}} | {:error, :invalid_request}` — pairs come
      from the story-2 raw parser `AuthorizeRequest.parse_query/1`; a name occurring twice (also
      with identical or one empty value) or a value with a `\\p{Cc}` character / invalid UTF-8 =>
      `:invalid_request`; afterwards EMPTY values are dropped (RFC 6749 3.1: empty = omitted);
      unknown parameters are kept in the map (and ignored by the caller).
    * `valid_content_type?(header | nil) :: boolean`
    * `valid_verifier?(v) :: boolean` (RFC 7636 4.1: 43..128 chars of `[A-Za-z0-9._~-]`)
    * `pkce_valid?(verifier, challenge) :: boolean` (format + S256 + `Plug.Crypto.secure_compare/2`)
    * `narrow_scope(requested | nil, granted) :: {:ok, scope} | {:error, :invalid_scope}` (AC11)
    * `valid_refresh_token_format?(v) :: boolean` (64 lowercase hex)

  Red today: `Nebu.OAuth.TokenRequest` does not exist (`UndefinedFunctionError`).
  """
  use ExUnit.Case, async: true

  @m Nebu.OAuth.TokenRequest
  @stable "urn:matrix:client:"
  @unstable "urn:matrix:org.matrix.msc2967.client:"

  defp tr(fun, args), do: apply(@m, fun, args)
  defp validate(pairs), do: tr(:validate_params, [pairs])

  defp parse_and_validate(raw) do
    case Nebu.OAuth.AuthorizeRequest.parse_query(raw) do
      {:ok, pairs} -> validate(pairs)
      {:error, :malformed} -> {:error, :invalid_request}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 steps 4-6 / T23 — parameters
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2/T23 — validate_params/1 (duplicates, control chars, empty = omitted)" do
    test "a valid code-grant parameter set becomes a map" do
      pairs = [{"grant_type", "authorization_code"}, {"code", "abc"}, {"redirect_uri", "https://app.example.com/cb"},
               {"code_verifier", String.duplicate("a", 43)}, {"client_id", "cid"}]

      assert {:ok, map} = validate(pairs)
      assert map["grant_type"] == "authorization_code"
      assert map["redirect_uri"] == "https://app.example.com/cb"
      assert map["client_id"] == "cid"
    end

    test "a duplicated parameter => :invalid_request (RFC 6749 3.2), also with identical values" do
      assert {:error, :invalid_request} = validate([{"code", "a"}, {"code", "b"}])
      assert {:error, :invalid_request} = validate([{"code", "a"}, {"code", "a"}])
    end

    test "two occurrences count as a duplicate even if one is empty" do
      assert {:error, :invalid_request} = validate([{"scope", ""}, {"scope", "openid"}])
      assert {:error, :invalid_request} = validate([{"client_secret", "x"}, {"client_secret", ""}])
    end

    test "x[] names are just names (no array semantics): x[] and x are different parameters" do
      assert {:ok, map} = validate([{"x[]", "1"}, {"x", "2"}])
      assert map["x[]"] == "1"
      assert map["x"] == "2"
      assert {:error, :invalid_request} = validate([{"x[]", "1"}, {"x[]", "2"}])
    end

    for {label, value} <- [{"NUL", "a\u0000b"}, {"LF", "a\nb"}, {"CR", "a\rb"}, {"TAB", "a\tb"}, {"DEL", "a\u007Fb"}, {"C1 NEL", "a\u0085b"}] do
      test "a value with a control character (#{label}) => :invalid_request (before any SQL, story-2 Trap 11)" do
        assert {:error, :invalid_request} = validate([{"grant_type", "authorization_code"}, {"code", unquote(value)}])
      end
    end

    test "a value that is not valid UTF-8 => :invalid_request" do
      assert {:error, :invalid_request} = validate([{"code", <<0xFF, 0xFE, ?a>>}])
    end

    test "parameters with an EMPTY value are dropped (RFC 6749 3.1, oracle C3)" do
      assert {:ok, map} = validate([{"grant_type", "refresh_token"}, {"scope", ""}, {"client_secret", ""}, {"refresh_token", "x"}])
      refute Map.has_key?(map, "scope")
      refute Map.has_key?(map, "client_secret")
      assert map["refresh_token"] == "x"
    end

    test "an empty REQUIRED parameter is simply missing afterwards (the caller answers invalid_request)" do
      assert {:ok, map} = validate([{"grant_type", ""}, {"code", ""}])
      refute Map.has_key?(map, "grant_type")
      refute Map.has_key?(map, "code")
    end

    test "unknown parameters are kept (and ignored by the caller, RFC 6749 3.2)" do
      assert {:ok, map} = validate([{"grant_type", "authorization_code"}, {"resource", "https://x"}, {"foo", "bar"}])
      assert map["foo"] == "bar"
    end

    test "values are compared AFTER form-decoding: a percent-encoded redirect_uri decodes to the plain URI" do
      raw = "grant_type=authorization_code&redirect_uri=https%3A%2F%2Fapp.example.com%2Fcb&code=c%2Bd+e"
      assert {:ok, map} = parse_and_validate(raw)
      assert map["redirect_uri"] == "https://app.example.com/cb"
      assert map["code"] == "c+d e", "+ is a space, %2B a literal +"
    end

    test "a malformed body (% not followed by two hex digits) is invalid_request (AC2 step 4)" do
      assert {:error, :invalid_request} = parse_and_validate("grant_type=authorization_code&code=%zz")
      assert {:error, :invalid_request} = parse_and_validate("code=%2")
    end

    test "a percent-encoded NUL is still refused after decoding" do
      assert {:error, :invalid_request} = parse_and_validate("grant_type=authorization_code&code=a%00b")
    end
  end

  describe "AC2 step 2 — valid_content_type?/1" do
    for ct <- ["application/x-www-form-urlencoded", "application/x-www-form-urlencoded; charset=UTF-8",
               "Application/X-WWW-Form-Urlencoded", "application/x-www-form-urlencoded;charset=utf-8"] do
      test "#{inspect(ct)} is accepted" do
        assert tr(:valid_content_type?, [unquote(ct)]) == true
      end
    end

    for ct <- [nil, "", "application/json", "multipart/form-data; boundary=x", "text/plain",
               "application/x-www-form-urlencoded-evil", "application/jsonx-www-form-urlencoded"] do
      test "#{inspect(ct)} is refused" do
        assert tr(:valid_content_type?, [unquote(ct)]) == false
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.4 / Must #4 — PKCE (RFC 7636 4.1 / 4.6)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.4/Must #4 — valid_verifier?/1 (43..128 of [A-Za-z0-9._~-])" do
    test "43 and 128 characters are valid; all unreserved characters are allowed" do
      assert tr(:valid_verifier?, [String.duplicate("a", 43)])
      assert tr(:valid_verifier?, [String.duplicate("Z", 128)])
      assert tr(:valid_verifier?, ["abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ0123456789-._~"])
    end

    test "42 and 129 characters are invalid" do
      refute tr(:valid_verifier?, [String.duplicate("a", 42)])
      refute tr(:valid_verifier?, [String.duplicate("a", 129)])
    end

    for bad <- ["+", "/", "=", " ", "%", "ä", "!"] do
      test "a verifier containing #{inspect(bad)} is invalid" do
        refute tr(:valid_verifier?, [String.duplicate("a", 42) <> unquote(bad)])
      end
    end

    test "non-binaries are invalid" do
      refute tr(:valid_verifier?, [nil])
      refute tr(:valid_verifier?, [123])
    end
  end

  describe "AC5.4/Must #4 — pkce_valid?/2 (S256)" do
    @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    test "the RFC 7636 Appendix B vector verifies" do
      assert tr(:pkce_valid?, [@verifier, @challenge]) == true
    end

    test "a wrong verifier fails" do
      refute tr(:pkce_valid?, [String.replace(@verifier, "d", "e", global: false), @challenge])
    end

    test "a 'plain' verifier equal to the stored challenge fails (S256 only)" do
      refute tr(:pkce_valid?, [@challenge, @challenge])
    end

    test "a 64+ char plain verifier equal to a (bogus) challenge fails" do
      plain = String.duplicate("p", 64)
      refute tr(:pkce_valid?, [plain, plain])
    end

    test "a correct hash of a verifier with an invalid format fails (format checked first)" do
      v = String.duplicate("a", 42)
      challenge = :crypto.hash(:sha256, v) |> Base.url_encode64(padding: false)
      refute tr(:pkce_valid?, [v, challenge])
    end

    test "random pairs round-trip" do
      for _ <- 1..5 do
        {v, c} = Nebu.OAuth.TestSupport.pkce_pair()
        assert tr(:pkce_valid?, [v, c])
      end
    end
  end

  describe "AC9 — valid_refresh_token_format?/1 (no DB access for junk)" do
    test "64 lowercase hex is valid" do
      assert tr(:valid_refresh_token_format?, [String.duplicate("0a", 32)])
    end

    for bad <- [String.duplicate("A", 64), String.duplicate("a", 63), String.duplicate("a", 65), String.duplicate("g", 64), "", "a.b.c"] do
      test "#{inspect(String.slice(bad, 0, 12))}... (#{byte_size(bad)} bytes) is invalid" do
        refute tr(:valid_refresh_token_format?, [unquote(bad)])
      end
    end

    test "non-binaries are invalid" do
      refute tr(:valid_refresh_token_format?, [nil])
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 / T13 / Must #20 — narrow_scope/2
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11/T13 — narrow_scope/2 (set semantics, prefix-normalized, stored string echoed)" do
    @granted "openid #{@unstable}api:* #{@unstable}device:AbCdEfGhIj"
    @granted_no_openid "#{@unstable}api:* #{@unstable}device:AbCdEfGhIj"

    defp narrow(req, granted \\ @granted), do: tr(:narrow_scope, [req, granted])

    test "absent (nil) => the granted scope unchanged" do
      assert narrow(nil) == {:ok, @granted}
    end

    test "empty string => the granted scope unchanged (RFC 6749 3.1, oracle C3)" do
      assert narrow("") == {:ok, @granted}
    end

    test "equal => granted" do
      assert narrow(@granted) == {:ok, @granted}
    end

    test "other order => granted (stored order echoed)" do
      assert narrow("#{@unstable}device:AbCdEfGhIj openid #{@unstable}api:*") == {:ok, @granted}
    end

    test "the other prefix for the same tokens is accepted; the echo keeps the STORED prefix" do
      assert narrow("openid #{@stable}api:* #{@stable}device:AbCdEfGhIj") == {:ok, @granted}

      stable_granted = "openid #{@stable}api:* #{@stable}device:AbCdEfGhIj"
      assert narrow("openid #{@unstable}api:* #{@unstable}device:AbCdEfGhIj", stable_granted) == {:ok, stable_granted}
    end

    test "mixed prefixes in one request are accepted (each token normalized)" do
      assert narrow("openid #{@stable}api:* #{@unstable}device:AbCdEfGhIj") == {:ok, @granted}
    end

    test "a duplicate token is accepted (duplicates collapse)" do
      assert narrow("openid openid #{@unstable}api:* #{@unstable}device:AbCdEfGhIj") == {:ok, @granted}
    end

    test "dropping openid => granted string minus openid" do
      assert narrow(@granted_no_openid) == {:ok, @granted_no_openid}
    end

    test "without openid granted, an equal request returns it unchanged" do
      assert narrow(@granted_no_openid, @granted_no_openid) == {:ok, @granted_no_openid}
    end

    test "openid cannot be added back (widening) => invalid_scope" do
      assert narrow(@granted, @granted_no_openid) == {:error, :invalid_scope}
    end

    test "an extra token => invalid_scope" do
      assert narrow(@granted <> " email") == {:error, :invalid_scope}
      assert narrow(@granted <> " #{@unstable}guest:*") == {:error, :invalid_scope}
    end

    test "missing device token => invalid_scope (Nebu policy, story-2 D6)" do
      assert narrow("openid #{@unstable}api:*") == {:error, :invalid_scope}
    end

    test "another device id => invalid_scope" do
      assert narrow("openid #{@unstable}api:* #{@unstable}device:OTHERDEVICE") == {:error, :invalid_scope}
    end

    test "missing api:* => invalid_scope" do
      assert narrow("openid #{@unstable}device:AbCdEfGhIj") == {:error, :invalid_scope}
    end

    test "only openid => invalid_scope" do
      assert narrow("openid") == {:error, :invalid_scope}
    end

    test "non-ASCII / outside the RFC 6749 3.3 charset => invalid_scope" do
      assert narrow("openid #{@unstable}api:* #{@unstable}device:AbCdEfGhIjä") == {:error, :invalid_scope}
      assert narrow(~s(openid "#{@unstable}api:*" #{@unstable}device:AbCdEfGhIj)) == {:error, :invalid_scope}
      assert narrow("openid #{@unstable}api:* #{@unstable}device:AbCdEfGhIj\\") == {:error, :invalid_scope}
    end

    test "more than 2048 bytes => invalid_scope" do
      long = @granted <> String.duplicate(" openid", 300)
      assert byte_size(long) > 2048
      assert narrow(long) == {:error, :invalid_scope}
    end

    test "extra spaces (empty tokens) are dropped" do
      assert narrow("  openid   #{@unstable}api:*  #{@unstable}device:AbCdEfGhIj ") == {:ok, @granted}
    end
  end
end
