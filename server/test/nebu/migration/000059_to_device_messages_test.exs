defmodule Nebu.Migration.Migration000059ToDeviceMessagesTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): the migration `000059_to_device_messages` (found by NAME,
  `*_to_device_messages.{up,down}.sql`, number 000059: 000058 is the key backup of the sibling story on this branch, 000056 / 000057 live on another branch, so the release
  contiguity guard stays red here by design).

  Contract (story "Queue rows are purged on device delete, logout, session revoke and GDPR erasure ... txn ids persisted"):

    * TWO new tables: `to_device_messages` (the queue; `user_id` = the RECIPIENT, `device_id`, `sender`, `created_at`) and `to_device_txns` (the idempotency records; `user_id` = the SENDER,
      `device_id` = the sending device, `event_type`, `txn_id`, `created_at`), all text columns `NOT NULL`, `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` (the TTL decides by it). The
      idempotency is a DATABASE fact: a unique key over (user_id, device_id, event_type, txn_id), so a retry on another node or after a restart cannot queue twice. The names are pinned
      because the erasure inventory, the device teardown and the tests name them.
    * Indexes that the hot paths need (catalog facts): the device queue scan (`user_id, device_id` leading), the TTL sweep (`created_at` leading), the erasure of the messages a user SENT
      (`sender` leading), the sweep of the idempotency records (`created_at` leading).
    * Grants: `SELECT, INSERT, UPDATE, DELETE` to `nebu_app` on both tables (and usage on the sequences the migration creates), nothing to PUBLIC, no default privileges, no TRUNCATE /
      REFERENCES / TRIGGER. Row level security ENABLED and FORCED with a policy for each command.
    * Nothing existing is touched (rolling-deploy safe): no ALTER of a table other than the two, no data statement; `down` removes exactly what `up` created (and warns that queued messages are discarded);
      a down / up round trip is harmless and `up` is idempotent.

  Static analysis (no DB), a catalog part as the RUNTIME role and a down / up round trip on the privileged role inside a rolled-back transaction. After adding the migration re-create the
  throwaway database (or run the migration).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @tables ~w(to_device_messages to_device_txns)

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_to_device_messages.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_to_device_messages.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_to_device_messages.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()
  defp header(path), do: path |> read!() |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.map_join("\n", &String.replace(&1, ~r/\A--\s?/, ""))

  defp table_body(table) do
    sql = norm(code_sql(up_file()))
    assert [_, body] = Regex.run(~r/create table if not exists (?:public\.)?#{table} \((.*?)\);/s, sql), "the up file creates #{table} with CREATE TABLE IF NOT EXISTS"
    body
  end

  describe "migration files (static)" do
    test "up and down exist exactly once, with the same number 000059, and no other migration has that number" do
      assert [up] = files("up"), "exactly one *_to_device_messages.up.sql"
      assert [down] = files("down"), "exactly one *_to_device_messages.down.sql"
      assert number(up) == number(down)
      assert number(up) == 59, "000058 is the key backup, 000056 / 000057 belong to another branch: this migration is 000059"
      assert Path.wildcard(Path.join(@dir, "000059_*.up.sql")) == [up], "no second migration with that number"
    end

    test "the files are named 000059_to_device_messages.{up,down}.sql and their first comment line names the file" do
      assert Path.basename(up_file()) == "000059_to_device_messages.up.sql"
      assert Path.basename(down_file()) == "000059_to_device_messages.down.sql"
      assert up_file() |> read!() |> String.split("\n") |> hd() =~ "000059_to_device_messages.up.sql"
      assert down_file() |> read!() |> String.split("\n") |> hd() =~ "000059_to_device_messages.down.sql"
    end

    test "the earlier migrations are untouched (000058 still creates the key backup tables)" do
      [f58] = Path.wildcard(Path.join(@dir, "000058_*.up.sql"))
      assert norm(read!(f58)) =~ "room_key_backup_versions"
    end

    test "up creates both tables with IF NOT EXISTS; the queue has user_id, device_id, sender TEXT NOT NULL and created_at TIMESTAMPTZ NOT NULL DEFAULT now()" do
      body = table_body("to_device_messages")
      for col <- ~w(user_id device_id sender), do: assert(body =~ ~r/\b#{col} text not null\b/, "to_device_messages.#{col} TEXT NOT NULL")
      assert body =~ ~r/\bcreated_at timestamptz not null default now\(\)/, "created_at TIMESTAMPTZ NOT NULL DEFAULT now() (the TTL is decided by it)"
    end

    test "the idempotency table: user_id, device_id, event_type, txn_id TEXT NOT NULL under ONE primary / unique key, created_at TIMESTAMPTZ NOT NULL DEFAULT now()" do
      body = table_body("to_device_txns")
      for col <- ~w(user_id device_id event_type txn_id), do: assert(body =~ ~r/\b#{col} text not null\b/, "to_device_txns.#{col} TEXT NOT NULL")
      assert body =~ ~r/(primary key|unique) \((?=[^)]*user_id)(?=[^)]*device_id)(?=[^)]*event_type)(?=[^)]*txn_id)[^)]*\)/, "the key over (user_id, device_id, event_type, txn_id) makes a retry idempotent in the database"
      assert body =~ ~r/\bcreated_at timestamptz not null default now\(\)/
    end

    test "up creates the two tables and the sequences they need, and nothing else: no change of an existing table, no trigger or function, no data statement, no BEGIN / COMMIT" do
      sql = code_sql(up_file())
      created = Regex.scan(~r/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?(\w+)/i, sql) |> Enum.map(&List.last/1) |> Enum.sort()
      assert created == Enum.sort(@tables), "exactly the two tables, got #{inspect(created)}"

      for [_, t] <- Regex.scan(~r/ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "ALTER TABLE #{t}: an existing table must not be touched")
      for [_, t] <- Regex.scan(~r/CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?\w+\s+ON\s+(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "an index on #{t}")
      for [_, t] <- Regex.scan(~r/CREATE\s+POLICY\s+\w+\s+ON\s+(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "a policy on #{t}")
      refute sql =~ ~r/\b(CREATE|DROP)\s+(OR\s+REPLACE\s+)?(TRIGGER|FUNCTION|TYPE|EXTENSION)\b/i
      refute sql =~ ~r/\bDROP\s+(TABLE|COLUMN)\b/i
      for [_, t] <- Regex.scan(~r/DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?\w+\s+ON\s+(?:public\.)?(\w+)/i, sql), do: assert(t in @tables, "DROP POLICY on #{t}")
      refute sql =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
    end

    test "up creates the indexes of the hot paths (static): the device queue, the TTL sweeps, the erasure by sender" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?to_device_messages \(user_id, device_id/, "the queue scan"
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?to_device_messages \(created_at\)/, "the TTL sweep of the queue"
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?to_device_messages \(sender/, "the erasure of the messages a user sent"
      assert sql =~ ~r/create index if not exists \w+ on (?:public\.)?to_device_txns \(created_at\)/, "the sweep of the idempotency records"
    end

    test "up grants SELECT, INSERT, UPDATE, DELETE on both tables to nebu_app, grants nothing to PUBLIC, sets no default privileges" do
      sql = norm(code_sql(up_file()))

      for table <- @tables do
        assert sql =~ ~r/grant select, insert, update, delete on (?:table )?(?:public\.)?#{table} to nebu_app/, "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO nebu_app"
      end

      refute sql =~ ~r/\bto public\b/
      refute sql =~ ~r/alter default privileges/
      refute sql =~ ~r/grant [^;]*\b(truncate|references|trigger|all)\b[^;]* to nebu_app/
    end

    test "up ENABLEs and FORCEs row level security on both tables and creates a policy for SELECT, INSERT, UPDATE and DELETE on each" do
      sql = norm(code_sql(up_file()))

      for table <- @tables do
        assert sql =~ ~r/alter table (?:public\.)?#{table} enable row level security/, "#{table}: ENABLE ROW LEVEL SECURITY"
        assert sql =~ ~r/alter table (?:public\.)?#{table} force row level security/, "#{table}: FORCE ROW LEVEL SECURITY"
        cmds = Regex.scan(~r/create policy \w+ on (?:public\.)?#{table} (?:as \w+ )?for (select|insert|update|delete|all)\b/, sql) |> Enum.map(&List.last/1)
        for cmd <- ~w(select insert update delete), do: assert(cmd in cmds or "all" in cmds, "#{table}: a policy for #{String.upcase(cmd)}, got #{inspect(cmds)}")
      end
    end

    test "down removes exactly the two tables (and the sequence of the up file), no grants, no DDL besides DROP" do
      sql = norm(code_sql(down_file()))
      drops = Regex.scan(~r/drop table (?:if exists )?(?:public\.)?(\w+)/, sql) |> Enum.map(&List.last/1) |> Enum.sort()
      assert drops == Enum.sort(@tables), "down drops exactly the two tables, got #{inspect(drops)}"
      refute sql =~ ~r/\b(grant|revoke)\b/
      refute sql =~ ~r/\b(alter|create)\s+(table|index|policy|trigger|function)\b/
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m
    end

    test "the headers name the story, both tables and the erasure; down warns that queued messages are discarded" do
      h = header(up_file())
      for word <- ["to-device-messaging", "to_device_messages", "to_device_txns", "user_id", "erasure"], do: assert(h =~ word, "the up header mentions #{word}")
      assert h =~ ~r/opaque/i
      assert header(down_file()) =~ ~r/WARNING|discard/i
    end
  end

  describe "migration applied (integration, catalog facts, runtime role)" do
    @describetag :integration

    test "both tables exist with the pinned columns: user_id / device_id TEXT NOT NULL, created_at timestamptz NOT NULL with a default" do
      for {table, cols} <- [{"to_device_messages", ~w(user_id device_id sender)}, {"to_device_txns", ~w(user_id device_id event_type txn_id)}] do
        for col <- cols do
          assert T.sql!("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2", [table, col]).rows == [["text", "NO"]],
                 "#{table}.#{col} TEXT NOT NULL"
        end

        assert T.sql!("SELECT data_type, is_nullable, column_default IS NOT NULL FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = 'created_at'", [table]).rows ==
                 [["timestamp with time zone", "NO", true]]
      end
    end

    test "the idempotency key is unique in the database: a second INSERT of the same (user, device, type, txn) is a unique violation" do
      uid = "@td-mig-#{T.rand(4)}:test.local"
      insert = fn -> Ecto.Adapters.SQL.query(Nebu.Repo, "INSERT INTO to_device_txns (user_id, device_id, event_type, txn_id) VALUES ($1, 'D', 'm.x', 't1')", [uid]) end
      assert {:ok, _} = insert.()
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = insert.()
      assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "INSERT INTO to_device_txns (user_id, device_id, event_type, txn_id) VALUES ($1, 'D', 'm.y', 't1')", [uid]), "another event type is another key"
      assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "INSERT INTO to_device_txns (user_id, device_id, event_type, txn_id) VALUES ($1, 'E', 'm.x', 't1')", [uid]), "another device is another key"
      T.sql!("DELETE FROM to_device_txns WHERE user_id = $1", [uid])
    end

    test "the hot paths have an index each: device queue, TTL sweep, erasure by sender, txn sweep" do
      lead = fn table ->
        T.sql!("SELECT (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = i.indrelid AND a.attnum = i.indkey[0]), (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = i.indrelid AND a.attnum = i.indkey[1]) FROM pg_index i WHERE i.indrelid = $1::text::regclass", [table]).rows
      end

      messages = lead.("to_device_messages")
      assert ["user_id", "device_id"] in messages, "an index (user_id, device_id, ...) for the queue scan: #{inspect(messages)}"
      assert Enum.any?(messages, &(hd(&1) == "created_at")), "an index led by created_at for the TTL sweep"
      assert Enum.any?(messages, &(hd(&1) == "sender")), "an index led by sender for the erasure of sent messages"
      assert Enum.any?(lead.("to_device_txns"), &(hd(&1) == "created_at")), "an index led by created_at for the sweep of the idempotency records"
    end

    test "row level security is enabled AND forced on both tables, each has a policy per command, none restrictive" do
      for table <- @tables do
        assert T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = $1::text::regclass", [table]).rows == [[true, true]]
        rows = T.sql!("SELECT cmd, permissive FROM pg_policies WHERE schemaname = current_schema() AND tablename = $1", [table]).rows
        cmds = Enum.map(rows, &hd/1)
        for cmd <- ~w(SELECT INSERT UPDATE DELETE), do: assert(cmd in cmds or "ALL" in cmds, "#{table}: no policy for #{cmd}")
        assert Enum.all?(rows, fn [_, permissive] -> permissive == "PERMISSIVE" end)
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
            assert all_tables(tx) == before -- @tables

            run!(tx, up)
            assert all_tables(tx) == before
            run!(tx, up)
            assert all_tables(tx) == before, "a second up is harmless (IF NOT EXISTS)"

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
