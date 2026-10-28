defmodule Nebu.OAuth.OAuthPayloadRedactionTest do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval`, AC7 (payload redaction).

  The story extends `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` so that the secrets of the
  upcoming OAuth token/authorize endpoints (stories 2-4) are already redacted:
  `code`, `code_verifier`, `refresh_token`, `client_secret`.

  Client metadata (`redirect_uris`, `client_name`, `logo_uri`, `client_uri`, …) are public
  application identifiers and MUST NOT be redacted.
  """
  use ExUnit.Case, async: true

  alias Nebu.Web.Plugs.RequestLogger.PayloadRedactor, as: R

  @redacted "***REDACTED***"

  describe "AC7 — OAuth secrets are redacted (map payloads, any depth)" do
    for key <- ~w(code code_verifier refresh_token client_secret) do
      test "top-level #{key}" do
        out = R.redact_payload(%{unquote(key) => "plaintext-secret-value", "grant_type" => "authorization_code"})
        assert out[unquote(key)] == @redacted
        assert out["grant_type"] == "authorization_code"
      end

      test "nested #{key}" do
        out = R.redact_payload(%{"outer" => %{"inner" => [%{unquote(key) => "plaintext-secret-value"}]}})
        refute inspect(out) =~ "plaintext-secret-value"
      end
    end

    test "keys are matched case-insensitively (Code, CODE_VERIFIER)" do
      out = R.redact_payload(%{"Code" => "abc123", "CODE_VERIFIER" => "verif456"})
      refute inspect(out) =~ "abc123"
      refute inspect(out) =~ "verif456"
    end
  end

  describe "AC7 — OAuth secrets are redacted in form-encoded / query-string payloads" do
    test "application/x-www-form-urlencoded token request body" do
      raw = "grant_type=authorization_code&code=abc123secret&code_verifier=verif456secret&client_id=cid"
      out = R.redact_payload(raw)
      refute out =~ "abc123secret"
      refute out =~ "verif456secret"
      assert out =~ "client_id=cid", "non-secret fields must survive"
    end

    test "authorize-callback query string (?code=...&state=...)" do
      out = R.redact_payload("code=cbsecret999&state=xyz")
      refute out =~ "cbsecret999"
    end
  end

  describe "AC7 — client metadata is NOT redacted at INFO/DEBUG (public app identifiers)" do
    test "redirect_uris, client_name, client_uri, logo_uri survive" do
      meta = %{
        "client_name" => "TestApp",
        "client_uri" => "https://testapp.example.com",
        "logo_uri" => "https://testapp.example.com/logo.png",
        "redirect_uris" => ["https://testapp.example.com/callback"]
      }

      assert R.redact_payload(meta) == meta
    end

    test "metadata survives but a nested client_secret in the same payload is redacted" do
      out =
        R.redact_payload(%{
          "client_name" => "TestApp",
          "redirect_uris" => ["https://testapp.example.com/callback"],
          "client_secret" => "dont-log-me"
        })

      assert out["client_name"] == "TestApp"
      assert out["redirect_uris"] == ["https://testapp.example.com/callback"]
      assert out["client_secret"] == @redacted
    end
  end

  describe "AC7 — extension point is documented for stories 2-4" do
    test "the redactor moduledoc names the OAuth secret keys" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(R)
      for key <- ~w(code_verifier client_secret refresh_token), do: assert(doc =~ key)
      assert doc =~ "OAuth", "document the OAuth extension point in the PayloadRedactor moduledoc"
    end
  end
  # ── story 3 (oauth-token-endpoint, AC19): id_token joins the credential keys ──

  describe "AC19 (story 3) — id_token is redacted and token-endpoint payloads are fully masked" do
    test "top-level and nested id_token (map payloads)" do
      out = R.redact_payload(%{"id_token" => "eyJ.idtoken-secret.sig", "token_type" => "Bearer"})
      assert out["id_token"] == @redacted
      assert out["token_type"] == "Bearer"
      refute inspect(R.redact_payload(%{"a" => [%{"id_token" => "eyJ.nested-idtoken.sig"}]})) =~ "nested-idtoken"
    end

    test "id_token in a form-encoded / query-string payload" do
      out = R.redact_payload("id_token=eyJ.form-idtoken.sig&state=keep-me")
      refute out =~ "form-idtoken"
      assert out =~ "keep-me"
    end

    test "a complete token-endpoint response map masks access, refresh and id token" do
      response = %{
        "access_token" => "at-SECRET-0123456789",
        "refresh_token" => "rt-SECRET-0123456789",
        "id_token" => "eyJ.idt-SECRET.sig",
        "token_type" => "Bearer",
        "expires_in" => 900,
        "scope" => "urn:matrix:client:api:*"
      }

      out = R.redact_payload(response)
      for k <- ~w(access_token refresh_token id_token), do: assert(out[k] == @redacted, "#{k} not masked")
      refute inspect(out) =~ "SECRET"
      assert out["expires_in"] == 900
      assert out["token_type"] == "Bearer"
    end

    test "a token request body code=...&code_verifier=...&refresh_token=... is fully masked" do
      out = R.redact_payload("grant_type=refresh_token&code=c-SECRET-1&code_verifier=v-SECRET-2&refresh_token=r-SECRET-3&client_id=cid")
      refute out =~ "SECRET"
      assert out =~ "client_id=cid"
    end

    test "the moduledoc names id_token" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(R)
      assert doc =~ "id_token"
    end
  end

  # ── story 4 (oauth-token-revocation-logout, AC12 / R22): `token` is already a credential key ──
  # Confirmation test (no PayloadRedactor change by design): green before and after story 4.

  describe "AC12/R22 (story 4) — revocation payloads mask `token`" do
    test "token=...&token_type_hint=...&client_id=... (form string) masks the token value" do
      out = R.redact_payload("token=rv-SECRET-0123456789abcdef&token_type_hint=access_token&client_id=cid")
      refute out =~ "rv-SECRET"
      assert out =~ "client_id=cid"
    end

    test "a %{\"token\" => ...} map masks the token value" do
      out = R.redact_payload(%{"token" => "rv-SECRET-map-value", "token_type_hint" => "refresh_token"})
      assert out["token"] == @redacted
      refute inspect(out) =~ "rv-SECRET"
    end
  end

  # ── story 6 (oauth-account-management, A22): csrf_token joins the credential keys ──

  describe "A22 (story 6) — csrf_token is redacted" do
    test "map key and form string" do
      out = R.redact_payload(%{"csrf_token" => "csrf-SECRET-value", "device_id" => "KEEPDEV"})
      assert out["csrf_token"] == @redacted
      assert out["device_id"] == "KEEPDEV"
      refute R.redact_payload("device_id=KEEPDEV&csrf_token=csrf-SECRET-form") =~ "csrf-SECRET-form"
    end
  end
end
