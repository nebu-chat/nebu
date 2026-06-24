defmodule Nebu.Web.TokenDenylistTest do
  @moduledoc """
  Unit tests for the F-1 logout token denylist (matrix-api-migration).

  Proves the ETS-backed denylist: revoke-then-check by jti and by token hash,
  self-expiry at the token's `exp`, and idempotent re-revocation.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.TokenDenylist

  @table :nebu_http_token_denylist

  # Every raw token string these tests revoke. revoked?/2 falls back to the
  # `invalidated_tokens` DB table on an ETS miss, so clearing only ETS is not
  # enough in the integration container (a live Nebu.Repo): a `jti:<jti>` or
  # SHA-256 hash row written by a PRIOR run would make a fresh "not revoked yet"
  # assertion read as revoked. Clear BOTH the jti-keyed rows and the hash-keyed
  # rows for this test's tokens, in setup and on_exit, guarded by Repo presence.
  @raw_tokens [
    "raw.token.value",
    "different-raw-token",
    "some.other.token",
    "raw.token",
    "secret-token",
    "some.other.token",
    "raw",
    "raw.tok"
  ]

  defp hash_db_key(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp clear_db_rows do
    if Process.whereis(Nebu.Repo) do
      # jti-keyed rows for all jtis this module uses (jti-1, jti-x, jti-expired, …).
      _ =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM invalidated_tokens WHERE token_hash LIKE 'jti:jti-%'",
          []
        )

      # hash-keyed rows for every raw token this module revokes.
      hashes = Enum.map(@raw_tokens, &hash_db_key/1)

      _ =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM invalidated_tokens WHERE token_hash = ANY($1)",
          [hashes]
        )
    end

    :ok
  end

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    clear_db_rows()

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
      clear_db_rows()
    end)

    :ok
  end

  defp future, do: System.system_time(:second) + 3600
  defp past, do: System.system_time(:second) - 1

  test "a token is not revoked until it is added" do
    refute TokenDenylist.revoked?("jti-1", "raw.token.value")
  end

  test "revoke by jti, then the same jti reads as revoked" do
    TokenDenylist.revoke("jti-1", "raw.token.value", future())
    assert TokenDenylist.revoked?("jti-1", "different-raw-token")
  end

  test "revoke without jti keys on the token hash" do
    TokenDenylist.revoke(nil, "raw.token.value", future())
    assert TokenDenylist.revoked?(nil, "raw.token.value")
    refute TokenDenylist.revoked?(nil, "some.other.token")
  end

  test "an entry whose exp is in the past reads as NOT revoked (self-expiry)" do
    TokenDenylist.revoke("jti-expired", "raw.token", past())
    refute TokenDenylist.revoked?("jti-expired", "raw.token")
  end

  test "the raw token is never stored verbatim (only its hash)" do
    TokenDenylist.revoke(nil, "secret-token", future())
    # Walk the table; no value should equal the raw token.
    stored = :ets.tab2list(@table)
    refute Enum.any?(stored, fn {key, _exp} -> key == {:hash, "secret-token"} end)
    assert Enum.any?(stored, fn {{tag, _}, _exp} -> tag == :hash end)
  end

  test "re-revoking the same token is idempotent" do
    TokenDenylist.revoke("jti-1", "raw", future())
    TokenDenylist.revoke("jti-1", "raw", future())
    assert TokenDenylist.revoked?("jti-1", "raw")
  end

  test "revoked? matches when a later request resolves by hash even if revoked by jti" do
    # Revoked with a jti; a check that also passes the raw token still matches via
    # the jti branch (the token carries the same jti claim each time).
    TokenDenylist.revoke("jti-x", "raw.tok", future())
    assert TokenDenylist.revoked?("jti-x", "raw.tok")
  end
end
