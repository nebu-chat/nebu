defmodule Nebu.Compliance.UserDeletionSchemaGuardTest do
  @moduledoc """
  Recurrence guard (Gherkin scenario 8, D3) of story `gdpr-erasure-global-data`: every table of the REAL schema that stores per-user data must be
  decided by the author of its migration: ERASED by `Nebu.Compliance.UserDeletion`, ended by the post-commit session teardown, or RETAINED ON PURPOSE with a
  reason. A new migration that adds per-user data breaks this test until its author decides.

  "Per-user table" = a public base table with a column `user_id`, a column `*_user_id`, a known user-reference column (`sender`, `inviter_id`, `invitee_id`,
  `granted_by`, `started_by`, `actor_id`, `owner`, `author`, `recipient`), a column matching `*_by`, `actor*`, `requester*`, `approver*`, `author*`, `owner*` or
  `recipient*` (the shapes D2's scan names plus the usual authorship columns: most tables of this schema do NOT use a foreign key to `users`), or a foreign key to
  `users`. A false positive goes on the explicit `@not_user_data` list below with its reason (a table there is not classified, it is declared harmless).

  ## How a new table is classified (read this when this test fails for your migration)

    * erased: add it to the `@erased_tables` attribute of `Nebu.Compliance.UserDeletion` (its rows are deleted by the erasure transaction, `WHERE user_id = ...`),
      seed a row for it in `UserDeletionTestSupport.seed_user!/2` and add it to `UserDeletionTestSupport.expected_erased/0`.
    * ended after the commit by the session teardown: `UserDeletionTestSupport.teardown_tables/0`.
    * retained on purpose: `UserDeletionTestSupport.retained_reasons/0`, with the reason (and name the table in `docs/architecture/08-concepts.md`).

  ## Contract pinned here

    * `Nebu.Compliance.UserDeletion.erased_tables/0` (NEW, public): the list (strings) of the tables whose rows of the user the erasure TRANSACTION deletes. The
      deleting code is driven by the same attribute, so the list and the code cannot drift; this suite pins that the list EQUALS the inventory of the suite
      (the real-database erasure tests seed and check exactly these tables) and that no `DELETE FROM` literal in `user_deletion.ex` names a table outside it.
    * The classification lists live in the test support (the list the author edits when this test fails); this file holds the generic logic, and proves with
      probe tables that the logic fails for an unclassified table (a `user_id`, a `*_user_id`, a `sender` and a foreign-key-only column) and for a listed table
      that no longer exists.
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @user_columns ~w(sender inviter_id invitee_id granted_by started_by actor_id owner author recipient)
  @user_column_patterns ["%\\_by", "actor%", "requester%", "approver%", "author%", "owner%", "recipient%"]

  # tables the heuristics above hit although they hold no data of a user, each with the reason
  @not_user_data %{"oban_jobs" => "attempted_by is the NODE name that ran the job (a list of node names), not a user"}
  @source Path.expand("../../../lib/nebu/compliance/user_deletion.ex", __DIR__)

  defp erased, do: apply(Nebu.Compliance.UserDeletion, :erased_tables, [])

  # ── the generic logic (also exercised against probe tables) ─────────────────

  # %{table => [reason it counts as per-user, ...]} over the public base tables
  defp discover do
    # pg_catalog, not information_schema: the latter lists only columns the CURRENT role has a privilege on (a table without a grant for the runtime role would vanish)
    columns =
      T.sql!(
        """
        SELECT cl.relname, a.attname
        FROM pg_attribute a
        JOIN pg_class cl ON cl.oid = a.attrelid AND cl.relkind IN ('r', 'p')
        JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = 'public'
        WHERE a.attnum > 0 AND NOT a.attisdropped
          AND (a.attname = 'user_id' OR a.attname LIKE '%\\_user\\_id' OR a.attname = ANY($1) OR a.attname LIKE ANY($2))
        """,
        [@user_columns, @user_column_patterns]
      ).rows

    fks =
      T.sql!(
        """
        SELECT cl.relname, a.attname
        FROM pg_constraint k
        JOIN pg_class cl ON cl.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = 'public'
        JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY(k.conkey)
        WHERE k.contype = 'f' AND k.confrelid = 'public.users'::regclass
        """
      ).rows

    (columns ++ fks)
    |> Enum.reduce(%{}, fn [table, column], acc -> Map.update(acc, table, [column], &Enum.uniq([column | &1])) end)
    |> Map.drop(Map.keys(@not_user_data))
  end

  defp existing_tables,
    do: T.sql!("SELECT cl.relname FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = 'public' WHERE cl.relkind IN ('r', 'p')").rows |> List.flatten()

  # the discovered tables nobody decided about
  defp unclassified(discovered, classified), do: discovered |> Map.keys() |> Enum.reject(&(&1 in classified)) |> Enum.sort()

  # the listed tables that do not exist (any more)
  defp missing(listed, existing), do: listed |> Enum.reject(&(&1 in existing)) |> Enum.sort()

  defp classified, do: erased() ++ E.teardown_tables() ++ Map.keys(E.retained_reasons())

  # every table of the lists and of the ignore list must exist
  defp all_listed, do: classified() ++ Map.keys(@not_user_data)

  # ═══ the guard on the real schema ═════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 8 - the real schema (HEAD)" do
    @describetag :integration

    test "every table with a per-user column is erased, ended by the teardown or retained on purpose (HEAD passes)" do
      discovered = discover()
      assert map_size(discovered) >= 30, "the discovery finds the per-user tables (found #{map_size(discovered)})"

      assert unclassified(discovered, classified()) == [],
             "per-user tables that are neither erased by UserDeletion, ended by the session teardown nor retained on purpose with a reason: " <>
               "#{inspect(unclassified(discovered, classified()))}. Decide for each: erase it (UserDeletion @erased_tables + the test support) or retain it " <>
               "(UserDeletionTestSupport.retained_reasons/0 with a reason and a sentence in docs/architecture/08-concepts.md)."
    end

    test "the inventory tables are found by the discovery (so the guard does not pass vacuously)" do
      discovered = Map.keys(discover())

      for t <- E.expected_erased() ++ E.teardown_tables() ++ ~w(users user_keys profiles room_members events audit_log) do
        assert t in discovered, "table #{t} of the inventory is not discovered as a per-user table"
      end
    end

    test "every listed table still exists (a dropped or renamed table must leave the lists)" do
      assert missing(all_listed(), existing_tables()) == []
    end

    test "no table is in two lists, every retained entry carries a reason" do
      lists = [erased(), E.teardown_tables(), Map.keys(E.retained_reasons()), Map.keys(@not_user_data)]
      all = List.flatten(lists)
      assert Enum.sort(all) == Enum.sort(Enum.uniq(all)), "a table is listed twice: #{inspect(all -- Enum.uniq(all))}"

      for {table, reason} <- Map.merge(E.retained_reasons(), @not_user_data) do
        assert is_binary(reason) and String.length(reason) >= 20, "table #{table} is retained / ignored without a real reason"
      end
    end
  end

  # ═══ UserDeletion.erased_tables/0 ═════════════════════════════════════════════════════════════════════════════════════════

  describe "UserDeletion.erased_tables/0" do
    test "is a list of table names without duplicates and equals the inventory of the suite (extend the support together with it)" do
      list = erased()
      assert is_list(list) and Enum.all?(list, &is_binary/1)
      assert Enum.sort(list) == Enum.sort(Enum.uniq(list)), "duplicates"

      assert Enum.sort(list) == Enum.sort(E.expected_erased()),
             "UserDeletion.erased_tables/0 and the inventory of the real-database erasure tests differ: add / remove the table in " <>
               "UserDeletionTestSupport.expected_erased/0 AND seed it in seed_user!/2 (only seeded tables are proven to be erased)"
    end

    @tag :integration
    test "every erased table exists and has the user_id column the erasure deletes by" do
      for t <- erased() do
        assert t in existing_tables(), "erased table #{t} does not exist"
        assert T.sql!("SELECT count(*) FROM pg_attribute a WHERE a.attrelid = ('public.' || $1)::regclass AND a.attname = 'user_id' AND NOT a.attisdropped", [t]).rows == [[1]]
      end
    end

    test "no DELETE FROM literal of user_deletion.ex names a table outside the list (the code and the list cannot drift)" do
      literals = Regex.scan(~r/DELETE\s+FROM\s+([a-z_]+)/i, File.read!(@source)) |> Enum.map(&List.last/1) |> Enum.uniq()
      assert literals -- erased() == [], "user_deletion.ex deletes from a table that is not in erased_tables/0: #{inspect(literals -- erased())}"
    end

    test "user_keys, users and events are not erased (the pseudonymous identity and the retained events stay)" do
      for t <- ~w(user_keys users events room_members profiles audit_log), do: refute(t in erased(), "#{t} must be retained (anonymised / crypto-shredded), not deleted")
    end
  end

  # ═══ the guard logic fails when it must ═══════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 8 - the guard fails naming the table (probe tables, rolled back by on_exit)" do
    @describetag :integration

    defp probe!(ddl_columns) do
      name = "atdd_ck_probe_" <> T.rand(4)
      T.privileged_sql!("CREATE TABLE #{name} (#{ddl_columns})")
      ExUnit.Callbacks.on_exit(fn -> T.privileged_sql!("DROP TABLE IF EXISTS #{name}") end)
      name
    end

    test "a new table with user_id, *_user_id, sender or a users foreign key is reported as unclassified" do
      p1 = probe!("user_id text")
      p2 = probe!("reporter_user_id text")
      p3 = probe!("sender text")
      p4 = probe!("holder text REFERENCES users(user_id)")
      harmless = probe!("note text")
      by = for col <- ~w(created_by granted_by requested_by author author_id owner_id recipient requester_name approver_sub actor_name), do: {col, probe!("#{col} text")}

      found = unclassified(discover(), classified())
      for p <- [p1, p2, p3, p4], do: assert(p in found, "the guard did not name the new per-user table #{p}")
      for {col, p} <- by, do: assert(p in found, "the guard did not name a new table whose only user column is #{col}")
      refute harmless in found, "a table without any per-user column is not the guard's business"
      assert found == Enum.sort([p1, p2, p3, p4 | Enum.map(by, &elem(&1, 1))]), "on HEAD only the probes are unclassified, got #{inspect(found)}"
    end

    test "an ignored false positive (@not_user_data) is not reported, and is declared with a reason" do
      assert "oban_jobs" in existing_tables()
      refute "oban_jobs" in Map.keys(discover()), "oban_jobs.attempted_by is a node name: declared harmless, not classified"
    end

    test "a listed table that no longer exists is reported" do
      assert missing(classified() ++ ["atdd_ck_dropped_table"], existing_tables()) == ["atdd_ck_dropped_table"]
    end
  end
end
