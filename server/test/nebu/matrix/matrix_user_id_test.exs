defmodule Nebu.Matrix.UserIdTest do
  @moduledoc """
  RETROACTIVE regression tests for `Nebu.Matrix.UserId` — the single source of
  truth that maps verified OIDC claims to a Matrix user_id, used by BOTH the
  public `POST /login` handler and the `OidcPlug` on every protected request. If
  the two diverged a client would log in as `@alex:localhost` but its
  sync/join/send would be attributed to `@<opaque-sub>:localhost` (and it would
  never see its own membership), so this contract must not regress.

  These tests exercise the fallback chain and localpart sanitisation, which are
  reachable WITHOUT a database: `configured_claim/0` reads
  `server_config.oidc_user_id_claim` only when `Nebu.Repo` is running, and falls
  back to `nil` otherwise — so in the DB-less container the configured-claim seam
  is inert and the standard `preferred_username → name → sub` chain applies. The
  operator-configured-claim path is covered by the `:integration` test below,
  which seeds `server_config`.

  Pure unit tests run under `--warnings-as-errors` in the DB-less container.
  """

  use ExUnit.Case, async: false

  alias Nebu.Matrix.UserId

  describe "localpart/1 fallback chain (no Repo → standard claims)" do
    test "preferred_username wins" do
      assert UserId.localpart(%{"preferred_username" => "alex"}) == "alex"
    end

    test "falls back to name when preferred_username is absent (and sanitises spaces)" do
      assert UserId.localpart(%{"name" => "Bob Smith"}) == "bob_smith"
    end

    test "falls back to sub when neither preferred_username nor name is present" do
      # an opaque Dex/Keycloak sub — uppercase letters are downcased, the rest kept
      assert UserId.localpart(%{"sub" => "CiQ123"}) == "ciq123"
    end

    test "preferred_username is preferred over both name and sub" do
      claims = %{"preferred_username" => "alex", "name" => "Bob Smith", "sub" => "CiQ123"}
      assert UserId.localpart(claims) == "alex"
    end
  end

  describe "localpart/1 sanitisation (Matrix localpart grammar)" do
    test "rejects ':' (the user_id separator) by replacing it" do
      lp = UserId.localpart(%{"preferred_username" => "alex:evil"})
      refute lp =~ ":"
      assert lp == "alex_evil"
    end

    test "downcases and replaces disallowed characters with '_'" do
      # allowed grammar: a-z 0-9 . _ = - / +
      assert UserId.localpart(%{"preferred_username" => "Foo Bar!#@x"}) == "foo_bar___x"
    end

    test "preserves the allowed special characters" do
      assert UserId.localpart(%{"preferred_username" => "a.b_c=d-e/f+g"}) == "a.b_c=d-e/f+g"
    end

    test "an empty preferred_username falls through to sub" do
      assert UserId.localpart(%{"preferred_username" => "", "sub" => "Sub99"}) == "sub99"
    end
  end

  describe "from_claims/2 (no Repo)" do
    test "assembles the full @localpart:server user_id" do
      assert UserId.from_claims(%{"preferred_username" => "alex"}, "localhost") ==
               "@alex:localhost"
    end

    test "applies the same fallback + sanitisation as localpart/1" do
      assert UserId.from_claims(%{"name" => "Bob Smith"}, "example.com") ==
               "@bob_smith:example.com"
    end
  end

  # ── operator-configured claim — needs server_config (live DB) ──────────────

  describe "from_claims/2 with an operator-configured oidc_user_id_claim" do
    @describetag :integration

    setup do
      if Process.whereis(Nebu.Repo) do
        # seed the configured claim, restore afterwards
        prev =
          case Ecto.Adapters.SQL.query(
                 Nebu.Repo,
                 "SELECT value FROM server_config WHERE key = 'oidc_user_id_claim' LIMIT 1",
                 []
               ) do
            {:ok, %{rows: [[v]]}} -> v
            _ -> nil
          end

        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "INSERT INTO server_config (key, value) VALUES ('oidc_user_id_claim', 'email') " <>
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
          []
        )

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            case prev do
              nil ->
                Ecto.Adapters.SQL.query!(
                  Nebu.Repo,
                  "DELETE FROM server_config WHERE key = 'oidc_user_id_claim'",
                  []
                )

              v ->
                Ecto.Adapters.SQL.query!(
                  Nebu.Repo,
                  "UPDATE server_config SET value = $1 WHERE key = 'oidc_user_id_claim'",
                  [v]
                )
            end
          end
        end)

        :ok
      else
        :ok
      end
    end

    test "the configured claim takes precedence over preferred_username" do
      claims = %{"preferred_username" => "alex", "email" => "ALEX@corp.example"}
      # configured claim is 'email'; '@' is downcased+replaced per the grammar
      assert UserId.from_claims(claims, "localhost") == "@alex_corp.example:localhost"
    end
  end
end
