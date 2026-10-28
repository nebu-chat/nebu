defmodule Nebu.Migration.Migration000052SyncDevicePositionsTest do
  @moduledoc """
  Acceptance tests for story `sync-token-per-device` (epic oauth-broker, follow-up `fd`), D9 / Sizing: migration
  `000052_sync_device_positions` (the number is confirmed by the implementer at commit time: the tests find the file by its NAME,
  `*_sync_device_positions.{up,down}.sql`, and require a number above 000051):

      CREATE SEQUENCE sync_global_pos_seq;
      account_data.stream_pos         BIGINT NOT NULL DEFAULT nextval('sync_global_pos_seq')   -- existing rows stamped by the volatile default
      cross_signing_keys.changed_pos  BIGINT NOT NULL DEFAULT 0
      sync_tokens.account_data_pos    BIGINT NOT NULL DEFAULT 0
      sync_tokens.cross_signing_pos   BIGINT NOT NULL DEFAULT 0
      CREATE INDEX ... ON account_data (user_id, stream_pos)
      GRANT USAGE, SELECT ON SEQUENCE sync_global_pos_seq TO nebu_app   -- the runtime role draws the positions
      -- down: drop the index, the four columns, the sequence

  Mirrors the sibling migration suites (`000049_...`, `000050_...`): static SQL-file analysis (no DB, runs in the unit job) and an
  `:integration` part as the RUNTIME role plus a down / up round trip on the privileged role inside a rolled-back transaction, on the
  migrated (fresh) schema AND on a POPULATED schema (rows that exist before the up migration get distinct positions, nothing is lost by a
  down). After adding the migration reset the throwaway database (`docker rm -f nebu-oauth-pg`) so that it runs.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @seq "sync_global_pos_seq"

  # {table, column, default pattern (a regex SOURCE: a Regex literal cannot live in a module attribute on every OTP)}
  @columns [
    {"account_data", "stream_pos", "nextval\\('?#{@seq}'?(::regclass)?\\)"},
    {"cross_signing_keys", "changed_pos", "\\A0\\z"},
    {"sync_tokens", "account_data_pos", "\\A0\\z"},
    {"sync_tokens", "cross_signing_pos", "\\A0\\z"}
  ]

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_sync_device_positions.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_sync_device_positions.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_sync_device_positions.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()

  describe "migration 000052 files (static)" do
    test "up and down exist exactly once, with the same number, above 000051" do
      assert [up] = files("up"), "exactly one *_sync_device_positions.up.sql"
      assert [down] = files("down"), "exactly one *_sync_device_positions.down.sql"
      assert number(up) == number(down), "up and down carry the same number"
      assert number(up) >= 52, "the next free number after 000051 (events_redacts)"
      assert Path.wildcard(Path.join(@dir, "#{String.pad_leading(Integer.to_string(number(up)), 6, "0")}_*.up.sql")) == [up], "no second migration with that number"
    end

    test "the earlier migrations are untouched: none of them mentions the new sequence or columns" do
      for f <- Path.wildcard(Path.join(@dir, "0000[0-4]*.sql")) ++ [Path.join(@dir, "000050_room_invitations_pending_inviter_idx.up.sql")] do
        content = File.read!(f)

        # whole identifiers only: 000039 names `user_room_account_data_pos_seq`, which merely CONTAINS `account_data_pos`
        for word <- [@seq, "account_data_pos", "cross_signing_pos", "changed_pos"],
            do: refute(content =~ Regex.compile!("(?<![A-Za-z0-9_])#{word}(?![A-Za-z0-9_])"), "#{Path.basename(f)} must not be edited (a new migration instead): #{word}")
      end
    end

    test "up creates the sequence sync_global_pos_seq" do
      assert norm(code_sql(up_file())) =~ ~r/create sequence (if not exists )?#{@seq}\b/
    end

    test "up adds account_data.stream_pos BIGINT NOT NULL DEFAULT nextval of the sequence (the volatile default stamps the existing rows)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/alter table account_data/
      assert sql =~ ~r/add column (if not exists )?stream_pos bigint not null default nextval\('#{@seq}'(::regclass)?\)/
    end

    test "up adds cross_signing_keys.changed_pos and the two sync_tokens position columns as BIGINT NOT NULL DEFAULT 0" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/alter table cross_signing_keys/
      assert sql =~ ~r/add column (if not exists )?changed_pos bigint not null default 0\b/
      assert sql =~ ~r/alter table sync_tokens/
      assert sql =~ ~r/add column (if not exists )?account_data_pos bigint not null default 0\b/
      assert sql =~ ~r/add column (if not exists )?cross_signing_pos bigint not null default 0\b/
    end

    test "up creates the (user_id, stream_pos) index on account_data, a plain index (transaction-safe)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/create index (if not exists )?\w+ on (public\.)?account_data\s*(using \w+\s*)?\(\s*user_id\s*,\s*stream_pos\s*\)/
      refute sql =~ "concurrently"
    end

    test "up grants USAGE and SELECT on the sequence to the runtime role nebu_app (the writer draws the position as nebu_app)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/grant [^;]*usage[^;]* on sequence #{@seq} to nebu_app/
    end

    test "up is DDL only (no data statement) and transaction-safe: no BEGIN / COMMIT / CONCURRENTLY" do
      sql = code_sql(up_file())
      refute sql =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
    end

    test "down drops the index, the four columns, then the sequence (the columns first: the default depends on the sequence)" do
      sql = norm(code_sql(down_file()))
      assert sql =~ ~r/drop index (if exists )?\w+/
      for {table, col, _} <- @columns, do: assert(sql =~ ~r/alter table #{table}[^;]*drop column (if exists )?#{col}\b/, "down drops #{table}.#{col}")
      assert sql =~ ~r/drop sequence (if exists )?#{@seq}\b/

      {col_at, _} = :binary.match(sql, "drop column")
      {seq_at, _} = :binary.match(sql, "drop sequence")
      assert col_at < seq_at, "DROP SEQUENCE comes after the DROP COLUMNs"
      refute sql =~ "concurrently"
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m
    end

    test "the header names the story and the sequence (the wording around it is free)" do
      header = read!(up_file()) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")

      assert header =~ "sync-token-per-device"
      assert header =~ @seq
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  # integration
  # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "migrated schema (integration, runtime role)" do
    @describetag :integration

    for {table, col, pattern} <- @columns do
      test "#{table}.#{col} is BIGINT NOT NULL with its default" do
        assert %{rows: [[type, nullable, default_sql]]} =
                 T.sql!(
                   "SELECT data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
                   [unquote(table), unquote(col)]
                 )

        assert type == "bigint"
        assert nullable == "NO"
        assert default_sql =~ Regex.compile!(unquote(pattern)), "default #{inspect(default_sql)}"
      end
    end

    test "the sequence exists and the runtime role nebu_app may draw from it (nextval is strictly increasing)" do
      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM pg_class WHERE relkind = 'S' AND relname = $1", [@seq])
      assert %{rows: [[true]]} = T.sql!("SELECT has_sequence_privilege(current_user, $1, 'USAGE')", [@seq])
      %{rows: [[a]]} = T.sql!("SELECT nextval('#{@seq}')")
      %{rows: [[b]]} = T.sql!("SELECT nextval('#{@seq}')")
      assert b > a
    end

    test "account_data has the (user_id, stream_pos) index" do
      assert %{rows: [[def_]]} =
               T.sql!(
                 "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'account_data' AND indexdef ~* '\\(user_id, stream_pos\\)'"
               )

      refute def_ =~ ~r/unique/i
    end

    test "a plain insert as the runtime role (no stream_pos given) stamps the next sequence value; an overwrite does NOT change it by itself" do
      uid = "@fd-mig-#{T.rand(5)}:test.local"
      now = System.system_time(:millisecond)

      T.sql!("INSERT INTO account_data (user_id, type, content_json, created_at, updated_at) VALUES ($1, 't1', '{}', $2, $2), ($1, 't2', '{}', $2, $2)", [uid, now])
      on_exit(fn -> T.sql!("DELETE FROM account_data WHERE user_id = $1", [uid]) end)

      assert %{rows: [[p1], [p2]]} = T.sql!("SELECT stream_pos FROM account_data WHERE user_id = $1 ORDER BY type", [uid])
      assert is_integer(p1) and is_integer(p2) and p1 > 0 and p1 != p2

      T.sql!("UPDATE account_data SET content_json = '{\"x\":1}' WHERE user_id = $1 AND type = 't1'", [uid])
      assert %{rows: [[^p1]]} = T.sql!("SELECT stream_pos FROM account_data WHERE user_id = $1 AND type = 't1'", [uid]), "the position is only drawn by the writer's SQL, not by a trigger"
    end
  end

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp column_exists?(tx, table, col) do
      %{rows: [[n]]} =
        Postgrex.query!(tx, "SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2", [table, col])

      n == 1
    end

    defp seq_exists?(tx), do: Postgrex.query!(tx, "SELECT count(*) FROM pg_class WHERE relkind = 'S' AND relname = $1", [@seq]).rows == [[1]]

    defp index_exists?(tx),
      do: Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'account_data' AND indexdef ~* '\\(user_id, stream_pos\\)'", []).rows == [[1]]

    defp all_present?(tx), do: Enum.all?(@columns, fn {t, c, _} -> column_exists?(tx, t, c) end) and seq_exists?(tx) and index_exists?(tx)
    defp all_absent?(tx), do: not Enum.any?(@columns, fn {t, c, _} -> column_exists?(tx, t, c) end) and not seq_exists?(tx) and not index_exists?(tx)

    test "fresh schema: down removes columns, index and sequence; up restores them" do
      up = read!(up_file())
      down = read!(down_file())

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert all_present?(tx), "precondition: the migrated database has the columns, the sequence and the index"

            Postgrex.query!(tx, down, [], query_type: :text)
            assert all_absent?(tx), "down must remove the four columns, the index and the sequence"

            Postgrex.query!(tx, up, [], query_type: :text)
            assert all_present?(tx), "up must restore all of it"

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end

    test "populated schema: existing rows get distinct positive stream_pos, the others default to 0; a down keeps the data" do
      uid = T.provision_user!()
      other = T.provision_user!()
      up = read!(up_file())
      down = read!(down_file())
      now = System.system_time(:millisecond)

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, down, [], query_type: :text)
            assert all_absent?(tx)

            # the populated "before" world: no position columns yet
            Postgrex.query!(
              tx,
              "INSERT INTO account_data (user_id, type, content_json, changed, created_at, updated_at) SELECT $1::text, 'type' || g, '{\"g\":' || g || '}', (g % 2 = 0), $2::bigint, $2::bigint FROM generate_series(1, 120) g",
              [uid, now]
            )

            Postgrex.query!(tx, "INSERT INTO account_data (user_id, type, content_json, created_at, updated_at) VALUES ($1, 'm.other', '{}', $2, $2)", [other, now])
            Postgrex.query!(tx, "INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at) VALUES ($1, '', 'tok-empty', NULL, $2), ($1, 'DEVA', 'tok-a', '$ev', $2)", [uid, now])
            Postgrex.query!(tx, "INSERT INTO cross_signing_keys (user_id, master_key_json, cross_signing_changed, created_at, updated_at) VALUES ($1, '{}', TRUE, $2, $2)", [uid, now])

            Postgrex.query!(tx, up, [], query_type: :text)

            assert %{rows: [[121, 121, min]]} = Postgrex.query!(tx, "SELECT count(*), count(DISTINCT stream_pos), min(stream_pos) FROM account_data WHERE user_id IN ($1, $2)", [uid, other])
            assert min >= 1, "every existing row is stamped by the volatile default (distinct, positive)"

            assert %{rows: [[0, 0], [0, 0]]} =
                     Postgrex.query!(tx, "SELECT account_data_pos, cross_signing_pos FROM sync_tokens WHERE user_id = $1 ORDER BY device_id", [uid]),
                   "existing token rows start at position 0 (every device falls back once anyway, D3)"

            assert %{rows: [[0]]} = Postgrex.query!(tx, "SELECT changed_pos FROM cross_signing_keys WHERE user_id = $1", [uid])

            # the data of the old columns is intact, and a new write after the migration is stamped above all of them
            assert %{rows: [[60]]} = Postgrex.query!(tx, "SELECT count(*) FROM account_data WHERE user_id = $1 AND changed", [uid])
            %{rows: [[max_before]]} = Postgrex.query!(tx, "SELECT max(stream_pos) FROM account_data", [])
            Postgrex.query!(tx, "INSERT INTO account_data (user_id, type, content_json, created_at, updated_at) VALUES ($1, 'new', '{}', $2, $2)", [uid, now])
            assert %{rows: [[new_pos]]} = Postgrex.query!(tx, "SELECT stream_pos FROM account_data WHERE user_id = $1 AND type = 'new'", [uid])
            assert new_pos > max_before

            # a down on the populated schema loses only the new columns
            Postgrex.query!(tx, down, [], query_type: :text)
            assert all_absent?(tx)
            assert %{rows: [[122]]} = Postgrex.query!(tx, "SELECT count(*) FROM account_data WHERE user_id IN ($1, $2)", [uid, other])
            assert %{rows: [[2]]} = Postgrex.query!(tx, "SELECT count(*) FROM sync_tokens WHERE user_id = $1", [uid])
            assert %{rows: [["tok-a"]]} = Postgrex.query!(tx, "SELECT since_token FROM sync_tokens WHERE user_id = $1 AND device_id = 'DEVA'", [uid])

            Postgrex.query!(tx, up, [], query_type: :text)
            assert all_present?(tx)

            Postgrex.rollback(tx, :populated_ok)
          end)
        end)

      assert result == {:error, :populated_ok}
    end
  end
end
