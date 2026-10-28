defmodule Nebu.Compliance.AuditWriterSpaceActionsTest do
  @moduledoc """
  Story `space-edit-audit` (follow-up `dj`), AC6 / D4: the four space-edit actions are in the `@known_actions` allowlist of `Nebu.Compliance.AuditWriter`.

  Dropping one would make the row silently vanish (`{:error, :audit_unknown_action}`, logged at error level only). Same FakeRepo strategy as
  `audit_writer_member_actions_test.exs` (no PostgreSQL needed); one persisted row per action. The persistence against the real table is covered by
  `test/nebu/admin/space_edit_audit_integration_test.exs`.
  """
  # async: false: this test mutates the process-global Application env key {:compliance, :repo}.
  use ExUnit.Case, async: false

  @actions ~w(space_name_changed space_topic_changed space_child_added space_child_removed)

  defmodule FakeRepo do
    @moduledoc "In-process fake for Nebu.Repo. Test-private."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

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

  for action <- @actions do
    test ~s|log/6 - action "#{action}" is a known action: returns :ok and persists exactly one row with that action, target room and the metadata|, %{bucket: bucket} do
      action = unquote(action)

      result =
        Nebu.Compliance.AuditWriter.log("@admin:test.local", action, "room", "!space:test.local", %{"event_id" => "$e1", "name" => "x"}, "success")

      refute result == {:error, :audit_unknown_action}, ~s|"#{action}" must be in the AuditWriter @known_actions allowlist, got #{inspect(result)}|
      assert result == :ok, "expected :ok, got #{inspect(result)}"

      assert [row] = Agent.get(bucket, & &1)
      assert row.action == action
      assert row.target_type == "room"
      assert row.target_id == "!space:test.local"
      assert row.actor_user_id == "@admin:test.local"
      assert row.outcome == "success"
    end
  end

  test "the allowlist still rejects a near-miss action name (the four are added, the check is not loosened)" do
    assert {:error, :audit_unknown_action} =
             Nebu.Compliance.AuditWriter.log("@admin:test.local", "space_renamed", "room", "!space:test.local", %{}, "success")
  end
end
