defmodule Nebu.Matrix.Session.MatrixSessionStoreTest do
  @moduledoc """
  RED-phase ATDD tests for `oidc-session-refresh` — store layer.

  Unit-level CRUD + grace-period semantics for
  `Nebu.Matrix.Session.MatrixSessionStore`. Mirrors the Go reference
  `gateway/internal/db/matrix_session_store_test.go`.

  ## Why these MUST FAIL right now

  The module `Nebu.Matrix.Session.MatrixSessionStore` does not exist yet
  (see story File List — it is a *New* file). Every test calls a public
  function on that module, so they fail (UndefinedFunctionError) until the
  dev phase implements it.

  ## DB-backed, no mocks (ADR-018)

  The `matrix_sessions` table already exists in the canonical schema
  (`server/priv/migrations/000001_init.up.sql`) — NO new migration. These
  tests INSERT/SELECT against the *real* test Postgres via the store, and
  manipulate `grace_until` / `expires_at` directly through `Nebu.Repo`
  (`Ecto.Adapters.SQL.query`) instead of sleeping, so they are deterministic.

  Tagged `:integration` — excluded from `mix test` (no DB); runs via
  `make test-integration` (sets NEBU_DB_URL, starts Nebu.Repo). Same pattern
  as the other `server/test/nebu/matrix/*_integration_test.exs`.

  Covered ACs (store layer): AC4 (grace period), AC6 (unknown/used RT).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  # ── helpers ────────────────────────────────────────────────────────────────

  # 32 random bytes → 64 lowercase hex chars, no dots (the opaque-token format
  # the store itself should produce; here we only need *valid* opaque values).
  defp opaque, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp unique_user, do: "@store_#{System.unique_integer([:positive])}:test.local"
  defp unique_device, do: "DEV_#{System.unique_integer([:positive])}"

  # Direct DB poke (no sleeping) — set grace_until/expires_at on a row.
  defp set_column(access_token, column, sql_value) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "UPDATE matrix_sessions SET #{column} = #{sql_value} WHERE access_token = $1",
        [access_token]
      )

    :ok
  end

  defp create_session(opts \\ []) do
    at = Keyword.get(opts, :access_token, opaque())
    rt = Keyword.get(opts, :refresh_token, opaque())

    :ok =
      Store.create(%{
        access_token: at,
        refresh_token: rt,
        user_id: Keyword.get(opts, :user_id, unique_user()),
        device_id: Keyword.get(opts, :device_id, unique_device()),
        expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second)),
        oidc_refresh_token: Keyword.get(opts, :oidc_refresh_token)
      })

    %{access_token: at, refresh_token: rt}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # create/1 + get_by_access_token/1 + get_by_refresh_token/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "create/1 and lookups" do
    test "create then get_by_access_token returns the session fields" do
      user = unique_user()
      device = unique_device()
      %{access_token: at} = create_session(user_id: user, device_id: device)

      assert {:ok, sess} = Store.get_by_access_token(at)
      assert sess.user_id == user
      assert sess.device_id == device
      assert sess.expires_at
    end

    test "create then get_by_refresh_token returns the session fields" do
      user = unique_user()
      %{refresh_token: rt} = create_session(user_id: user)

      assert {:ok, sess} = Store.get_by_refresh_token(rt)
      assert sess.user_id == user
    end

    test "get_by_access_token for an unknown token → :error" do
      assert :error = Store.get_by_access_token(opaque())
    end

    test "get_by_refresh_token for an unknown token → :error (AC6)" do
      assert :error = Store.get_by_refresh_token(opaque())
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # rotate_tokens/1 — atomic soft-revoke of the old row + insert of the new row
  # ══════════════════════════════════════════════════════════════════════════

  describe "rotate_tokens/1" do
    test "issues a new AT+RT pair retrievable by the new tokens" do
      %{access_token: at_a} = create_session()
      new_at = opaque()
      new_rt = opaque()

      assert :ok =
               Store.rotate_tokens(%{
                 old_access_token: at_a,
                 new_access_token: new_at,
                 new_refresh_token: new_rt,
                 new_expires_at: DateTime.add(DateTime.utc_now(), 8 * 3600, :second)
               })

      assert {:ok, _} = Store.get_by_access_token(new_at)
      assert {:ok, _} = Store.get_by_refresh_token(new_rt)
    end

    test "rotating an unknown old access token → :error" do
      assert :error =
               Store.rotate_tokens(%{
                 old_access_token: opaque(),
                 new_access_token: opaque(),
                 new_refresh_token: opaque(),
                 new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })
    end

    test "carries over the encrypted OIDC refresh token to the new row" do
      enc = "ENCRYPTED_OIDC_RT_PLACEHOLDER"
      %{access_token: at_a} = create_session(oidc_refresh_token: enc)
      new_at = opaque()
      new_rt = opaque()

      assert :ok =
               Store.rotate_tokens(%{
                 old_access_token: at_a,
                 new_access_token: new_at,
                 new_refresh_token: new_rt,
                 new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })

      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT oidc_refresh_token FROM matrix_sessions WHERE access_token = $1",
          [new_at]
        )

      assert [[^enc]] = rows
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — grace period: old RT valid once more, until the new AT is used.
  # Deterministic: we manipulate grace_until via SQL, never Process.sleep.
  # ══════════════════════════════════════════════════════════════════════════

  describe "grace period (AC4)" do
    test "after rotate, the old RT is still resolvable during the grace window" do
      %{access_token: at_a, refresh_token: rt_a} = create_session()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: at_a,
          new_access_token: opaque(),
          new_refresh_token: opaque(),
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # rotate set grace_until = NOW() + 60s on the old row → still valid.
      assert {:ok, sess} = Store.get_by_refresh_token(rt_a),
             "old RT must remain valid during the 60s grace window (Matrix MUST)"

      assert sess
    end

    test "old RT is NOT resolvable once its grace window has elapsed" do
      %{access_token: at_a, refresh_token: rt_a} = create_session()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: at_a,
          new_access_token: opaque(),
          new_refresh_token: opaque(),
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # Force the grace window into the past (no sleep).
      set_column(at_a, "grace_until", "NOW() - INTERVAL '1 second'")

      assert :error = Store.get_by_refresh_token(rt_a)
    end

    test "mark_access_token_used closes the old RT grace window early (AC4)" do
      user = unique_user()
      device = unique_device()
      %{access_token: at_a, refresh_token: rt_a} = create_session(user_id: user, device_id: device)
      new_at = opaque()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: at_a,
          new_access_token: new_at,
          new_refresh_token: opaque(),
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # Grace still open right after rotate.
      assert {:ok, _} = Store.get_by_refresh_token(rt_a)

      # First use of the new AT closes the grace window for the soft-revoked sibling.
      assert :ok = Store.mark_access_token_used(new_at)

      assert :error = Store.get_by_refresh_token(rt_a),
             "after the new AT is used, the old RT must no longer be valid (AC4)"
    end

    test "mark_access_token_used is idempotent (no error on a token with no open grace siblings)" do
      %{access_token: at} = create_session()
      assert :ok = Store.mark_access_token_used(at)
      assert :ok = Store.mark_access_token_used(at)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # revoke/1 — hard delete (logout)
  # ══════════════════════════════════════════════════════════════════════════

  describe "revoke/1" do
    test "revoke removes the row; subsequent AT lookup → :error" do
      %{access_token: at} = create_session()
      assert {:ok, _} = Store.get_by_access_token(at)

      assert :ok = Store.revoke(at)
      assert :error = Store.get_by_access_token(at)
    end

    # MINOR-1: logout must also delete the rotated soft-revoked sibling(s) for the
    # same (user_id, device_id), not just the presented row.
    test "revoke also deletes rotated soft-revoked siblings (MINOR-1)" do
      user = unique_user()
      device = unique_device()
      %{access_token: at_a} = create_session(user_id: user, device_id: device)
      new_at = opaque()
      new_rt = opaque()

      :ok =
        Store.rotate_tokens(%{
          old_access_token: at_a,
          new_access_token: new_at,
          new_refresh_token: new_rt,
          new_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # Two rows now exist for (user, device): the soft-revoked old one + the new one.
      # Logout presents the new (active) AT.
      assert :ok = Store.revoke(new_at)

      # Neither the new row nor the lingering old sibling remain.
      assert :error = Store.get_by_access_token(new_at)
      assert :error = Store.get_by_access_token(at_a)

      {:ok, %{rows: [[count]]}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT COUNT(*) FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
          [user, device]
        )

      assert count == 0, "no rows for (user, device) must remain after logout"
    end

    test "revoke on an unknown access token is a no-op :ok (MINOR-1)" do
      assert :ok = Store.revoke(opaque())
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # delete_for_user/1 + delete_for_user_device/2 — admin deactivation / logout
  # invalidation of opaque sessions (MINOR-2).
  # ══════════════════════════════════════════════════════════════════════════

  describe "delete_for_user/1 and delete_for_user_device/2 (MINOR-2)" do
    test "delete_for_user removes all rows for the user across devices" do
      user = unique_user()
      %{access_token: at1} = create_session(user_id: user, device_id: unique_device())
      %{access_token: at2} = create_session(user_id: user, device_id: unique_device())

      assert :ok = Store.delete_for_user(user)

      assert :error = Store.get_by_access_token(at1)
      assert :error = Store.get_by_access_token(at2)
    end

    test "delete_for_user_device removes only the matching device's rows" do
      user = unique_user()
      dev_a = unique_device()
      dev_b = unique_device()
      %{access_token: at_a} = create_session(user_id: user, device_id: dev_a)
      %{access_token: at_b} = create_session(user_id: user, device_id: dev_b)

      assert :ok = Store.delete_for_user_device(user, dev_a)

      assert :error = Store.get_by_access_token(at_a)
      assert {:ok, _} = Store.get_by_access_token(at_b),
             "other devices must remain after a per-device delete"
    end

    test "delete_for_user on a user with no sessions is a no-op :ok" do
      assert :ok = Store.delete_for_user(unique_user())
    end
  end
end
