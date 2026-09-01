defmodule Nebu.Admin.MediaLive.Detail do
  @moduledoc """
  Admin Media Detail — `/admin/media/:media_id`
  (media-security-admin-control/6b-file-detail-storage-summary).

  Story: docs/stories/media-security-admin-control/6b-file-detail-storage-summary.md

  Read-only per-file detail view reached from `Nebu.Admin.MediaLive`'s (5a) table rows: the
  file's own metadata, its full immutable audit trail from `media_state_transitions`
  (append-only ledger, ADR-031), and a page-level storage-summary panel (aggregate bytes for
  `:released` vs `:deleted` media, across ALL `media_files` rows — not scoped to the one file
  being viewed).

  ADR-018 (inline SQL, no Repository/Service layer) / ADR-020 (no cross-domain calls needed —
  everything read here lives in `Nebu.Media`'s own tables). Three read-only queries, each a
  module attribute per `Nebu.Admin.AuditLogLive`'s own `@sql` convention.

  ## Read-only by design (AC10)

  This LiveView issues `SELECT` statements only. It performs no `INSERT`/`UPDATE`/`DELETE`
  against `media_files` or `media_state_transitions`, registers no new
  `Nebu.Compliance.AuditWriter.@known_actions` entry, and renders no action buttons of its own —
  6a/6c/6d's Block/Unblock/Delete/Rescan/Override controls are a separate, later wiring concern
  on this same page. `media_state_transitions` is append-only (ADR-031); this module must never
  attempt an `UPDATE`/`DELETE` against it, even to "fix up" the empty-history case (AC4) — that
  case is a display-only empty state, nothing more.

  ## Route shape — static path param, no `handle_params/3` (mirrors `LogsLive.WarRoom`'s `:show`)

  `media_id` arrives as a static PATH segment, available directly in `mount/3`'s own `params`
  argument (`%{"media_id" => id}`) — there is no filter/pagination URL state for a single-file
  detail page, so (unlike `Nebu.Admin.MediaLive`'s own `handle_params/3` for its filtered table)
  this module needs none.

  ## Honest scope note on "compression ratio" (see the story's own Summary section)

  `media_files.file_size` is the original, pre-compression, pre-encryption byte count in every
  case (`Nebu.Media.DB`/`Nebu.Media.Storage` compute it via `byte_size(original_body)` before
  `:zlib.gzip/1` runs) — the same value Matrix clients see as the file's logical size, and the
  same value both the per-file "Größe" field and the storage-summary aggregates below read,
  regardless of the `compressed` flag. There is no compressed-on-disk byte count persisted
  anywhere in the schema, so this page shows `compressed` as a plain yes/no indicator (AC6) and
  never fabricates a percentage/ratio/bytes-saved figure.

  ## Actor display convention (AC3)

  Matches `Nebu.Admin.AuditLogLive`'s own `actor_user_id` display convention: no name/email join,
  no new cross-domain lookup. `actor_type = :system` renders as `"System"`; `actor_type = :admin`
  renders the raw `actor_id` (a Matrix-ID-shaped TEXT value since migration
  `000029_media_state_transitions_actor_id_text`, Story 6a).
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  alias Nebu.Repo

  # ══════════════════════════════════════════════════════════════════════════
  # Inline SQL (ADR-018) — three read-only queries, no writes anywhere in this module
  # ══════════════════════════════════════════════════════════════════════════

  @sql_file """
  SELECT media_id, server_name, content_type, file_size, uploader_user_id, uploaded_at,
         state, file_hash, scan_metadata, storage_key, compressed, archived_at,
         deleted_at, hard_deleted_at
  FROM media_files
  WHERE media_id = $1
  LIMIT 1
  """

  @sql_transitions """
  SELECT from_state, to_state, actor_type, actor_id, metadata, inserted_at
  FROM media_state_transitions
  WHERE media_id = $1
  ORDER BY inserted_at ASC, id ASC
  """

  # `::bigint` cast is required: Postgres's `SUM(bigint)` aggregate returns
  # `numeric` (Postgrex decodes that as `%Decimal{}`), not a plain integer —
  # without the cast, `reduce_storage_totals/1`'s `{bytes, count}` tuples
  # would carry a `%Decimal{}` for `bytes`, and `Nebu.Admin.MediaLive.
  # humanize_bytes/1` (which pattern-matches `is_integer/1`) would silently
  # fall through to its `"—"` clause instead of ever rendering a byte count.
  @sql_storage_totals """
  SELECT state, COALESCE(SUM(file_size), 0)::bigint, COUNT(*)
  FROM media_files
  WHERE state IN ('released', 'deleted')
  GROUP BY state
  """

  # ══════════════════════════════════════════════════════════════════════════
  # Mount — static path param, no handle_params/3 (see moduledoc)
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def mount(%{"media_id" => media_id}, _session, socket) do
    file = fetch_file(media_id)

    {:ok,
     socket
     |> assign(:active_nav, "media-explorer")
     |> assign(:page_title, "Medium: #{media_id}")
     |> assign(:media_id, media_id)
     |> assign(:file, file)
     |> assign(:transitions, if(file, do: fetch_transitions(media_id), else: []))
     |> assign(:storage_totals, fetch_storage_totals())}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Query helpers — every value travels as a positional bind param, never
  # interpolated into the SQL text (ADR-018/ADR-020 shared convention).
  # ══════════════════════════════════════════════════════════════════════════

  defp fetch_file(media_id) do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Repo, @sql_file, [media_id]) do
        {:ok, %{rows: [row]}} -> row_to_file(row)
        _ -> nil
      end
    end
  end

  defp row_to_file([
         media_id,
         server_name,
         content_type,
         file_size,
         uploader_user_id,
         uploaded_at,
         state,
         file_hash,
         scan_metadata,
         storage_key,
         compressed,
         archived_at,
         deleted_at,
         hard_deleted_at
       ]) do
    %{
      media_id: media_id,
      server_name: server_name,
      content_type: content_type,
      file_size: file_size,
      uploader_user_id: uploader_user_id,
      uploaded_at: uploaded_at,
      state: to_string(state),
      file_hash: file_hash,
      scan_metadata: scan_metadata,
      storage_key: storage_key,
      compressed: compressed,
      archived_at: archived_at,
      deleted_at: deleted_at,
      hard_deleted_at: hard_deleted_at
    }
  end

  defp fetch_transitions(media_id) do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Repo, @sql_transitions, [media_id]) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &row_to_transition/1)
        _ -> []
      end
    else
      []
    end
  end

  defp row_to_transition([from_state, to_state, actor_type, actor_id, metadata, inserted_at]) do
    %{
      from_state: if(from_state, do: to_string(from_state)),
      to_state: to_string(to_state),
      actor_type: to_string(actor_type),
      actor_id: actor_id,
      metadata: metadata,
      inserted_at: inserted_at
    }
  end

  defp fetch_storage_totals do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Repo, @sql_storage_totals, []) do
        {:ok, %{rows: rows}} -> reduce_storage_totals(rows)
        _ -> reduce_storage_totals([])
      end
    else
      reduce_storage_totals([])
    end
  end

  # AC5/AC6: `GROUP BY` omits states with zero matching rows entirely — it does
  # NOT return a zero row for them — so the Elixir-side default to `{0, 0}` is
  # required for both buckets to always render, never crash on a missing key.
  # `public` (not `defp`) on purpose: a pure function of `rows` (no DB access
  # of its own) is directly unit-testable against a `[]`/partial input without
  # depending on the shared integration database ever having a literal
  # zero-row state bucket — see detail_test.exs's AT6 for why that DB-level
  # guarantee isn't reproducible against a table shared by the whole test run.
  def reduce_storage_totals(rows) do
    default = %{active: {0, 0}, pending_hard_delete: {0, 0}}

    Enum.reduce(rows, default, fn [state, bytes, count], acc ->
      case to_string(state) do
        "released" -> Map.put(acc, :active, {bytes, count})
        "deleted" -> Map.put(acc, :pending_hard_delete, {bytes, count})
        _ -> acc
      end
    end)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Render helpers
  # ══════════════════════════════════════════════════════════════════════════

  # State-badge grouping — reuses Nebu.Admin.MediaLive's own convention exactly
  # (Technical Requirements: "do not invent a second palette for the same 8
  # states"), via the small public accessors that module exposes for this
  # purpose (`badge_group/1`/`badge_label/1`).
  defp badge_group(state), do: Nebu.Admin.MediaLive.badge_group(state)
  defp badge_label(state), do: Nebu.Admin.MediaLive.badge_label(state)

  # Reuses Nebu.Admin.MediaLive's own `humanize_bytes/1` (Technical Requirements:
  # "reuse/extract it rather than re-deriving the same rounding logic twice").
  defp humanize_bytes(bytes), do: Nebu.Admin.MediaLive.humanize_bytes(bytes)

  defp format_ts(nil), do: "—"

  defp format_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> "—"
    end
  end

  defp format_ts(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_ts(_), do: "—"

  defp uploader_display(nil), do: "—"
  defp uploader_display(""), do: "—"
  defp uploader_display(uploader), do: uploader

  # AC3: "System" for actor_type=system; the raw actor_id for actor_type=admin
  # — no name/email join (matches Nebu.Admin.AuditLogLive's own actor_user_id
  # display convention, no new cross-domain lookup).
  defp actor_display("system", _actor_id), do: "System"
  defp actor_display(_actor_type, nil), do: "—"
  defp actor_display(_actor_type, ""), do: "—"
  defp actor_display(_actor_type, actor_id), do: actor_id

  # AC6: plain yes/no compression indicator — never a percentage/ratio/bytes-saved figure.
  defp compression_label(true), do: "Komprimiert"
  defp compression_label(_), do: "Nicht komprimiert"

  # AC7: the ClamAV signature block is rendered ONLY when scan_metadata is a map
  # that actually contains a "clamav_signature" key — NULL (never scanned) and a
  # present-but-signature-less map (e.g. %{"skipped" => "size_limit"}) both
  # omit the block entirely, no "N/A"/"—" placeholder clutter.
  #
  # Schema-reality correction (code-review self-catch, same class of drift 5a's
  # own moduledoc already documents): this story's own AC7/Acceptance-Tests text
  # says the key is plain "signature", but the only real writer of scan_metadata
  # in the whole codebase — Nebu.Workers.MediaScanWorker.infect/2 (Story 4b,
  # landed) — persists %{clamav_signature: signature, scanned_at: ...}, i.e. the
  # JSONB key round-trips as "clamav_signature", never "signature". Matching the
  # story's literal (stale) text here would mean this block never renders for
  # any real infected file. Nebu.Admin.MediaLive (5a) hit and corrected this
  # exact drift already (see that module's own moduledoc "Schema-reality
  # corrections" section) — this is the same correction, applied here.
  defp scan_signature(%{"clamav_signature" => signature}) when is_binary(signature),
    do: signature

  defp scan_signature(_), do: nil

  defp truncated_hash(nil), do: "—"

  defp truncated_hash(hash) when is_binary(hash) do
    if String.length(hash) > 16 do
      String.slice(hash, 0, 16) <> "…"
    else
      hash
    end
  end

  @impl Phoenix.LiveView
  def render(%{file: nil} = assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Medium nicht gefunden</h1>

    <p class="text-text-secondary">
      Kein Medium mit der ID <code>{@media_id}</code> gefunden.
    </p>

    <.link
      navigate="/admin/media"
      class="link link-primary focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
    >
      Zurück zur Übersicht
    </.link>
    """
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Medium-Details</h1>

    <.link
      navigate="/admin/media"
      class="link link-primary focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200 mb-4 inline-block"
    >
      ← Zurück zur Übersicht
    </.link>

    <%!-- ═══ File metadata (AC2, AC6, AC7) ═══ --%>
    <section aria-labelledby="media-detail-metadata-heading" class="mb-8">
      <h2 id="media-detail-metadata-heading" class="text-lg font-semibold mb-2">Metadaten</h2>

      <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-2">
        <div>
          <dt class="text-caption uppercase text-text-secondary">Media-ID</dt>
          <dd class="font-mono"><code>{@file.media_id}</code></dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">Status</dt>
          <dd>
            <span class={["badge badge-sm", "media-badge--#{badge_group(@file.state)}"]}>
              {badge_label(@file.state)}
            </span>
          </dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">MIME-Typ</dt>
          <dd>{@file.content_type}</dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">Dateigröße</dt>
          <dd>{humanize_bytes(@file.file_size)}</dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">Uploader</dt>
          <dd class="font-mono">{uploader_display(@file.uploader_user_id)}</dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">Hochgeladen</dt>
          <dd class="whitespace-nowrap">{format_ts(@file.uploaded_at)}</dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">Datei-Hash (SHA-256)</dt>
          <dd class="font-mono text-mono" title={@file.file_hash}>
            {truncated_hash(@file.file_hash)}
          </dd>
        </div>
        <div>
          <dt class="text-caption uppercase text-text-secondary">Komprimierung</dt>
          <dd>
            <span class="badge badge-sm badge-outline">{compression_label(@file.compressed)}</span>
          </dd>
        </div>
        <div :if={scan_signature(@file.scan_metadata)}>
          <dt class="text-caption uppercase text-text-secondary">ClamAV-Signatur</dt>
          <dd class="font-mono">{scan_signature(@file.scan_metadata)}</dd>
        </div>
      </dl>
    </section>

    <%!-- ═══ Storage summary panel (AC5) — page-level, ALL media_files rows ═══ --%>
    <section aria-labelledby="media-detail-storage-heading" class="mb-8">
      <h2 id="media-detail-storage-heading" class="text-lg font-semibold mb-2">
        Speicherübersicht
      </h2>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="p-4 rounded border border-base-300">
          <p class="text-caption uppercase text-text-secondary">Aktiv (freigegeben)</p>
          <p class="text-xl font-semibold">
            {humanize_bytes(elem(@storage_totals.active, 0))}
          </p>
          <p class="text-text-secondary">
            {elem(@storage_totals.active, 1)} Dateien
          </p>
        </div>
        <div class="p-4 rounded border border-base-300">
          <p class="text-caption uppercase text-text-secondary">
            Ausstehend endgültige Löschung
          </p>
          <p class="text-xl font-semibold">
            {humanize_bytes(elem(@storage_totals.pending_hard_delete, 0))}
          </p>
          <p class="text-text-secondary">
            {elem(@storage_totals.pending_hard_delete, 1)} Dateien
          </p>
        </div>
      </div>
    </section>

    <%!-- ═══ Full audit trail (AC3, AC4, AC12) ═══ --%>
    <section aria-labelledby="media-detail-history-heading">
      <h2 id="media-detail-history-heading" class="text-lg font-semibold mb-2">
        Verlauf (Zustandsübergänge)
      </h2>

      <p :if={@transitions == []} class="text-text-secondary">
        Kein Verlauf aufgezeichnet.
      </p>

      <div :if={@transitions != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <caption class="sr-only">
            Zustandsübergänge für Medium {@media_id}, chronologisch aufsteigend
          </caption>
          <thead>
            <tr>
              <th scope="col">Von</th>
              <th scope="col">Nach</th>
              <th scope="col">Akteur</th>
              <th scope="col">Zeitpunkt</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @transitions}>
              <td>{t.from_state || "—"}</td>
              <td>{t.to_state}</td>
              <td class="font-mono">{actor_display(t.actor_type, t.actor_id)}</td>
              <td class="whitespace-nowrap">{format_ts(t.inserted_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end
end
