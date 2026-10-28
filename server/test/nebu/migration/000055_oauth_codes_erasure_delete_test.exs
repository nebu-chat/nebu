defmodule Nebu.Migration.Migration000055OauthCodesErasureDeleteTest do
  @moduledoc """
  Acceptance tests for story `gdpr-erasure-global-data` (epic oauth-broker, follow-up `ck`), D11: migration `000055_oauth_codes_erasure_delete` (the number is confirmed
  by the implementer at commit time: the tests find the files by NAME, `*_oauth_codes_erasure_delete.{up,down}.sql`, and require a number above 000054).

  Contract (D11): POLICY ONLY. The FORCE-RLS DELETE policy `oauth_codes_delete` of 000041 (`expires_at < now() - interval '24 hours'`, reuse detection) gets a second
  branch for the rows of a user whose `deletion_status IS NOT NULL` (the erasure sets it in its own transaction BEFORE it deletes); `down` restores exactly the 000041
  policy. The policy must not allow deleting an active user's unexpired code (the behaviour is pinned by `compliance/user_deletion_global_data_test.exs`). No table,
  column, index, trigger, function or grant is touched; the SELECT / INSERT / UPDATE policies and the guard trigger of 000041 stay.

  Mirrors `000054_sync_room_cursors_test.exs`: static analysis of the files (no DB, runs in the unit job), an `:integration` part that reads the catalog (`pg_policies`,
  `pg_trigger`, grants, the force flag; facts, not SQL text) as the RUNTIME role, and a down / up round trip on the privileged role inside a rolled-back transaction. The
  restored 000041 policy is compared with the policy created from 000041's OWN statement (read from that file), so "down restores the 000041 policy" is exact.
  After adding the migration reset the throwaway database (`docker rm -fv nebu-oauth-pg`, `.oauth-ci/cleanup.sh`) so that it runs.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_oauth_codes_erasure_delete.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_oauth_codes_erasure_delete.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_oauth_codes_erasure_delete.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()
  defp header(path), do: path |> read!() |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.map_join("\n", &String.replace(&1, ~r/\A--\s?/, ""))

  # the statement 000041 uses to create the DELETE policy (the policy `down` must restore)
  defp policy_000041 do
    [file] = Path.wildcard(Path.join(@dir, "000041_*.up.sql"))
    [stmt] = Regex.run(~r/CREATE POLICY oauth_codes_delete ON oauth_codes FOR DELETE USING \(.*?\);/s, read!(file))
    stmt
  end

  describe "migration 000055 files (static)" do
    test "up and down exist exactly once, with the same number, above 000054" do
      assert [up] = files("up"), "exactly one *_oauth_codes_erasure_delete.up.sql"
      assert [down] = files("down"), "exactly one *_oauth_codes_erasure_delete.down.sql"
      assert number(up) == number(down), "up and down carry the same number"
      assert number(up) >= 55, "the next free number after 000054 (sync_room_cursors)"
      assert Path.wildcard(Path.join(@dir, "#{String.pad_leading(Integer.to_string(number(up)), 6, "0")}_*.up.sql")) == [up], "no second migration with that number"
    end

    test "the earlier migrations are untouched: 000041 keeps its 24 hour policy and knows nothing about deletion_status" do
      [f41] = Path.wildcard(Path.join(@dir, "000041_*.up.sql"))
      sql = norm(read!(f41))
      assert sql =~ "create policy oauth_codes_delete on oauth_codes for delete using (expires_at < now() - interval '24 hours')"
      refute sql =~ "deletion_status", "a new migration instead of an edit of 000041"
    end

    test "up replaces the DELETE policy oauth_codes_delete: the 24 hour branch stays, a second branch reads users.deletion_status IS NOT NULL" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/drop policy if exists oauth_codes_delete on (public\.)?oauth_codes/
      assert sql =~ ~r/create policy oauth_codes_delete on (public\.)?oauth_codes for delete using/
      assert sql =~ "interval '24 hours'", "the reuse-detection branch of 000041 stays"
      assert sql =~ ~r/\bor\b/, "a SECOND branch, not a replacement"
      assert sql =~ ~r/\busers\b/ and sql =~ "deletion_status is not null"
      refute sql =~ ~r/using \(\s*true\s*\)/, "the policy must not be widened to every row"
    end

    test "up is a policy and nothing else: no table / column / index / trigger / function / grant, no data statement, no BEGIN / COMMIT" do
      sql = code_sql(up_file())
      refute sql =~ ~r/\b(CREATE|ALTER|DROP)\s+(TABLE|INDEX|TRIGGER|FUNCTION|SEQUENCE|TYPE|EXTENSION)\b/i
      refute sql =~ ~r/\b(ADD|DROP)\s+COLUMN\b/i
      refute sql =~ ~r/\b(GRANT|REVOKE)\b/i
      refute sql =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
      refute sql =~ ~r/\bDISABLE\s+ROW\s+LEVEL\b|\bNO\s+FORCE\b/i, "row level security stays enabled and forced"
    end

    test "down restores the 000041 policy: only the 24 hour branch, no users, no deletion_status; nothing else" do
      sql = norm(code_sql(down_file()))
      assert sql =~ ~r/drop policy if exists oauth_codes_delete on (public\.)?oauth_codes/
      assert sql =~ ~r/create policy oauth_codes_delete on (public\.)?oauth_codes for delete using/
      assert sql =~ "expires_at < now() - interval '24 hours'"
      refute sql =~ "deletion_status"
      refute sql =~ ~r/\busers\b/
      refute sql =~ ~r/using \(\s*true\s*\)/
      refute sql =~ ~r/\b(create|alter|drop)\s+(table|index|trigger|function)\b/
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m
    end

    test "the header names the story, the policy and why (the erasure must delete a pending code), and the release note wording stays policy only" do
      h = header(up_file())
      for word <- ["gdpr-erasure-global-data", "oauth_codes_delete", "deletion_status", "idp_rt_enc"], do: assert(h =~ word, "the up header mentions #{word}")
      assert header(down_file()) =~ ~r/000041/
    end
  end

  # ═══ the catalog, as the runtime role ═════════════════════════════════════════════════════════════════════════════════════════

  defp policies do
    T.sql!("SELECT policyname, cmd, permissive, roles::text, qual, with_check FROM pg_policies WHERE tablename = 'oauth_codes' ORDER BY policyname").rows
  end

  defp delete_policy, do: Enum.find(policies(), &(hd(&1) == "oauth_codes_delete"))

  describe "migration 000055 applied (integration, catalog facts)" do
    @describetag :integration

    test "the only DELETE policy keeps the 24 hour branch and has a users.deletion_status IS NOT NULL branch correlated to the row's user" do
      assert [[_, "DELETE", _, _, qual, nil]] = Enum.filter(policies(), &(Enum.at(&1, 1) == "DELETE")), "one DELETE policy, no WITH CHECK"
      q = norm(qual)
      assert q =~ "expires_at" and q =~ "24:00:00", "the reuse-detection branch (24 hours after the expiry) stays"
      assert q =~ "deletion_status is not null"
      assert q =~ ~r/oauth_codes\.user_id|user_id = oauth_codes/, "the users subquery is CORRELATED to the row's user_id (an uncorrelated EXISTS would delete everyone's codes)"
      refute q =~ ~r/^\(?true\)?$/
    end

    test "the SELECT / INSERT / UPDATE policies, the force flag, the guard trigger and the runtime grants are as 000041 left them" do
      by_cmd = Map.new(policies(), fn [name, cmd | _] = row -> {cmd, {name, row}} end)
      assert map_size(by_cmd) == 4, "exactly the four policies of 000041, got #{inspect(Map.keys(by_cmd))}"
      assert {"oauth_codes_select", [_, _, _, _, "true", nil]} = by_cmd["SELECT"]
      assert {"oauth_codes_insert", [_, _, _, _, nil, wc]} = by_cmd["INSERT"]
      assert norm(wc) =~ "used_at is null"
      assert {"oauth_codes_update", [_, _, _, _, "true", "true"]} = by_cmd["UPDATE"]

      assert T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'oauth_codes'").rows == [[true, true]]

      assert T.sql!("SELECT tgname FROM pg_trigger WHERE tgrelid = 'oauth_codes'::regclass AND NOT tgisinternal ORDER BY 1").rows == [["oauth_codes_guard"]]

      grants = T.sql!("SELECT privilege_type FROM information_schema.role_table_grants WHERE table_name = 'oauth_codes' AND grantee = 'nebu_app' ORDER BY 1").rows
      assert grants == [["DELETE"], ["INSERT"], ["SELECT"], ["UPDATE"]]
    end
  end

  # ═══ down / up round trip, privileged, rolled back ══════════════════════════════════════════════════════════════════════════

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp run!(tx, sql), do: Postgrex.query!(tx, sql, [], query_type: :text)

    defp tx_policies(tx),
      do: Postgrex.query!(tx, "SELECT policyname, cmd, permissive, roles::text, qual, with_check FROM pg_policies WHERE tablename = 'oauth_codes' ORDER BY policyname", []).rows

    defp tx_delete_qual(tx), do: tx_policies(tx) |> Enum.find(&(hd(&1) == "oauth_codes_delete")) |> Enum.at(4)

    defp tx_other(tx), do: tx_policies(tx) |> Enum.reject(&(hd(&1) == "oauth_codes_delete"))

    defp tx_objects(tx) do
      %{
        triggers: Postgrex.query!(tx, "SELECT tgname FROM pg_trigger WHERE tgrelid = 'oauth_codes'::regclass AND NOT tgisinternal ORDER BY 1", []).rows,
        columns: Postgrex.query!(tx, "SELECT attname, atttypid::regtype::text FROM pg_attribute WHERE attrelid = 'oauth_codes'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum", []).rows,
        indexes: Postgrex.query!(tx, "SELECT indexname FROM pg_indexes WHERE tablename = 'oauth_codes' ORDER BY 1", []).rows,
        grants: Postgrex.query!(tx, "SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE table_name = 'oauth_codes' ORDER BY 1, 2", []).rows,
        rls: Postgrex.query!(tx, "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'oauth_codes'", []).rows
      }
    end

    test "down restores EXACTLY the 000041 policy, up the migrated one, a second up is harmless; nothing else changes" do
      up = read!(up_file())
      down = read!(down_file())
      p41 = policy_000041()

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            migrated = tx_delete_qual(tx)
            others = tx_other(tx)
            objects = tx_objects(tx)
            assert norm(migrated) =~ "deletion_status is not null", "precondition: the migrated database has the erasure branch"

            # the reference: the policy exactly as 000041's own statement creates it
            run!(tx, "DROP POLICY oauth_codes_delete ON oauth_codes")
            run!(tx, p41)
            q41 = tx_delete_qual(tx)
            refute norm(q41) =~ "deletion_status"

            run!(tx, up)
            assert tx_delete_qual(tx) == migrated, "up from the 000041 state gives the migrated policy"

            run!(tx, down)
            assert tx_delete_qual(tx) == q41, "down restores EXACTLY the 000041 policy"
            assert tx_other(tx) == others, "the SELECT / INSERT / UPDATE policies are untouched by down"
            assert tx_objects(tx) == objects, "down touches no trigger, column, index, grant or RLS flag"

            run!(tx, up)
            assert tx_delete_qual(tx) == migrated
            run!(tx, up)
            assert tx_delete_qual(tx) == migrated, "a second up is harmless (DROP POLICY IF EXISTS first)"
            assert tx_other(tx) == others
            assert tx_objects(tx) == objects, "up touches nothing but the one policy"

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
      assert delete_policy() |> Enum.at(4) |> norm() =~ "deletion_status is not null", "the rolled-back transaction left the database migrated"
    end
  end
end
