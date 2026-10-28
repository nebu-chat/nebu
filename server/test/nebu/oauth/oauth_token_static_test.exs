defmodule Nebu.OAuth.OAuthTokenStaticTest do
  @moduledoc """
  RED-phase static acceptance tests for story `oauth-token-endpoint` (story 3 of epic
  oauth-broker), no DB:

    * T1 / ADR-020 module boundaries: the new OAuth modules exist; `lib/nebu/oauth/*.ex` never names
      the Matrix-internal session modules (`Nebu.Matrix.Session.*`, `Nebu.Matrix.HttpPublic`,
      `Nebu.Matrix.DeviceKeyStore`) or `Nebu.Web.Plugs.OidcPlug`; the Matrix side lives in
      `Nebu.Matrix.OAuthSession` / `Nebu.Matrix.Session.OAuthSessionStore`, reachable only through
      five documented `Nebu.Matrix` facade functions.
    * must-test 4: the PKCE comparison uses `Plug.Crypto.secure_compare/2`.
    * T17: the id_token algorithm is the constant `ES256` (never `none`).
    * T23 / AC1 / AC21: `JsonBody` skips `/oauth2/token`; the router forwards `/oauth2/token`,
      `/oauth2/jwks` and serves `/.well-known/openid-configuration`; `/oauth2/revoke` is routed
      since story 4 (changed deliberately).

  Red today: none of the files / routes / facade functions exist.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  defp read(rel), do: File.read!(Path.join(@lib, rel))
  defp code(rel), do: rel |> read() |> String.replace(~r/#[^\n]*/, "")

  describe "T1 — module files exist" do
    for f <- ~w(oauth/token.ex oauth/token_request.ex oauth/id_token.ex oauth/signing_key_store.ex
                matrix/oauth_session.ex matrix/session/oauth_session_store.ex) do
      test "lib/nebu/#{f} exists" do
        assert File.exists?(Path.join(@lib, "nebu/" <> unquote(f))), "lib/nebu/#{unquote(f)} missing"
      end
    end
  end

  describe "T1 — ADR-020 boundary: lib/nebu/oauth/*.ex only talks to the Nebu.Matrix facade" do
    test "no OAuth file names Matrix-internal session modules or the OidcPlug" do
      files = Path.wildcard(Path.join(@lib, "nebu/oauth/*.ex")) ++ [Path.join(@lib, "nebu/oauth.ex")]
      assert Enum.any?(files, &String.ends_with?(&1, "token.ex")), "token.ex must exist for this check to be meaningful"

      for f <- files, forbidden <- ["Nebu.Matrix.Session.", "Nebu.Matrix.HttpPublic", "Nebu.Matrix.DeviceKeyStore", "Nebu.Web.Plugs.OidcPlug"] do
        refute File.read!(f) =~ forbidden, "#{Path.basename(f)} must not name #{forbidden} (use the Nebu.Matrix facade, T1)"
      end
    end

    test "Nebu.Matrix exports the five documented facade functions" do
      assert {:module, _} = Code.ensure_loaded(Nebu.Matrix)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Nebu.Matrix)

      for {fun, arity} <- [
            oauth_issue_session: 1,
            oauth_resolve_refresh_token: 1,
            oauth_refresh_session: 4,
            oauth_revoke_device_session: 2,
            oauth_revoke_sessions_for_code: 1
          ] do
        assert function_exported?(Nebu.Matrix, fun, arity), "Nebu.Matrix.#{fun}/#{arity} missing"

        doc =
          Enum.find_value(docs, fn
            {{:function, ^fun, ^arity}, _, _, %{"en" => d}, _} -> d
            _ -> nil
          end)

        assert is_binary(doc) and doc != "", "Nebu.Matrix.#{fun}/#{arity} needs a @doc (ADR-020 facade)"
      end
    end
  end

  describe "must-test 4 / T17 — constant-time PKCE, constant ES256" do
    test "token_request.ex compares the S256 challenge with Plug.Crypto.secure_compare/2" do
      assert code("nebu/oauth/token_request.ex") =~ "Plug.Crypto.secure_compare"
    end

    test "id_token.ex signs with the constant ES256 and never mentions alg none" do
      src = code("nebu/oauth/id_token.ex")
      assert src =~ ~s("ES256")
      refute src =~ ~r/"none"/i
    end
  end

  describe "T23 / AC1 / AC21 — plugs and routes" do
    test "JsonBody skips /oauth2/token (the raw body is read once by Nebu.OAuth.Token)" do
      # test review (f): loose pin (behaviour covered by oauth_token_http_test: JSON/form bodies are
      # read once by the handler); only the skip entry for the token path is required.
      assert code("nebu/web/plugs/json_body.ex") =~ ~r/"oauth2"\s*,\s*"token"|\/oauth2\/token/
    end

    test "the router forwards /oauth2/token and /oauth2/jwks to Nebu.OAuth.Http and serves /.well-known/openid-configuration" do
      # test review (f): loose pin; the routing BEHAVIOUR is covered by the HTTP tests.
      src = code("nebu/web/router.ex")
      assert src =~ ~r/"\/oauth2\/token"[^\n]*Nebu\.OAuth\.Http/
      assert src =~ ~r/"\/oauth2\/jwks"[^\n]*Nebu\.OAuth\.Http/
      assert src =~ "\"/.well-known/openid-configuration\""
    end

    # story 4 (oauth-token-revocation-logout, AC1 / Trap 7): changed deliberately. Story 3 pinned
    # "/oauth2/revoke stays unrouted (story 4)"; story 4 routes it (the full pin lives in
    # oauth_revoke_static_test.exs).
    test "/oauth2/revoke is routed (story 4)" do
      assert code("nebu/web/router.ex") =~ "\"/oauth2/revoke\""
    end
  end
end
