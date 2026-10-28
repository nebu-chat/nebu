defmodule Nebu.OAuth.OAuthPendingProtectionTest do
  @moduledoc """
  Tests for the code-review cycle 0 decision "pending-row protection" (story
  `oauth-metadata-dcr-admin-approval`, ADR-033 "Pending registrations"):

    * `Nebu.OAuth.Config.pending_limits/0` — TTL (`oauth_pending_ttl_days`, default 30) and cap
      (`oauth_pending_cap`, default 5000) from `server_config`, invalid values => defaults
    * the cap on `POST /oauth2/register`: NEW metadata above it => `503 temporarily_unavailable`
      (OAuth shape) + `Retry-After`; a dedup hit (pending OR decided) still returns its client_id;
      only `pending` rows count
    * `Nebu.OAuth.ClientStore.purge_expired_pending/1` and `Nebu.Workers.OAuthPendingPurgeWorker`
      — purge ONLY pending rows older than the TTL, concurrent-safe
    * the database guard: with row level security the runtime role can DELETE pending rows but
      NOT approved/rejected ones, and a decided row cannot be flipped back to pending to dodge it
    * the Oban cron entry + queue of the purge worker

  The DB-backed groups are tagged `:integration` (`mix test --include integration`). The shared
  test database may contain foreign pending rows, so the cap tests derive their cap from the
  current pending count instead of assuming an empty table.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  # ── unit: config seam + static wiring (no DB) ──────────────────────────────

  describe "Nebu.OAuth.Config.pending_limits/0 — defaults and seam (no DB)" do
    setup do
      on_exit(&T.clear_oauth_config/0)
    end

    test "the seam map without limit keys yields the defaults (30 days, cap 5000)" do
      T.enable_oauth()
      assert %{ttl_days: 30, cap: 5000} = Nebu.OAuth.Config.pending_limits()
    end

    test "the seam may set both limits; invalid / non-positive / absurd values fall back to the defaults" do
      put = fn ttl, cap ->
        Application.put_env(:nebu_http, :oauth_config_source, fn ->
          %{enabled: true, issuer_url: T.issuer(), pending_ttl_days: ttl, pending_cap: cap}
        end)
      end

      put.(7, 12)
      assert %{ttl_days: 7, cap: 12} = Nebu.OAuth.Config.pending_limits()
      put.("9", "13")
      assert %{ttl_days: 9, cap: 13} = Nebu.OAuth.Config.pending_limits()

      for bad <- [0, -1, "0", "-3", "abc", "", nil, 1.5, "12x", 99_999_999_999] do
        put.(bad, bad)
        assert %{ttl_days: 30, cap: 5000} = Nebu.OAuth.Config.pending_limits(), "value #{inspect(bad)}"
      end
    end
  end

  describe "purge worker wiring (static)" do
    test "the hourly Oban cron entry and a dedicated queue exist" do
      oban = Application.get_env(:nebu, Oban)
      {_plugin, cron_opts} = Enum.find(oban[:plugins], fn {mod, _} -> mod == Oban.Plugins.Cron end)

      assert Enum.any?(cron_opts[:crontab], fn {expr, worker} ->
               worker == Nebu.Workers.OAuthPendingPurgeWorker and expr =~ ~r/^\d+ \* \* \* \*$/
             end),
             "OAuthPendingPurgeWorker must run hourly via Oban.Plugins.Cron"

      assert Keyword.has_key?(oban[:queues], :oauth_cleanup)
      assert to_string(Nebu.Workers.OAuthPendingPurgeWorker.__opts__()[:queue]) == "oauth_cleanup"
    end

    # Story oauth-dcr-abuse-hardening (AH8, AC14.2): the bulk removal of pending registrations is the
    # SECOND (and last) DELETE of the store; both are restricted to pending rows.
    test "only pending rows can match the two DELETE statements (TTL purge, bulk removal); the store has no other DELETE" do
      src = File.read!(Path.expand("../../../lib/nebu/oauth/client_store.ex", __DIR__))
      deletes = Regex.scan(~r/DELETE\s+FROM\s+oauth_clients[^"]*/is, src)
      assert length(deletes) == 2, "purge + bulk removal, got #{length(deletes)}"
      for [d] <- deletes, do: assert(d =~ ~r/status\s*=\s*'pending'/, "every DELETE is restricted to pending rows")
    end
  end

  describe "admin list helpers (unit)" do
    alias Nebu.Admin.OAuthRegistrationsHTML, as: H

    test "logo_origin/1 yields a strict https CSP source or nil" do
      assert H.logo_origin("https://app.example.com/logo.png") == "https://app.example.com"
      assert H.logo_origin("https://APP.example.com:8443/x.png?v=1") == "https://app.example.com:8443"
      assert H.logo_origin("https://app.example.com:443/x.png") == "https://app.example.com"

      for bad <- [
            "http://app.example.com/logo.png",
            "https://user:pw@app.example.com/logo.png",
            "https://app.example.com;img-src */logo.png",
            "https://app.example.com'/logo.png",
            "https://exämple.com/logo.png",
            "https://[::1]/logo.png",
            # F-4: IP literals and single-label hosts are not logo origins
            "https://10.0.0.5/logo.png",
            "https://127.0.0.1:8443/logo.png",
            "https://0.1/logo.png",
            # N-2: hex-notation last label is an IPv4 literal for the WHATWG parser
            "https://127.0.0.0x1/logo.png",
            "https://0x7f.0x1/logo.png",
            "https://10.0.0.0x5:8443/logo.png",
            "https://localhost/logo.png",
            "https://intranet/logo.png",
            "https://app.example.com./logo.png",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            nil,
            ""
          ] do
        assert H.logo_origin(bad) == nil, "#{inspect(bad)} must not become a CSP source"
      end
    end

    test "confirm_text/3 leads with the client host and quotes the name (F-5)" do
      c = %{client_id: "id1", client_name: "Element (app.element.io)", client_uri: "https://evil.example.com"}

      assert H.confirm_text(c, "Approve", "Sure.") ==
               ~s|Approve client at evil.example.com (name "Element (app.element.io)")? Sure.|

      assert H.confirm_text(%{client_id: "id1", client_name: nil, client_uri: "https://evil.example.com"}, "Reject", "x") ==
               ~s|Reject client at evil.example.com (name "(unnamed client id1)")? x|

      assert H.confirm_text(%{client_id: "id1", client_name: "N", client_uri: nil}, "Approve", "x") ==
               ~s|Approve client "N"? x|
    end

    test "redirect_binding/1: https is host-bound, loopback and private-use schemes are not (F-5)" do
      assert H.redirect_binding("https://app.example.com/cb") == :host_bound
      assert H.redirect_binding("http://localhost/cb") == :not_host_bound
      assert H.redirect_binding("http://127.0.0.1/cb") == :not_host_bound
      assert H.redirect_binding("http://[::1]/cb") == :not_host_bound
      assert H.redirect_binding("com.example.app:/cb") == :not_host_bound

      assert H.any_unbound?(%{redirect_uris: ["https://a.example.com/cb", "com.example.app:/cb"]})
      refute H.any_unbound?(%{redirect_uris: ["https://a.example.com/cb"]})
    end

    test "safe_logo/2 only yields a URL when logos were requested and the origin is safe" do
      c = %{logo_uri: "https://app.example.com/logo.png"}
      assert H.safe_logo(c, false) == nil
      assert H.safe_logo(c, true) == "https://app.example.com/logo.png"
      assert H.safe_logo(%{logo_uri: "http://app.example.com/logo.png"}, true) == nil
      assert H.safe_logo(%{logo_uri: nil}, true) == nil
    end

    test "list_href/2 keeps page and logo mode" do
      assert H.list_href(1, false) == "/admin/oauth/registrations"
      assert H.list_href(3, false) == "/admin/oauth/registrations?page=3"
      assert H.list_href(1, true) == "/admin/oauth/registrations?logos=1"
      assert H.list_href(2, true) == "/admin/oauth/registrations?page=2&logos=1"
    end
  end

  # ── integration ────────────────────────────────────────────────────────────

  defp insert_row(ids, status, age_days, opts \\ []) do
    id = "atdd-pp-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    Agent.update(ids, &[id | &1])
    meta = %{"client_name" => Keyword.get(opts, :name, id), "client_uri" => "https://example.com"}

    T.insert_row!(id, meta, Keyword.get(opts, :hash, "hash-" <> id), status, "NOW() - (#{age_days}::int * INTERVAL '1 day')")

    id
  end

  defp exists?(id), do: T.client_row(id) != nil

  defp pending_count do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE status = 'pending'")
    n
  end

  describe "DB-backed pending limits" do
    @describetag :integration

    setup do
      T.clear_oauth_config()
      keys = ["oauth_pending_ttl_days", "oauth_pending_cap", "oauth_pending_host_cap"]

      prior =
        Map.new(keys, fn k ->
          case T.sql!("SELECT value FROM server_config WHERE key = $1", [k]).rows do
            [[v]] -> {k, v}
            [] -> {k, nil}
          end
        end)

      on_exit(fn ->
        # The runtime role cannot DELETE from server_config: "absent" is restored as the default.
        for {k, v} <- prior, do: set_config(k, v || default_for(k))
      end)

      :ok
    end

    defp default_for("oauth_pending_ttl_days"), do: "30"
    defp default_for("oauth_pending_cap"), do: "5000"
    defp default_for("oauth_pending_host_cap"), do: "20"

    defp set_config(key, value) do
      T.sql!(
        "INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, 0) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        [key, value]
      )
    end

    test "values come from server_config and a changed value is visible immediately (UPDATE allowed by the policy)" do
      set_config("oauth_pending_ttl_days", "7")
      set_config("oauth_pending_cap", "123")
      set_config("oauth_pending_host_cap", "9")
      assert %{ttl_days: 7, cap: 123, host_cap: 9} = Nebu.OAuth.Config.pending_limits()

      set_config("oauth_pending_ttl_days", " 14 ")
      set_config("oauth_pending_cap", "124")
      set_config("oauth_pending_host_cap", " 10 ")
      assert %{ttl_days: 14, cap: 124, host_cap: 10} = Nebu.OAuth.Config.pending_limits()
    end

    test "an invalid stored value falls back to the default (never 'unlimited')" do
      for bad <- ["abc", "0", "-5", "", "1e3", "99999999999"] do
        set_config("oauth_pending_ttl_days", bad)
        set_config("oauth_pending_cap", bad)
        set_config("oauth_pending_host_cap", bad)
        assert %{ttl_days: 30, cap: 5000, host_cap: 20} = Nebu.OAuth.Config.pending_limits(), "value #{inspect(bad)}"
      end
    end

    test "the purge uses the configured TTL" do
      {:ok, ids} = Agent.start(fn -> [] end)
      on_exit(fn -> T.cleanup_clients(Agent.get(ids, & &1)) end)

      young = insert_row(ids, "pending", 3)
      old = insert_row(ids, "pending", 10)

      set_config("oauth_pending_ttl_days", "7")
      assert {:ok, n} = Nebu.OAuth.ClientStore.purge_expired_pending()
      assert n >= 1
      refute exists?(old)
      assert exists?(young)
    end
  end

  describe "pending cap on POST /oauth2/register" do
    @describetag :integration

    setup do
      T.reset_rate_limits()
      {:ok, ids} = Agent.start(fn -> [] end)

      on_exit(fn ->
        T.cleanup_clients(Agent.get(ids, & &1))
        Agent.stop(ids)
        T.clear_oauth_config()
        T.restore_rate_limits()
      end)

      {:ok, ids: ids}
    end

    defp enable_with_cap(cap) do
      Application.put_env(:nebu_http, :oauth_config_source, fn ->
        %{enabled: true, issuer_url: T.issuer(), pending_cap: cap}
      end)
    end

    defp register_new(ids) do
      conn = T.register(T.web_body())
      if conn.status == 201, do: Agent.update(ids, &[T.json(conn)["client_id"] | &1])
      conn
    end

    test "NEW metadata above the cap => 503 temporarily_unavailable (OAuth shape) + Retry-After + CORS", %{ids: ids} do
      enable_with_cap(pending_count() + 2)

      assert register_new(ids).status == 201
      assert register_new(ids).status == 201

      before = pending_count()
      conn = register_new(ids)
      T.assert_oauth_error(conn, 503, "temporarily_unavailable")
      assert {n, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert n >= 1
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert pending_count() == before, "a refused registration must not create a row"
    end

    test "a dedup hit still returns the existing client_id while the cap is reached", %{ids: ids} do
      enable_with_cap(pending_count() + 1)
      body = T.web_body()

      first = T.register(body)
      assert first.status == 201
      client_id = T.json(first)["client_id"]
      Agent.update(ids, &[client_id | &1])

      # cap reached: new metadata is refused ...
      assert register_new(ids).status == 503
      # ... but identical metadata (pending dedup hit) is answered
      again = T.register(body)
      assert again.status == 201
      assert T.json(again)["client_id"] == client_id
    end

    test "dedup hits of APPROVED and REJECTED registrations bypass the cap too", %{ids: ids} do
      enable_with_cap(10_000)
      approved_body = T.web_body()
      rejected_body = T.web_body()
      approved_id = register_ok(approved_body, ids)
      rejected_id = register_ok(rejected_body, ids)
      assert :ok = Nebu.OAuth.approve_registration(approved_id, "@admin:test.local")
      assert :ok = Nebu.OAuth.reject_registration(rejected_id, "@admin:test.local")

      # reach the cap exactly: new metadata is refused, decided dedup hits are answered
      insert_row(ids, "pending", 0)
      enable_with_cap(pending_count())
      assert register_new(ids).status == 503
      assert T.json(T.register(approved_body))["client_id"] == approved_id
      assert T.json(T.register(rejected_body))["client_id"] == rejected_id
    end

    test "only PENDING rows count: deciding one frees a slot", %{ids: ids} do
      enable_with_cap(pending_count() + 1)
      first = register_ok(T.web_body(), ids)
      assert register_new(ids).status == 503

      assert :ok = Nebu.OAuth.approve_registration(first, "@admin:test.local")
      assert register_new(ids).status == 201
    end

    defp register_ok(body, ids) do
      conn = T.register(body)
      assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
      id = T.json(conn)["client_id"]
      Agent.update(ids, &[id | &1])
      id
    end
  end

  describe "purge of expired pending registrations" do
    @describetag :integration

    setup do
      {:ok, ids} = Agent.start(fn -> [] end)
      on_exit(fn -> T.cleanup_clients(Agent.get(ids, & &1)) end)
      {:ok, ids: ids}
    end

    test "deletes pending rows older than the TTL and ONLY those", %{ids: ids} do
      old_pending = insert_row(ids, "pending", 31)
      young_pending = insert_row(ids, "pending", 29)
      old_approved = insert_row(ids, "approved", 400)
      old_rejected = insert_row(ids, "rejected", 400)

      assert {:ok, deleted} = Nebu.OAuth.ClientStore.purge_expired_pending(ttl_days: 30)
      assert deleted >= 1

      refute exists?(old_pending)
      assert exists?(young_pending)
      assert exists?(old_approved), "approved registrations are never purged"
      assert exists?(old_rejected), "rejected registrations are never purged"
    end

    test "the Oban worker runs the purge (:ok) and honours the same rules", %{ids: ids} do
      old_pending = insert_row(ids, "pending", 3650 + 5)
      old_approved = insert_row(ids, "approved", 3650 + 5)

      assert :ok = Nebu.Workers.OAuthPendingPurgeWorker.perform(%Oban.Job{})
      refute exists?(old_pending)
      assert exists?(old_approved)
    end

    test "batched: more rows than one batch are all purged in one call" do
      n = 1100

      T.sql!(
        "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status, created_at) " <>
          "SELECT 'atdd-bulk-' || $1::text || '-' || g, '{}'::jsonb, 'atdd-bulk-' || $1::text || '-' || g, 'pending', NOW() - INTERVAL '60 days' " <>
          "FROM generate_series(1, $2::int) g",
        [to_string(System.unique_integer([:positive])), n]
      )

      assert {:ok, deleted} = Nebu.OAuth.ClientStore.purge_expired_pending(ttl_days: 30)
      assert deleted >= n
      %{rows: [[left]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE client_id LIKE 'atdd-bulk-%'")
      assert left == 0
    end

    test "concurrent purges (several nodes) never fail and together remove every expired row", %{ids: ids} do
      expired = for _ <- 1..40, do: insert_row(ids, "pending", 90)
      survivor = insert_row(ids, "pending", 1)
      decided = insert_row(ids, "approved", 90)

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> Nebu.OAuth.ClientStore.purge_expired_pending(ttl_days: 30) end) end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, _}, &1)), "got #{inspect(results)}"
      for id <- expired, do: refute(exists?(id))
      assert exists?(survivor)
      assert exists?(decided)
    end

    test "a purge on an unavailable database is an error tuple, not a crash" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_repo) end)
      assert {:error, _} = Nebu.OAuth.ClientStore.purge_expired_pending(ttl_days: 30)
      assert {:error, _} = Nebu.Workers.OAuthPendingPurgeWorker.perform(%Oban.Job{})
    end
  end

  describe "database guard: the runtime role can only delete PENDING rows (RLS, migration 000040)" do
    @describetag :integration

    setup do
      {:ok, ids} = Agent.start(fn -> [] end)
      on_exit(fn -> T.cleanup_clients(Agent.get(ids, & &1)) end)
      {:ok, ids: ids}
    end

    test "DELETE removes an expired/young pending row but never an approved or rejected one", %{ids: ids} do
      approved = insert_row(ids, "approved", 400)
      rejected = insert_row(ids, "rejected", 400)
      expired_pending = insert_row(ids, "pending", 400)
      young_pending = insert_row(ids, "pending", 0)

      for id <- [approved, rejected] do
        assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [id])
        assert exists?(id), "the runtime role must not delete a decided registration"
      end

      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [expired_pending])
      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [young_pending])
      refute exists?(expired_pending)
      refute exists?(young_pending)
    end

    test "even an unfiltered-looking DELETE on decided ids is a no-op (RLS hides the rows)", %{ids: ids} do
      decided = for s <- ~w(approved rejected approved rejected), do: insert_row(ids, s, 1)
      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_clients WHERE client_id = ANY($1)", [decided])
      for id <- decided, do: assert(exists?(id))
    end

    test "a decided registration cannot be flipped back to pending (which would make it deletable)", %{ids: ids} do
      approved = insert_row(ids, "approved", 1)
      rejected = insert_row(ids, "rejected", 1)

      for id <- [approved, rejected] do
        assert_raise Postgrex.Error, ~r/cannot become pending again/, fn ->
          T.sql!("UPDATE oauth_clients SET status = 'pending' WHERE client_id = $1", [id])
        end

        assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [id])
        assert exists?(id)
      end
    end

    test "the normal decisions are still possible: pending -> approved / rejected", %{ids: ids} do
      a = insert_row(ids, "pending", 0)
      r = insert_row(ids, "pending", 0)
      assert :ok = Nebu.OAuth.approve_registration(a, "@admin:test.local")
      assert :ok = Nebu.OAuth.reject_registration(r, "@admin:test.local")
      # an update that does not touch status on a decided row is fine
      assert %{num_rows: 1} = T.sql!("UPDATE oauth_clients SET last_used_at = NOW() WHERE client_id = $1", [a])
    end

    test "a purge racing an approval never deletes the approved row", %{ids: ids} do
      rows = for _ <- 1..30, do: insert_row(ids, "pending", 90)

      approver =
        Task.async(fn ->
          for id <- rows, do: Nebu.OAuth.approve_registration(id, "@admin:test.local")
        end)

      purger = Task.async(fn -> Nebu.OAuth.ClientStore.purge_expired_pending(ttl_days: 30) end)
      approved_results = Task.await(approver, 30_000)
      assert {:ok, _} = Task.await(purger, 30_000)

      # Every row is either gone (purged first) or approved (decision first) - never "approved
      # but deleted" (an :ok approval whose row vanished) and never still pending past the TTL
      # after both finished.
      for {id, result} <- Enum.zip(rows, approved_results) do
        case result do
          :ok -> assert T.client_row(id)["status"] == "approved"
          {:error, :not_pending} -> :ok
        end
      end
    end
  end
end
