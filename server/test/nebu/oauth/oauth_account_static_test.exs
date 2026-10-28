defmodule Nebu.OAuth.OAuthAccountStaticTest do
  @moduledoc """
  Static acceptance tests for story `oauth-account-management` (story 6 of epic
  oauth-broker), no DB:

    * A1 / Must #39 (ADR-020): the new OAuth files exist and name no Matrix-internal module; the
      Matrix facade exports the A1 functions with `@doc`; `Nebu.OAuth.cross_signing_reset_url/0`,
      `purge_expired_account_state/0` exist; no node-local state (ETS / Agent / GenServer) in the
      account modules.
    * A14 / Trap 1: the device-signing replacement branch decides OAuth by `:auth_api`.
    * A15 / Trap 4: `Nebu.Matrix.Uia` keeps the `cross_signing_reset` op away from `complete/2` and
      `load/1`.
    * A18: the Metadata moduledoc no longer lists the account fields as "deliberately NOT advertised".
    * A23: the purge worker calls both new purge functions.

  Behaviour (CORS skip, JsonBody skip, headers) is covered through HTTP in `oauth_account_test.exs`.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  defp read(rel), do: File.read!(Path.join(@lib, rel))
  defp code(rel), do: rel |> read() |> String.replace(~r/#[^\n]*/, "")

  defp doc_of(mod, fun, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    Enum.find_value(docs, fn
      {{:function, ^fun, ^arity}, _, _, %{"en" => d}, _} -> d
      _ -> nil
    end)
  end

  describe "A1/Must #39 — files, boundaries, facade" do
    for f <- ~w(oauth/account.ex oauth/account_store.ex oauth/account_pages.ex) do
      test "lib/nebu/#{f} exists" do
        assert File.exists?(Path.join(@lib, "nebu/" <> unquote(f))), "lib/nebu/#{unquote(f)} missing"
      end
    end

    test "the account OAuth files name no Matrix-internal module and keep no node-local state" do
      files = Path.wildcard(Path.join(@lib, "nebu/oauth/account*.ex"))
      assert length(files) >= 3, "the three account modules must exist"

      for f <- files do
        src = f |> File.read!() |> String.replace(~r/#[^\n]*/, "")
        rel = Path.relative_to(f, @lib)
        refute src =~ ~r/Nebu\.Matrix\.(Session|Uia|DeviceKeyStore|CrossSigningKeyStore|HttpPublic|SsoLogin|OAuthSession)\b/, "#{rel}: use the Nebu.Matrix facade (A1)"
        refute src =~ ~r/alias\s+Nebu\.Matrix\.\{/, "#{rel}: no aliasing of Matrix internals"
        refute src =~ ~r/:ets\.|Agent\.|GenServer\.|:persistent_term/, "#{rel}: no node-local state decides an A-behaviour"
      end
    end

    test "Nebu.Matrix exports the A1 facade functions with @doc" do
      assert {:module, _} = Code.ensure_loaded(Nebu.Matrix)

      for {fun, arity} <- [account_identity: 1, account_devices: 1, account_profile: 1, cross_signing_reset_requests: 1,
                           approve_cross_signing_reset: 2, decline_cross_signing_reset: 2, purge_expired_uia_sessions: 0] do
        assert function_exported?(Nebu.Matrix, fun, arity), "Nebu.Matrix.#{fun}/#{arity} missing"
        assert is_binary(doc_of(Nebu.Matrix, fun, arity)), "Nebu.Matrix.#{fun}/#{arity} needs a @doc"
      end
    end

    test "Nebu.OAuth exports cross_signing_reset_url/0 and purge_expired_account_state/0 with @doc" do
      # function_exported?/3 does not load the module (an isolated run of this file would see it unloaded)
      assert {:module, _} = Code.ensure_loaded(Nebu.OAuth)

      for {fun, arity} <- [cross_signing_reset_url: 0, purge_expired_account_state: 0] do
        assert function_exported?(Nebu.OAuth, fun, arity), "Nebu.OAuth.#{fun}/#{arity} missing"
        assert is_binary(doc_of(Nebu.OAuth, fun, arity))
      end
    end
  end

  describe "A14/A15/A18/A23 — wiring" do
    test "protected.ex: the replacement branch reads the :auth_api assign and asks Nebu.OAuth.cross_signing_reset_url/0" do
      src = code("nebu/web/router/protected.ex")
      [_, body] = String.split(src, ~r/defp\s+do_persist_cross_signing\(/, parts: 2)
      body = body |> String.split(~r/\n  defp\s/, parts: 2) |> hd()
      assert body =~ "auth_api"
      assert src =~ "Nebu.OAuth.cross_signing_reset_url"
      refute src =~ "Full UIA is out of scope", "the stale replacement-branch comment is replaced (AC14)"
    end

    test "Uia.complete/2 and load/1 exclude the cross_signing_reset op" do
      src = code("nebu/matrix/uia.ex")
      assert src =~ "cross_signing_reset"
      [_, complete] = String.split(src, ~r/def\s+complete\(session_id/, parts: 2)
      assert complete |> String.split(~r/\n  def\s/, parts: 2) |> hd() =~ "cross_signing_reset"
      [_, load] = String.split(src, ~r/def\s+load\(/, parts: 2)
      assert load |> String.split(~r/\n  def\s/, parts: 2) |> hd() =~ "cross_signing_reset"
    end

    test "the Metadata moduledoc no longer lists the account fields as not advertised" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Nebu.OAuth.Metadata)
      not_advertised = doc |> String.split(~r/deliberately NOT advertised/i, parts: 2) |> Enum.at(1, "")
      refute not_advertised |> String.split("\n\n", parts: 2) |> hd() =~ "account_management"
    end

    test "the purge worker calls purge_expired_account_state/0 and purge_expired_uia_sessions/0" do
      src = code("nebu/workers/oauth_flow_purge_worker.ex")
      assert src =~ "purge_expired_account_state"
      assert src =~ "purge_expired_uia_sessions"
      assert src =~ "purge_expired_flow_state"
    end
  end

  describe "test review — the :account_matrix_repo seam is test-only (compile-time guarded)" do
    test "every lib file reading :account_matrix_repo guards it with `if Mix.env() == :test do`" do
      files =
        Path.wildcard(Path.join(@lib, "**/*.ex"))
        |> Enum.filter(&(File.read!(&1) =~ ":account_matrix_repo"))

      assert files != [], "the Matrix account facade must honour the :account_matrix_repo seam"

      for f <- files do
        src = File.read!(f)
        assert src =~ ~r/if Mix\.env\(\) == :test do[\s\S]*:account_matrix_repo[\s\S]*else/,
               "#{Path.relative_to(f, @lib)}: the seam read must sit in the test branch of `if Mix.env() == :test do ... else ... end`"
      end
    end
  end
end

