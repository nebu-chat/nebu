defmodule Nebu.OAuth.OAuthLegacyCoexistenceStaticTest do
  @moduledoc """
  Static acceptance tests for story `oauth-legacy-coexistence` (story 5 of epic
  oauth-broker), no DB:

    * C1 / Must #30 (ADR-020): `lib/nebu/matrix/**` and `lib/nebu/matrix.ex` never name
      `Nebu.OAuth.Config` / `Nebu.OAuth.Metadata`; the Matrix side asks `Nebu.OAuth.oauth_aware?/0`;
      `Nebu.OAuth.oauth_aware?/0` and `Nebu.Matrix.end_device_session/2` are exported with `@doc`.
    * C7 / Trap 1-2: both device-delete handlers decide by `conn.assigns[:auth_api]` and refuse BEFORE
      the IDOR guard, the body validation and `uia_gate`; no session-store lookup decides the API.
    * C13: no inline `revoke_by_hash` loop outside `DeviceBinding.kill_device_jwts/3`.

  They pin the boundaries and the single kill-switch implementation.
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

  # the body of a Plug.Router route matched by `header_re`, up to the next top-level `end`
  defp route_body(src, header_re) do
    case Regex.split(header_re, src, parts: 2) do
      [_, rest] -> rest |> String.split(~r/\n  end\n/, parts: 2) |> hd()
      _ -> flunk("route #{inspect(header_re.source)} not found")
    end
  end

  # the refusal: the `auth_api` assign read inline OR a helper named after OAuth (e.g.
  # `refuse_oauth_caller(conn)`), whichever comes first
  defp refusal_index!(body) do
    case Regex.run(~r/auth_api|oauth/i, body, return: :index) do
      [{i, _}] -> i
      _ -> flunk("no OAuth refusal (auth_api assign / oauth helper) in the handler")
    end
  end

  defp index!(text, needle) do
    case :binary.match(text, needle) do
      {i, _} -> i
      :nomatch -> flunk("#{inspect(needle)} not found in the handler")
    end
  end

  describe "C1/Must #30 — boundaries and facade functions" do
    # test review: comments stripped (code/1) and alias forms covered (`alias Nebu.OAuth.{Config, ...}`,
    # `alias Nebu.OAuth.Config, as: X`); the behaviour itself is covered by the AC1/AC2 tests.
    test "Matrix files never reference Nebu.OAuth.Config or Nebu.OAuth.Metadata (also via alias)" do
      files = Path.wildcard(Path.join(@lib, "nebu/matrix/**/*.ex")) ++ [Path.join(@lib, "nebu/matrix.ex")]

      for f <- files do
        src = f |> File.read!() |> String.replace(~r/#[^\n]*/, "")
        rel = Path.relative_to(f, @lib)
        refute src =~ ~r/Nebu\.OAuth\.(Config|Metadata)\b/, "#{rel} must ask Nebu.OAuth.oauth_aware?/0 (C1)"
        refute src =~ ~r/alias\s+Nebu\.OAuth\.\{[^}]*\b(Config|Metadata)\b/, "#{rel} aliases Nebu.OAuth.Config/Metadata (C1)"
      end
    end

    test "Nebu.OAuth.oauth_aware?/0 and Nebu.Matrix.end_device_session/2 are exported with @doc" do
      for {mod, fun, arity} <- [{Nebu.OAuth, :oauth_aware?, 0}, {Nebu.Matrix, :end_device_session, 2}] do
        assert {:module, _} = Code.ensure_loaded(mod)
        assert function_exported?(mod, fun, arity), "#{inspect(mod)}.#{fun}/#{arity} missing"
        assert is_binary(doc_of(mod, fun, arity)) and doc_of(mod, fun, arity) != "", "#{inspect(mod)}.#{fun}/#{arity} needs a @doc"
      end
    end

    test "HttpPublic (GET /login) and SsoLogin (action) consult Nebu.OAuth.oauth_aware?" do
      assert code("nebu/matrix/http_public.ex") =~ "Nebu.OAuth.oauth_aware?"
      assert code("nebu/matrix/sso_login.ex") =~ "Nebu.OAuth.oauth_aware?"
    end
  end

  describe "C7/Trap 1-2 — refusal FIRST, decided by the :auth_api assign" do
    test "DELETE /devices/:device_id: auth_api check precedes the IDOR guard and uia_gate; no store lookup" do
      body = route_body(code("nebu/web/router/protected.ex"), ~r/delete\s+"\/client\/v3\/devices\/:device_id"\s+do/)
      i = refusal_index!(body)
      assert i < index!(body, "belongs_to_other_user?")
      assert i < index!(body, "uia_gate")
      refute body =~ "MatrixSessionStore"
      refute body =~ "OAuthSessionStore"
    end

    test "POST /delete_devices: auth_api check precedes the body validation and uia_gate; no store lookup" do
      body = route_body(code("nebu/web/router/protected.ex"), ~r/post\s+"\/client\/v3\/delete_devices"\s+do/)
      i = refusal_index!(body)
      assert i < index!(body, ~s("devices")), "the refusal precedes the `devices` body validation"
      assert i < index!(body, "uia_gate")
      refute body =~ "MatrixSessionStore"
      refute body =~ "OAuthSessionStore"
    end
  end

  describe "C13 — one kill-switch implementation" do
    test "no inline revoke_by_hash loop in protected.ex, matrix.ex or oauth_session.ex" do
      for f <- ~w(nebu/web/router/protected.ex nebu/matrix.ex nebu/matrix/oauth_session.ex) do
        refute code(f) =~ "revoke_by_hash", "#{f} must use DeviceBinding.kill_device_jwts/3 (C13 b)"
      end

      assert code("nebu/matrix/session/device_binding.ex") =~ ~r/def\s+kill_device_jwts\(/
    end
  end
end
