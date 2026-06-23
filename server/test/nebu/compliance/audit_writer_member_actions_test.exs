defmodule Nebu.Compliance.AuditWriterMemberActionsTest do
  # async: false — this test mutates the process-global Application env key
  # {:compliance, :repo} (FakeRepo injection). Run concurrently with the other
  # AuditWriter test (which mutates the same key), a transient window where the
  # key is unset falls back to the un-started Nebu.Repo → "could not lookup Ecto
  # repo". Serialising the AuditWriter env-injection tests removes that race.
  use ExUnit.Case, async: false

  # ─── Bug regression (merge room-management-elixir → full-elixir-stack) ───────
  #
  # The merge introduced admin-initiated room membership changes that emit the
  # audit action strings "member_added" / "member_removed"
  # (Nebu.Matrix.EventDispatcher.Server.admin_add_room_member/3 and
  # admin_remove_room_member/3), but the AuditWriter @known_actions allowlist was
  # NOT extended with those two actions. As a result AuditWriter.log/6 returns
  # {:error, :audit_unknown_action}, logs "rejected unknown audit action", and the
  # admin membership change is NEVER written to audit_log — a broken audit trail.
  #
  # These tests FAIL against the current code (allowlist lacks the two actions)
  # and pass once "member_added" and "member_removed" are added to @known_actions.
  #
  # Persistenz-Strategie: Option C — Stateless. AuditWriter has no GenServer state.
  # No crash/restart test required.
  #
  # Test strategy mirrors audit_writer_test.exs: a FakeRepo (Agent-backed) replaces
  # Nebu.Repo so no PostgreSQL is needed and we can assert exactly one row was
  # persisted with the expected action.

  # ─── FakeRepo (mirrors audit_writer_test.exs) ────────────────────────────────

  defmodule FakeRepo do
    @moduledoc "In-process fake for Nebu.Repo. Test-private."

    def transaction(fun) when is_function(fun, 0) do
      result = fun.()
      {:ok, result}
    end

    def insert(struct, _opts \\ []) do
      bucket = Application.get_env(:compliance, :__test_fake_repo_bucket__)
      if bucket, do: Agent.update(bucket, fn rows -> [struct | rows] end)
      {:ok, struct}
    end

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  # ─── Setup ────────────────────────────────────────────────────────────────────

  setup do
    {:ok, bucket} = Agent.start_link(fn -> [] end)
    Application.put_env(:compliance, :__test_fake_repo_bucket__, bucket)
    Application.put_env(:compliance, :repo, FakeRepo)

    on_exit(fn ->
      Application.delete_env(:compliance, :__test_fake_repo_bucket__)
      Application.delete_env(:compliance, :repo)
    end)

    {:ok, bucket: bucket}
  end

  # ─── AC1: "member_added" is a known action and persists one row ──────────────

  test ~s|log/6 — action "member_added" returns {:ok, _} and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "@admin:test.local",
        "member_added",
        "room",
        "!room123:test.local",
        %{"user_id" => "@bob:test.local"},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"member_added" must be in the AuditWriter @known_actions allowlist, | <>
             "got #{inspect(result)}"

    assert result == :ok, "expected :ok, got #{inspect(result)}"

    rows = Agent.get(bucket, & &1)

    assert length(rows) == 1,
           ~s|expected exactly one audit_log row for "member_added", got #{length(rows)}|

    [row] = rows

    assert row.action == "member_added",
           ~s|expected persisted row action="member_added", got #{inspect(row.action)}|
  end

  # ─── AC2: "member_removed" is a known action and persists one row ────────────

  test ~s|log/6 — action "member_removed" returns {:ok, _} and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "@admin:test.local",
        "member_removed",
        "room",
        "!room123:test.local",
        %{"user_id" => "@bob:test.local"},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"member_removed" must be in the AuditWriter @known_actions allowlist, | <>
             "got #{inspect(result)}"

    assert result == :ok, "expected :ok, got #{inspect(result)}"

    rows = Agent.get(bucket, & &1)

    assert length(rows) == 1,
           ~s|expected exactly one audit_log row for "member_removed", got #{length(rows)}|

    [row] = rows

    assert row.action == "member_removed",
           ~s|expected persisted row action="member_removed", got #{inspect(row.action)}|
  end

  # ─── room_visibility_changed is a known action and persists one row ──────────
  # Emitted by Server.update_room_visibility (room-management rm1); was missing
  # from the allowlist after the merge → admin visibility toggles went un-audited.

  test ~s|log/6 — action "room_visibility_changed" returns {:ok, _} and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "@admin:test.local",
        "room_visibility_changed",
        "room",
        "!room123:test.local",
        %{"visibility" => "public"},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"room_visibility_changed" must be in the AuditWriter @known_actions allowlist, | <>
             "got #{inspect(result)}"

    assert result == :ok, "expected :ok, got #{inspect(result)}"

    rows = Agent.get(bucket, & &1)

    assert length(rows) == 1,
           ~s|expected exactly one audit_log row for "room_visibility_changed", got #{length(rows)}|

    [row] = rows

    assert row.action == "room_visibility_changed",
           ~s|expected persisted row action="room_visibility_changed", got #{inspect(row.action)}|
  end
end
