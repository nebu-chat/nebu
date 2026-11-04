defmodule Nebu.Migration.Migration000058RoomKeyBackupTest do
  @moduledoc """
  Acceptance tests for story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011): the migration `000058_room_key_backup` (the tests find the files by NAME,
  `*_room_key_backup.{up,down}.sql`, and require the number 000058). Cycle 1 (code review m1): the cycle-0 number 000056 clashes with `bugfix/oauth-session-lifetime-and-consent`
  (000056 = session lifetime setting, 000057 = persistent consent grants), so the migration is renumbered to 000058; the file header names its own number. The migration also
  gets a PARTIAL index of the live versions (`(user_id, version) WHERE deleted_at IS NULL`, code review m6): the markers are never pruned (accepted growth), the live-version
  lookups must not scan them.

  Contract (story "Storage": new migration after `000055` with runtime role grants and RLS / ownership policies in the style of the per-user tables, every row scoped to its owning user):

    * TWO new tables and nothing else: `room_key_backup_versions` and `room_key_backup_sessions`, both with `user_id TEXT NOT NULL` (the GDPR erasure deletes `WHERE user_id = $1`,
      and the schema recurrence guard classifies a table by that column). No existing table, column, index, trigger, function or policy is touched (rolling-deploy safe: old code
      keeps working).
    * Grants (UpCloud managed PostgreSQL has no default privileges for the migrate role): `GRANT SELECT, INSERT, UPDATE, DELETE ON <table> TO nebu_app` for both, nothing to PUBLIC,
      no `ALTER DEFAULT PRIVILEGES`; the runtime role gets no TRUNCATE / REFERENCES / TRIGGER.
    * Row level security ENABLED and FORCED on both tables (in the single-role dev setup the runtime role owns the tables; a table owner bypasses RLS unless forced), with a policy for
      each of SELECT, INSERT, UPDATE and DELETE (a command without a policy is denied). The predicate is not pinned: the Matrix routes do not set a per-request database role, so the
      per-user scoping is done by the `user_id` predicate of every statement (pinned by the behavioural suites: no cross-user path).
    * `down` removes exactly the two tables (sessions first) and grants nothing; a down / up round trip is harmless and `up` is idempotent (`IF NOT EXISTS`).

  Static analysis of the files (no DB, runs in the unit job), an `:integration` part that reads the catalog as the RUNTIME role (facts, not SQL text) and a down / up round trip on the
  privileged role inside a rolled-back transaction. After adding the migration re-create the throwaway database (or run the migration) so that it is applied.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @tables ~w(room_key_backup_versions room_key_backup_sessions)

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_room_key_backup.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_room_key_backup.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_room_key_backup.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()
  defp header(path), do: path |> read!() |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.map_join("\n", &String.replace(&1, ~r/\A--\s?/, ""))

  # the column list of one CREATE TABLE of the up file
  defp table_body(table) do
    sql = norm(code_sql(up_file()))
    assert [_, body] = Regex.run(~r/create table if not exists (?:public\.)?#{table} \((.*?)\);/s, sql), "the up file creates #{table} with CREATE TABLE IF NOT EXISTS"
    body
  end

  describe "migration files (static)" do
    test "up and down exist exactly once, with the same number 000058, and no other migration has that number" do
      assert [up] = files("up"), "exactly one *_room_key_backup.up.sql"
      assert [down] = files("down"), "exactly one *_room_key_backup.down.sql"
      assert number(up) == number(down), "up and down carry the same number"
      assert number(up) == 58, "000056 (session lifetime setting) and 000057 (persistent consent grants) belong to other stories: this migration is 000058"
      assert Path.wildcard(Path.join(@dir, "#{String.pad_leading(Integer.to_string(number(up)), 6, "0")}_*.up.sql")) == [up], "no second migration with that number"
    end

    test "the files are named 000058_room_key_backup.{up,down}.sql and their first comment line names the file (no stale number from the cycle-0 numbering)" do
      assert Path.basename(up_file()) == "000058_room_key_backup.up.sql"
      assert Path.basename(down_file()) == "000058_room_key_backup.down.sql"
      assert up_file() |> read!() |> String.split("\n") |> hd() =~ "000058_room_key_backup.up.sql"
      assert down_file() |> read!() |> String.split("\n") |> hd() =~ "000058_room_key_backup.down.sql"
      refute read!(up_file()) =~ "000056", "a stale 000056 in the up file"
      refute read!(down_file()) =~ "000056", "a stale 000056 in the down file"
    end

    test "up creates the PARTIAL index of the live versions: (user_id, version) WHERE deleted_at IS NULL, IF NOT EXISTS, on the versions table" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?room_key_backup_versions \(user_id, version\) where deleted_at is null/
    end

    test "the earlier migrations are untouched (the 000055 policy file keeps its statement)" do
      [f55] = Path.wildcard(Path.join(@dir, "000055_*.up.sql"))
      assert norm(read!(f55)) =~ "create policy oauth_codes_delete on oauth_codes for delete using"
    end

    test "up creates both tables with IF NOT EXISTS, each with user_id TEXT NOT NULL" do
      for table <- @tables do
        body = table_body(table)
        assert body =~ ~r/\buser_id text not null\b/, "#{table}.user_id TEXT NOT NULL (the erasure and the schema guard rely on it)"
      end
    end

    # Decision: the session rows have a FOREIGN KEY to their version, WITHOUT a cascade: a version row cannot go while sessions point to it, so the
    # erasure (and any delete of a version) must delete the sessions first (the order of UserDeletion.erased_tables/0 is tested in user_deletion_room_keys_test.exs)
    test "Decision: room_key_backup_sessions has a foreign key (user_id, version) to room_key_backup_versions, without a cascade" do
      body = table_body("room_key_backup_sessions")
      assert body =~ ~r/foreign key \(user_id, version\) references (?:public\.)?room_key_backup_versions \(user_id, version\)/
      refute body =~ ~r/on delete (cascade|set null|set default)/, "restrict semantics: no cascade from a version to its sessions"
    end

    test "up creates the two tables and nothing else: no change of an existing table, no trigger, function, index on another table, no data statement, no BEGIN / COMMIT" do
      sql = code_sql(up_file())
      created = Regex.scan(~r/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?(\w+)/i, sql) |> Enum.map(&List.last/1) |> Enum.sort()
      assert created == Enum.sort(@tables), "exactly the two tables, got #{inspect(created)}"

      for [_, t] <- Regex.scan(~r/ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "ALTER TABLE #{t}: an existing table must not be touched")
      for [_, t] <- Regex.scan(~r/CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?\w+\s+ON\s+(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "an index on #{t}")
      for [_, t] <- Regex.scan(~r/CREATE\s+POLICY\s+\w+\s+ON\s+(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "a policy on #{t}")
      refute sql =~ ~r/\b(CREATE|DROP)\s+(OR\s+REPLACE\s+)?(TRIGGER|FUNCTION|TYPE|EXTENSION|SEQUENCE)\b/i
      refute sql =~ ~r/\bDROP\s+(TABLE|COLUMN)\b/i
      for [_, t] <- Regex.scan(~r/DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?\w+\s+ON\s+(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "DROP POLICY on #{t}: an existing policy must not be touched")
      refute sql =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
    end

    test "up grants SELECT, INSERT, UPDATE, DELETE on both tables to nebu_app, grants nothing to PUBLIC, sets no default privileges" do
      sql = norm(code_sql(up_file()))

      for table <- @tables do
        assert sql =~ ~r/grant select, insert, update, delete on (?:table )?(?:public\.)?#{table} to nebu_app/, "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO nebu_app"
      end

      refute sql =~ ~r/\bto public\b/, "no grant to PUBLIC"
      refute sql =~ ~r/alter default privileges/, "no ALTER DEFAULT PRIVILEGES (managed PostgreSQL has none for the migrate role)"
      refute sql =~ ~r/grant [^;]*\b(truncate|references|trigger|all)\b[^;]* to nebu_app/, "no TRUNCATE / REFERENCES / TRIGGER / ALL for the runtime role"
    end

    test "up ENABLEs and FORCEs row level security on both tables and creates a policy for SELECT, INSERT, UPDATE and DELETE on each" do
      sql = norm(code_sql(up_file()))

      for table <- @tables do
        assert sql =~ ~r/alter table (?:public\.)?#{table} enable row level security/, "#{table}: ENABLE ROW LEVEL SECURITY"
        assert sql =~ ~r/alter table (?:public\.)?#{table} force row level security/, "#{table}: FORCE ROW LEVEL SECURITY"

        cmds = Regex.scan(~r/create policy \w+ on (?:public\.)?#{table} (?:as \w+ )?for (select|insert|update|delete|all)\b/, sql) |> Enum.map(&List.last/1)

        for cmd <- ~w(select insert update delete), do: assert(cmd in cmds or "all" in cmds, "#{table}: a policy for #{String.upcase(cmd)} (a command without a policy is denied), got #{inspect(cmds)}")
      end

      refute sql =~ ~r/disable row level security|no force row level security/
    end

    test "down removes exactly the two tables, the sessions BEFORE the versions, and nothing else; no grants" do
      sql = norm(code_sql(down_file()))
      drops = Regex.scan(~r/drop table (?:if exists )?(?:public\.)?(\w+)/, sql) |> Enum.map(&List.last/1)
      assert drops == ["room_key_backup_sessions", "room_key_backup_versions"], "down drops the session rows' table first, got #{inspect(drops)}"
      refute sql =~ ~r/\b(grant|revoke)\b/, "down contains no GRANT / REVOKE"
      refute sql =~ ~r/\b(alter|create)\s+(table|index|policy|trigger|function)\b/
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m
    end

    test "the headers name the story, both tables and the erasure reason; down warns that the backup is discarded" do
      h = header(up_file())
      for word <- ["server-side-key-backup", "room_key_backup_versions", "room_key_backup_sessions", "user_id", "erasure"], do: assert(h =~ word, "the up header mentions #{word}")
      assert header(down_file()) =~ ~r/WARNING|discard/i, "down says that dropping the tables discards the key backups (clients must create a new backup)"
    end
  end

  # ═══ the catalog, as the runtime role ═════════════════════════════════════════════════════════════════════════════════════════

  describe "migration applied (integration, catalog facts, runtime role)" do
    @describetag :integration

    test "Decision (catalog): exactly one foreign key on the sessions table, to the versions table over (user_id, version), delete rule NO ACTION or RESTRICT" do
      assert [["room_key_backup_versions", cols, fcols, rule]] =
               T.sql!("""
               SELECT c.confrelid::regclass::text,
                      (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum),
                      (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.confkey) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum),
                      c.confdeltype::text
               FROM pg_constraint c WHERE c.conrelid = 'room_key_backup_sessions'::regclass AND c.contype = 'f'
               """).rows

      assert cols == ["user_id", "version"] and fcols == ["user_id", "version"]
      assert rule in ["a", "r"], "NO ACTION or RESTRICT, never a cascade (got #{rule})"
    end

    test "the partial index of the live versions exists (catalog): (user_id, version) WHERE (deleted_at IS NULL), not unique" do
      defs = T.sql!("SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'room_key_backup_versions'").rows |> List.flatten()
      partial = Enum.filter(defs, &(&1 =~ ~r/WHERE \(?deleted_at IS NULL\)?/))
      assert [def_] = partial, "exactly one partial index on the live versions, got #{inspect(defs)}"
      assert def_ =~ "(user_id, version)"
      refute def_ =~ "UNIQUE"
    end

    test "both tables exist with user_id TEXT NOT NULL" do
      for table <- @tables do
        assert T.sql!("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = 'user_id'", [table]).rows == [["text", "NO"]],
               "#{table}.user_id TEXT NOT NULL"
      end
    end

    test "row level security is enabled AND forced on both tables" do
      for table <- @tables do
        assert T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = $1::text::regclass", [table]).rows == [[true, true]], "#{table}: RLS enabled and forced"
      end
    end

    test "each table has a policy for SELECT, INSERT, UPDATE and DELETE (or ALL), none restrictive, none for a role other than public / nebu_app" do
      for table <- @tables do
        rows = T.sql!("SELECT cmd, permissive, roles::text FROM pg_policies WHERE schemaname = current_schema() AND tablename = $1", [table]).rows
        cmds = Enum.map(rows, &hd/1)
        for cmd <- ~w(SELECT INSERT UPDATE DELETE), do: assert(cmd in cmds or "ALL" in cmds, "#{table}: no policy for #{cmd}, got #{inspect(cmds)}")
        assert Enum.all?(rows, fn [_, permissive, _] -> permissive == "PERMISSIVE" end), "#{table}: a RESTRICTIVE policy"
        assert Enum.all?(rows, fn [_, _, roles] -> roles in ["{public}", "{nebu_app}"] end), "#{table}: policies for #{inspect(Enum.map(rows, &List.last/1))}"
      end
    end

    test "the runtime role has SELECT, INSERT, UPDATE, DELETE on both tables and no TRUNCATE, REFERENCES or TRIGGER; PUBLIC has nothing" do
      for table <- @tables do
        privs = for p <- ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER), into: %{}, do: {p, T.sql!("SELECT has_table_privilege('nebu_app', $1, '#{p}')", [table]).rows |> hd() |> hd()}

        assert privs == %{"SELECT" => true, "INSERT" => true, "UPDATE" => true, "DELETE" => true, "TRUNCATE" => false, "REFERENCES" => false, "TRIGGER" => false}, "#{table}: #{inspect(privs)}"

        acl = T.sql!("SELECT COALESCE(relacl::text, '') FROM pg_class WHERE oid = $1::text::regclass", [table]).rows |> hd() |> hd()
        refute acl =~ ~r/(?:\{|,)=[a-zA-Z*]*\//, "#{table}: a grant to PUBLIC in #{acl}"
      end
    end

    test "the runtime role can work with the tables (a refused row is a constraint, not a permission error): the tables are empty for a user that never wrote" do
      uid = "@never-wrote-#{T.rand(5)}:test.local"

      for table <- @tables, do: assert(T.sql!("SELECT count(*) FROM #{table} WHERE user_id = $1", [uid]).rows == [[0]])
    end
  end

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp present?(tx, table), do: Postgrex.query!(tx, "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1", [table]).rows == [[1]]
    defp all_tables(tx), do: Postgrex.query!(tx, "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() ORDER BY 1", []).rows |> List.flatten()
    defp run!(tx, sql), do: Postgrex.query!(tx, sql, [], query_type: :text)

    test "down removes exactly the two tables, up restores them (and only them), a second up is a no-op" do
      up = read!(up_file())
      down = read!(down_file())

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            before = all_tables(tx)
            for t <- @tables, do: assert(present?(tx, t), "precondition: the migrated database has #{t}")

            run!(tx, down)
            for t <- @tables, do: refute(present?(tx, t), "down must remove #{t}")
            assert all_tables(tx) == before -- @tables, "down removed exactly the two tables"

            run!(tx, up)
            for t <- @tables, do: assert(present?(tx, t), "up must restore #{t}")
            assert all_tables(tx) == before, "up restored exactly the two tables"

            run!(tx, up)
            assert all_tables(tx) == before, "a second up is harmless (IF NOT EXISTS)"

            # the restored objects carry grants and RLS again
            for table <- @tables do
              assert Postgrex.query!(tx, "SELECT has_table_privilege('nebu_app', $1, 'SELECT'), has_table_privilege('nebu_app', $1, 'DELETE'), (SELECT relforcerowsecurity FROM pg_class WHERE oid = $1::text::regclass)", [table]).rows == [[true, true, true]]
            end

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end
  end
end
