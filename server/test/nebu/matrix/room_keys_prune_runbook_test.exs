defmodule Nebu.Matrix.RoomKeysPruneRunbookTest do
  @moduledoc """
  Acceptance test (REAL database) of the OPERATOR SQL that prunes old soft-delete markers (story `server-side-key-backup`, cycle 2, orchestrator decision 5; code review MINOR-3): the cap of
  1000 version rows per user INCLUDES the markers of deleted versions, there is NO automatic pruning, so a user who created and deleted versions 1000 times is locked out of
  `POST /room_keys/version` until an operator prunes. The 403 text keeps pointing at the operator and the DOCS must contain the exact SQL.

  The SQL is taken from the documentation itself (a fenced ```sql block of `docs/compliance/gdpr-deletion-runbook.md` or `docs/architecture/11-risks.md` that contains
  `DELETE FROM room_key_backup_versions`), the user placeholder `'<user_id>'` is bound to a parameter, and it is EXECUTED here, so the documented statement is the tested one:

    * it deletes the soft-delete markers of THAT user only, except the HIGHEST-numbered marker (so the numbers are never reused: the next version is still numbered above it);
    * live versions (their `auth_data`) and every session row stay untouched, another user's rows too;
    * a user who is locked out by the cap can create a version again afterwards.

  Only the statement(s) that delete markers (`DELETE FROM room_key_backup_versions ... deleted_at IS NOT NULL`) are executed; the erasure sweep of the runbook is not a prune and is ignored.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @root Path.expand("../../../..", __DIR__)
  @docs [Path.join(@root, "docs/compliance/gdpr-deletion-runbook.md"), Path.join(@root, "docs/architecture/11-risks.md")]
  @room "!prune:test.local"
  @algo RK.algorithm()

  setup do
    RK.disable_rate_limit()
    :ok
  end

  # the documented prune statement(s): a `DELETE FROM room_key_backup_versions` that selects the MARKERS (`deleted_at IS NOT NULL`) of one user (not the erasure sweep of the runbook, which
  # deletes every row of an erased user), the user placeholder replaced by `$1`
  defp documented_statements do
    statements =
      for path <- @docs,
          [_, sql] <- Regex.scan(~r/```sql\s*\n(.*?)```/s, File.read!(path)),
          stmt <- sql |> String.replace(~r/--[^\n]*/, "") |> String.split(";"),
          stmt = String.trim(stmt),
          stmt =~ ~r/\ADELETE\s+FROM\s+room_key_backup_versions\b/i and stmt =~ ~r/deleted_at\s+IS\s+NOT\s+NULL/i,
          do: stmt

    assert statements != [],
           "no ```sql block with a `DELETE FROM room_key_backup_versions ... deleted_at IS NOT NULL ... '<user_id>'` in #{inspect(Enum.map(@docs, &Path.relative_to(&1, @root)))}: " <>
             "the operator SQL that prunes old markers is not documented"

    for stmt <- statements do
      assert stmt =~ "'<user_id>'", "the documented prune DELETE must name the user as '<user_id>': #{stmt}"
      String.replace(stmt, "'<user_id>'", "$1::text")
    end
  end

  defp prune!(uid) do
    for stmt <- documented_statements(), do: T.sql!(stmt, [uid])
    :ok
  end

  defp version_numbers(uid), do: T.sql!("SELECT version FROM room_key_backup_versions WHERE user_id = $1 ORDER BY version", [uid]).rows |> List.flatten()
  defp live_numbers(uid), do: T.sql!("SELECT version FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL ORDER BY version", [uid]).rows |> List.flatten()

  test "the documented SQL removes the old markers of the user, keeps the highest-numbered marker, the live versions with their sessions, and other users' rows" do
    u = RK.user!()
    v1 = RK.create!(u)
    v2 = RK.create!(u)
    v3 = RK.create!(u, RK.auth_data("live3"))
    assert {1, _} = RK.count_etag!(RK.put_session(u.at, v3, @room, "s3", RK.kbd(1, 0, false, %{"c" => "on-v3"})))
    v4 = RK.create!(u)
    v5 = RK.create!(u, RK.auth_data("live5"))
    assert {1, _} = RK.count_etag!(RK.put_session(u.at, v5, @room, "s5", RK.kbd(1, 0, false, %{"c" => "on-v5"})))
    for v <- [v1, v2, v4], do: assert(RK.delete_version(u.at, v).status == 200)

    other = RK.user!()
    ov1 = RK.create!(other)
    ov2 = RK.create!(other)
    for v <- [ov1, ov2], do: assert(RK.delete_version(other.at, v).status == 200)

    assert version_numbers(u.uid) == [1, 2, 3, 4, 5]
    sessions_before = RK.rows(RK.sessions_table(), u.uid)

    prune!(u.uid)

    assert version_numbers(u.uid) == [3, 4, 5], "markers 1 and 2 are pruned; marker 4 (the highest-numbered marker) stays so that no number is reused"
    assert live_numbers(u.uid) == [3, 5]
    assert RK.rows(RK.sessions_table(), u.uid) == sessions_before, "pruning markers touched session rows"
    assert RK.info!(u.at, v3)["auth_data"] == RK.auth_data("live3") and RK.info!(u.at, v3)["count"] === 1
    assert RK.info!(u.at)["version"] == v5 and RK.info!(u.at)["auth_data"] == RK.auth_data("live5")
    assert RK.json(RK.get_keys(u.at, v5, @room, "s5"))["session_data"] == %{"c" => "on-v5"}
    assert version_numbers(other.uid) == [1, 2], "another user's markers were pruned"

    assert String.to_integer(RK.create!(u)) > 5, "a number is never reused after the pruning"
  end

  test "a user locked out by the row cap (only markers left) can create again after the pruning, and the new number is above every old one" do
    RK.put_env_restoring(:nebu, :room_keys_max_version_rows_per_user, 4)
    u = RK.user!()
    for _ <- 1..4, do: assert(RK.delete_version(u.at, RK.create!(u)).status == 200)

    body = RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")
    assert is_binary(body["error"]) and body["error"] =~ ~r/operator|administrator|admin/i, "the 403 text points at the operator: #{inspect(body["error"])}"
    assert version_numbers(u.uid) == [1, 2, 3, 4]

    prune!(u.uid)

    assert version_numbers(u.uid) == [4], "all markers but the highest-numbered one are gone"
    assert RK.create!(u) == "5", "the first number after the prune continues above the highest marker"
    assert version_numbers(u.uid) == [4, 5]
  end

  test "the pruning is idempotent and a user without markers is not touched" do
    u = RK.user!()
    v = RK.create!(u)
    assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false)))
    prune!(u.uid)
    prune!(u.uid)
    assert version_numbers(u.uid) == [1] and RK.rows(RK.sessions_table(), u.uid) == 1
  end
end
