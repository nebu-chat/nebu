defmodule Nebu.Compliance.AuditWriterMediaActionsTest do
  @moduledoc """
  Allowlist regression test for `media-security-admin-control/
  4c-infected-scanfailed-audit-bridge` (Acceptance Test 4) — mirrors
  `AuditWriterMemberActionsTest` exactly (same `FakeRepo`-injection pattern),
  and exists precisely to fail loudly against `AuditWriter.@known_actions`
  rather than against `Nebu.Workers.MediaScanWorker`, per this repo's
  documented history of a branch merge silently dropping actions from the
  allowlist (`member_added`/`member_removed`/`room_visibility_changed`
  falling out — see `AuditWriterMemberActionsTest`'s own moduledoc).
  """

  use ExUnit.Case, async: false

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

  test ~s|log/6 — action "media_infected_detected" returns :ok and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_scan_worker",
        "media_infected_detected",
        "media",
        "media-infected-1",
        %{
          media_id: "media-infected-1",
          filename: "eicar.txt",
          sha256: "deadbeef",
          uploader_id: "@uploader:test.local",
          clamav_signature: "Eicar-Test-Signature"
        },
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_infected_detected" must be in @known_actions, got #{inspect(result)}|

    assert result == :ok

    rows = Agent.get(bucket, & &1)
    assert length(rows) == 1
    [row] = rows
    assert row.action == "media_infected_detected"
    assert row.target_type == "media"
    assert row.target_id == "media-infected-1"
    assert row.outcome == "success"
  end

  test ~s|log/6 — action "media_scan_failed" returns :ok and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_scan_worker",
        "media_scan_failed",
        "media",
        "media-exhausted-1",
        %{
          media_id: "media-exhausted-1",
          filename: "corrupt.bin",
          sha256: "cafebabe",
          uploader_id: "@uploader:test.local",
          reason: "max_attempts_exhausted"
        },
        "failure"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_scan_failed" must be in @known_actions, got #{inspect(result)}|

    assert result == :ok

    rows = Agent.get(bucket, & &1)
    assert length(rows) == 1
    [row] = rows
    assert row.action == "media_scan_failed"
    assert row.target_type == "media"
    assert row.target_id == "media-exhausted-1"
    assert row.outcome == "failure"
  end

  # media-security-admin-control/8a-media-cleanup-worker (AC9/AC10) — dedicated
  # allowlist regression test for "media_hard_deleted", mirroring the two
  # tests above exactly (same FakeRepo-injection pattern). Exists precisely
  # to fail loudly against `AuditWriter.@known_actions` rather than against
  # `Nebu.Workers.MediaCleanupWorker`, per this repo's documented history of a
  # branch merge silently dropping actions from the allowlist (this story's
  # own AC10, and 4c/6a's identical documented footgun). Currently RED:
  # `"media_hard_deleted"` is not yet in `@known_actions` in
  # `server/lib/nebu/compliance/audit_writer.ex`.
  test ~s|log/6 — action "media_hard_deleted" returns :ok and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_cleanup_worker",
        "media_hard_deleted",
        "media",
        "media-hard-deleted-1",
        %{
          from_state: "deleted",
          file_hash: "deadbeef",
          bytes_freed: 4096,
          uploader_user_id: "@uploader:test.local",
          retention_days: 30
        },
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_hard_deleted" must be in @known_actions, got #{inspect(result)}|

    assert result == :ok

    rows = Agent.get(bucket, & &1)
    assert length(rows) == 1
    [row] = rows
    assert row.action == "media_hard_deleted"
    assert row.target_type == "media"
    assert row.target_id == "media-hard-deleted-1"
    assert row.outcome == "success"
  end

  # media-security-admin-control/10d-scan-kill-switch (AC7, Acceptance Test 6)
  # — dedicated allowlist regression test for "media_unscanned_release",
  # mirroring the tests above exactly (same FakeRepo-injection pattern).
  # Exists precisely to fail loudly against `AuditWriter.@known_actions`
  # rather than against `Nebu.Workers.MediaScanWorker`, per this repo's
  # documented history of a branch merge silently dropping actions from the
  # allowlist (4c's/6a's/8a's identical documented footgun). Currently RED:
  # "media_unscanned_release" is not yet in `@known_actions` in
  # `server/lib/nebu/compliance/audit_writer.ex`.
  test ~s|log/6 — action "media_unscanned_release" returns :ok and persists exactly one row|,
       %{bucket: bucket} do
    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_scan_worker",
        "media_unscanned_release",
        "media",
        "media-unscanned-1",
        %{
          media_id: "media-unscanned-1",
          filename: "unscanned.bin",
          sha256: "sha256-unscanned",
          uploader_id: "@uploader:test.local",
          reason: "clamav_unavailable"
        },
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_unscanned_release" must be in @known_actions, got #{inspect(result)}|

    assert result == :ok

    rows = Agent.get(bucket, & &1)
    assert length(rows) == 1
    [row] = rows
    assert row.action == "media_unscanned_release"
    assert row.target_type == "media"
    assert row.target_id == "media-unscanned-1"
    assert row.outcome == "success"
  end
end
