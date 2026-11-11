defmodule Nebu.Acceptance.GrantNebuAppMissingTablePrivilegesTest do
  @moduledoc """
  ATDD for story `grant-nebu-app-missing-table-privileges`.

  Static analysis of `priv/migrations/*.sql` (no database needed, same approach as
  `Nebu.Matrix.MigrationsGrantTest`). One test per Gherkin scenario, tagged
  `@tag ac: "<scenario-slug>"`. Red until migration `000064_grant_missing_table_privileges` exists.
  """
  use ExUnit.Case, async: true

  @migrations_dir Path.expand("../../../priv/migrations", __DIR__)

  @up_064 "000064_grant_missing_table_privileges.up.sql"
  @down_064 "000064_grant_missing_table_privileges.down.sql"

  @five_tables ~w(cross_signing_keys account_data operational_logs war_room_sessions admin_temporary_captures)
  @sequence "operational_logs_id_seq"

  # sha256 of the shipped migrations 000001 and 000014-000020 as of the story start (HEAD before 000064).
  # The fix is forward-only: none of these files may change.
  @shipped_sha256 %{
    "000001_init.up.sql" => "f92916f41e27296bc7c71cfda7383ac225eb8e80e606e4d79b8f07ac8345e6b7",
    "000014_cross_signing_keys.down.sql" => "efc11c4ef0fb4fff05f5803c2827adec28bfbac3d732a484caf7444e7b17fdcc",
    "000014_cross_signing_keys.up.sql" => "15f0dc81344713fcf3032fe17cbfd1536448ed63773969c61bfa2e33813c0a36",
    "000015_account_data.down.sql" => "9cd91582a91e7b826729767578fa143582e6d332edd81fe6867e68181d70b44d",
    "000015_account_data.up.sql" => "bf80f3a745116902c66ffd16211c4d6aa7be40b768b112e43b5b586a3ae5f781",
    "000016_config_admin_group_claim_path.down.sql" => "e17a8cbfb231036ae78c1a9a53b23fede8d4b326f9fedc1daacb6e2e0b047f98",
    "000016_config_admin_group_claim_path.up.sql" => "5684f8040e33f35a4f4b5868b8ba92d477c9946ccf30eb77769c900cf0b76e15",
    "000017_operational_logs.down.sql" => "19a93a0274fb95e0bdbe71a23011d2afad5451d8da10967b8a5448768f9ef93c",
    "000017_operational_logs.up.sql" => "861f8ec7159d3c51d1193c0754c9ed1ee1db35c2ed68fdde31d21b03bb7296fc",
    "000018_config_log_info_max_count_mutable.down.sql" => "27d4de175a3881bd561dd1f1aef85d8b53c122931226c4b16bb0d372a01d2d0b",
    "000018_config_log_info_max_count_mutable.up.sql" => "188147c908ea3e40d8a53a258fa2dd1b80f238ce4c8d395110ac04d16b9114cf",
    "000019_war_room_sessions.down.sql" => "6f029ecea6092d6d45e92eae6021134a26d3005b641f660cedaed8af922e29f8",
    "000019_war_room_sessions.up.sql" => "fd4394786ea538fb338bc8a85fef85ea82daf6413a26d26fd7984a7b0d00015b",
    "000020_admin_temporary_captures.down.sql" => "88a52fd18d1e2b8d088a71c4e20c3ef5a3d3a1993ddd6ec7065c599adb3bfc8d",
    "000020_admin_temporary_captures.up.sql" => "be91ddf16bee021f2929b38e4d0a249cf34f777e9039b585f368528aed6000b3"
  }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp path(file), do: Path.join(@migrations_dir, file)

  # Reads a migration, failing with a readable message when it does not exist yet.
  defp read_migration(file) do
    assert File.exists?(path(file)), "migration #{file} does not exist (priv/migrations)"
    File.read!(path(file))
  end

  # Removes `-- line` and `/* block */` comments so that prose never counts as SQL.
  defp strip_comments(sql) do
    sql
    |> String.replace(~r{/\*.*?\*/}s, " ")
    |> String.replace(~r/--[^\n]*/, "")
  end

  defp statements(sql) do
    sql
    |> strip_comments()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Parses `GRANT <privs> ON [TABLE|SEQUENCE] <objs> TO <grantee>` into a map; nil for anything else.
  defp parse_grant(stmt) do
    re = ~r/\AGRANT\s+(?<privs>.+?)\s+ON\s+(?<rest>.+?)\s+TO\s+(?<to>.+)\z/is

    with %{"privs" => privs, "rest" => rest, "to" => to} <- Regex.named_captures(re, stmt) do
      {kind, objs} =
        cond do
          m = Regex.run(~r/\ASEQUENCE\s+(.+)\z/is, rest) -> {:sequence, Enum.at(m, 1)}
          m = Regex.run(~r/\ATABLE\s+(.+)\z/is, rest) -> {:table, Enum.at(m, 1)}
          Regex.match?(~r/\AALL\s+/i, rest) -> {:all, rest}
          true -> {:table, rest}
        end

      %{
        privs: privs |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.upcase())) |> MapSet.new(),
        kind: kind,
        objects: objs |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("public.", ""))),
        to: String.trim(to)
      }
    else
      _ -> nil
    end
  end

  defp grants(sql), do: sql |> statements() |> Enum.map(&parse_grant/1) |> Enum.reject(&is_nil/1)

  defp up_files do
    @migrations_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".up.sql")) |> Enum.sort()
  end

  defp version(file), do: file |> String.split("_", parts: 2) |> hd()

  # Table modifiers PostgreSQL accepts between CREATE and TABLE.
  @table_modifiers ~S"(?:(?:GLOBAL\s+|LOCAL\s+)?(?:TEMPORARY\s+|TEMP\s+)|UNLOGGED\s+)?"

  # {table, migration_file} for every CREATE [TEMP|UNLOGGED] TABLE in the up migrations after 000001.
  defp created_tables do
    re =
      Regex.compile!(
        "\\ACREATE\\s+" <> @table_modifiers <> "TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(?:public\\.)?\"?([a-z_][a-z0-9_]*)\"?",
        "i"
      )

    for file <- up_files(),
        version(file) != "000001",
        stmt <- statements(File.read!(path(file))),
        m = Regex.run(re, stmt),
        do: {Enum.at(m, 1), file}
  end

  # Grantees of a parsed grant: `TO a, "b" WITH GRANT OPTION` -> ["a", "b"] (lowercased, unquoted).
  defp grantees(%{to: to}) do
    to
    |> String.replace(~r/\s+WITH\s+GRANT\s+OPTION\z/i, "")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"") |> String.downcase()))
  end

  defp to_nebu_app?(g), do: "nebu_app" in grantees(g)

  defp all_privs?(privs), do: MapSet.member?(privs, "ALL") or MapSet.member?(privs, "ALL PRIVILEGES")

  # Tables that some migration grants any privilege on to nebu_app by name (several tables are
  # deliberately least-privilege, e.g. no DELETE, so no particular privilege set is required here).
  defp granted_tables do
    for file <- up_files(),
        g <- grants(File.read!(path(file))),
        g.kind == :table,
        to_nebu_app?(g),
        obj <- g.objects,
        into: MapSet.new(),
        do: String.downcase(obj)
  end

  # Sequences that some migration grants USAGE on to nebu_app by name.
  defp granted_sequences do
    for file <- up_files(),
        g <- grants(File.read!(path(file))),
        g.kind == :sequence,
        to_nebu_app?(g),
        all_privs?(g.privs) or MapSet.member?(g.privs, "USAGE"),
        obj <- g.objects,
        into: MapSet.new(),
        do: String.downcase(obj)
  end

  # {sequence, migration_file} for every sequence a post-000001 migration creates, explicitly
  # (CREATE SEQUENCE) or implicitly (SERIAL/BIGSERIAL/SMALLSERIAL or GENERATED ... AS IDENTITY
  # columns in CREATE TABLE and ALTER TABLE ... ADD COLUMN), named `<table>_<column>_seq`.
  defp created_sequences do
    explicit_re = ~r/\ACREATE\s+(?:(?:TEMPORARY|TEMP|UNLOGGED)\s+)?SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?"?([a-z_][a-z0-9_]*)"?/i
    table_re = ~r/\A(?:CREATE\s+(?:(?:GLOBAL\s+|LOCAL\s+)?(?:TEMPORARY\s+|TEMP\s+)|UNLOGGED\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?|ALTER\s+TABLE(?:\s+IF\s+EXISTS)?(?:\s+ONLY)?)\s+(?:public\.)?"?([a-z_][a-z0-9_]*)"?/i
    serial_re = ~r/"?([a-z_][a-z0-9_]*)"?\s+(?:small|big)?serial\b/i
    identity_re = ~r/"?([a-z_][a-z0-9_]*)"?\s+[a-z0-9_]+\s+GENERATED\s+(?:ALWAYS|BY\s+DEFAULT)\s+AS\s+IDENTITY/i

    for file <- up_files(),
        version(file) != "000001",
        stmt <- statements(File.read!(path(file))),
        {seq, _} <-
          (case Regex.run(explicit_re, stmt) do
             [_, name] ->
               [{name, file}]

             nil ->
               case Regex.run(table_re, stmt) do
                 [_, table] ->
                   cols =
                     Enum.map(Regex.scan(serial_re, stmt), &Enum.at(&1, 1)) ++
                       Enum.map(Regex.scan(identity_re, stmt), &Enum.at(&1, 1))

                   Enum.map(cols, &{"#{table}_#{&1}_seq", file})

                 nil ->
                   []
               end
           end),
        do: {String.downcase(seq), file}
  end

  # ---------------------------------------------------------------------------
  # Scenario: The five tables are granted to the runtime role
  # ---------------------------------------------------------------------------
  @tag ac: "the-five-tables-are-granted-to-the-runtime-role"
  test "Scenario: The five tables are granted to the runtime role" do
    grants = @up_064 |> read_migration() |> grants()
    dml = MapSet.new(~w(SELECT INSERT UPDATE DELETE))

    for table <- @five_tables do
      assert Enum.any?(grants, fn g ->
               g.kind == :table and table in g.objects and g.privs == dml and String.downcase(g.to) == "nebu_app"
             end),
             "#{@up_064} must contain `GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO nebu_app`"
    end

    assert Enum.any?(grants, fn g ->
             g.kind == :sequence and @sequence in g.objects and g.privs == MapSet.new(~w(USAGE SELECT)) and
               String.downcase(g.to) == "nebu_app"
           end),
           "#{@up_064} must contain `GRANT USAGE, SELECT ON SEQUENCE #{@sequence} TO nebu_app`"
  end

  # ---------------------------------------------------------------------------
  # Scenario: No table can be shipped without a runtime grant again
  # ---------------------------------------------------------------------------
  @tag ac: "no-table-can-be-shipped-without-a-runtime-grant-again"
  test "Scenario: No table can be shipped without a runtime grant again" do
    granted = granted_tables()
    created = created_tables()

    assert created != [], "expected CREATE TABLE statements in the up migrations after 000001"

    missing =
      for {table, file} <- created, not MapSet.member?(granted, table) do
        "table #{table} (created in #{file}) has no `GRANT ... ON #{table} TO nebu_app` in any migration"
      end

    assert missing == [], Enum.join(missing, "\n")
  end

  @tag ac: "no-table-can-be-shipped-without-a-runtime-grant-again"
  test "Scenario: No sequence can be shipped without a runtime grant again" do
    granted = granted_sequences()
    created = created_sequences()

    assert created != [], "expected serial/identity columns or CREATE SEQUENCE in the up migrations after 000001"

    missing =
      for {seq, file} <- created, not MapSet.member?(granted, seq) do
        "sequence #{seq} (created in #{file}) has no `GRANT USAGE ... ON SEQUENCE #{seq} TO nebu_app` in any migration"
      end

    assert missing == [], Enum.join(missing, "\n")
  end

  # ---------------------------------------------------------------------------
  # Scenario: The grant is minimal
  # ---------------------------------------------------------------------------
  @tag ac: "the-grant-is-minimal"
  test "Scenario: The grant is minimal" do
    up = read_migration(@up_064)
    down = read_migration(@down_064)
    code = strip_comments(up)

    for {label, re} <- [
          {"GRANT ALL", ~r/\bGRANT\s+ALL\b/i},
          {"ALL PRIVILEGES", ~r/\bALL\s+PRIVILEGES\b/i},
          {"TRUNCATE", ~r/\bTRUNCATE\b/i},
          {"REFERENCES", ~r/\bREFERENCES\b/i},
          {"TRIGGER", ~r/\bTRIGGER\b/i},
          {"PUBLIC", ~r/\bPUBLIC\b/i},
          {"WITH GRANT OPTION", ~r/\bWITH\s+GRANT\s+OPTION\b/i}
        ] do
      refute Regex.match?(re, code), "#{@up_064} must not contain #{label}"
    end

    stmts = statements(up)
    assert stmts != [], "#{@up_064} must contain statements"
    assert Enum.all?(stmts, &(parse_grant(&1) != nil)), "#{@up_064} must be GRANT-only (no schema change)"

    gs = grants(up)
    assert Enum.all?(gs, &(String.downcase(&1.to) == "nebu_app")), "#{@up_064} must grant to nebu_app only"
    assert Enum.all?(gs, &(&1.kind in [:table, :sequence])), "#{@up_064} must not use ALL TABLES/SEQUENCES grants"

    tables = gs |> Enum.filter(&(&1.kind == :table)) |> Enum.flat_map(& &1.objects) |> Enum.sort()
    sequences = gs |> Enum.filter(&(&1.kind == :sequence)) |> Enum.flat_map(& &1.objects) |> Enum.sort()

    assert tables == Enum.sort(@five_tables), "#{@up_064} must grant on exactly the five tables, got #{inspect(tables)}"
    assert sequences == [@sequence], "#{@up_064} must grant on exactly #{@sequence}, got #{inspect(sequences)}"

    assert Enum.all?(gs, fn g ->
             g.privs == if(g.kind == :table, do: MapSet.new(~w(SELECT INSERT UPDATE DELETE)), else: MapSet.new(~w(USAGE SELECT)))
           end),
           "#{@up_064} must grant exactly SELECT/INSERT/UPDATE/DELETE on tables and USAGE/SELECT on the sequence"

    refute Regex.match?(~r/\bGRANT\b/i, strip_comments(down)), "#{@down_064} must contain no GRANT"
  end

  # ---------------------------------------------------------------------------
  # Scenario: Shipped migrations stay untouched
  # ---------------------------------------------------------------------------
  @tag ac: "shipped-migrations-stay-untouched"
  test "Scenario: Shipped migrations stay untouched" do
    # The fix lives in the forward-only 000064; without it the guard below would pass vacuously.
    assert File.exists?(path(@up_064)), "forward-only fix #{@up_064} must exist"

    changed =
      for {file, expected} <- @shipped_sha256,
          actual = :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower),
          actual != expected,
          do: file

    assert changed == [], "shipped migrations must not be edited (forward-only fix): #{inspect(changed)}"
  end

  # ---------------------------------------------------------------------------
  # Scenario: The release still migrates
  # ---------------------------------------------------------------------------
  @tag ac: "the-release-still-migrates"
  test "Scenario: The release still migrates" do
    listed = @migrations_dir |> Nebu.Release.list_up_migrations() |> Enum.sort_by(&elem(&1, 0))
    versions = Enum.map(listed, &elem(&1, 0))

    assert 64 in versions, "Nebu.Release must list migration version 64 (#{@up_064})"
    assert Enum.at(versions, Enum.find_index(versions, &(&1 == 64)) - 1) == 63, "64 must directly follow 63"

    {64, file} = Enum.find(listed, fn {v, _} -> v == 64 end)
    assert Path.basename(file) == @up_064
  end
end
