defmodule Nebu.Migration.Migration000050RoomInvitationsPendingInviterIdxTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room` (epic oauth-broker, follow-up `ey`), D8: migration
  `000050_room_invitations_pending_inviter_idx`: ONE partial index so that the per-inviter and per-pair counts of the pending-invitation
  caps are index reads (`room_invitations` has only `room_invitations_invitee_idx (invitee_id)`: a COUNT by `inviter_id` was a sequential
  scan). The statement that needs it, its plan and its bounded counts are pinned on the real DB in `invite_caps_db_test.exs`.

      CREATE INDEX IF NOT EXISTS room_invitations_pending_inviter_idx ON room_invitations (inviter_id, invitee_id)
        WHERE accepted_at IS NULL AND rejected_at IS NULL;
      -- down: DROP INDEX IF EXISTS room_invitations_pending_inviter_idx;

  Mirrors the sibling migration suites (`000049_...`, `000044_...`): static SQL-file analysis (no DB) and an `:integration` part against the
  migrated schema, with a down / up round trip on the privileged role inside a rolled-back transaction (a plain `CREATE INDEX`: the file is
  applied by `Nebu.Release.migrate/0` in a transaction, so `CONCURRENTLY` is not available and the round trip inside a transaction proves the
  file is transaction-safe). After adding the migration reset the throwaway database (`docker rm -f nebu-oauth-pg`) so that it runs.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000050_room_invitations_pending_inviter_idx.up.sql"
  @down "000050_room_invitations_pending_inviter_idx.down.sql"
  @idx "room_invitations_pending_inviter_idx"

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp statements(f), do: f |> code_sql() |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  describe "AC4 - migration files (static)" do
    test "up and down exist and are the only 000050" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000050_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000050 up migration"
      assert Path.wildcard(Path.join(@dir, "000050_*.down.sql")) == [Path.join(@dir, @down)], "exactly one 000050 down migration"
    end

    test "up is ONE CREATE INDEX IF NOT EXISTS on room_invitations (inviter_id, invitee_id) with the pending predicate" do
      assert [stmt] = statements(@up)

      normalised = stmt |> String.replace(~r/\s+/, " ") |> String.downcase()

      assert normalised =~ "create index if not exists #{@idx} on room_invitations (inviter_id, invitee_id)"
      assert normalised =~ "where accepted_at is null and rejected_at is null"
      refute normalised =~ "unique"
    end

    test "up is transaction-safe and does nothing else: no CONCURRENTLY, no BEGIN / COMMIT, no GRANT, no ALTER / DROP, no data change" do
      sql = code_sql(@up)

      refute sql =~ ~r/CONCURRENTLY/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/\b(GRANT|REVOKE)\b/i
      refute sql =~ ~r/\b(ALTER|DROP)\s+(TABLE|INDEX|POLICY)\b/i
      refute sql =~ ~r/\b(INSERT|UPDATE|DELETE)\b/i
      refute sql =~ ~r/CREATE\s+(OR\s+REPLACE\s+)?(TRIGGER|FUNCTION|POLICY)/i
    end

    test "down is exactly DROP INDEX IF EXISTS of this index" do
      assert [stmt] = statements(@down)
      assert stmt |> String.replace(~r/\s+/, " ") |> String.downcase() == "drop index if exists #{@idx}"
      refute code_sql(@down) =~ ~r/CONCURRENTLY/i
    end

    test "the header names the story, the index and the pending predicate (the wording around it is free)" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")

      assert header =~ "rate-limits-join-invite-create-room"
      assert header =~ @idx
      assert header =~ ~r/accepted_at IS NULL AND rejected_at IS NULL/i
    end

    test "the earlier migrations do not mention the new index (a new migration instead of an edit of 000001)" do
      for f <- Path.wildcard(Path.join(@dir, "0000[0-4]*.sql")) do
        refute File.read!(f) =~ @idx, "#{Path.basename(f)} must not be edited by this story"
      end
    end
  end

  describe "AC4 - migrated schema (integration)" do
    @describetag :integration

    defp index_def(tx) do
      %{rows: rows} =
        Postgrex.query!(tx, "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'room_invitations' AND indexname = $1", [@idx])

      List.flatten(rows)
    end

    test "the runtime schema has the index, partial on the pending predicate, with the pair order (inviter_id, invitee_id); the old invitee index is still there" do
      assert %{rows: [[def_]]} = T.sql!("SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1", [@idx])

      normalised = def_ |> String.replace(~r/[\s()]+/, " ") |> String.downcase()
      assert normalised =~ "using btree inviter_id, invitee_id"
      assert normalised =~ "where accepted_at is null and rejected_at is null"

      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM pg_indexes WHERE indexname = 'room_invitations_invitee_idx'")
    end

    test "down / up round trip (privileged role, rolled back): down removes the index, up restores it, a second up is a no-op (IF NOT EXISTS)" do
      down = read!(@down)
      up = read!(@up)

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert [_] = index_def(tx), "precondition: the migrated database has the index"

            Postgrex.query!(tx, down, [], query_type: :text)
            assert index_def(tx) == [], "down must drop the index"

            %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE indexname = 'room_invitations_invitee_idx'", [])

            Postgrex.query!(tx, up, [], query_type: :text)
            assert [_] = index_def(tx), "up must recreate the index (inside a transaction: no CONCURRENTLY)"

            Postgrex.query!(tx, up, [], query_type: :text)
            assert [_] = index_def(tx), "a repeated up is a no-op"

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end
  end
end
