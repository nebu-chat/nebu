defmodule Nebu.OAuth.OAuthBulkRemoveTest do
  @moduledoc """
  RED-phase acceptance tests (integration, runtime role) for story `oauth-dcr-abuse-hardening`,
  AC8 (AH8, AH9): the bulk store functions behind the admin "Remove pending registrations" action,
  plus the store-level part of AC12 (logging).

  ## ATDD decisions (the story leaves the exact shapes open; the dev run must honour them)

    * `Nebu.OAuth.bulk_remove_pending(criteria, as_of, opts)` and
      `Nebu.OAuth.bulk_remove_preview(criteria, as_of)`. `criteria` is a map
      `%{host: String.t() | nil, match: :exact | :domain, older_than_days: integer | binary | nil}`;
      all three keys are always present in the tests. Invalid criteria (none, bad host, days out of
      1..3650 or not an integer, `:domain` on a public suffix) => `{:error, {:invalid_criteria, reason}}`
      BEFORE any query (the tests install a broken repo to prove it).
    * `as_of` is a `DateTime` (UTC); only rows with `created_at <= as_of` are touched.
    * Result: `{:ok, %{removed: n, remaining: m, client_ids: [..]}}`; `removed <= 500`, oldest first.
    * Preview: `{:ok, %{count: n, rows: [%{client_id: ..., ...}]}}`, at most 20 rows, newest first.
    * `opts[:audit]` is a 1-arity function receiving the list of removed client ids, called inside
      the deletion transaction; `{:error, reason}` (or an aborted transaction) rolls the deletion
      back and yields `{:error, {:audit, reason}}`. It is NOT called when nothing matched.

  Every test seeds its own registrable domain (`t<rand>.com`) so persistent databases with foreign
  pending rows are never touched; no test uses an age-only criterion.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    tag = T.rand(5)
    dom = "t#{tag}.com"
    {:ok, ids} = Agent.start(fn -> [] end)

    on_exit(fn ->
      T.cleanup_clients(Agent.get(ids, & &1))
      T.privileged_sql!("DELETE FROM oauth_clients WHERE client_id LIKE $1", ["atdd-bulk-#{tag}-%"])
      Agent.stop(ids)
      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    {:ok, tag: tag, dom: dom, ids: ids}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp bulk(criteria, as_of, opts \\ []), do: apply(Nebu.OAuth, :bulk_remove_pending, [criteria, as_of, opts])
  defp preview(criteria, as_of), do: apply(Nebu.OAuth, :bulk_remove_preview, [criteria, as_of])

  defp crit(host, match \\ :domain, days \\ nil), do: %{host: host, match: match, older_than_days: days}

  defp db_now do
    %{rows: [[now]]} = T.sql!("SELECT now()")
    now
  end

  # `as_of` = the DB clock NOW, i.e. at or after every row the test seeded before (rows are seeded at
  # `now() - g seconds`). Never in the future: the controller refuses a future snapshot.
  defp as_of, do: db_now()

  # n pending rows `atdd-bulk-<tag>-<name>-<g>` for `host` (client_domain `cd` or NULL); `g = 1` is the
  # NEWEST row (created `age_s + g` seconds ago), so the oldest-first order is g descending.
  defp seed!(tag, name, host, cd, n, age_s \\ 0) do
    T.sql!(
      "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, client_host, client_domain, created_at) " <>
        "SELECT 'atdd-bulk-' || $1::text || '-' || $2::text || '-' || g, '{}'::jsonb, 'atdd-bulk-h-' || $1::text || '-' || $2::text || '-' || g, " <>
        "'web', $3, $4, now() - (($5::int + g) * interval '1 second') FROM generate_series(1, $6::int) g",
      [tag, name, host, cd, age_s, n]
    )

    for g <- 1..n, do: "atdd-bulk-#{tag}-#{name}-#{g}"
  end

  defp decided!(ids, tag, name, host, cd, status) do
    id = "atdd-bulk-#{tag}-#{name}"
    Agent.update(ids, &[id | &1])

    :ok =
      T.insert_row!(id, Jason.encode!(%{"client_name" => name}), "atdd-bulk-h-#{tag}-#{name}", status, "NOW()", "web",
        client_host: host,
        client_domain: cd
      )

    id
  end

  defp exists?(id), do: T.client_row(id) != nil
  defp count_like(tag), do: T.sql!("SELECT count(*) FROM oauth_clients WHERE client_id LIKE $1", ["atdd-bulk-#{tag}-%"]).rows |> hd() |> hd()

  # ── AC8.1 ──────────────────────────────────────────────────────────────────

  describe "AC8.1 — only PENDING rows matching ALL criteria are deleted" do
    test "approved and rejected rows of the same host survive; pending ones are gone", %{tag: tag, dom: dom, ids: ids} do
      host = "app." <> dom
      pending = seed!(tag, "p", host, dom, 3)
      approved = decided!(ids, tag, "a", host, dom, "approved")
      rejected = decided!(ids, tag, "r", host, dom, "rejected")

      assert {:ok, %{removed: 3, remaining: 0, client_ids: removed}} = bulk(crit(dom), as_of())
      assert Enum.sort(removed) == Enum.sort(pending)
      for id <- pending, do: refute(exists?(id))
      assert exists?(approved) and exists?(rejected), "decided registrations are NEVER deleted (Matrix spec)"
      assert T.client_row(approved)["status"] == "approved"
    end

    test "defence in depth: even a raw DELETE without status filter as the runtime role leaves decided rows (RLS)", %{tag: tag, dom: dom, ids: ids} do
      host = "app." <> dom
      pending = seed!(tag, "p", host, dom, 2)
      approved = decided!(ids, tag, "a", host, dom, "approved")
      rejected = decided!(ids, tag, "r", host, dom, "rejected")

      assert %{num_rows: 2} = T.sql!("DELETE FROM oauth_clients WHERE client_host = $1", [host])
      for id <- pending, do: refute(exists?(id))
      assert exists?(approved) and exists?(rejected)
    end

    test "criteria are AND-combined: host + older_than_days removes only the old rows of that host", %{tag: tag, dom: dom} do
      host = "app." <> dom
      old = seed!(tag, "old", host, dom, 3, 40 * 86_400)
      fresh = seed!(tag, "new", host, dom, 2)
      other = seed!(tag, "oth", "app.o" <> dom, "o" <> dom, 2, 40 * 86_400)

      assert {:ok, %{removed: 3}} = bulk(crit(dom, :domain, 30), as_of())
      for id <- old, do: refute(exists?(id))
      for id <- fresh ++ other, do: assert(exists?(id), "#{id} must survive")
    end

    test "older_than_days is exclusive of rows younger than the limit", %{tag: tag, dom: dom} do
      young = seed!(tag, "y", "app." <> dom, dom, 2, 29 * 86_400)
      assert {:ok, %{removed: 0, remaining: 0, client_ids: []}} = bulk(crit(dom, :domain, 30), as_of())
      for id <- young, do: assert(exists?(id))
    end
  end

  # ── AC8.2 ──────────────────────────────────────────────────────────────────

  describe "AC8.2 — exact vs domain" do
    setup %{tag: tag, dom: dom} do
      rows = %{
        sub: seed!(tag, "sub", "app." <> dom, dom, 1),
        apex: seed!(tag, "apex", dom, dom, 1),
        legacy: seed!(tag, "leg", "old." <> dom, nil, 1),
        deep: seed!(tag, "deep", "a.b.c." <> dom, dom, 1),
        boundary: seed!(tag, "bnd", "not" <> dom, "not" <> dom, 1),
        other: seed!(tag, "oth", "app.other-" <> dom, "other-" <> dom, 1)
      }

      {:ok, rows: rows}
    end

    test "exact: only the identical host is removed", %{dom: dom, rows: rows} do
      assert {:ok, %{removed: 1}} = bulk(crit("app." <> dom, :exact), as_of())
      refute exists?(hd(rows.sub))
      for k <- [:apex, :legacy, :deep, :boundary, :other], do: assert(exists?(hd(rows[k])), "#{k} must survive an exact match")
    end

    test "domain: the registrable domain, its subdomains and rows WITHOUT client_domain (pre-000044)", %{dom: dom, rows: rows} do
      assert {:ok, %{removed: 4}} = bulk(crit(dom, :domain), as_of())
      for k <- [:sub, :apex, :legacy, :deep], do: refute(exists?(hd(rows[k])), "#{k} must be removed")
    end

    test "example.com never matches notexample.com (label boundary) nor other-example.com", %{dom: dom, rows: rows} do
      bulk(crit(dom, :domain), as_of())
      assert exists?(hd(rows.boundary))
      assert exists?(hd(rows.other))
    end

    test "a host input is trimmed and lowercased; a subdomain input means the registrable domain of it", %{tag: tag, dom: dom, rows: rows} do
      assert {:ok, %{removed: 1}} = bulk(crit("  APP." <> String.upcase(dom) <> " ", :exact), as_of())
      refute exists?(hd(rows.sub))

      # `domain` of a subdomain input = the registrable domain: everything of `dom` goes
      assert {:ok, %{removed: 3}} = bulk(crit("whatever." <> dom, :domain), as_of())
      for k <- [:apex, :legacy, :deep], do: refute(exists?(hd(rows[k])))
      assert exists?(hd(rows.boundary))
      assert count_like(tag) == 2
    end

    test "LIKE metacharacters in the input are data, never a pattern", %{dom: dom, rows: rows} do
      assert {:error, {:invalid_criteria, _}} = bulk(crit("%" <> dom, :exact), as_of())
      assert {:error, {:invalid_criteria, _}} = bulk(crit("app._" <> dom, :domain), as_of())
      for k <- Map.keys(rows), do: assert(exists?(hd(rows[k])))
    end
  end

  # ── AC8.3 ──────────────────────────────────────────────────────────────────

  describe "AC8.3 — at most 500 per call, oldest first" do
    test "501 matches => 500 removed (the 500 oldest), 1 remaining; the second call removes the rest", %{tag: tag, dom: dom} do
      ids = seed!(tag, "bulk", "app." <> dom, dom, 501)
      newest = hd(ids)
      assert newest == "atdd-bulk-#{tag}-bulk-1"

      assert {:ok, %{removed: 500, remaining: 1, client_ids: removed}} = bulk(crit(dom), as_of())
      assert length(removed) == 500
      refute newest in removed, "oldest first: the newest row is the one left"
      assert exists?(newest)
      assert count_like(tag) == 1

      assert {:ok, %{removed: 1, remaining: 0, client_ids: [^newest]}} = bulk(crit(dom), as_of())
      assert count_like(tag) == 0
    end
  end

  # ── AC8.4 ──────────────────────────────────────────────────────────────────

  describe "AC8.4 — the snapshot (as_of)" do
    test "a row created after as_of is never removed", %{tag: tag, dom: dom} do
      before_ids = seed!(tag, "before", "app." <> dom, dom, 2, 120)
      snapshot = DateTime.add(db_now(), -60, :second)
      after_ids = seed!(tag, "after", "app." <> dom, dom, 2, 0)

      assert {:ok, %{removed: 2, remaining: 0, client_ids: removed}} = bulk(crit(dom), snapshot)
      assert Enum.sort(removed) == Enum.sort(before_ids)
      for id <- after_ids, do: assert(exists?(id), "a registration made after the preview must survive")
    end

    test "remaining counts only rows inside the snapshot", %{tag: tag, dom: dom} do
      seed!(tag, "before", "app." <> dom, dom, 3, 120)
      snapshot = DateTime.add(db_now(), -60, :second)
      seed!(tag, "after", "app." <> dom, dom, 5, 0)
      assert {:ok, %{removed: 3, remaining: 0}} = bulk(crit(dom), snapshot)
    end
  end

  # ── AC8.5 ──────────────────────────────────────────────────────────────────

  describe "AC8.5 — concurrent calls" do
    test "three parallel removals over more than one batch remove each row exactly once in total and never error", %{tag: tag, dom: dom} do
      # 1200 rows > 2 x the batch of 500: the batches of concurrent callers must be disjoint
      # (FOR UPDATE SKIP LOCKED), otherwise a row would be counted twice or an error raised.
      all = seed!(tag, "c", "app." <> dom, dom, 1200)
      snapshot = as_of()

      results =
        for _ <- 1..3 do
          Task.async(fn -> bulk(crit(dom), snapshot) end)
        end
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, %{}}, &1)), "no call may fail: #{inspect(results)}"
      removed = results |> Enum.flat_map(fn {:ok, r} -> r.client_ids end)
      assert length(removed) == length(Enum.uniq(removed)), "a row is removed by exactly one call"
      assert Enum.sort(removed) == Enum.sort(all)
      assert results |> Enum.map(fn {:ok, r} -> r.removed end) |> Enum.sum() == 1200
      assert Enum.all?(results, fn {:ok, r} -> r.removed <= 500 end), "never more than 500 per call"
      assert count_like(tag) == 0
    end
  end

  # ── AC8.6 ──────────────────────────────────────────────────────────────────

  describe "AC8.6 — audit in the same transaction" do
    test "the audit function runs inside the transaction with exactly the removed ids", %{tag: tag, dom: dom} do
      seeded = seed!(tag, "au", "app." <> dom, dom, 4)
      parent = self()

      audit = fn ids ->
        send(parent, {:audited, ids, Nebu.Repo.in_transaction?()})
        :ok
      end

      assert {:ok, %{removed: 4}} = bulk(crit(dom), as_of(), audit: audit)
      assert_received {:audited, ids, true}
      assert Enum.sort(ids) == Enum.sort(seeded)
    end

    test "an audit error rolls the deletion back: {:error, {:audit, reason}}, every row present", %{tag: tag, dom: dom} do
      seeded = seed!(tag, "au", "app." <> dom, dom, 4)
      assert {:error, {:audit, :boom}} = bulk(crit(dom), as_of(), audit: fn _ -> {:error, :boom} end)
      for id <- seeded, do: assert(exists?(id), "the deletion must be rolled back")
      assert {:ok, %{removed: 4}} = bulk(crit(dom), as_of(), audit: fn _ -> :ok end), "and the removal works once the audit works"
    end

    test "an audit step that ABORTS the database transaction also rolls back; the connection stays usable", %{tag: tag, dom: dom} do
      seeded = seed!(tag, "ab", "app." <> dom, dom, 2)

      failing = fn _ids ->
        case Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT 1/0", []) do
          {:error, e} -> {:error, e}
          _ -> :ok
        end
      end

      assert {:error, {:audit, _}} = bulk(crit(dom), as_of(), audit: failing)
      for id <- seeded, do: assert(exists?(id))
      assert {:ok, %{removed: 2}} = bulk(crit(dom), as_of())
    end

    test "an audit function that raises rolls the deletion back and never leaks the raise as a partial delete", %{tag: tag, dom: dom} do
      seeded = seed!(tag, "rs", "app." <> dom, dom, 2)
      result = try do bulk(crit(dom), as_of(), audit: fn _ -> raise "audit repo down" end) rescue e -> {:raised, e} end
      assert match?({:error, {:audit, _}}, result) or match?({:raised, _}, result)
      for id <- seeded, do: assert(exists?(id))
    end

    test "zero matches: nothing deleted and the audit function is NOT called", %{dom: dom} do
      parent = self()
      assert {:ok, %{removed: 0, remaining: 0, client_ids: []}} = bulk(crit(dom), as_of(), audit: fn ids ->
        send(parent, {:audited, ids})
        :ok
      end)
      refute_received {:audited, _}
    end
  end

  # ── AC8.7 ──────────────────────────────────────────────────────────────────

  describe "AC8.7 — invalid criteria never reach the database" do
    setup do
      # every query fails with an error tuple: a result other than invalid_criteria proves a query was made
      Application.put_env(:nebu_http, :oauth_repo, Nebu.OAuth.TestSupport.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_repo) end)
      :ok
    end

    invalid = [
      {"no criterion at all", %{host: nil, match: :domain, older_than_days: nil}},
      {"an empty host", %{host: "", match: :exact, older_than_days: nil}},
      {"a blank host", %{host: "   ", match: :exact, older_than_days: nil}},
      {"a host with a space", %{host: "a b.example.com", match: :exact, older_than_days: nil}},
      {"a host with LIKE metacharacters", %{host: "%.example.com", match: :exact, older_than_days: nil}},
      {"a host with a path", %{host: "example.com/x", match: :exact, older_than_days: nil}},
      {"a host with an underscore", %{host: "a_b.example.com", match: :exact, older_than_days: nil}},
      {"a host over 253 bytes", %{host: String.duplicate("a", 250) <> ".com", match: :exact, older_than_days: nil}},
      {"older_than_days 0", %{host: "example.com", match: :exact, older_than_days: 0}},
      {"older_than_days 3651", %{host: "example.com", match: :exact, older_than_days: 3651}},
      {"older_than_days negative", %{host: "example.com", match: :exact, older_than_days: -5}},
      {"older_than_days \"x\"", %{host: "example.com", match: :exact, older_than_days: "x"}},
      {"older_than_days \"1.5\"", %{host: "example.com", match: :exact, older_than_days: "1.5"}},
      {"match :domain on the public suffix github.io", %{host: "github.io", match: :domain, older_than_days: nil}},
      {"match :domain on the public suffix co.uk", %{host: "co.uk", match: :domain, older_than_days: 30}},
      {"an unknown match mode", %{host: "example.com", match: :substring, older_than_days: nil}}
    ]

    for {label, criteria} <- invalid do
      test "#{label} => {:error, {:invalid_criteria, _}} (bulk and preview)" do
        c = unquote(Macro.escape(criteria))
        assert {:error, {:invalid_criteria, _reason}} = bulk(c, DateTime.utc_now())
        assert {:error, {:invalid_criteria, _reason}} = preview(c, DateTime.utc_now())
      end
    end
  end

  # ── preview ────────────────────────────────────────────────────────────────

  describe "preview (read only)" do
    test "count + the first 20 rows, newest first; nothing is changed", %{tag: tag, dom: dom} do
      seeded = seed!(tag, "pv", "app." <> dom, dom, 25)
      assert {:ok, %{count: 25, rows: rows}} = preview(crit(dom), as_of())
      assert length(rows) == 20
      assert hd(rows).client_id == hd(seeded), "newest first"
      assert rows |> Enum.map(& &1.client_id) |> Enum.uniq() |> length() == 20
      assert count_like(tag) == 25
    end

    test "only pending rows and only rows inside the snapshot are counted", %{tag: tag, dom: dom, ids: ids} do
      seed!(tag, "pv", "app." <> dom, dom, 3, 120)
      decided!(ids, tag, "a", "app." <> dom, dom, "approved")
      snapshot = DateTime.add(db_now(), -60, :second)
      seed!(tag, "late", "app." <> dom, dom, 4, 0)
      assert {:ok, %{count: 3}} = preview(crit(dom), snapshot)
    end

    test "zero matches", %{dom: dom} do
      assert {:ok, %{count: 0, rows: []}} = preview(crit(dom), as_of())
    end
  end

  # ── AC12 (store level) ─────────────────────────────────────────────────────

  describe "AC12 — the store logs nothing about hosts, domains or ids" do
    test "no host, domain or client id in the log of a successful removal and of a refused one", %{tag: tag, dom: dom} do
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)
      seeded = seed!(tag, "lg", "app." <> dom, dom, 3)

      log =
        capture_log([level: :info], fn ->
          bulk(crit(dom), as_of(), audit: fn _ -> :ok end)
          bulk(crit(dom), as_of(), audit: fn _ -> {:error, :nope} end)
          bulk(crit("%" <> dom, :exact), as_of())
        end)

      refute log =~ dom
      refute log =~ tag
      for id <- seeded, do: refute(log =~ id)
    end
  end
end
