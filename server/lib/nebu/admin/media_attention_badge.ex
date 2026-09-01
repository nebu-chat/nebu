defmodule Nebu.Admin.MediaAttentionBadge do
  @moduledoc """
  Shared helper for the admin nav "attention" badge
  (media-security-admin-control/5b-live-updates-nav-badges, AC2-AC4).

  Mirrors `Nebu.Admin.WarRoomIndicator`'s shape exactly: a small, stateless helper module
  that every relevant admin LiveView calls from its own `mount/3` (subscribe + initial
  assign) and `handle_info/2` (delegate on a PubSub message), rather than duplicating this
  cross-cutting concern six times over.

  ## The six LiveViews (corrected 2026-07-18 — see the story's own Summary correction)

  `server/lib/nebu/admin/router.ex`'s `live_session :admin` block declares six LiveViews:
  `Nebu.Admin.DashboardLive`, `Nebu.Admin.AuditLogLive`, `Nebu.Admin.LogsLive`,
  `Nebu.Admin.LogsLive.TraceMap`, `Nebu.Admin.LogsLive.WarRoom`, and
  `Nebu.Admin.MediaLive` (5a) — every one of them calls `subscribe/0` + `initial_count/0`
  in `mount/3` and adds one `handle_info/2` clause delegating to `apply_transition/3`. All
  six already carry the identical `Nebu.Admin.WarRoomIndicator` wiring precedent this badge
  mirrors. Users/Rooms/Spaces/Config remain plain dead-render controllers (no persistent
  process to receive a PubSub message) and are correctly out of scope — see the story's
  two-tier note in its Summary.

  ## Design: one `COUNT` at mount, zero queries per broadcast thereafter

  `initial_count/0` runs a single inline `COUNT` query (ADR-018 — no Ecto schema, no
  Repository/Service layer) over the exact 3-state attention set. Every subsequent
  `"media:admin"` broadcast adjusts the already-assigned integer via `classify/1`'s
  delta — no DB round-trip per broadcast. This intentionally does NOT introduce a second
  persistent data structure (a maintained counter column/table) — see the story's Technical
  Requirements for why: `media_files.state` is already the source of truth, ADR-018
  discourages new aggregate structures where a query suffices, and a `COUNT` is one query per
  connected *admin session*, not per media event.

  Each LiveView keeps its own `socket.assigns.media_attention_count` — there is no shared
  mutable counter one session could race against another's (AC4). A fresh mount/reconnect
  always re-derives from `initial_count/0`, so drift from a missed broadcast is bounded to
  the remaining lifetime of that one LiveView process and self-heals on next navigation or
  remount (AC4).
  """

  import Phoenix.Component, only: [assign: 3]

  @topic "media:admin"

  # AC2: the exact attention state set — :quarantined, :scan_failed, :infected. Deliberately
  # excludes :reserved/:scanning (nothing actionable yet), :admin_blocked (already a
  # deliberate admin action), and the terminal states :released/:deleted/:hard_deleted
  # (resolved). Kept as both a string list (for the inline SQL `ANY($1::media_state[])`
  # filter, matching `Nebu.Admin.MediaLive`'s own `condition_sql(:states, idx)` casting
  # convention) and an atom list (`classify/1` receives atoms off the `"media:admin"`
  # broadcast payload, matching `Nebu.Media.StateMachine`'s `state()` type).
  @attention_states_sql ["quarantined", "scan_failed", "infected"]
  @attention_states_atoms [:quarantined, :scan_failed, :infected]

  @sql_count "SELECT count(*) FROM media_files WHERE state = ANY($1::media_state[])"

  @doc "Subscribes the calling (LiveView) process to the broad `\"media:admin\"` topic."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Nebu.PubSub, @topic)

  @doc """
  A live `COUNT` of `media_files` currently in one of the 3 attention states
  (`:quarantined`, `:scan_failed`, `:infected`) — `0` when `Nebu.Repo` is not running (plain
  unit-test runs), mirroring every other DB-guarded helper in this codebase
  (`Nebu.Admin.WarRoomIndicator.status/0`).
  """
  @spec initial_count() :: non_neg_integer()
  def initial_count do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_count, [@attention_states_sql]) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end
    else
      0
    end
  end

  @doc """
  `1` if `state` is one of the 3 attention states, `0` otherwise. Accepts the atom shape
  broadcast on `"media:admin"` (`Nebu.Media.StateMachine`'s `state()` type) — any other
  input (including `nil`, e.g. a genesis transition's `from_state`) classifies as `0`.
  """
  @spec classify(atom()) :: 0 | 1
  def classify(state) when state in @attention_states_atoms, do: 1
  def classify(_state), do: 0

  @doc """
  Adjusts `socket.assigns.media_attention_count` by `classify(new_state) - classify(old_state)`
  — `+1` entering the attention set, `-1` leaving it, `0` otherwise (AC2/AC4). `assign_new`-safe:
  if `:media_attention_count` was never assigned (a LiveView that hasn't called `initial_count/0`
  for any reason), this treats the prior value as `0` rather than raising.
  """
  @spec apply_transition(Phoenix.LiveView.Socket.t(), atom() | nil, atom()) ::
          Phoenix.LiveView.Socket.t()
  def apply_transition(socket, old_state, new_state) do
    current = Map.get(socket.assigns, :media_attention_count) || 0
    delta = classify(new_state) - classify(old_state)
    assign(socket, :media_attention_count, current + delta)
  end
end
