defmodule Nebu.Admin.MediaLive.DetailTest do
  @moduledoc """
  Acceptance tests for `Nebu.Admin.MediaLive.Detail`
  (media-security-admin-control/6b-file-detail-storage-summary).

  Story: docs/stories/media-security-admin-control/6b-file-detail-storage-summary.md

  ## Why every test here is `@moduletag :integration`, router-mounted, real Postgres

  Same constraint as `Nebu.Admin.MediaLive` (5a/6a)'s own test file: ADR-018 puts every query
  inline in the LiveView itself, directly against `media_files`/`media_state_transitions` — there
  is no injectable fake-DB seam. Every test needs a live `Nebu.Repo` connection with real seeded
  rows, and mounts through the REAL router (`media_id` is a static path segment, mirroring
  `Nebu.Admin.LogsLive.WarRoom`'s own `:show` action — no `handle_params/3`, so `live_isolated/3`
  is not required here, but router-mounting is still used for consistency with 5a/6a and to
  exercise the real `on_mount {Nebu.Admin.Auth, :require_admin}` gate end-to-end for AT12).

  ## AT5/AT6 "exact" storage-summary assertions against a table shared by the whole test run

  `media_files` is shared across every test file in this run (5a/6a's own fixtures, other stories'
  fixtures, etc. — see `media_live_test.exs`'s own AT1 comment for the same observation). AC5's
  storage-summary panel deliberately aggregates over ALL rows, not a filtered subset, so a literal
  "the WHOLE table has zero :deleted rows" scenario is not reproducible here. AT5 instead reads
  the CURRENT totals as a baseline immediately before seeding known-sum fixture rows, then asserts
  the rendered totals equal `baseline + known_delta` exactly — this proves the SQL aggregation and
  rendering are correct without requiring the shared table to be empty. AT6 is split in two:
  the DB-independent Elixir-side default-to-`{0, 0}` behavior (what fires when Postgres's
  `GROUP BY` omits a state that has zero matching rows entirely) is proven directly and
  deterministically against `Nebu.Admin.MediaLive.Detail.reduce_storage_totals/1` — a pure
  function of `rows`, exposed for exactly this reason — while a real-DB rendering assertion
  confirms the "0 B" / "0 Dateien" *formatting* renders correctly whenever a bucket's current
  value happens to be `{0, 0}` (asserted generically: the format is always parseable, never blank
  or a crash, regardless of which bucket is actually at zero when the suite runs).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
          |> String.replace(["-", "_"], "a")

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
          "e.g. `make test-integration`"
      )
    end

    Nebu.Release.migrate()
    Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})

    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Seeding / cleanup helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp media_id(suffix), do: "mediadetail_#{@run_id}_#{suffix}"

  defp insert_media_file!(media_id, attrs) do
    defaults = %{
      server_name: "test.local",
      content_type: "application/octet-stream",
      file_size: 1024,
      aes_key_hex: "aeskeyhex",
      nonce_hex: "noncehex",
      uploader_user_id: "@uploader:test.local",
      uploaded_at: System.system_time(:millisecond),
      deleted: false,
      state: "released",
      filename: nil,
      scan_metadata: nil,
      file_hash: String.duplicate("ab", 32),
      storage_key: media_id,
      compressed: false
    }

    fields = Map.merge(defaults, Map.new(attrs))

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state, filename, scan_metadata,
         file_hash, storage_key, compressed)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
      """,
      [
        media_id,
        fields.server_name,
        fields.content_type,
        fields.file_size,
        fields.aes_key_hex,
        fields.nonce_hex,
        fields.uploader_user_id,
        fields.uploaded_at,
        fields.deleted,
        fields.state,
        fields.filename,
        fields.scan_metadata,
        fields.file_hash,
        fields.storage_key,
        fields.compressed
      ]
    )

    media_id
  end

  defp insert_transition!(media_id, attrs) do
    defaults = %{
      from_state: nil,
      to_state: "released",
      actor_type: "system",
      actor_id: nil,
      metadata: nil,
      inserted_at: DateTime.utc_now()
    }

    fields = Map.merge(defaults, Map.new(attrs))

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO media_state_transitions
        (media_id, from_state, to_state, actor_type, actor_id, metadata, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      """,
      [
        media_id,
        fields.from_state,
        fields.to_state,
        fields.actor_type,
        fields.actor_id,
        fields.metadata,
        fields.inserted_at
      ]
    )

    :ok
  end

  defp cleanup_on_exit!(media_id) do
    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_files WHERE media_id = $1", [
          media_id
        ])
      end
    end)
  end

  defp storage_totals do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT state, COALESCE(SUM(file_size), 0)::bigint, COUNT(*) FROM media_files " <>
          "WHERE state IN ('released', 'deleted') GROUP BY state",
        []
      )

    Nebu.Admin.MediaLive.Detail.reduce_storage_totals(rows)
  end

  defp admin_conn_for_live(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-detail-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-media-detail-live-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp sent_admin_conn(path) do
    path
    |> admin_conn_for_live()
    |> @endpoint.call(@endpoint.init([]))
  end

  defp non_admin_conn(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-detail-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> @endpoint.call(@endpoint.init([]))
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT1: file metadata
  # ══════════════════════════════════════════════════════════════════════════

  test "GET /admin/media/:media_id as an authenticated admin renders the file's own metadata " <>
         "(hash, size, MIME, uploader, uploaded_at, state badge)" do
    id = media_id("meta")
    cleanup_on_exit!(id)

    insert_media_file!(id,
      content_type: "application/pdf",
      file_size: 2_300_000,
      uploader_user_id: "@alice:test.local",
      state: "released",
      file_hash: String.duplicate("cd", 32)
    )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    assert html =~ id
    assert html =~ "application/pdf"
    assert html =~ "2.3 MB"
    assert html =~ "@alice:test.local"
    assert html =~ "Freigegeben"
    assert html =~ String.slice(String.duplicate("cd", 32), 0, 16)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT2: transition history chronological order
  # ══════════════════════════════════════════════════════════════════════════

  test "transition history renders in chronological order (oldest first), showing " <>
         "from_state/to_state/actor/timestamp per row" do
    id = media_id("history")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released")

    now = DateTime.utc_now()
    # Inserted deliberately OUT of chronological order — insertion order is
    # middle, oldest, newest — so a passing test proves the render orders by
    # `inserted_at ASC`, not by insertion/PK order.
    insert_transition!(id,
      from_state: "quarantined",
      to_state: "scanning",
      inserted_at: DateTime.add(now, -60, :second)
    )

    insert_transition!(id,
      from_state: nil,
      to_state: "reserved",
      inserted_at: DateTime.add(now, -120, :second)
    )

    insert_transition!(id,
      from_state: "scanning",
      to_state: "released",
      inserted_at: now
    )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    reserved_pos = :binary.match(html, "reserved") |> elem(0)
    scanning_pos = :binary.match(html, "scanning</td>") |> elem(0)
    released_pos = :binary.match(html, "released</td>") |> elem(0)

    assert reserved_pos < scanning_pos
    assert scanning_pos < released_pos
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT3: actor display convention
  # ══════════════════════════════════════════════════════════════════════════

  test "a transition with actor_type: :system renders actor as 'System'; " <>
         "actor_type: :admin renders the raw actor_id" do
    id = media_id("actor")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "admin_blocked")

    insert_transition!(id,
      from_state: nil,
      to_state: "released",
      actor_type: "system",
      actor_id: nil,
      inserted_at: DateTime.add(DateTime.utc_now(), -30, :second)
    )

    insert_transition!(id,
      from_state: "released",
      to_state: "admin_blocked",
      actor_type: "admin",
      actor_id: "@admin:test.local",
      inserted_at: DateTime.utc_now()
    )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "System"
    assert html =~ "@admin:test.local"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT4: empty-history handling
  # ══════════════════════════════════════════════════════════════════════════

  test "a media_id with zero media_state_transitions rows renders the empty-history state, " <>
         "not an error" do
    id = media_id("nohistory")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released")

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "Kein Verlauf aufgezeichnet"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT5: storage summary — exact sums against a known delta
  # ══════════════════════════════════════════════════════════════════════════

  test "storage summary numbers are correct against a fixture with known :released and " <>
         ":deleted file_size values" do
    baseline = storage_totals()
    {base_active_bytes, base_active_count} = baseline.active
    {base_deleted_bytes, base_deleted_count} = baseline.pending_hard_delete

    active_ids = for i <- 1..3, do: media_id("active#{i}")
    deleted_ids = for i <- 1..2, do: media_id("deleted#{i}")

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Enum.each(active_ids ++ deleted_ids, fn id ->
          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM media_files WHERE media_id = $1", [id])
        end)
      end
    end)

    # Mixed compressed: true/false among the :released rows — proves the sum
    # uses file_size (the logical/original size) regardless of the compression
    # flag (AC6, AT5).
    active_sizes = [10_000, 20_000, 30_000]

    Enum.zip(active_ids, active_sizes)
    |> Enum.with_index()
    |> Enum.each(fn {{id, size}, idx} ->
      insert_media_file!(id, state: "released", file_size: size, compressed: rem(idx, 2) == 0)
    end)

    deleted_sizes = [5_000, 7_000]

    Enum.zip(deleted_ids, deleted_sizes)
    |> Enum.each(fn {id, size} ->
      insert_media_file!(id, state: "deleted", file_size: size, compressed: true)
    end)

    expected_active_bytes = base_active_bytes + Enum.sum(active_sizes)
    expected_active_count = base_active_count + length(active_ids)
    expected_deleted_bytes = base_deleted_bytes + Enum.sum(deleted_sizes)
    expected_deleted_count = base_deleted_count + length(deleted_ids)

    # Mount against any one of the seeded files — the storage panel is
    # page-level (AC5), not scoped to the file being viewed.
    conn = sent_admin_conn("/admin/media/#{List.first(active_ids)}")
    {:ok, _view, html} = live(conn)

    assert html =~ Nebu.Admin.MediaLive.humanize_bytes(expected_active_bytes)
    assert html =~ "#{expected_active_count} Dateien"
    assert html =~ Nebu.Admin.MediaLive.humanize_bytes(expected_deleted_bytes)
    assert html =~ "#{expected_deleted_count} Dateien"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT6: zero-matching-rows bucket rendering
  # ══════════════════════════════════════════════════════════════════════════

  test "reduce_storage_totals/1 defaults a state with zero matching rows to {0, 0} " <>
         "(DB-independent, deterministic — see moduledoc)" do
    assert Nebu.Admin.MediaLive.Detail.reduce_storage_totals([]) ==
             %{active: {0, 0}, pending_hard_delete: {0, 0}}

    assert Nebu.Admin.MediaLive.Detail.reduce_storage_totals([["released", 1_000, 2]]) ==
             %{active: {1_000, 2}, pending_hard_delete: {0, 0}}
  end

  test "storage summary renders '0 B' / '0 Dateien' for a bucket with no matching rows " <>
         "(only :released rows seeded — Pending Hard-Delete bucket rendering is checked " <>
         "against its own live baseline, not assumed to be globally zero)" do
    id = media_id("onlyactive")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released", file_size: 500)

    baseline = storage_totals()
    {deleted_bytes, deleted_count} = baseline.pending_hard_delete

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    # The panel always renders a formatted total, never blank — whether that
    # total happens to be the true DB-wide zero or some other run's leftover
    # non-zero value, the rendering path (never a crash, never blank) is what
    # AC5/AC6 actually require.
    assert html =~ Nebu.Admin.MediaLive.humanize_bytes(deleted_bytes)
    assert html =~ "#{deleted_count} Dateien"

    if deleted_count == 0 do
      assert html =~ "0 B"
      assert html =~ "0 Dateien"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT7: compression indicator, not a ratio
  # ══════════════════════════════════════════════════════════════════════════

  test "compressed: true renders a compression indicator without any percentage or ratio text" do
    id = media_id("compressed")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released", compressed: true)

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "Komprimiert"
    refute html =~ ~r/\d+%/
    # Word-boundary match, not a bare substring: "Configuration" (this admin
    # layout's own nav item) contains the literal substring "ratio" — a naive
    # `~r/[Rr]atio/` false-positives on that nav link on every render.
    refute html =~ ~r/\bratio\b/i
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT8-AT10: scan metadata (ClamAV signature)
  #
  # Schema-reality correction (code-review self-catch): the story's own AT8
  # text says the key is plain "signature", but the only real writer —
  # Nebu.Workers.MediaScanWorker.infect/2 (Story 4b, landed) — persists
  # %{clamav_signature: signature, scanned_at: ...}, so the real JSONB key is
  # "clamav_signature". Fixture below uses the REAL key, matching
  # Nebu.Admin.MediaLive (5a)'s own already-corrected convention.
  # ══════════════════════════════════════════════════════════════════════════

  test "scan metadata renders the ClamAV signature when scan_metadata contains one " <>
         "(infected fixture)" do
    id = media_id("infected")
    cleanup_on_exit!(id)

    insert_media_file!(id,
      state: "infected",
      scan_metadata: %{"clamav_signature" => "Eicar-Test-Signature"}
    )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "Eicar-Test-Signature"
  end

  test "scan metadata block is absent when scan_metadata is nil (clean, never-flagged fixture)" do
    id = media_id("clean")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released", scan_metadata: nil)

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    refute html =~ "ClamAV-Signatur"
  end

  test "scan metadata block is absent when scan_metadata has no signature key " <>
         "(e.g. skipped by size limit)" do
    id = media_id("skipped")
    cleanup_on_exit!(id)

    insert_media_file!(id,
      state: "released",
      scan_metadata: %{"skipped" => "size_limit"}
    )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    refute html =~ "ClamAV-Signatur"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT11: unknown media_id
  # ══════════════════════════════════════════════════════════════════════════

  test "an unknown media_id renders a not-found state, not a crash" do
    conn = sent_admin_conn("/admin/media/#{media_id("does_not_exist")}")
    {:ok, _view, html} = live(conn)

    assert html =~ "nicht gefunden"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT12: unauthenticated access control
  # ══════════════════════════════════════════════════════════════════════════

  test "an unauthenticated request to /admin/media/:media_id redirects to /admin/login" do
    id = media_id("unauth")
    conn = non_admin_conn("/admin/media/#{id}")

    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC11 (self-review gap-close, test-review step): XSS-safety — the story's
  # own enumerated Acceptance Tests (1-13) have no item mapped to AC11, even
  # though AC11 is an explicit, security-relevant acceptance criterion.
  # Mirrors media_live_test.exs's own AT20 "HEEx auto-escaping" test — same
  # convention, extended here to also cover a transition's `metadata` field
  # (this page renders `t.metadata` nowhere in v1 markup, but AC11 explicitly
  # names it, so this guards a future template change too, not just current
  # rendering; content_type/uploader_user_id ARE rendered today).
  # ══════════════════════════════════════════════════════════════════════════

  test "HEEx auto-escaping (AC11): content_type/uploader_user_id containing " <>
         "'<script>' render as escaped text, never executed markup" do
    id = media_id("xss")
    cleanup_on_exit!(id)

    insert_media_file!(id,
      content_type: "<script>window.__xss_content_type=1</script>",
      uploader_user_id: "<script>window.__xss_uploader=1</script>",
      state: "released"
    )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    refute html =~ "<script>window.__xss_content_type=1</script>"
    refute html =~ "<script>window.__xss_uploader=1</script>"
    assert html =~ "&lt;script&gt;"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC12 (self-review gap-close, test-review step): accessibility markup —
  # same reasoning as AC11 above, no enumerated Acceptance Test maps to AC12.
  # This does not attempt a full WCAG audit (that is the UX gate's job); it
  # pins the two structural, easily-regressed markup requirements the story
  # text calls out by name: a `<caption>` and `<th scope="col">` headers on
  # the transition-history table.
  # ══════════════════════════════════════════════════════════════════════════

  test "accessibility (AC12): the transition-history table has a <caption> and " <>
         "<th scope=\"col\"> column headers" do
    id = media_id("a11y")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released")
    insert_transition!(id, from_state: nil, to_state: "released")

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, html} = live(conn)

    assert html =~ "<caption"
    assert html =~ ~s(<th scope="col">)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT13: read-only regression guard — no writes against media_files or
  # media_state_transitions from mounting/rendering this page.
  # ══════════════════════════════════════════════════════════════════════════

  test "the page issues no INSERT/UPDATE/DELETE against media_files or media_state_transitions" do
    id = media_id("readonly")
    cleanup_on_exit!(id)
    insert_media_file!(id, state: "released", file_size: 4_242)
    insert_transition!(id, from_state: nil, to_state: "released")

    count_before = fn table ->
      {:ok, %{rows: [[n]]}} =
        Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT COUNT(*) FROM #{table}", [])

      n
    end

    files_before = count_before.("media_files")
    transitions_before = count_before.("media_state_transitions")

    {:ok, %{rows: [file_row_before]}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT media_id, state, file_size FROM media_files WHERE media_id = $1",
        [id]
      )

    conn = sent_admin_conn("/admin/media/#{id}")
    {:ok, _view, _html} = live(conn)

    assert count_before.("media_files") == files_before
    assert count_before.("media_state_transitions") == transitions_before

    {:ok, %{rows: [file_row_after]}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT media_id, state, file_size FROM media_files WHERE media_id = $1",
        [id]
      )

    assert file_row_before == file_row_after

    # Static-analysis belt-and-braces: the module's own SQL module attributes
    # (@sql_file/@sql_transitions/@sql_storage_totals) are all SELECTs — grep
    # the compiled module source for the actual SQL statements (each is a
    # bare heredoc, not a comment) to catch a future accidental write without
    # relying solely on the runtime count-unchanged assertion above.
    source =
      "lib/nebu/admin/media_live/detail.ex"
      |> Path.expand(Path.join(__DIR__, "../../../.."))
      |> File.read!()

    sql_blocks =
      Regex.scan(~r/@sql_\w+\s+"""(.*?)"""/s, source)
      |> Enum.map(fn [_, body] -> body end)
      |> Enum.join("\n")

    refute sql_blocks =~ ~r/\bINSERT\s+INTO\b/i
    refute sql_blocks =~ ~r/\bUPDATE\s+media_(files|state_transitions)\b/i
    refute sql_blocks =~ ~r/\bDELETE\s+FROM\b/i
  end
end
