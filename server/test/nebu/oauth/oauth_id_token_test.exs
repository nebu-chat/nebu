defmodule Nebu.OAuth.OAuthIdTokenTest do
  @moduledoc """
  RED-phase unit tests for story `oauth-token-endpoint` (story 3), AC12 / T15-T17 / Must #25-#26:
  the PURE id_token module `Nebu.OAuth.IdToken`.

  Pinned API:

    * `claims(%{issuer:, user_id:, client_id:, auth_time:, nonce:}, now) :: map` — EXACTLY `iss`,
      `sub`, `aud` (a STRING), `iat` = now, `exp` = now + 300, `auth_time` (omitted when nil), `nonce`
      (only when non-nil). Nothing else (no email/name/at_hash/azp).
    * `sign(claims, %{kid: kid, jwk: %JOSE.JWK{}}) :: compact JWS` — protected header EXACTLY
      `{"alg":"ES256","kid":kid,"typ":"JWT"}`; `alg` is a constant in code, never read from the key.

  Red today: `Nebu.OAuth.IdToken` does not exist. Key material is never inspected in a failure
  message (Trap 8): only kids are compared.
  """
  use ExUnit.Case, async: true

  @m Nebu.OAuth.IdToken

  @base %{
    issuer: "https://nebu.example.com",
    user_id: "@alice:test.local",
    client_id: "client-123",
    auth_time: 1_700_000_000,
    nonce: "client-nonce-xyz"
  }

  defp claims(input, now), do: apply(@m, :claims, [input, now])
  defp sign(c, key), do: apply(@m, :sign, [c, key])

  defp new_key do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    %{kid: JOSE.JWK.thumbprint(jwk), jwk: jwk}
  end

  defp header(compact) do
    [h | _] = String.split(compact, ".")
    h |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp verify(compact, %{jwk: jwk}) do
    case JOSE.JWT.verify_strict(JOSE.JWK.to_public(jwk), ["ES256"], compact) do
      {true, %JOSE.JWT{fields: f}, _} -> {:ok, f}
      _ -> :error
    end
  end

  describe "AC12/T16 — claims/2 (exact claim set)" do
    test "code grant: iss, sub, aud (string), iat, exp = iat + 300, auth_time, nonce — nothing else" do
      now = 1_800_000_000

      assert claims(@base, now) == %{
               "iss" => "https://nebu.example.com",
               "sub" => "@alice:test.local",
               "aud" => "client-123",
               "iat" => now,
               "exp" => now + 300,
               "auth_time" => 1_700_000_000,
               "nonce" => "client-nonce-xyz"
             }
    end

    test "no nonce (refresh grant, or the authorize request had none) => no nonce member" do
      c = claims(%{@base | nonce: nil}, 100)
      refute Map.has_key?(c, "nonce")
      assert Enum.sort(Map.keys(c)) == ~w(aud auth_time exp iat iss sub)
    end

    test "auth_time nil => the auth_time member is omitted" do
      c = claims(%{@base | auth_time: nil, nonce: nil}, 100)
      assert Enum.sort(Map.keys(c)) == ~w(aud exp iat iss sub)
    end

    test "aud is the client_id as a STRING (not an array)" do
      assert is_binary(claims(@base, 1)["aud"])
    end

    test "never personal data or optional code-flow claims" do
      c = claims(@base, 1)
      for k <- ~w(email name preferred_username at_hash azp c_hash sid), do: refute(Map.has_key?(c, k))
    end
  end

  describe "AC12/T17 — sign/2 (ES256, header exactly alg/kid/typ, verifiable)" do
    test "the protected header is exactly {alg: ES256, kid, typ: JWT}" do
      key = new_key()
      token = sign(claims(@base, System.system_time(:second)), key)
      assert is_binary(token) and length(String.split(token, ".")) == 3
      assert header(token) == %{"alg" => "ES256", "kid" => key.kid, "typ" => "JWT"}
    end

    test "the signature verifies with the PUBLIC key (verify_strict, ES256 only) and carries the claims" do
      key = new_key()
      c = claims(@base, System.system_time(:second))
      token = sign(c, key)
      assert {:ok, ^c} = verify(token, key)
    end

    test "another key does not verify it" do
      token = sign(claims(@base, 1), new_key())
      assert verify(token, new_key()) == :error
    end

    for alg <- ["none", "HS256", "RS256"] do
      test "a key map carrying \"alg\": #{inspect(alg)} cannot change the header (alg is a code constant)" do
        jwk = JOSE.JWK.generate_key({:ec, "P-256"})
        {_, map} = JOSE.JWK.to_map(jwk)
        tainted = JOSE.JWK.from_map(Map.put(map, "alg", unquote(alg)))
        key = %{kid: JOSE.JWK.thumbprint(jwk), jwk: tainted}

        token = sign(claims(@base, 1), key)
        assert header(token)["alg"] == "ES256"
        refute header(token)["alg"] == "none"
        assert {:ok, _} = verify(token, %{jwk: jwk})
      end
    end

    test "the compact token contains no private key member" do
      key = new_key()
      token = sign(claims(@base, 1), key)
      {_, %{"d" => d}} = JOSE.JWK.to_map(key.jwk)
      refute String.contains?(token, d)
      refute header(token) |> Map.has_key?("jwk")
    end
  end
end
