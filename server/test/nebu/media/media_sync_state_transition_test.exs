defmodule Nebu.Web.MediaSyncStateTransitionTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/2c-sync-upload-
  shared-pipeline` — AC4 (and AC1's state-machine-genesis shape).

  Per the story's "CRITICAL DESIGN FINDING": the sync upload path must land
  its brand-new `media_files` row DIRECTLY in `:quarantined` via a NEW,
  single-step `Nebu.Media.StateMachine.create_quarantined/1` genesis function
  (mirroring `create/1`'s INSERT-plus-single-genesis-audit-row shape, but
  with `state = 'quarantined'` and a genesis transition row `NULL ->
  'quarantined'`) — NOT `create/1` (-> :reserved) followed by `transition/4`
  (:reserved -> :quarantined), which would incorrectly leave TWO
  `media_state_transitions` rows for a sync upload, contradicting this
  story's own "post-upload state is equivalent" acceptance test (the sync
  row must have exactly ONE transition row; the async row has TWO).

  This file has two independent test groups:

    1. Fast, fakes-only HTTP-level tests (default `mix test`, no live
       Postgres) — assert the SHAPE of state-machine seam calls: exactly one
       `create_quarantined/1` call for sync, `create/1` THEN `transition/4`
       (two calls) for async — a faithful proxy for "one transition row" vs
       "two transition rows" given `Nebu.Media.StateMachine.create/1` and
       `.transition/4` each unconditionally write exactly one
       `media_state_transitions` row apiece (already covered by
       `state_machine_test.exs`).
    2. `@tag :integration` tests (only run via `make test-integration` /
       `mix test --include integration`, live PostgreSQL required) — a direct
       unit-level test of the not-yet-existing
       `Nebu.Media.StateMachine.create_quarantined/1` itself, querying the
       REAL `media_state_transitions` table and asserting EXACTLY ONE row
       with `from_state IS NULL, to_state = 'quarantined'` — the literal
       assertion this story's own acceptance test demands, not just "final
       state is :quarantined" (which would also incorrectly pass a
       create/1+transition/4 implementation).

  ## Why these tests currently FAIL (valid RED)

  `Nebu.Media.StateMachine.create_quarantined/1` does not exist yet — group 2
  fails with `** (UndefinedFunctionError)`. Group 1 fails today because
  `store_upload/4` still uses its own `insert_media_row/7` path: it never
  calls `create_quarantined/1`, `create/1`, or `transition/4` at all, so
  `assert_received {:create_quarantined_called, _}` times out/fails.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @sync_path "/_matrix/media/v3/upload"
  @create_path "/_matrix/media/v1/create"
  @async_base_path "/_matrix/media/v3/upload"

  # ══════════════════════════════════════════════════════════════════════
  # Group 1 — fast, fakes-only HTTP-level seam-call-shape tests
  # ══════════════════════════════════════════════════════════════════════

  describe "seam-call shape (fakes only, no live DB required)" do
    setup do
      priv = S.setup_oidc_keys()
      {uid, token} = S.bearer_for("uploader", priv)

      test_pid = self()

      Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
      Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
      Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
      Application.put_env(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)
      Application.put_env(:nebu_http, :media_permission_module, MediaFakes.Permission)

      Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
        send(test_pid, {:stored, key, bytes})
        :ok
      end)

      Application.put_env(:nebu_http, :media_persist_upload_fun, fn fields ->
        send(test_pid, {:persisted, fields})
        :ok
      end)

      Application.put_env(:nebu_http, :media_state_machine_create_quarantined_fun, fn attrs ->
        send(test_pid, {:create_quarantined_called, attrs})
        {:ok, Map.fetch!(attrs, :media_id)}
      end)

      Application.put_env(:nebu_http, :media_state_machine_create_fun, fn attrs ->
        send(test_pid, {:state_machine_create_called, attrs})
        {:ok, Map.fetch!(attrs, :media_id)}
      end)

      Application.put_env(:nebu_http, :media_state_machine_transition_fun, fn media_id,
                                                                              to_state,
                                                                              actor,
                                                                              metadata ->
        send(test_pid, {:transition_called, media_id, to_state, actor, metadata})
        {:ok, to_state}
      end)

      Application.put_env(:nebu_http, :media_scan_enqueue_fun, fn media_id ->
        send(test_pid, {:scan_enqueued, media_id})
        :ok
      end)

      Application.put_env(:nebu_http, :media_permission_fun, fn _user -> true end)
      Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 0 end)

      prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      on_exit(fn ->
        Application.delete_env(:nebu_http, :media_db_module)
        Application.delete_env(:nebu_http, :media_storage_module)
        Application.delete_env(:nebu_http, :media_state_machine_module)
        Application.delete_env(:nebu_http, :media_scan_enqueue_module)
        Application.delete_env(:nebu_http, :media_permission_module)
        Application.delete_env(:nebu_http, :media_storage_put_fun)
        Application.delete_env(:nebu_http, :media_persist_upload_fun)
        Application.delete_env(:nebu_http, :media_state_machine_create_quarantined_fun)
        Application.delete_env(:nebu_http, :media_state_machine_create_fun)
        Application.delete_env(:nebu_http, :media_state_machine_transition_fun)
        Application.delete_env(:nebu_http, :media_scan_enqueue_fun)
        Application.delete_env(:nebu_http, :media_permission_fun)
        Application.delete_env(:nebu_http, :media_pending_count_fun)
        Application.delete_env(:nebu_http, :media_max_upload_bytes)
        Application.delete_env(:nebu_http, :media_lookup_reservation_fun)

        case prev_rl do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end
      end)

      {:ok, token: token, user_id: uid}
    end

    defp put_sync(body, headers) do
      conn =
        conn(:post, @sync_path, body)
        |> Map.put(:req_headers, [])

      conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
      Nebu.Web.Router.call(conn, S.router_opts())
    end

    defp post_create(headers) do
      conn =
        conn(:post, @create_path)
        |> Map.put(:req_headers, [])

      conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
      Nebu.Web.Router.call(conn, S.router_opts())
    end

    defp put_async(media_id, body, headers) do
      conn =
        conn(:put, "#{@async_base_path}/#{S.server_name()}/#{media_id}", body)
        |> Map.put(:req_headers, [])

      conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
      Nebu.Web.Router.call(conn, S.router_opts())
    end

    defp seed_reservation(uploader_user_id) do
      Application.put_env(:nebu_http, :media_lookup_reservation_fun, fn _server_name, _media_id ->
        {:ok,
         %{
           uploader_user_id: uploader_user_id,
           state: :reserved,
           uploaded_at: System.system_time(:millisecond)
         }}
      end)
    end

    defp media_id_from_uri(uri, server_name) do
      String.replace_prefix(uri, "mxc://#{server_name}/", "")
    end

    test "sync upload creates its media_files row directly in :quarantined via " <>
           "create_quarantined/1 (never :reserved) and enqueues a scan job",
         %{token: token} do
      conn =
        put_sync("bytes", [{"content-type", "application/octet-stream"} | S.auth(token)])

      assert conn.status == 200,
             "sync upload must succeed, got #{conn.status} (#{inspect(S.json(conn))})"

      media_id = media_id_from_uri(S.json(conn)["content_uri"], S.server_name())

      assert_received {:create_quarantined_called, %{media_id: ^media_id} = attrs},
                      "sync upload must create its row via " <>
                        "Nebu.Media.StateMachine.create_quarantined/1 — the single-step " <>
                        "genesis-into-:quarantined seam (AC1/AC4)"

      assert attrs.uploader_user_id != nil,
             "create_quarantined/1 must be called with the uploading user's identity"

      refute_received {:state_machine_create_called, _attrs},
                      "sync upload must NEVER call create/1 (the :reserved genesis) — " <>
                        "that would leave a spurious NULL->reserved transition row for a " <>
                        "flow that never has bytes-not-yet-present semantics"

      refute_received {:transition_called, _media_id, _to_state, _actor, _metadata},
                      "sync upload must NEVER call transition/4 — the row is created " <>
                        "ALREADY in :quarantined in one step (create_quarantined/1), " <>
                        "there is no separate transition to make (a create/1 + " <>
                        "transition/4 pair would produce a SECOND media_state_transitions " <>
                        "row and contradict this story's AC4)"

      assert_received {:scan_enqueued, ^media_id},
                      "the same Oban/ScanEnqueue job the async PUT handler enqueues on " <>
                        "success must also be enqueued for a sync upload"
    end

    test "sync-uploaded row's post-upload seam shape is equivalent to an async row's " <>
           "post-PUT shape, differing only by the extra reserved-genesis call",
         %{token: token, user_id: uid} do
      # ── sync flow: exactly ONE state-machine seam call ──
      conn_sync =
        put_sync("sync bytes", [{"content-type", "application/octet-stream"} | S.auth(token)])

      assert conn_sync.status == 200
      sync_media_id = media_id_from_uri(S.json(conn_sync)["content_uri"], S.server_name())

      assert_received {:create_quarantined_called, %{media_id: ^sync_media_id}}
      refute_received {:state_machine_create_called, _}
      refute_received {:transition_called, _, _, _, _}
      assert_received {:scan_enqueued, ^sync_media_id}

      # ── async flow: create/1 (-> :reserved) THEN transition/4 (-> :quarantined) ──
      conn_create = post_create(S.auth(token))
      assert conn_create.status == 200
      async_media_id = media_id_from_uri(S.json(conn_create)["content_uri"], S.server_name())

      assert_received {:state_machine_create_called, %{media_id: ^async_media_id}},
                      "the async /create step must go through create/1 (genesis into " <>
                        ":reserved) — unaffected by this story"

      seed_reservation(uid)

      conn_async =
        put_async(async_media_id, "async bytes", [
          {"content-type", "application/octet-stream"} | S.auth(token)
        ])

      assert conn_async.status == 200

      assert_received {:transition_called, ^async_media_id, :quarantined, {:system, nil}, _},
                      "the async PUT step must go through transition/4 " <>
                        "(:reserved -> :quarantined) — this story does not touch 2b's " <>
                        "own handler"

      assert_received {:scan_enqueued, ^async_media_id}

      # The crux of AC4's equivalence claim: BOTH rows end up :quarantined with
      # a scan job enqueued, but the async row required TWO state-machine seam
      # calls (create/1 + transition/4 == two media_state_transitions rows,
      # per state_machine_test.exs's own coverage of each function) while the
      # sync row required exactly ONE (create_quarantined/1 == one
      # media_state_transitions row) — never the reverse, and never a sync
      # row with two calls.
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Group 2 — real-Postgres integration tests: exact media_state_transitions
  # row shape for the new create_quarantined/1 genesis function itself.
  # Mirrors state_machine_test.exs's create/1 genesis tests and its no-Sandbox
  # / manual-cleanup convention exactly (same file requires a live Nebu.Repo,
  # `make test-integration` / `mix test --include integration`).
  # ══════════════════════════════════════════════════════════════════════

  describe "Nebu.Media.StateMachine.create_quarantined/1 (real Postgres)" do
    @describetag :integration

    alias Nebu.Media.StateMachine
    alias Nebu.Repo

    @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    defp media_id(suffix), do: "sync_sm_#{@run_id}_#{suffix}"

    defp fetch_state!(media_id) do
      %Postgrex.Result{rows: [[state]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT state FROM media_files WHERE media_id = $1",
          [media_id]
        )

      String.to_existing_atom(state)
    end

    defp fetch_transitions!(media_id) do
      %Postgrex.Result{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT from_state, to_state, actor_type, actor_id, metadata, inserted_at
          FROM media_state_transitions
          WHERE media_id = $1
          ORDER BY id
          """,
          [media_id]
        )

      rows
    end

    # Same `nebu_migrate`-role DISABLE/ENABLE TRIGGER dance as
    # state_machine_test.exs (media_state_transitions is append-only,
    # ADR-031 — even the table owner cannot plain-DELETE it).
    defp migrate_role_conn! do
      url =
        System.get_env("NEBU_DB_URL") ||
          raise "NEBU_DB_URL is not set — this test requires a live PostgreSQL connection"

      uri = URI.parse(url)

      {:ok, conn} =
        Postgrex.start_link(
          hostname: uri.host || "localhost",
          port: uri.port || 5432,
          database: String.trim_leading(uri.path || "", "/"),
          username: "nebu_migrate",
          password: "nebu_migrate_dev_pw"
        )

      conn
    end

    defp cleanup!(media_id) do
      conn = migrate_role_conn!()

      try do
        Postgrex.query!(
          conn,
          "ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate",
          []
        )

        Postgrex.query(conn, "DELETE FROM media_state_transitions WHERE media_id = $1", [
          media_id
        ])

        Postgrex.query(conn, "DELETE FROM media_files WHERE media_id = $1", [media_id])
      after
        Postgrex.query!(
          conn,
          "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
          []
        )
      end
    end

    setup do
      if Process.whereis(Nebu.Repo) == nil do
        flunk(
          "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
            "e.g. `make test-integration`"
        )
      end

      :ok
    end

    test "create_quarantined/1 inserts a fresh row directly in :quarantined and " <>
           "writes EXACTLY ONE genesis transition row (NULL -> quarantined)" do
      mid = media_id("genesis_quarantined")
      on_exit(fn -> cleanup!(mid) end)

      assert {:ok, ^mid} =
               StateMachine.create_quarantined(%{
                 media_id: mid,
                 server_name: "test.local",
                 uploader_user_id: "@tester:test.local"
               })

      assert fetch_state!(mid) == :quarantined,
             "the row must be :quarantined immediately — it must NEVER pass through " <>
               ":reserved for a sync upload (bytes are already present)"

      rows = fetch_transitions!(mid)

      assert length(rows) == 1,
             "expected EXACTLY ONE media_state_transitions row for a sync-created " <>
               "row, got #{length(rows)}: #{inspect(rows)}. A create/1 (-> :reserved) " <>
               "followed by transition/4 (:reserved -> :quarantined) implementation " <>
               "would incorrectly produce TWO rows here — this is precisely the wrong " <>
               "design this test guards against (see the story's CRITICAL DESIGN " <>
               "FINDING)."

      assert [[from_state, to_state, actor_type, actor_id, _metadata, _inserted_at]] = rows

      assert from_state == nil,
             "the genesis transition's from_state must be SQL NULL (brand-new row, no " <>
               "prior state) — got #{inspect(from_state)}"

      assert to_state == "quarantined",
             "the genesis transition must land directly on 'quarantined', got " <>
               "#{inspect(to_state)}"

      assert actor_type == "system"
      assert actor_id == nil
    end

    test "create_quarantined/1 persists uploader_user_id on the media_files row" do
      mid = media_id("genesis_quarantined_uploader")
      on_exit(fn -> cleanup!(mid) end)

      assert {:ok, ^mid} =
               StateMachine.create_quarantined(%{
                 media_id: mid,
                 server_name: "test.local",
                 uploader_user_id: "@tester:test.local"
               })

      %Postgrex.Result{rows: [[uploader_user_id]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT uploader_user_id FROM media_files WHERE media_id = $1",
          [mid]
        )

      assert uploader_user_id == "@tester:test.local"
    end

    test "create_quarantined/1 on an existing media_id returns {:error, " <>
           ":media_id_taken}, writes no transition row" do
      mid = media_id("genesis_quarantined_collision")
      on_exit(fn -> cleanup!(mid) end)

      assert {:ok, ^mid} =
               StateMachine.create_quarantined(%{
                 media_id: mid,
                 server_name: "test.local",
                 uploader_user_id: "@tester:test.local"
               })

      assert {:error, :media_id_taken} =
               StateMachine.create_quarantined(%{
                 media_id: mid,
                 server_name: "test.local",
                 uploader_user_id: "@someone-else:test.local"
               })

      assert length(fetch_transitions!(mid)) == 1,
             "a collision must not add a second (or corrupt) transition row"
    end

    # ── comparison: the async genesis (create/1 -> transition/4) really does
    # produce TWO rows, proving the "sync has one, async has two" contrast is
    # real and not an artifact of this test's own assumptions. ──
    test "in contrast, async-style create/1 then transition/4 DOES produce TWO " <>
           "transition rows for the same media_id" do
      mid = media_id("async_style_two_rows")
      on_exit(fn -> cleanup!(mid) end)

      assert {:ok, ^mid} =
               StateMachine.create(%{
                 media_id: mid,
                 server_name: "test.local",
                 uploader_user_id: "@tester:test.local"
               })

      assert fetch_state!(mid) == :reserved

      assert {:ok, :quarantined} = StateMachine.transition(mid, :quarantined, {:system, nil}, %{})

      rows = fetch_transitions!(mid)

      assert length(rows) == 2,
             "the async create/1 + transition/4 pair must produce exactly TWO " <>
               "media_state_transitions rows (NULL->reserved, reserved->quarantined) — " <>
               "got #{length(rows)}: #{inspect(rows)}"

      assert [[nil, "reserved", _, _, _, _], [from2, "quarantined", _, _, _, _]] = rows
      assert from2 == "reserved"
    end
  end
end
