defmodule Nebu.OAuth.OAuthRevokeStaticTest do
  @moduledoc """
  RED-phase static acceptance tests for story `oauth-token-revocation-logout` (story 4 of epic
  oauth-broker), no DB:

    * R1 / ADR-020: `lib/nebu/oauth/revoke.ex` and `form_post.ex` exist and name no Matrix-internal
      module; the facade exports `oauth_revoke_token/1` and `oauth_end_user_sessions/1` with docs;
      the web layer reaches them only through `Nebu.Matrix` (logout, erasure).
    * R1 / Must #36: `Nebu.OAuth.Token` delegates to `Nebu.OAuth.FormPost` (no own body read / cap).
    * AC1: the router comment no longer claims revoke is unrouted (forward, CORS branch and JsonBody
      skip are covered BEHAVIOURALLY by the HTTP / logging tests: test review MINOR 11).
    * AC2: the `:oauth_revoke_test_hook` seam is compile-time guarded.
    * Must #35 (cluster safety): no ETS / process state in `Revoke` or the revocation functions.

  Red today: none of the files / routes / functions exist.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  defp read(rel), do: File.read!(Path.join(@lib, rel))
  defp code(rel), do: rel |> read() |> String.replace(~r/#[^\n]*/, "")

  describe "R1 — module files exist" do
    for f <- ~w(oauth/revoke.ex oauth/form_post.ex) do
      test "lib/nebu/#{f} exists" do
        assert File.exists?(Path.join(@lib, "nebu/" <> unquote(f))), "lib/nebu/#{unquote(f)} missing"
      end
    end
  end

  describe "R1/ADR-020 — boundaries" do
    test "revoke.ex and form_post.ex name no Matrix-internal module (only the Nebu.Matrix facade)" do
      for f <- ~w(oauth/revoke.ex oauth/form_post.ex),
          forbidden <- ["Nebu.Matrix.Session.", "Nebu.Matrix.OAuthSession", "Nebu.Matrix.DeviceKeyStore", "Nebu.Matrix.HttpPublic", "Nebu.Web.Plugs.OidcPlug"] do
        refute read("nebu/" <> f) =~ forbidden, "#{f} must not name #{forbidden} (R1)"
      end

      assert code("nebu/oauth/revoke.ex") =~ "Nebu.Matrix.oauth_revoke_token", "revoke.ex reaches the Matrix side only via the facade"
    end

    test "Nebu.Matrix exports oauth_revoke_token/1 and oauth_end_user_sessions/1 with @doc" do
      assert {:module, _} = Code.ensure_loaded(Nebu.Matrix)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Nebu.Matrix)

      for {fun, arity} <- [oauth_revoke_token: 1, oauth_end_user_sessions: 1] do
        assert function_exported?(Nebu.Matrix, fun, arity), "Nebu.Matrix.#{fun}/#{arity} missing"

        doc =
          Enum.find_value(docs, fn
            {{:function, ^fun, ^arity}, _, _, %{"en" => d}, _} -> d
            _ -> nil
          end)

        assert is_binary(doc) and doc != "", "Nebu.Matrix.#{fun}/#{arity} needs a @doc (R24)"
      end
    end

    test "the logout handlers and the erasure call the facade, not Nebu.Matrix.OAuthSession / OAuthSessionStore directly" do
      protected = code("nebu/web/router/protected.ex")
      assert protected =~ "Nebu.Matrix.oauth_revoke_token", "OAuth /logout uses the facade (R1, R15)"
      assert protected =~ "Nebu.Matrix.oauth_end_user_sessions", "/logout/all uses the facade (R17)"
      refute protected =~ "OAuthSessionStore"
      refute protected =~ "Nebu.Matrix.OAuthSession."

      server = code("nebu/matrix/event_dispatcher/server.ex")
      assert server =~ "oauth_end_user_sessions", "GDPR erasure ends OAuth sessions via the facade (R19)"
    end

    # test review MINOR 11: loosened to a behavioural pin. The byte-identical token behaviour is covered
    # by the whole story-3 token suite (Must #36); statically only "no second body reader / cap".
    test "Nebu.OAuth.Token keeps no own body read or 16 KiB cap (moved to Nebu.OAuth.FormPost; Must #36)" do
      token = code("nebu/oauth/token.ex")
      assert token =~ "FormPost", "token.ex must delegate to Nebu.OAuth.FormPost"
      refute token =~ ~r/16_?384/, "the 16 KiB cap lives in FormPost only"
      refute token =~ "read_body", "the raw body is read once, in FormPost"
    end
  end

  describe "AC1/R14/AC2 — plugs, routes, seams" do
    test "the router comment no longer claims /oauth2/revoke stays unrouted" do
      refute read("nebu/web/router.ex") =~ ~r/revoke stays unrouted/i
    end

    test "the :oauth_revoke_test_hook seam is compile-time guarded (Mix.env() == :test)" do
      src = code("nebu/oauth/revoke.ex")
      assert src =~ ":oauth_revoke_test_hook"
      assert src =~ ~r/if Mix\.env\(\) == :test do/
    end

    test "Nebu.OAuth.Http moduledoc lists /oauth2/revoke and drops 'not routed yet'" do
      src = read("nebu/oauth/http.ex")
      assert src =~ "POST /oauth2/revoke"
      refute src =~ "not routed yet"
    end
  end

  describe "Must #35 — cluster safety: no node-local state decides a revocation" do
    test "revoke.ex and the Matrix revocation code use no ETS / Agent / GenServer / persistent_term" do
      for f <- ~w(oauth/revoke.ex oauth/form_post.ex matrix/oauth_session.ex matrix/session/oauth_session_store.ex),
          forbidden <- [":ets.", "Agent.", "GenServer.", ":persistent_term"] do
        refute code("nebu/" <> f) =~ forbidden, "#{f} must not use #{forbidden} (ADR-020 cluster safety)"
      end
    end

    test "the store takes the PLAINTEXT token and hashes it once (pass-the-hash guard, Trap 10)" do
      src = code("nebu/matrix/session/oauth_session_store.ex")
      assert src =~ ~r/def\s+end_session_for_token\(/
      refute src =~ ~r/def\s+end_session_for_token\(\s*\w*hash/
      refute src =~ "old_access_token_hash"
    end
  end
end
