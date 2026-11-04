defmodule Nebu.Migration.Migration000060DeviceListChangesTest do
  @moduledoc """
  Acceptance tests for story `device-key-directory` (epic e2ee-client-support, REQ-2026-013): the migration `000060_device_list_changes` (found by NAME, `*_device_list_changes.{up,down}.sql`,
  number 000060: 000058 is the key backup and 000059 the to-device queue of the sibling stories on this branch, 000056 / 000057 live on another branch, so the release contiguity guard stays
  red here by design).

  Contract (decisions D10, D13, D15 of the story):

    * ONE new table `device_list_changes`: `user_id`, `room_id` (default `''`), `kind` (`keys` / `join` / `leave`, a CHECK) `TEXT NOT NULL`, `pos BIGINT` (NULL until the commit stamps it),
      `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`; the LATEST change per (user, room) is one row: primary key `(user_id, room_id)`. The names are pinned because the erasure inventory, the
      readers and the tests name them.
    * ONE additive column `device_fallback_keys.key_id TEXT` (nullable): the id of an uploaded fallback key, which `POST /keys/claim` has to return.
    * The stamp: a DEFERRABLE INITIALLY DEFERRED constraint trigger on the table assigns `pos` from the EXISTING sequence `sync_global_pos_seq` AT COMMIT under one advisory lock; a trigger
      on `room_members` (INSERT, UPDATE OF left_at) writes the `join` / `leave` rows. Neither function is SECURITY DEFINER; no new sequence.
    * Indexes for the position scan (`pos` leading) and the room scan (`room_id`, `pos`); the erasure is served by the primary key (`user_id` leading).
    * Grants: `SELECT, INSERT, UPDATE, DELETE` to `nebu_app`, nothing to PUBLIC, no default privileges, no TRUNCATE / REFERENCES / TRIGGER. Row level security ENABLED and FORCED with a policy for
      each command.
    * Additive and rolling-deploy safe: no data statement, no change of an existing table except the nullable column and the membership trigger; `down` removes exactly what `up` created (and
      warns that the stream is discarded); a down / up round trip is harmless and `up` is idempotent.

  Static analysis (no DB), a catalog part as the RUNTIME role and a down / up round trip on the privileged role inside a rolled-back transaction. After adding the migration re-create the
  throwaway database (or run the migration).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @table "device_list_changes"

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_device_list_changes.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_device_list_changes.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_device_list_changes.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  # the SQL with the function bodies ($$ ... $$) removed: the DDL / DML of the file itself
  defp top_sql(path), do: path |> code_sql() |> String.replace(~r/\$\$.*?\$\$/s, "$$ $$")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()
  defp header(path), do: path |> read!() |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.map_join("\n", &String.replace(&1, ~r/\A--\s?/, ""))

  defp table_body do
    sql = norm(code_sql(up_file()))
    assert [_, body] = Regex.run(~r/create table if not exists (?:public\.)?#{@table} \((.*?)\);/s, sql), "the up file creates #{@table} with CREATE TABLE IF NOT EXISTS"
    body
  end

  describe "migration files (static)" do
    test "up and down exist exactly once, with the same number 000060, and no other migration has that number" do
      assert [up] = files("up")
      assert [down] = files("down")
      assert number(up) == number(down)
      assert number(up) == 60, "000058 is the key backup, 000059 the to-device queue: this migration is 000060"
      assert Path.wildcard(Path.join(@dir, "000060_*.up.sql")) == [up]
    end

    test "the files are named 000060_device_list_changes.{up,down}.sql and their first comment line names the file" do
      assert Path.basename(up_file()) == "000060_device_list_changes.up.sql"
      assert Path.basename(down_file()) == "000060_device_list_changes.down.sql"
      assert up_file() |> read!() |> String.split("\n") |> hd() =~ "000060_device_list_changes.up.sql"
      assert down_file() |> read!() |> String.split("\n") |> hd() =~ "000060_device_list_changes.down.sql"
    end

    test "the earlier migrations are untouched (000059 still creates the to-device tables)" do
      [f59] = Path.wildcard(Path.join(@dir, "000059_*.up.sql"))
      assert norm(read!(f59)) =~ "to_device_messages"
    end

    test "up creates the table with IF NOT EXISTS: user_id, room_id (default ''), checked kind, nullable pos, created_at, key (user_id, room_id)" do
      body = table_body()
      assert body =~ ~r/\buser_id text not null\b/
      assert body =~ ~r/\broom_id text not null default ''/
      assert body =~ ~r/\bkind text not null\b/ and body =~ ~r/check \(kind in \('keys', 'join', 'leave'\)\)/
      assert body =~ ~r/\bpos bigint(?! not null)/, "pos is nullable: it stays NULL until the commit stamps it"
      assert body =~ ~r/\bcreated_at timestamptz not null default now\(\)/
      assert body =~ ~r/primary key \(user_id, room_id\)/
    end

    test "up adds ONE nullable column to the fallback keys (ADD COLUMN IF NOT EXISTS key_id TEXT) and touches no other existing table except room_members (the trigger)" do
      sql = top_sql(up_file())
      assert norm(sql) =~ ~r/alter table (?:if exists )?(?:public\.)?device_fallback_keys add column if not exists key_id text\s*;/
      for [_, t] <- Regex.scan(~r/ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?(\w+)/i, sql), do: assert(t in [@table, "device_fallback_keys"], "ALTER TABLE #{t}: an existing table must not be touched")
      assert norm(sql) =~ ~r/create trigger \w+ after insert or update of left_at on (?:public\.)?room_members/
      refute norm(sql) =~ ~r/drop column|set not null|alter column/
    end

    test "up has no data statement outside the function bodies, no BEGIN / COMMIT, no CONCURRENTLY, no new sequence, no EXTENSION" do
      sql = top_sql(up_file())
      refute sql =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|TRUNCATE)\b/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY|CREATE\s+SEQUENCE|CREATE\s+EXTENSION|DROP\s+(TABLE|COLUMN)\b/i
    end

    test "the stamp reads the EXISTING sequence sync_global_pos_seq, takes one advisory lock and is a deferrable initially deferred constraint trigger that fires only for pos NULL" do
      sql = norm(code_sql(up_file()))
      assert sql =~ "nextval('sync_global_pos_seq')"
      assert sql =~ ~r/pg_advisory_xact_lock\(\s*\d+\s*,\s*\d+\s*\)/
      assert sql =~ ~r/create constraint trigger \w+ after insert or update on (?:public\.)?#{@table} deferrable initially deferred for each row when \(new\.pos is null\) execute function/
    end

    test "neither trigger function is SECURITY DEFINER (they run with the rights of the writing role)" do
      refute norm(code_sql(up_file())) =~ "security definer"
    end

    test "the membership trigger function covers INSERT (join), left_at set (leave) and left_at cleared (join) and writes only the three kinds" do
      sql = norm(code_sql(up_file()))
      assert [_, fun] = Regex.run(~r/create or replace function device_list_changes_member\(\).*?\$\$(.*?)\$\$/s, sql)
      assert fun =~ "tg_op = 'insert'" and fun =~ "'join'" and fun =~ "'leave'"
      assert fun =~ ~r/old\.left_at is null and new\.left_at is not null/ and fun =~ ~r/old\.left_at is not null and new\.left_at is null/
    end

    test "up creates the indexes of the hot paths: the position scan and the room scan" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?#{@table} \(pos\)/
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?#{@table} \(room_id, pos\)/
    end

    test "up grants SELECT, INSERT, UPDATE, DELETE to nebu_app, nothing to PUBLIC, no default privileges" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/grant select, insert, update, delete on (?:table )?(?:public\.)?#{@table} to nebu_app/
      refute sql =~ ~r/\bto public\b/
      refute sql =~ ~r/alter default privileges/
      refute sql =~ ~r/grant [^;]*\b(truncate|references|trigger|all)\b[^;]* to nebu_app/
    end

    test "up ENABLEs and FORCEs row level security and creates a policy for SELECT, INSERT, UPDATE and DELETE" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/alter table (?:public\.)?#{@table} enable row level security/
      assert sql =~ ~r/alter table (?:public\.)?#{@table} force row level security/
      cmds = Regex.scan(~r/create policy \w+ on (?:public\.)?#{@table} (?:as \w+ )?for (select|insert|update|delete|all)\b/, sql) |> Enum.map(&List.last/1)
      for cmd <- ~w(select insert update delete), do: assert(cmd in cmds or "all" in cmds, "a policy for #{String.upcase(cmd)}, got #{inspect(cmds)}")
    end

    test "up is idempotent by construction: IF NOT EXISTS, OR REPLACE and DROP ... IF EXISTS before every CREATE of a trigger or policy" do
      sql = norm(code_sql(up_file()))
      for trig <- Regex.scan(~r/create (?:constraint )?trigger (\w+)/, sql) |> Enum.map(&List.last/1), do: assert(sql =~ ~r/drop trigger if exists #{trig}\b/, "DROP TRIGGER IF EXISTS #{trig}")
      for pol <- Regex.scan(~r/create policy (\w+)/, sql) |> Enum.map(&List.last/1), do: assert(sql =~ ~r/drop policy if exists #{pol}\b/, "DROP POLICY IF EXISTS #{pol}")
      assert Regex.scan(~r/create function/, sql) == [], "functions are CREATE OR REPLACE"
    end

    test "down removes both triggers, both functions, the table and the key_id column, nothing else: no grants, no CREATE" do
      sql = norm(code_sql(down_file()))
      assert sql =~ ~r/drop trigger if exists device_list_changes_member_trigger on (?:public\.)?room_members/
      assert sql =~ ~r/drop trigger if exists device_list_changes_stamp_trigger on (?:public\.)?#{@table}/
      assert sql =~ "drop function if exists device_list_changes_member()" and sql =~ "drop function if exists device_list_changes_stamp()"
      assert sql =~ ~r/drop table if exists (?:public\.)?#{@table}/
      assert sql =~ ~r/alter table (?:if exists )?(?:public\.)?device_fallback_keys drop column if exists key_id/
      refute sql =~ ~r/\b(grant|revoke)\b/
      refute sql =~ ~r/\bcreate\b/
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m
    end

    test "the headers name the story, the table, the commit-time stamp and the erasure; down warns that the stream is discarded" do
      h = header(up_file())
      for word <- ["device-key-directory", @table, "user_id", "commit", "sync_global_pos_seq", "key_id"], do: assert(h =~ word, "the up header mentions #{word}")
      assert h =~ ~r/erasure/i
      assert header(down_file()) =~ ~r/WARNING|discard/i
    end
  end

  describe "migration applied (integration, catalog facts, runtime role)" do
    @describetag :integration

    test "the table exists with the pinned columns and types" do
      cols = T.sql!("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1", [@table]).rows |> Map.new(fn [c, t, n] -> {c, {t, n}} end)

      assert cols["user_id"] == {"text", "NO"} and cols["room_id"] == {"text", "NO"} and cols["kind"] == {"text", "NO"}
      assert cols["pos"] == {"bigint", "YES"}
      assert cols["created_at"] == {"timestamp with time zone", "NO"}
    end

    test "the key is (user_id, room_id): a second row for the same pair is a unique violation, another room is another row" do
      uid = "@dlc-mig-#{T.rand(4)}:test.local"
      ins = fn room, kind -> Ecto.Adapters.SQL.query(Nebu.Repo, "INSERT INTO device_list_changes (user_id, room_id, kind, pos) VALUES ($1, $2, $3, 1)", [uid, room, kind]) end
      assert {:ok, _} = ins.("", "keys")
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = ins.("", "keys")
      assert {:ok, _} = ins.("!r:test.local", "join")
      T.sql!("DELETE FROM device_list_changes WHERE user_id = $1", [uid])
    end

    test "kind is checked: a value other than keys / join / leave is rejected" do
      uid = "@dlc-mig-#{T.rand(4)}:test.local"
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = Ecto.Adapters.SQL.query(Nebu.Repo, "INSERT INTO device_list_changes (user_id, kind, pos) VALUES ($1, 'bogus', 1)", [uid])
    end

    test "room_id defaults to the empty string and created_at to now()" do
      uid = "@dlc-mig-#{T.rand(4)}:test.local"
      T.sql!("INSERT INTO device_list_changes (user_id, kind, pos) VALUES ($1, 'keys', 1)", [uid])
      assert T.sql!("SELECT room_id, created_at IS NOT NULL FROM device_list_changes WHERE user_id = $1", [uid]).rows == [["", true]]
      T.sql!("DELETE FROM device_list_changes WHERE user_id = $1", [uid])
    end

    test "device_fallback_keys has a nullable TEXT key_id" do
      assert T.sql!("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'device_fallback_keys' AND column_name = 'key_id'").rows == [["text", "YES"]]
    end

    test "the stamp: pos is NULL inside the transaction and drawn from sync_global_pos_seq AFTER the commit; a rollback changes nothing" do
      uid = "@dlc-mig-#{T.rand(4)}:test.local"
      before = T.sql!("SELECT last_value FROM sync_global_pos_seq").rows |> hd() |> hd()

      assert {:ok, inside} =
               Nebu.Repo.transaction(fn ->
                 T.sql!("INSERT INTO device_list_changes (user_id, kind, pos) VALUES ($1, 'keys', NULL)", [uid])
                 T.sql!("SELECT pos FROM device_list_changes WHERE user_id = $1", [uid]).rows |> hd() |> hd()
               end)

      assert inside == nil, "the position is assigned at commit, not at the statement"
      [[pos]] = T.sql!("SELECT pos FROM device_list_changes WHERE user_id = $1", [uid]).rows
      assert is_integer(pos) and pos > before

      assert {:error, :undo} =
               Nebu.Repo.transaction(fn ->
                 T.sql!("UPDATE device_list_changes SET pos = NULL WHERE user_id = $1", [uid])
                 Nebu.Repo.rollback(:undo)
               end)

      assert T.sql!("SELECT pos FROM device_list_changes WHERE user_id = $1", [uid]).rows == [[pos]], "a rolled back write changes nothing"

      T.sql!("UPDATE device_list_changes SET pos = NULL WHERE user_id = $1", [uid])
      [[pos2]] = T.sql!("SELECT pos FROM device_list_changes WHERE user_id = $1", [uid]).rows
      assert pos2 > pos, "an UPDATE that sets pos NULL is stamped again at its commit"
      T.sql!("DELETE FROM device_list_changes WHERE user_id = $1", [uid])
    end

    test "a row that is written WITH a position keeps it (the stamp fires only for NULL)" do
      uid = "@dlc-mig-#{T.rand(4)}:test.local"
      T.sql!("INSERT INTO device_list_changes (user_id, kind, pos) VALUES ($1, 'keys', 424242)", [uid])
      assert T.sql!("SELECT pos FROM device_list_changes WHERE user_id = $1", [uid]).rows == [[424_242]]
      T.sql!("DELETE FROM device_list_changes WHERE user_id = $1", [uid])
    end

    test "both triggers exist as pinned: the stamp deferrable initially deferred, the membership trigger on room_members, both enabled" do
      rows = T.sql!("SELECT tgname, tgrelid::regclass::text, tgdeferrable, tginitdeferred, tgenabled FROM pg_trigger WHERE tgname IN ('device_list_changes_stamp_trigger', 'device_list_changes_member_trigger') ORDER BY tgname").rows
      assert rows == [["device_list_changes_member_trigger", "room_members", false, false, "O"], ["device_list_changes_stamp_trigger", "device_list_changes", true, true, "O"]]
    end

    test "neither function is SECURITY DEFINER" do
      assert T.sql!("SELECT proname, prosecdef FROM pg_proc WHERE proname IN ('device_list_changes_stamp', 'device_list_changes_member') ORDER BY proname").rows ==
               [["device_list_changes_member", false], ["device_list_changes_stamp", false]]
    end

    test "the indexes of the hot paths exist: pos leading, (room_id, pos), and the key serves the erasure (user_id leading)" do
      lead = T.sql!("SELECT (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = i.indrelid AND a.attnum = i.indkey[0]), (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = i.indrelid AND a.attnum = i.indkey[1]) FROM pg_index i WHERE i.indrelid = $1::text::regclass", [@table]).rows
      assert ["pos", nil] in lead and ["room_id", "pos"] in lead and ["user_id", "room_id"] in lead, inspect(lead)
    end

    test "row level security is enabled AND forced, each command has a permissive policy" do
      assert T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = $1::text::regclass", [@table]).rows == [[true, true]]
      rows = T.sql!("SELECT cmd, permissive FROM pg_policies WHERE schemaname = current_schema() AND tablename = $1", [@table]).rows
      cmds = Enum.map(rows, &hd/1)
      for cmd <- ~w(SELECT INSERT UPDATE DELETE), do: assert(cmd in cmds or "ALL" in cmds, "no policy for #{cmd}")
      assert Enum.all?(rows, fn [_, permissive] -> permissive == "PERMISSIVE" end)
    end

    test "the runtime role has SELECT, INSERT, UPDATE, DELETE and no TRUNCATE, REFERENCES or TRIGGER; PUBLIC has nothing" do
      privs = for p <- ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER), into: %{}, do: {p, T.sql!("SELECT has_table_privilege('nebu_app', $1, '#{p}')", [@table]).rows |> hd() |> hd()}
      assert privs == %{"SELECT" => true, "INSERT" => true, "UPDATE" => true, "DELETE" => true, "TRUNCATE" => false, "REFERENCES" => false, "TRIGGER" => false}
      acl = T.sql!("SELECT COALESCE(relacl::text, '') FROM pg_class WHERE oid = $1::text::regclass", [@table]).rows |> hd() |> hd()
      refute acl =~ ~r/(?:\{|,)=[a-zA-Z*]*\//, "a grant to PUBLIC in #{acl}"
    end
  end

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp present?(tx, table), do: Postgrex.query!(tx, "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1", [table]).rows == [[1]]
    defp triggers(tx), do: Postgrex.query!(tx, "SELECT tgname FROM pg_trigger WHERE tgname LIKE 'device_list_changes%' ORDER BY 1", []).rows |> List.flatten()
    defp key_id?(tx), do: Postgrex.query!(tx, "SELECT count(*) FROM information_schema.columns WHERE table_name = 'device_fallback_keys' AND column_name = 'key_id'", []).rows == [[1]]
    defp run!(tx, sql), do: Postgrex.query!(tx, sql, [], query_type: :text)

    test "down removes the table, both triggers and the column, up restores them, a second up is a no-op, the other tables are untouched" do
      up = read!(up_file())
      down = read!(down_file())

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert present?(tx, @table) and key_id?(tx), "precondition: the migrated database has the table and the column"
            tables = Postgrex.query!(tx, "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() ORDER BY 1", []).rows

            run!(tx, down)
            refute present?(tx, @table)
            refute key_id?(tx)
            assert triggers(tx) == [], "down removes both triggers"
            assert Postgrex.query!(tx, "SELECT count(*) FROM pg_proc WHERE proname LIKE 'device_list_changes%'", []).rows == [[0]], "and both functions"
            assert Postgrex.query!(tx, "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema()", []).rows == [[length(tables) - 1]]

            run!(tx, up)
            assert present?(tx, @table) and key_id?(tx)
            assert triggers(tx) == ["device_list_changes_member_trigger", "device_list_changes_stamp_trigger"]
            run!(tx, up)
            assert triggers(tx) == ["device_list_changes_member_trigger", "device_list_changes_stamp_trigger"], "a second up is harmless"
            assert Postgrex.query!(tx, "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() ORDER BY 1", []).rows == tables

            assert Postgrex.query!(tx, "SELECT has_table_privilege('nebu_app', $1, 'SELECT'), has_table_privilege('nebu_app', $1, 'DELETE'), (SELECT relforcerowsecurity FROM pg_class WHERE oid = $1::text::regclass)", [@table]).rows == [[true, true, true]]

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end
  end
end
