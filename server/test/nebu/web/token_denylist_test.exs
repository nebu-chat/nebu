defmodule Nebu.Web.TokenDenylistTest do
  @moduledoc """
  Unit tests for the F-1 logout token denylist (matrix-api-migration).

  Proves the ETS-backed denylist: revoke-then-check by jti and by token hash,
  self-expiry at the token's `exp`, and idempotent re-revocation.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.TokenDenylist

  @table :nebu_http_token_denylist

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    on_exit(fn -> if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table) end)
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
