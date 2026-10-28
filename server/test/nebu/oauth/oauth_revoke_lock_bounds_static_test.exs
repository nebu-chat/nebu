defmodule Nebu.OAuth.OAuthRevokeLockBoundsStaticTest do
  @moduledoc """
  Static guards (no DB, no network) for bugfix story `revoke-lock-bounds` (epic SEC gate 3, G3-1), AC6 / AC7 and
  decisions D1-D5: every statement the story bounds carries its bound in the source, no role-level lock timeout
  exists (D3), and the runbook / ADR / follow-ups / the story's Dev Agent Record state what is bounded.
  The behaviour itself is tested in `oauth_revoke_lock_bounds_test.exs` (integration).
  """
  use ExUnit.Case, async: true

  @server Path.expand("../../..", __DIR__)
  @docs Path.expand("../../../../docs", __DIR__)
  @store Path.join(@server, "lib/nebu/matrix/session/oauth_session_store.ex")
  @keys Path.join(@server, "lib/nebu/matrix/device_key_store.ex")
  @deploy Path.join(@docs, "architecture/07-deployment.md")
  @adr Path.join(@docs, "architecture/adr/ADR-033-authorization-server-broker-model.md")
  @followups Path.join(@docs, "stories/oauth-broker/follow-ups.md")
  @story Path.join(@docs, "stories/oauth-broker/revoke-lock-bounds.md")

  defp read!(path), do: File.read!(path)

  # the source text from `start` up to (excluding) the next `stop` marker
  defp slice!(text, start, stop) do
    [_, rest] = String.split(text, start, parts: 2)
    rest |> String.split(stop, parts: 2) |> hd()
  end

  describe "AC6 — every bounded statement carries its bound in the source (D1, D2, D3)" do
    test "D1: claim_lease/4 sets a transaction-local lock_timeout and maps the timeout to :lock_timeout" do
      body = slice!(read!(@store), "def claim_lease(", "@doc \"\"\"\n  Releases the lease")
      assert body =~ ~r/SET LOCAL lock_timeout/i, "the lease claim must run under `SET LOCAL lock_timeout = '2s'`"
      assert body =~ ":lock_timeout", "a lock timeout is its own outcome ({:error, :lock_timeout}), not the generic {:error, reason}"
      assert body =~ ~r/transaction/i, "the claim runs in a short transaction (no connection held across the IdP call)"
    end

    test "D3: release_lease/3 also runs under a transaction-local lock_timeout (a revoke cascade-deletes the lease row)" do
      body = slice!(read!(@store), "def release_lease(", "# The devices-row lock")
      assert body =~ ~r/SET LOCAL lock_timeout/i
      assert body =~ ":lock_timeout"
    end

    test "D1: OAuthSession maps the claim's lock timeout to {:unavailable, 2} (503 + Retry-After: 2)" do
      src = read!(Path.join(@server, "lib/nebu/matrix/oauth_session.ex"))
      body = slice!(src, "defp acquire_lease(", "defp run_as_holder(")
      assert body =~ ":lock_timeout", "acquire_lease/7 must handle {:error, :lock_timeout}"
      assert body =~ ~r/:lock_timeout.*\n?.*unavailable/s
    end

    test "D2: touch_last_seen/3 skips locked rows (FOR UPDATE SKIP LOCKED or an equivalent non-waiting form)" do
      body = slice!(read!(@keys), "def touch_last_seen(", "@doc \"\"\"\n  Renames")
      assert body =~ ~r/SKIP LOCKED|NOWAIT|lock_timeout/i, "touch_last_seen must not wait on a locked devices row"
    end

    test "D3: no role-level lock_timeout anywhere in the migrations (it would also bound advisory locks and teardown)" do
      for path <- Path.wildcard(Path.join(@server, "priv/migrations/*.sql")) do
        refute read!(path) =~ ~r/ALTER\s+(ROLE|DATABASE|USER)[^;]*lock_timeout/is, "#{Path.basename(path)} sets a role/database-level lock_timeout"
      end
    end

    test "D5: no migration belongs to this story (no schema change, no role setting)" do
      for path <- Path.wildcard(Path.join(@server, "priv/migrations/*.sql")), do: refute(read!(path) =~ "revoke-lock-bounds", "#{Path.basename(path)} names this story")
    end

    test "D6 (M-1): the request-path teardowns lock bounded, the revoke's own teardown (end_each) stays unbounded" do
      src = read!(@store)
      end_device = slice!(src, "def end_device(", "@sql_recheck_legacy_token")
      assert end_device =~ "bounded?" and end_device =~ "lock_device_bounded!", "end_device/4 is bounded by default (`bounded?: true`)"
      by_token = slice!(src, "def end_session_for_token(", "@doc")
      assert by_token =~ "lock_device_bounded!", "/oauth2/revoke's end_session_for_token is bounded"
      each = slice!(src, "defp end_each(", "@doc")
      assert each =~ "bounded?: false", "the client revoke's own teardown must stay unbounded (it holds the rows by design)"
    end

    test "L-2: mark_access_token_used skips locked sibling rows and does not match {:ok, _} on the UPDATE" do
      body = slice!(read!(Path.join(@server, "lib/nebu/matrix/session/matrix_session_store.ex")), "def mark_access_token_used(", "def has_open_grace_window?(")
      assert body =~ "FOR UPDATE SKIP LOCKED"
      refute body =~ "{:ok, _} =", "a failing statement is tolerated (best effort), not a MatchError"
    end

    test "L-3: touch_last_seen locks with FOR NO KEY UPDATE SKIP LOCKED (no conflict with the lease claim's KEY SHARE)" do
      body = slice!(read!(@keys), "def touch_last_seen(", "@doc \"\"\"\n  Renames")
      assert body =~ "FOR NO KEY UPDATE SKIP LOCKED"
    end

    test "AC6: the story's Dev Agent Record has the D3 audit table with the two bounded statements and a decision per row" do
      story = read!(@story)
      assert story =~ ~r/^## Dev Agent Record/m, "the dev fills the Dev Agent Record"
      [_, record] = String.split(story, ~r/^## Dev Agent Record[^\n]*\n/m, parts: 2)
      assert record =~ ~r/statement/i and record =~ ~r/path/i and record =~ ~r/bounded|accepted/i, "table: statement, file, path, bounded or accepted + reason"
      assert record =~ "claim_lease" and record =~ "touch_last_seen"
      for needle <- ["devices", "device_keys", "matrix_sessions"], do: assert(record =~ needle, "the audit lists the #{needle} writers")
    end
  end

  describe "AC7 — docs" do
    test "07-deployment 'Revoking a client' states what is bounded (issuance, rotation, lease claim: 2 s -> 503; /sync last-seen skipped) and that a huge revoke still holds the rows" do
      d = read!(@deploy)
      section = slice!(d, "### Revoking a client", "\n### ")
      assert section =~ ~r/lease/i, "the lease claim is named"
      assert section =~ ~r/last[- ]seen|touch_last_seen/i, "the /sync last-seen update is named"
      assert section =~ ~r/skipp/i, "the last-seen update is skipped, not delayed"
      assert section =~ ~r/Retry-After/, "503 + Retry-After"
      assert section =~ ~r/\bbb\b|two-phase/i, "follow-up bb stays the full fix"
    end

    test "ADR-033 CR11 names the lease claim and the skipped last-seen update and still points to follow-up bb" do
      adr = read!(@adr)
      cr11 = slice!(adr, "- **CR11 (scale).**", "- **CR12")
      assert cr11 =~ ~r/lease/i
      assert cr11 =~ ~r/last[- ]seen/i
      assert cr11 =~ ~r/\bbb\b/
    end

    test "follow-ups records the audit result and G3-1 as closed by this story" do
      t = read!(@followups)
      lines = t |> String.split("\n") |> Enum.filter(&(&1 =~ "revoke-lock-bounds"))
      assert lines != [], "a follow-ups row/line must mention story revoke-lock-bounds"
      assert Enum.any?(lines, &(&1 =~ "G3-1" and &1 =~ ~r/closed/i)), "G3-1 is marked closed there"
      assert Enum.any?(lines, &(&1 =~ ~r/audit/i)), "the D3 audit result is recorded"
    end
  end
end
