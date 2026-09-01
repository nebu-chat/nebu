defmodule Nebu.Admin.MediaLive do
  @moduledoc """
  Admin Media Overview — `/admin/media` (media-security-admin-control/5a-admin-media-table).

  Story: docs/stories/media-security-admin-control/5a-admin-media-table.md
  Design: _bmad-output/planning-artifacts/ux-designs/ux-media-security-admin-control-2026-07-02/

  Read-only, filterable, keyset-paginated table over `media_files` (ADR-018: every query is
  inline SQL in this module's own functions — no Ecto schema, no repository/service layer;
  ADR-020: `Nebu.Admin` is the only namespace allowed to read `media_files` directly for
  admin-facing concerns). This story's scope is exactly query/filter/paginate/render/select — row
  actions (Block/Unblock/Delete/Rescan/Override) are Story 6a/6c, live PubSub row updates + nav
  attention badges are Story 5b, bulk-action wiring onto this story's multi-select is Story 6d.

  ## Schema-reality corrections (2026-07-18) — see the story's own Summary section

  An earlier draft of this story assumed `media_files` had no human-readable filename column and
  that `uploader_user_id` was always present. Both assumptions are now stale relative to the live,
  committed schema:

    * `filename` (nullable `TEXT`) was added by Story 2b's migration 000025 — the identity column
      below shows it when present, falling back to the Media-ID (`media_id`, `<code>` styling)
      when `NULL` (e.g. `:reserved` genesis rows, or an upload that omitted `?filename=`).
    * `uploader_user_id` became nullable via Story 2e's migration 000027 (nulled on the
      `:reserved -> :hard_deleted` cleanup transition) — rendered as `"—"` when `NULL`.
    * The ClamAV signature column reads `scan_metadata->>'clamav_signature'`, not a plain
      `'signature'` key — `Nebu.Workers.MediaScanWorker.infect/2` (Story 4b, landed) is the only
      real writer of `scan_metadata` and persists the signature under that key.

  ## URL-driven filter/pagination state

  Mirrors `Nebu.Admin.LogsLive.TraceMap`'s already-established contract in this codebase: the URL
  is the single source of truth for filters and pagination. `mount/3` does no query work at all;
  every filter control and the "Weitere laden" button issue a `push_patch/2`, and `handle_params/3`
  is the only place rows are ever fetched. Unlike `Nebu.Admin.LogsLive` (which cannot export
  `handle_params/3` without breaking its own large `live_isolated/3`-based test suite — see that
  module's moduledoc), this module has no such constraint since its entire test suite mounts
  through the real router (this page's filters/pagination/multi-select behavior is inherently
  URL/router-dependent, so `live_isolated/3` was never an option here anyway).

  A `cursor` query param distinguishes a fresh filter/page-1 fetch (absent) from a "Weitere laden"
  continuation (present): its presence triggers `stream_insert/4` (append) instead of
  `stream(reset: true)`, so a bookmarked URL with a `cursor` reproduces exactly the one keyset page
  starting after that cursor (AC4) rather than replaying every prior page.

  ## Multi-select

  `socket.assigns.selected_ids` is a plain `MapSet` of `media_id`s — keyed by id, never row
  index/position, so a future `stream_insert` from Story 5b's PubSub updates can never invalidate
  an existing selection. "Select all matching filter" runs the same `WHERE` clause (no `LIMIT`,
  cursor-free) capped at `@select_all_cap` rows with a truncation flag surfaced to the template.

  ## Live row updates + nav badge (media-security-admin-control/5b-live-updates-nav-badges)

  This module already uses `Phoenix.LiveView.stream/3` for `:media_rows` (confirmed before
  building 5b on top of it — no conversion was needed, unlike the risk 5b's own story
  flagged). `mount/3` subscribes to `Nebu.Admin.MediaAttentionBadge`'s broad `"media:admin"`
  topic ONCE, for this process's entire lifetime — never one `"media:\#{media_id}"`
  subscription per visible row (see this module's own AT8 regression guard in
  `media_live_test.exs`, and the story's Guardrails). `socket.assigns.visible_media_ids` (a
  plain `MapSet`, reset/extended alongside the stream in `handle_params/3`) is the O(1)
  membership check `handle_info/2` uses to decide whether an incoming broadcast's `media_id`
  is on the current page/filter at all — avoiding both a DB round-trip for broadcasts about
  files nowhere near the current page (the common case) and any dependency on `Phoenix.LiveView`
  stream internals for a "is this key present" query. When a broadcast's `media_id` IS visible,
  the row is re-fetched fresh by id (`fetch_row_by_id/1`, reusing the same `@select_columns`/
  `row_to_map/1` shape as `fetch_rows/3`) and `stream_insert/3`'d — the broadcast payload only
  carries `media_id`/`old_state`/`new_state`, not the row's other columns, so a full re-fetch is
  the simplest way to patch the state-derived columns (badge, `scanned_at`, ClamAV signature)
  without corrupting the untouched ones (filename, uploader, mime, size, uploaded_at).
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  require Logger

  alias Nebu.Admin.MediaAttentionBadge
  alias Nebu.Repo

  @page_size 50
  @select_all_cap 5_000

  # State-badge grouping per DESIGN.md's media-state vocabulary (D2).
  @badge_groups %{
    "reserved" => {"media-processing", "Ausstehend"},
    "quarantined" => {"media-processing", "In Quarantäne"},
    "scanning" => {"media-processing", "Wird geprüft"},
    "scan_failed" => {"media-processing", "Prüfung fehlgeschlagen"},
    "released" => {"media-released", "Freigegeben"},
    "infected" => {"media-infected", "Infiziert"},
    "admin_blocked" => {"media-blocked", "Gesperrt"},
    "deleted" => {"media-terminal", "Gelöscht"},
    "hard_deleted" => {"media-terminal", "Endgültig gelöscht"}
  }

  @all_states Map.keys(@badge_groups)

  # ══════════════════════════════════════════════════════════════════════════
  # Mount / handle_params
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    MediaAttentionBadge.subscribe()

    {:ok,
     socket
     |> assign(:active_nav, "media-explorer")
     |> assign(:page_title, "Medien")
     |> assign(:filters, %{
       states: [],
       mime_prefix: nil,
       uploader: nil,
       uploaded_from: nil,
       uploaded_to: nil
     })
     |> assign(:cursor, nil)
     |> assign(:has_more, false)
     |> assign(:result_count, 0)
     |> assign(:loaded_count, 0)
     |> assign(:announcement, "")
     |> assign(:selected_ids, MapSet.new())
     |> assign(:select_all_active, false)
     |> assign(:select_all_truncated, false)
     |> assign(:visible_media_ids, MapSet.new())
     |> assign(:media_attention_count, MediaAttentionBadge.initial_count())
     # media-security-admin-control/6a-routine-state-actions
     |> assign(:confirm_delete_media_id, nil)
     |> assign(:action_flash, nil)
     # media-security-admin-control/6c-infected-override (AC6): computed ONCE
     # here (reading the same Nebu.Media.DB.check_override_role/1 the public
     # API's own authorize_override/1 uses, via the current admin's id) so
     # row-action rendering can conditionally show/hide the Override button
     # per-page without a per-row DB round trip. This is a UI-convenience
     # read only — NOT the enforcement point (AC6's real guard is
     # Nebu.Media.admin_override_infected/3's own independent re-check).
     |> assign(:media_admin_override?, media_admin_override_flag(socket.assigns.current_user))
     |> assign(:confirm_override_media_id, nil)
     |> assign(:override_reason, "")
     |> stream(:media_rows, [], dom_id: &row_dom_id/1)}
  end

  defp row_dom_id(row), do: "media-row-#{row.media_id}"

  # media-security-admin-control/6c-infected-override (AC6): same
  # `if Process.whereis(Nebu.Repo)` defensive guard fetch_rows/1, count_rows/1,
  # fetch_row_by_id/1, and fetch_all_matching_ids/1 already use — this module's
  # own established pattern for any Repo-touching call reached from mount/3
  # (which runs before handle_params/3, and this codebase's convention is to
  # never let a live-Repo read crash the mount itself).
  defp media_admin_override_flag(current_user) do
    if Process.whereis(Nebu.Repo) do
      Nebu.Media.DB.check_override_role(actor_id(current_user))
    else
      false
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)
    load_more? = Map.has_key?(params, "cursor")
    cursor = if load_more?, do: parse_cursor(params["cursor"]), else: nil

    # code-review self-fix: fetch one extra row so `has_more` is exact, not a
    # `length(rows) == @page_size` heuristic — that heuristic is wrong whenever
    # the true remaining count is an exact multiple of @page_size (it would show
    # one harmless-but-wasteful extra "Weitere laden" round trip that fetches
    # zero new rows). Trim the sentinel row before it ever reaches the stream,
    # the cursor computation, or the loaded/result counters.
    fetched = fetch_rows(filters, cursor)
    has_more = length(fetched) > @page_size
    rows = Enum.take(fetched, @page_size)

    socket =
      if load_more? do
        loaded_before = socket.assigns.loaded_count
        new_loaded = loaded_before + length(rows)

        socket
        |> append_rows(rows)
        |> assign(:loaded_count, new_loaded)
        |> assign(
          :visible_media_ids,
          MapSet.union(socket.assigns.visible_media_ids, row_ids(rows))
        )
        |> assign(
          :announcement,
          load_more_announcement(length(rows), new_loaded, socket.assigns.result_count)
        )
        |> maybe_push_focus(rows)
      else
        count = count_rows(filters)

        socket
        |> stream(:media_rows, rows, reset: true)
        |> assign(:loaded_count, length(rows))
        |> assign(:visible_media_ids, row_ids(rows))
        |> assign(:result_count, count)
        |> assign(:announcement, result_announcement(count, filters))
      end

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:cursor, next_cursor(rows) || cursor)
     |> assign(:has_more, has_more)}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5b: live row updates + nav badge — "media:admin" broadcasts only (AT8)
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def handle_info({:media_state_transition, media_id, old_state, new_state}, socket) do
    socket = MediaAttentionBadge.apply_transition(socket, old_state, new_state)

    socket =
      if MapSet.member?(socket.assigns.visible_media_ids, media_id) do
        case fetch_row_by_id(media_id) do
          nil ->
            socket

          row ->
            # UX gate (2026-07-18): reuses 5a's own aria-live="polite" role="status"
            # sr-only `@announcement` div (this module's existing filter/pagination
            # announcer, see the template above) so a screen-reader user is notified
            # of an in-place row update too — a stream_insert alone patches the DOM
            # silently, same accessibility gap this codebase already tracks for
            # LiveView-updated content in general (see nebu-agent-ux MEMORY.md "Known
            # Accessibility Gaps"); reusing the existing mechanism here costs nothing
            # and closes the gap for this one case.
            socket
            |> stream_insert(:media_rows, row)
            |> assign(:announcement, row_update_announcement(row))
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp append_rows(socket, rows) do
    Enum.reduce(rows, socket, fn row, acc -> stream_insert(acc, :media_rows, row) end)
  end

  # 5b: builds the O(1) membership set `handle_info/2` uses to decide whether an incoming
  # "media:admin" broadcast's media_id is on the current page/filter at all.
  defp row_ids(rows), do: rows |> Enum.map(& &1.media_id) |> MapSet.new()

  defp maybe_push_focus(socket, []), do: socket

  defp maybe_push_focus(socket, [first | _]) do
    push_event(socket, "focus_media_row", %{id: row_dom_id(first)})
  end

  defp next_cursor([]), do: nil

  defp next_cursor(rows) do
    %{uploaded_at: ts, media_id: id} = List.last(rows)
    %{uploaded_at: ts, media_id: id}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Filter parsing (URL is the single source of truth — Technical Requirements §3)
  # ══════════════════════════════════════════════════════════════════════════

  defp parse_filters(params) do
    %{
      states: parse_states(params["state"]),
      mime_prefix: blank_to_nil(params["mime_prefix"]),
      uploader: blank_to_nil(params["uploader"]),
      uploaded_from: parse_int(params["uploaded_from"]),
      uploaded_to: parse_int(params["uploaded_to"])
    }
  end

  defp parse_states(nil), do: []
  defp parse_states(v) when is_binary(v), do: if(v in @all_states, do: [v], else: [])

  defp parse_states(v) when is_list(v) do
    v |> Enum.filter(&is_binary/1) |> Enum.filter(&(&1 in @all_states)) |> Enum.uniq()
  end

  defp parse_states(_), do: []

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_cursor(nil), do: nil
  defp parse_cursor(""), do: nil

  defp parse_cursor(encoded) when is_binary(encoded) do
    with {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         [ts_str, media_id] <- String.split(decoded, "|", parts: 2),
         {ts, ""} <- Integer.parse(ts_str) do
      %{uploaded_at: ts, media_id: media_id}
    else
      _ -> nil
    end
  end

  defp encode_cursor(%{uploaded_at: ts, media_id: id}) do
    Base.url_encode64("#{ts}|#{id}", padding: false)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Query composition (ADR-018 inline SQL — never string-interpolate user input)
  # ══════════════════════════════════════════════════════════════════════════

  @select_columns "media_id, filename, uploader_user_id, content_type, file_size, uploaded_at, state, scan_metadata"

  # `limit` is always a compile-time integer constant from a caller (never user
  # input) — safe to interpolate directly, same as every other LIMIT below.
  defp fetch_rows(filters, cursor, limit \\ @page_size + 1) do
    if Process.whereis(Nebu.Repo) do
      {where, params} = build_where(filters, cursor)

      sql = """
      SELECT #{@select_columns}
      FROM media_files
      WHERE #{where}
      ORDER BY uploaded_at DESC, media_id DESC
      LIMIT #{limit}
      """

      case Ecto.Adapters.SQL.query(Repo, sql, params) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &row_to_map/1)
        _ -> []
      end
    else
      []
    end
  end

  defp count_rows(filters) do
    if Process.whereis(Nebu.Repo) do
      {where, params} = build_where(filters, nil)
      sql = "SELECT COUNT(*) FROM media_files WHERE #{where}"

      case Ecto.Adapters.SQL.query(Repo, sql, params) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end
    else
      0
    end
  end

  # 5b: re-fetches ONE row fresh by media_id for the row-patch handler. The "media:admin"
  # broadcast payload only carries media_id/old_state/new_state — not the row's other
  # columns — so a full re-fetch (same @select_columns/row_to_map/1 shape as fetch_rows/3)
  # is the simplest way to patch the state-derived columns without corrupting the untouched
  # ones (filename, uploader, mime, size, uploaded_at). Returns `nil` if the row no longer
  # exists (defensive — a hard_deleted row is never physically removed per ADR-031, but this
  # guards against any future exception) or `Nebu.Repo` isn't running.
  defp fetch_row_by_id(media_id) do
    if Process.whereis(Nebu.Repo) do
      sql = "SELECT #{@select_columns} FROM media_files WHERE media_id = $1"

      case Ecto.Adapters.SQL.query(Repo, sql, [media_id]) do
        {:ok, %{rows: [row]}} -> row_to_map(row)
        _ -> nil
      end
    end
  end

  defp fetch_all_matching_ids(filters) do
    if Process.whereis(Nebu.Repo) do
      {where, params} = build_where(filters, nil)

      sql = """
      SELECT media_id FROM media_files
      WHERE #{where}
      ORDER BY uploaded_at DESC, media_id DESC
      LIMIT #{@select_all_cap + 1}
      """

      case Ecto.Adapters.SQL.query(Repo, sql, params) do
        {:ok, %{rows: rows}} ->
          ids = Enum.map(rows, fn [id] -> id end)

          if length(ids) > @select_all_cap do
            {Enum.take(ids, @select_all_cap), true}
          else
            {ids, false}
          end

        _ ->
          {[], false}
      end
    else
      {[], false}
    end
  end

  # Builds the WHERE clause + bound params incrementally (Technical Requirements §2).
  # Filter values are NEVER interpolated into the SQL string — every value travels as a
  # positional `$n` bind parameter; only the parameter INDEX (an integer we compute) is
  # interpolated into the template text.
  defp build_where(filters, cursor) do
    {conditions, params, next_idx} =
      [
        {non_empty(filters.states), :states},
        {filters.mime_prefix, :mime_prefix},
        {filters.uploader, :uploader},
        {filters.uploaded_from, :uploaded_from},
        {filters.uploaded_to, :uploaded_to}
      ]
      |> Enum.reduce({[], [], 1}, fn
        {nil, _kind}, acc ->
          acc

        {value, kind}, {conds, params, idx} ->
          {condition_sql(kind, idx), bound_value(kind, value)}
          |> then(fn {sql, bound} -> {[sql | conds], params ++ [bound], idx + 1} end)
      end)

    {cursor_sql, cursor_params} = cursor_clause(cursor, next_idx)
    all_conditions = Enum.reverse(conditions) ++ List.wrap(cursor_sql)

    where = if all_conditions == [], do: "TRUE", else: Enum.join(all_conditions, " AND ")
    {where, params ++ cursor_params}
  end

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp condition_sql(:states, idx), do: "state = ANY($#{idx}::media_state[])"
  defp condition_sql(:mime_prefix, idx), do: "content_type LIKE $#{idx}"
  defp condition_sql(:uploader, idx), do: "uploader_user_id ILIKE $#{idx}"
  defp condition_sql(:uploaded_from, idx), do: "uploaded_at >= $#{idx}"
  defp condition_sql(:uploaded_to, idx), do: "uploaded_at <= $#{idx}"

  defp bound_value(:mime_prefix, value), do: value <> "%"
  defp bound_value(:uploader, value), do: "%" <> value <> "%"
  defp bound_value(_kind, value), do: value

  # Keyset predicate: strictly "older" than the last row seen, tie-broken by media_id.
  defp cursor_clause(nil, _next_idx), do: {nil, []}

  defp cursor_clause(%{uploaded_at: ts, media_id: id}, next_idx) do
    {"(uploaded_at, media_id) < ($#{next_idx}, $#{next_idx + 1})", [ts, id]}
  end

  defp row_to_map([
         media_id,
         filename,
         uploader_user_id,
         content_type,
         file_size,
         uploaded_at,
         state,
         scan_metadata
       ]) do
    %{
      media_id: media_id,
      filename: filename,
      uploader_user_id: uploader_user_id,
      content_type: content_type,
      file_size: file_size,
      uploaded_at: uploaded_at,
      state: state,
      scan_metadata: scan_metadata || %{}
    }
  end

  # ══════════════════════════════════════════════════════════════════════════
  # handle_event — filters, pagination, multi-select
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def handle_event("toggle_state", %{"state" => state}, socket) do
    states = socket.assigns.filters.states
    new_states = if state in states, do: List.delete(states, state), else: states ++ [state]
    new_filters = %{socket.assigns.filters | states: new_states}
    {:noreply, push_patch(socket, to: media_path(new_filters))}
  end

  def handle_event("filter_changed", params, socket) do
    new_filters = %{
      states: socket.assigns.filters.states,
      mime_prefix: blank_to_nil(params["mime_prefix"]),
      uploader: blank_to_nil(params["uploader"]),
      uploaded_from: date_param_to_ms(params["uploaded_from"], :from),
      uploaded_to: date_param_to_ms(params["uploaded_to"], :to)
    }

    {:noreply, push_patch(socket, to: media_path(new_filters))}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, push_patch(socket, to: media_path(socket.assigns.filters, socket.assigns.cursor))}
  end

  def handle_event("toggle_select", %{"media_id" => media_id}, socket) do
    selected = socket.assigns.selected_ids

    new_selected =
      if MapSet.member?(selected, media_id) do
        MapSet.delete(selected, media_id)
      else
        MapSet.put(selected, media_id)
      end

    {:noreply,
     socket
     |> assign(:selected_ids, new_selected)
     |> assign(:select_all_active, false)
     # code-review self-fix: an individual toggle after "select all" must not
     # leave the truncation notice ("Auswahl auf N begrenzt") stranded on
     # screen once select_all_active itself has flipped false — both flags
     # describe the SAME "select all" action and must clear together.
     |> assign(:select_all_truncated, false)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    if socket.assigns.select_all_active do
      {:noreply,
       socket
       |> assign(:select_all_active, false)
       |> assign(:selected_ids, MapSet.new())
       |> assign(:select_all_truncated, false)}
    else
      {ids, truncated} = fetch_all_matching_ids(socket.assigns.filters)

      {:noreply,
       socket
       |> assign(:select_all_active, true)
       |> assign(:selected_ids, MapSet.new(ids))
       |> assign(:select_all_truncated, truncated)}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # handle_event — routine admin actions (media-security-admin-control/
  # 6a-routine-state-actions): Block/Unblock/Delete/Rescan. Every action goes
  # through Nebu.Media's new admin_* public functions (ADR-020) — this module
  # never calls Nebu.Media.StateMachine directly. A successful state
  # transition's own row-patch (badge update) arrives for free via the
  # EXISTING 5b "media:admin" broadcast + this module's own handle_info/2
  # clause above — no manual stream_insert/3 needed here for Block/Unblock/
  # Delete. Rescan (AC4) never calls StateMachine.transition/4 at all, so the
  # row's state deliberately does not change here — only the flash confirms
  # the job was queued.
  # ══════════════════════════════════════════════════════════════════════════

  def handle_event("block", %{"media_id" => media_id, "reason" => reason}, socket) do
    admin_id = actor_id(socket.assigns.current_user)

    case Nebu.Media.admin_block(media_id, admin_id, blank_to_nil(reason)) do
      {:ok, :admin_blocked} ->
        log_admin_media_action("media_blocked", media_id)
        {:noreply, action_flash(socket, :info, "Datei gesperrt.")}

      {:ok, :already_blocked} ->
        {:noreply, action_flash(socket, :info, "Bereits gesperrt.")}

      {:error, {:invalid_transition, _from, _to}} ->
        {:noreply,
         action_flash(socket, :error, "Datei kann in diesem Status nicht gesperrt werden.")}

      {:error, :not_found} ->
        {:noreply, action_flash(socket, :error, "Datei nicht gefunden.")}

      # Defensive catch-all (AC8: "never a silent, unexplained failure") —
      # e.g. {:error, :invalid_actor}, which Nebu.Media.StateMachine.transition/4
      # would return if actor_id/1 ever yielded nil (should not happen behind
      # the on_mount :require_admin gate, since every admin session's
      # current_user always carries matrix_user_id — but a CaseClauseError
      # crash here would itself violate this AC far worse than a generic flash).
      {:error, _reason} ->
        {:noreply, action_flash(socket, :error, "Aktion fehlgeschlagen.")}
    end
  end

  def handle_event("unblock", %{"media_id" => media_id}, socket) do
    admin_id = actor_id(socket.assigns.current_user)

    case Nebu.Media.admin_unblock(media_id, admin_id) do
      {:ok, :released} ->
        log_admin_media_action("media_unblocked", media_id)
        {:noreply, action_flash(socket, :info, "Datei entsperrt.")}

      {:ok, :already_released} ->
        {:noreply, action_flash(socket, :info, "Bereits freigegeben.")}

      {:error, {:invalid_transition, _from, _to}} ->
        {:noreply,
         action_flash(socket, :error, "Datei kann in diesem Status nicht entsperrt werden.")}

      {:error, :not_found} ->
        {:noreply, action_flash(socket, :error, "Datei nicht gefunden.")}

      {:error, _reason} ->
        {:noreply, action_flash(socket, :error, "Aktion fehlgeschlagen.")}
    end
  end

  def handle_event("open_delete_confirm", %{"media_id" => media_id}, socket) do
    {:noreply, assign(socket, :confirm_delete_media_id, media_id)}
  end

  def handle_event("cancel_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_media_id, nil)}
  end

  def handle_event("confirm_delete", %{"media_id" => media_id}, socket) do
    admin_id = actor_id(socket.assigns.current_user)
    socket = assign(socket, :confirm_delete_media_id, nil)

    case Nebu.Media.admin_delete(media_id, admin_id) do
      {:ok, :deleted} ->
        log_admin_media_action("media_deleted", media_id)
        {:noreply, action_flash(socket, :info, "Datei gelöscht.")}

      {:error, {:invalid_transition, _from, _to}} ->
        {:noreply,
         action_flash(socket, :error, "Datei kann in diesem Status nicht gelöscht werden.")}

      {:error, :not_found} ->
        {:noreply, action_flash(socket, :error, "Datei nicht gefunden.")}

      {:error, _reason} ->
        {:noreply, action_flash(socket, :error, "Aktion fehlgeschlagen.")}
    end
  end

  def handle_event("rescan", %{"media_id" => media_id}, socket) do
    admin_id = actor_id(socket.assigns.current_user)

    # `Nebu.Media.admin_rescan/2`'s own @spec is closed to exactly
    # `{:ok, :rescan_queued} | {:error, :invalid_state_for_rescan} | {:error, :not_found}`
    # (unlike admin_block/3, admin_unblock/2, admin_delete/2, which route
    # through `state_machine_module().transition/4` and its own
    # `{:error, {:invalid_transition, atom(), atom()}}` shape) — rescan never
    # calls `transition/4` at all (see `Nebu.Media.admin_rescan/2`'s own
    # comment), so a trailing `{:error, _reason}` catch-all here is
    # unreachable dead code per the compiler's own type-checker, not a
    # defensive branch. Removed rather than silenced.
    case Nebu.Media.admin_rescan(media_id, admin_id) do
      {:ok, :rescan_queued} ->
        log_admin_media_action("media_rescanned", media_id)
        {:noreply, action_flash(socket, :info, "Erneute Prüfung eingeplant.")}

      {:error, :invalid_state_for_rescan} ->
        {:noreply,
         action_flash(socket, :error, "Datei kann derzeit nicht erneut geprüft werden.")}

      {:error, :not_found} ->
        {:noreply, action_flash(socket, :error, "Datei nicht gefunden.")}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # handle_event — infected override (media-security-admin-control/
  # 6c-infected-override): gated by the distinct media_admin_override grant
  # (AC6), with its own escalated-warning confirm modal (AC7). Mirrors 6a's
  # Delete confirm-modal event trio (open_delete_confirm/cancel_delete_confirm/
  # confirm_delete) exactly, substituting "override" for "delete". The real
  # enforcement (reason validation, role re-check) lives entirely in
  # Nebu.Media.admin_override_infected/3 — this handler never duplicates
  # that logic, it only forwards params and maps the result to a flash.
  # ══════════════════════════════════════════════════════════════════════════

  def handle_event("open_override_confirm", %{"media_id" => media_id}, socket) do
    if socket.assigns.media_admin_override? do
      {:noreply, assign(socket, confirm_override_media_id: media_id, override_reason: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_override_confirm", _params, socket) do
    {:noreply, assign(socket, confirm_override_media_id: nil, override_reason: "")}
  end

  # EXPERIENCE.md (confirm-dialog pattern): "Override's confirm stays disabled
  # until the reason is non-empty." Tracks the textarea's live value in
  # @override_reason so the submit button's `disabled={trimmed empty?}`
  # binding below reflects each keystroke — a client-side UX affordance only;
  # AC2's real enforcement is entirely server-side in
  # Nebu.Media.admin_override_infected/3's own validate_reason/1 (a forged/
  # scripted submit bypassing this event entirely still gets rejected there).
  def handle_event("validate_override_reason", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, override_reason: reason)}
  end

  def handle_event("confirm_override", %{"media_id" => media_id, "reason" => reason}, socket) do
    admin_id = actor_id(socket.assigns.current_user)

    case Nebu.Media.admin_override_infected(media_id, admin_id, reason) do
      {:ok, :released} ->
        log_admin_media_action("media_infected_override", media_id)

        {:noreply,
         socket
         |> assign(confirm_override_media_id: nil, override_reason: "")
         |> action_flash(:info, "Datei aus dem Infiziert-Status freigegeben.")}

      # AC2/AC8: a blank/whitespace-only reason keeps the modal open (same
      # media_id) with a visible validation error — never a silent close, and
      # never pre-filling/caching the rejected value back into the textarea
      # (AC8: override_reason always resets to "", exactly like
      # open_override_confirm/cancel_override_confirm above — there is no
      # caching mechanism anywhere in this write path).
      {:error, :reason_required} ->
        {:noreply,
         socket
         |> assign(confirm_override_media_id: media_id, override_reason: "")
         |> action_flash(:error, "Eine Begründung ist für diese Aktion erforderlich.")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(confirm_override_media_id: nil, override_reason: "")
         |> action_flash(:error, "Sie sind nicht berechtigt, diese Aktion durchzuführen.")}

      {:error, {:invalid_transition, _from, _to}} ->
        {:noreply,
         socket
         |> assign(confirm_override_media_id: nil, override_reason: "")
         |> action_flash(:error, "Datei ist für diese Aktion nicht mehr geeignet.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(confirm_override_media_id: nil, override_reason: "")
         |> action_flash(:error, "Datei nicht gefunden.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(confirm_override_media_id: nil, override_reason: "")
         |> action_flash(:error, "Aktion fehlgeschlagen.")}
    end
  end

  # Same shape/extraction convention as Nebu.Admin.UsersController.actor_id/1
  # (conn-based there; socket.assigns-based here) — matrix_user_id, falling
  # back to sub. Always a Matrix-ID string, never a UUID (see migration
  # 000029_media_state_transitions_actor_id_text's Dev Notes).
  defp actor_id(current_user) do
    case current_user do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> nil
    end
  end

  # media-security-admin-control/10e-trace-map-war-room-integration (AC3):
  # fired immediately alongside (never instead of) the pre-existing
  # Nebu.Compliance.AuditWriter.log/6 call each Nebu.Media.admin_* function
  # already performs (see lib/nebu/media.ex's own write_admin_audit/4) — a
  # second, independent operational-visibility channel, not a new
  # compliance-audit action (no AuditWriter.@known_actions change). `action`
  # is the SAME action string Nebu.Media's write_admin_audit/4 already uses
  # for this call site — reused literally here since that string lives in
  # Nebu.Media, not as a variable this LiveView's own handle_event/3 clauses
  # have in scope.
  #
  # code-review cycle 2 (MAJOR-2): Logger.info/2, exactly as AC3's Technical
  # Requirements specify — the previous cycle had substituted Logger.warning/2
  # here to route around a test-env primary-Logger-level gap
  # (config/test.exs sets the level to :warning) instead of fixing the test
  # visibility itself. That gap is now fixed properly: the "10e AC3" describe
  # block in media_live_test.exs raises the Logger level to :info for its own
  # tests (mirroring request_logger_test.exs's Logger.configure(level: :info)
  # precedent), so this call is observable there without deviating from the
  # AC-specified severity.
  defp log_admin_media_action(action, media_id) do
    Logger.info(
      "admin media action: #{action}",
      route_template: "/admin/media",
      request_id: media_id
    )
  end

  # AC8/AC9: a visible flash. This admin layout does NOT render Phoenix's
  # built-in @flash (same fact Nebu.Admin.LogsLive.TraceMap's own
  # @cascade_flash and Nebu.Admin.LogsLive.WarRoom's own @copy_toast are
  # already built around) — a dedicated assign, rendered by this module's own
  # template, is the established convention for a visible action-result
  # message in this codebase.
  defp action_flash(socket, type, message) when type in [:info, :error] do
    assign(socket, :action_flash, %{type: type, message: message})
  end

  defp date_param_to_ms(nil, _bound), do: nil
  defp date_param_to_ms("", _bound), do: nil

  defp date_param_to_ms(date_str, bound) when is_binary(date_str) do
    with {:ok, date} <- Date.from_iso8601(date_str) do
      time = if bound == :from, do: ~T[00:00:00], else: ~T[23:59:59]

      date
      |> NaiveDateTime.new!(time)
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.to_unix(:millisecond)
    else
      _ -> nil
    end
  end

  defp date_param_to_ms(_other, _bound), do: nil

  # ══════════════════════════════════════════════════════════════════════════
  # URL building (mirrors Nebu.Admin.LogsLive.TraceMap's patch_path/1 pattern)
  # ══════════════════════════════════════════════════════════════════════════

  defp media_path(filters, cursor \\ nil) do
    parts =
      Enum.map(filters.states, fn s -> "state%5B%5D=" <> URI.encode_www_form(s) end) ++
        kv("mime_prefix", filters.mime_prefix) ++
        kv("uploader", filters.uploader) ++
        kv("uploaded_from", filters.uploaded_from) ++
        kv("uploaded_to", filters.uploaded_to) ++
        cursor_kv(cursor)

    case parts do
      [] -> "/admin/media"
      _ -> "/admin/media?" <> Enum.join(parts, "&")
    end
  end

  defp kv(_key, nil), do: []
  defp kv(_key, ""), do: []
  defp kv(key, val) when is_integer(val), do: [key <> "=" <> Integer.to_string(val)]
  defp kv(key, val) when is_binary(val), do: [key <> "=" <> URI.encode_www_form(val)]

  defp cursor_kv(nil), do: []
  defp cursor_kv(cursor), do: ["cursor=" <> encode_cursor(cursor)]

  defp any_filter_active?(filters) do
    filters.states != [] or not is_nil(filters.mime_prefix) or not is_nil(filters.uploader) or
      not is_nil(filters.uploaded_from) or not is_nil(filters.uploaded_to)
  end

  # AC10 (accessibility hard constraint): the table caption must DESCRIBE the
  # active filter, not just note that filtering is happening — a screen-reader
  # user navigating straight to the table needs to know WHICH filter narrowed
  # the result set, not only that one exists.
  defp filter_summary(filters) do
    parts =
      [
        if(filters.states != [],
          do: "Status: " <> Enum.map_join(filters.states, ", ", &badge_label/1)
        ),
        if(filters.mime_prefix, do: "MIME-Typ: " <> filters.mime_prefix <> "*"),
        if(filters.uploader, do: "Uploader: " <> filters.uploader),
        if(filters.uploaded_from || filters.uploaded_to, do: "Zeitraum eingeschränkt")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> ""
      _ -> " (gefiltert — " <> Enum.join(parts, "; ") <> ")"
    end
  end

  defp result_announcement(0, filters) do
    if any_filter_active?(filters),
      do: "Keine Treffer — Filter anpassen",
      else: "Noch keine Medien hochgeladen."
  end

  defp result_announcement(count, _filters), do: "#{count} Medien gefunden"

  defp load_more_announcement(new_count, total_loaded, total_matching) do
    "#{new_count} weitere geladen, #{total_loaded} von #{total_matching} geladen"
  end

  # 5b / UX gate: announces a live row patch through the same sr-only channel as
  # every other dynamic change on this page (filter results, "Weitere laden").
  defp row_update_announcement(row) do
    name =
      case identity_display(row.filename, row.media_id) do
        {:code, val} -> val
        {:text, val} -> val
      end

    "Status von #{name} geändert zu #{badge_label(row.state)}"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Render helpers
  # ══════════════════════════════════════════════════════════════════════════

  # `badge_group/1`/`badge_label/1`/`humanize_bytes/1` are `def` (not `defp`) —
  # media-security-admin-control/6b-file-detail-storage-summary's own Technical
  # Requirements ask the detail view to "reuse/extract" this module's badge
  # palette and byte-formatting helper "rather than re-deriving the same
  # rounding logic twice"; `Nebu.Admin.MediaLive.Detail` calls these three
  # directly instead of duplicating the palette/rounding rules a second time.
  def badge_group(state), do: elem(Map.get(@badge_groups, state, {"media-terminal", state}), 0)
  def badge_label(state), do: elem(Map.get(@badge_groups, state, {"media-terminal", state}), 1)

  def humanize_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{round_1(bytes / 1_000_000_000)} GB"
      bytes >= 1_000_000 -> "#{round_1(bytes / 1_000_000)} MB"
      bytes >= 1_000 -> "#{round_1(bytes / 1_000)} KB"
      true -> "#{bytes} B"
    end
  end

  def humanize_bytes(_), do: "—"

  defp round_1(n), do: Float.round(n / 1, 1)

  # Reuses server/lib/nebu/admin/users_html.ex's format_ts/1 pattern exactly
  # (Technical Requirements §7) rather than inventing a new conversion.
  defp format_ts(nil), do: "—"

  defp format_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> "—"
    end
  end

  defp format_ts(_), do: "—"

  defp scanned_at(scan_metadata), do: scan_metadata |> Map.get("scanned_at") |> present_or_dash()

  defp clamav_signature(scan_metadata),
    do: scan_metadata |> Map.get("clamav_signature") |> present_or_dash()

  defp present_or_dash(nil), do: "—"
  defp present_or_dash(""), do: "—"
  defp present_or_dash(value), do: to_string(value)

  defp identity_display(nil, media_id), do: {:code, media_id}
  defp identity_display("", media_id), do: {:code, media_id}
  defp identity_display(filename, _media_id), do: {:text, filename}

  defp uploader_display(nil), do: "—"
  defp uploader_display(""), do: "—"
  defp uploader_display(uploader), do: uploader

  # Deliberate lifecycle-order pill list (not @badge_groups' arbitrary Map.keys/1
  # order) — mirrors the state machine's own progression.
  @state_order [
    "reserved",
    "quarantined",
    "scanning",
    "scan_failed",
    "released",
    "infected",
    "admin_blocked",
    "deleted",
    "hard_deleted"
  ]

  defp state_pill_order, do: @state_order
  defp select_all_cap, do: @select_all_cap

  defp date_input_value(nil), do: nil

  defp date_input_value(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> dt |> DateTime.to_date() |> Date.to_iso8601()
      _ -> nil
    end
  end

  defp date_input_value(_), do: nil

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Medien</h1>

    <div aria-live="polite" role="status" class="sr-only">{@announcement}</div>

    <%!-- media-security-admin-control/6a-routine-state-actions (AC8/AC9): a
          visible flash. This admin layout does NOT render Phoenix's built-in
          @flash (Nebu.Admin.LogsLive.TraceMap's own @cascade_flash / Nebu.Admin.
          LogsLive.WarRoom's own @copy_toast are already built around the same
          fact) — this dedicated assign is the established substitute. --%>
    <p
      :if={@action_flash}
      data-testid="media-action-flash"
      class={["alert mb-4", if(@action_flash.type == :error, do: "alert-error", else: "alert-success")]}
      role={if @action_flash.type == :error, do: "alert", else: "status"}
    >
      {@action_flash.message}
    </p>

    <div class="mb-4 space-y-4">
      <div role="group" aria-labelledby="media-state-filter-label" class="space-y-1">
        <span id="media-state-filter-label" class="text-caption uppercase text-text-secondary">
          Status
        </span>
        <div class="flex flex-wrap gap-2">
          <button
            :for={state <- state_pill_order()}
            type="button"
            phx-click="toggle_state"
            phx-value-state={state}
            aria-pressed={to_string(state in @filters.states)}
            class={[
              "badge badge-sm cursor-pointer",
              "focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200",
              if(state in @filters.states, do: "badge-primary", else: "badge-outline")
            ]}
          >
            {badge_label(state)}
          </button>
        </div>
      </div>

      <form id="media-filter-form" phx-change="filter_changed" class="flex flex-wrap gap-4 items-end">
        <div class="form-control">
          <label for="media-filter-mime" class="label-text-alt">MIME-Typ</label>
          <input
            type="text"
            id="media-filter-mime"
            name="mime_prefix"
            value={@filters.mime_prefix}
            placeholder="z. B. application/pdf"
            class="input input-bordered input-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
          />
        </div>
        <div class="form-control">
          <label for="media-filter-uploader" class="label-text-alt">Uploader</label>
          <input
            type="text"
            id="media-filter-uploader"
            name="uploader"
            value={@filters.uploader}
            placeholder="@user:server"
            class="input input-bordered input-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
          />
        </div>
        <div class="form-control">
          <label for="media-filter-from" class="label-text-alt">Von</label>
          <input
            type="date"
            id="media-filter-from"
            name="uploaded_from"
            value={date_input_value(@filters.uploaded_from)}
            class="input input-bordered input-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
          />
        </div>
        <div class="form-control">
          <label for="media-filter-to" class="label-text-alt">Bis</label>
          <input
            type="date"
            id="media-filter-to"
            name="uploaded_to"
            value={date_input_value(@filters.uploaded_to)}
            class="input input-bordered input-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
          />
        </div>
      </form>
    </div>

    <div
      :if={MapSet.size(@selected_ids) > 0}
      class="mb-4 p-3 rounded bg-base-200 border border-base-300 flex items-center justify-between gap-4"
      role="region"
      aria-label="Auswahl-Aktionen"
    >
      <span>{MapSet.size(@selected_ids)} ausgewählt</span>
      <span :if={@select_all_truncated} class="text-caption text-warning">
        Auswahl auf {select_all_cap()} begrenzt
      </span>
    </div>

    <p :if={@result_count == 0} class="text-text-secondary">
      <%= if any_filter_active?(@filters) do %>
        Keine Treffer — Filter anpassen
      <% else %>
        Noch keine Medien hochgeladen.
      <% end %>
    </p>

    <div :if={@result_count > 0} class="overflow-x-auto">
      <table class="table table-zebra">
        <caption class="sr-only">
          Medienliste, {@result_count} Treffer{filter_summary(@filters)}
        </caption>
        <thead>
          <tr>
            <th scope="col">
              <input
                type="checkbox"
                aria-label="Alle Medien der aktuellen Filterung auswählen"
                checked={@select_all_active}
                phx-click="toggle_select_all"
                class="checkbox checkbox-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
              />
            </th>
            <th scope="col">Status</th>
            <th scope="col">Dateiname</th>
            <th scope="col">Uploader</th>
            <th scope="col">MIME-Typ</th>
            <th scope="col">Größe</th>
            <th scope="col">Hochgeladen</th>
            <th scope="col">Geprüft</th>
            <th scope="col">ClamAV-Signatur</th>
            <th scope="col">Aktionen</th>
          </tr>
        </thead>
        <tbody id="media-rows" phx-update="stream">
          <tr
            :for={{dom_id, row} <- @streams.media_rows}
            id={dom_id}
            data-role="media-row"
            data-media-id={row.media_id}
            data-state={row.state}
          >
            <td>
              <input
                type="checkbox"
                aria-label={"Medium #{row.media_id} auswählen"}
                checked={MapSet.member?(@selected_ids, row.media_id)}
                phx-click="toggle_select"
                phx-value-media_id={row.media_id}
                class="checkbox checkbox-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
              />
            </td>
            <td>
              <span class={["badge badge-sm", "media-badge--#{badge_group(row.state)}"]}>
                <svg
                  aria-hidden="true"
                  class="inline-block w-3 h-3 mr-1"
                  viewBox="0 0 12 12"
                  fill="currentColor"
                >
                  <circle cx="6" cy="6" r="5" />
                </svg>
                {badge_label(row.state)}
              </span>
            </td>
            <td class="font-mono text-mono">
              <%= case identity_display(row.filename, row.media_id) do %>
                <% {:code, val} -> %>
                  <code>{val}</code>
                <% {:text, val} -> %>
                  {val}
              <% end %>
            </td>
            <td class="font-mono">{uploader_display(row.uploader_user_id)}</td>
            <td>{row.content_type}</td>
            <td>{humanize_bytes(row.file_size)}</td>
            <td class="whitespace-nowrap">{format_ts(row.uploaded_at)}</td>
            <td class="whitespace-nowrap">{scanned_at(row.scan_metadata)}</td>
            <td class="font-mono">{clamav_signature(row.scan_metadata)}</td>
            <td class="whitespace-nowrap">
              <div class="flex flex-wrap items-center gap-2">
                <.link
                  navigate={"/admin/media/" <> row.media_id}
                  class="link link-primary focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                >
                  Ansehen
                </.link>

                <%!-- media-security-admin-control/6a-routine-state-actions:
                      Block/Unblock/Rescan fire immediately (AC10, no modal).
                      An optional free-text reason (AC11) rides along with Block
                      as an ordinary form submit — still no modal, no window.confirm. --%>
                <form
                  :if={row.state == "released"}
                  id={"block-form-" <> row.media_id}
                  phx-submit="block"
                  class="inline-flex items-center gap-1"
                >
                  <input type="hidden" name="media_id" value={row.media_id} />
                  <label class="sr-only" for={"block-reason-" <> row.media_id}>
                    Grund für Sperrung (optional)
                  </label>
                  <input
                    type="text"
                    id={"block-reason-" <> row.media_id}
                    name="reason"
                    placeholder="Grund (optional)"
                    class="input input-bordered input-xs w-28 focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                  />
                  <button
                    type="submit"
                    class="btn btn-xs focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                  >
                    Sperren
                  </button>
                </form>

                <button
                  :if={row.state == "admin_blocked"}
                  type="button"
                  phx-click="unblock"
                  phx-value-media_id={row.media_id}
                  class="btn btn-xs focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                >
                  Entsperren
                </button>

                <button
                  :if={row.state in ["quarantined", "scan_failed"]}
                  type="button"
                  phx-click="rescan"
                  phx-value-media_id={row.media_id}
                  class="btn btn-xs focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                >
                  Erneut prüfen
                </button>

                <%!-- AC3/AC10: Delete is available from every state the guard table
                      allows a :deleted edge from (quarantined/released/admin_blocked/
                      infected/scan_failed — never reserved/scanning/deleted/hard_deleted).
                      Opens a confirm modal — never fires directly. --%>
                <button
                  :if={row.state in ["quarantined", "released", "admin_blocked", "infected", "scan_failed"]}
                  type="button"
                  id={"delete-trigger-" <> row.media_id}
                  phx-click="open_delete_confirm"
                  phx-value-media_id={row.media_id}
                  class="btn btn-xs btn-error focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                >
                  Löschen
                </button>

                <%!-- media-security-admin-control/6c-infected-override (AC1/AC6):
                      the narrow :infected -> :released false-positive override,
                      gated by the distinct media_admin_override grant (never the
                      standard admin gate alone) — the button itself is only
                      rendered for a session holding that grant. Opens a confirm
                      modal with an escalated warning — never fires directly. --%>
                <button
                  :if={row.state == "infected" and @media_admin_override?}
                  type="button"
                  id={"override-trigger-" <> row.media_id}
                  phx-click="open_override_confirm"
                  phx-value-media_id={row.media_id}
                  class="btn btn-xs btn-warning focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
                >
                  Freigeben (Override)
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div :if={@has_more} class="mt-4">
      <button
        type="button"
        id="load-more-btn"
        phx-click="load_more"
        phx-hook="MediaLoadMoreFocus"
        class="btn btn-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
      >
        Weitere laden
      </button>
    </div>

    <%!-- media-security-admin-control/6a-routine-state-actions (AC10): CSP-safe
          Delete confirm modal. No window.confirm. No `position: fixed` (epic's
          explicit constraint) — `absolute inset-0` instead, which (with no
          positioned ancestor in this LiveView's own template) covers the full
          document and scrolls with it, rather than staying pinned like `fixed`. --%>
    <div
      :if={@confirm_delete_media_id}
      id="media-delete-confirm-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="media-delete-confirm-title"
      phx-hook="MediaDeleteConfirmModal"
      phx-window-keydown="cancel_delete_confirm"
      phx-key="Escape"
      data-trigger-id={"delete-trigger-" <> @confirm_delete_media_id}
      class="absolute inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <div class="bg-base-100 rounded-lg p-6 max-w-sm w-full shadow-xl">
        <h2 id="media-delete-confirm-title" class="text-lg font-semibold mb-2">
          Datei löschen?
        </h2>
        <p class="mb-4 text-text-secondary">
          Die Datei wird als gelöscht markiert (Soft-Delete). Diese Aktion kann über die
          Admin-Oberfläche nicht rückgängig gemacht werden.
        </p>
        <div class="flex justify-end gap-2">
          <button
            type="button"
            id="media-delete-confirm-cancel"
            phx-click="cancel_delete_confirm"
            class="btn btn-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
            autofocus
          >
            Abbrechen
          </button>
          <button
            type="button"
            id="media-delete-confirm-submit"
            phx-click="confirm_delete"
            phx-value-media_id={@confirm_delete_media_id}
            class="btn btn-sm btn-error focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
          >
            Endgültig löschen
          </button>
        </div>
      </div>
    </div>

    <%!-- media-security-admin-control/6c-infected-override (AC7): CSP-safe
          Override confirm modal — same family as the Delete confirm modal
          above (no window.confirm, no `position: fixed`, real Tab-trap via
          its own JS hook, Escape-cancels via phx-window-keydown, destructive
          action never default-focused), extended with the mandatory
          server-validated (AC2) reason input and the literal escalated
          warning copy the epic specifies. The confirm button stays disabled
          while the trimmed reason is empty — a client-side UX affordance
          only; AC2's real enforcement is entirely server-side in
          Nebu.Media.admin_override_infected/3's own validate_reason/1. --%>
    <div
      :if={@confirm_override_media_id}
      id="media-override-confirm-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="media-override-confirm-title"
      phx-hook="MediaOverrideConfirmModal"
      phx-window-keydown="cancel_override_confirm"
      phx-key="Escape"
      data-trigger-id={"override-trigger-" <> @confirm_override_media_id}
      class="absolute inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <div class="bg-base-100 rounded-lg p-6 max-w-sm w-full shadow-xl">
        <h2 id="media-override-confirm-title" class="text-lg font-semibold mb-2">
          Infiziert-Status überschreiben?
        </h2>
        <p class="mb-4 text-text-secondary font-semibold">
          Diese Datei wurde als Malware erkannt. Freigabe erfolgt auf eigene Verantwortung.
        </p>
        <form
          id={"override-confirm-form-" <> @confirm_override_media_id}
          phx-submit="confirm_override"
          phx-change="validate_override_reason"
        >
          <input type="hidden" name="media_id" value={@confirm_override_media_id} />
          <div class="form-control mb-4 text-left">
            <label class="label-text-alt" for="override-reason-input">
              Begründung (erforderlich)
            </label>
            <textarea
              id="override-reason-input"
              name="reason"
              required
              class="textarea textarea-bordered textarea-sm w-full focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
            >{@override_reason}</textarea>
          </div>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              id="media-override-confirm-cancel"
              phx-click="cancel_override_confirm"
              class="btn btn-sm focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
              autofocus
            >
              Abbrechen
            </button>
            <button
              type="submit"
              id="media-override-confirm-submit"
              disabled={String.trim(@override_reason) == ""}
              class="btn btn-sm btn-warning focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200"
            >
              Freigabe bestätigen
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
