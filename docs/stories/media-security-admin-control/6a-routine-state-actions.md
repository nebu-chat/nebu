---
story_id: 6a-routine-state-actions
title: "Admin Media Actions: Routine State Actions (Block/Unblock/Delete/Rescan)"
epic: media-security-admin-control
status: done
security_review: required
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 5a gives admins a read-only `/admin/media` table. This story adds the first write-path
surface on top of it: four routine, non-Two-Eyes admin actions per row — **Block**, **Unblock**,
**Delete** (soft), **Rescan**. Every action is a thin `Nebu.Media` public-API call (ADR-020) that
does exactly two things transactionally-adjacent to each other: (1) drive `media_files.state`
through `Nebu.Media.StateMachine.transition/4` (Story 1b) — the **only** legal write path into
`state` — and (2) bridge a compliance-relevant admin action into the global `audit_log` via
`Nebu.Compliance.AuditWriter.log/6` (the same bridge pattern Story 4c established for
system-driven `:infected`/`scan_failed` events, per ADR-028).

Two properties are load-bearing and both are already-solved problems elsewhere in this epic that
this story must not regress: the **anonymity of Block** (1c/ADR-026 — a blocked file's download
response must stay byte-identical to a genuine 404, this story must not accidentally introduce a
distinguishing signal anywhere in the write path) and the **known-actions allowlist gotcha**
(`AuditWriter.@known_actions` — a new action string that isn't added to the allowlist in the same
commit doesn't error loudly, it silently degrades to `{:error, :audit_unknown_action}` and the
audit trail quietly loses coverage for exactly the actions this story exists to make auditable).

## User Story

As an admin operating `/admin/media`, I want to Block, Unblock, Delete, or Rescan a media file
directly from its row, with every action enforced by the state machine's guard and recorded both
in the file's own transition history and in the global compliance audit log, so that routine
moderation and cleanup actions are safe, reversible where the state machine allows it, and fully
accountable to a specific admin identity.

## Acceptance Criteria

1. **AC1 — Block: `:released → :admin_blocked`.** The anonymity requirement established by Story
   1c/ADR-026 continues to hold after this story: once blocked, the file's download response is
   HTTP 451 with errcode `M_NOT_FOUND` and a body byte-identical to a genuine 404 — this story adds
   no admin-facing signal (message text, header, timing) anywhere in the *download* path that would
   let a client distinguish "an admin blocked this" from "this never existed." (The **admin UI**
   itself, naturally, does show the block — the anonymity contract is about the unauthenticated
   client-facing download response only, exactly as scoped in 1c.)
2. **AC2 — Unblock: `:admin_blocked → :released`.** Reverses AC1; the file re-enters the single
   state that serves bytes (1c AC4).
3. **AC3 — Delete: transitions to `:deleted` (soft-delete), never `:hard_deleted`.** Delete is
   available from every state the guard table allows an edge to `:deleted` from (`:quarantined`,
   `:released`, `:admin_blocked`, `:infected` — Story 1b's guard table). It never calls or
   approximates `:deleted → :hard_deleted` — that transition's *policy* (retention/lifecycle) is
   Story 8/13's scope; this story only ever requests `:deleted`.
4. **AC4 — Rescan re-enqueues the Story 4b scan job.** Available from `:quarantined` and
   `:scan_failed`. Rescan does not itself call `StateMachine.transition/4` to `:scanning` — that
   transition happens inside `Nebu.Workers.MediaScanWorker` exactly as Story 4b already specifies
   (`quarantined → scanning`, "Oban scan job picked up"). This story's obligation is solely to
   enqueue a new `Nebu.Workers.MediaScanWorker` job for the given `media_id`; the worker's own
   already-built flow does the rest, including its own `media_state_transitions` write.
5. **AC5 — Every action is admin-role-gated.** All four actions require the standard admin session
   gate already enforced by `on_mount({Nebu.Admin.Auth, :require_admin}, ...)` (the same gate Story
   5a's table itself sits behind). No action in this story requires the separate
   `media_admin_override` role — that stricter role gate belongs to Story 6c's Infected-Override
   action only, which is explicitly out of scope here (Block/Unblock/Delete/Rescan never touch
   `:infected` files except via the universal Delete edge in AC3).
6. **AC6 — Every action writes an audit entry via `Nebu.Compliance`'s public API, stamped with the
   acting admin's `actor_id`.** `Nebu.Compliance.AuditWriter.log/6` (there is no separate
   `Nebu.Compliance` facade module in the repo today — `AuditWriter` called directly, optionally
   through the existing `Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)`
   test-injection seam, *is* the public entry point other domains use; see
   `Nebu.Admin.UsersController.write_audit/6` and Story 4c's worker call for precedent) is called
   with `actor_user_id` = the acting admin's user id (read from `socket.assigns.current_user`,
   same shape/extraction convention as `Nebu.Admin.UsersController.actor_id/1`), `target_type:
   "media"`, `target_id: media_id`.
7. **AC7 — The four new action atoms are added to `AuditWriter.@known_actions` in the same
   commit.** `media_blocked`, `media_unblocked`, `media_deleted`, `media_rescanned`. This is the
   same known repo gotcha Story 4c's audit-bridge AC flags: an admin action that calls
   `AuditWriter.log/6` with an action string not yet in `@known_actions` does not raise or 500 — it
   returns `{:error, :audit_unknown_action}` and logs an `AuditWriter: rejected unknown audit
   action` error, and the state transition itself (already committed via `StateMachine.transition/4`
   in a separate, prior `Repo.transaction/1`) is **not** rolled back by that failure. The state
   changes; the compliance trail silently doesn't. Shipping this story without the allowlist update
   produces exactly that failure mode for every one of the four actions — this is an explicit,
   independently-testable AC, not an implementation detail.
8. **AC8 — Invalid transitions are rejected with a clear error via the state machine's guard, not a
   silent no-op.** Attempting Block on a file already in `:admin_blocked` (not `:released`),
   Unblock on a file not in `:admin_blocked`, or any of the four actions against `:reserved` or
   `:scanning` (neither state has an outgoing edge to the requested target in Story 1b's guard
   table, except where AC9 below defines an explicit idempotent no-op) returns
   `{:error, {:invalid_transition, from, to}}` from `Nebu.Media.StateMachine.transition/4`, and
   the LiveView surfaces this as a visible error/info flash — never a silent, unexplained failure
   to update the row.
9. **AC9 — Block/Unblock are idempotent no-ops, not errors, when already in the target state.**
   Per the epic's explicit scope note ("Block/Unblock idempotent (No-Op + Info-Flash)"): calling
   Block on a file already `:admin_blocked`, or Unblock on a file already `:released`, does not
   attempt a `StateMachine.transition/4` call at all (there is no `:admin_blocked → :admin_blocked`
   or `:released → :released` edge to attempt) — it short-circuits to an info flash ("Already
   blocked." / "Already released.") and writes **no** additional `media_state_transitions` row and
   **no** additional `audit_log` entry. This is distinct from AC8: AC8 covers transitions the guard
   table genuinely forbids (e.g. Block from `:quarantined`); AC9 covers the specific
   already-in-target-state case that the epic calls out as a required no-op rather than a guard
   rejection.
10. **AC10 — Delete requires a LiveView confirm modal; Block/Unblock/Rescan do not.** Per the
    epic's Story 6a scope line and `EXPERIENCE.md`'s `confirm-dialog` component pattern: Delete
    (destructive) opens a CSP-safe LiveView modal (no `window.confirm`, no `position: fixed`) with
    focus trapped inside it, focus returned to the trigger element on close, Escape cancels, and
    the destructive confirm button is never the default-focused element. Block, Unblock, and
    Rescan fire immediately on click with no modal.
11. **AC11 — Block accepts an optional free-text reason.** Per the epic scope note, an optional
    reason string is accepted on Block and, when present, stored in
    `media_state_transitions.metadata.reason` **and** in the `audit_log` entry's `metadata.reason`
    — both writes carry the same value, consistent with how Story 4c's `scan_metadata`/audit
    metadata pairing already keeps the two logs' payloads aligned for the same event. An empty or
    absent reason is valid (unlike Story 6c's override, which is a separate action with a mandatory
    reason).

## Acceptance Tests

Test file: `server/test/nebu/media_admin_actions_test.exs` (unit-level, `Nebu.Media`'s new public
functions, no LiveView):

1. `test "admin_block/3 transitions :released -> :admin_blocked and returns :ok"`
2. `test "admin_unblock/2 transitions :admin_blocked -> :released and returns :ok"`
3. `test "admin_delete/2 transitions each of :quarantined/:released/:admin_blocked/:infected to :deleted and returns :ok"`
4. `test "admin_rescan/2 enqueues a Nebu.Workers.MediaScanWorker job for the given media_id and does not itself call StateMachine.transition/4"`
5. `test "admin_block/3 writes exactly one audit_log entry via AuditWriter with action \"media_blocked\", target_type \"media\", target_id = media_id, and actor_user_id = the given admin id"`
6. `test "admin_unblock/2 writes exactly one audit_log entry with action \"media_unblocked\" and the given admin id as actor"`
7. `test "admin_delete/2 writes exactly one audit_log entry with action \"media_deleted\" and the given admin id as actor"`
8. `test "admin_rescan/2 writes exactly one audit_log entry with action \"media_rescanned\" and the given admin id as actor"`
9. `test "media_blocked, media_unblocked, media_deleted, media_rescanned are all present in AuditWriter.@known_actions"` — a direct, standalone assertion against the allowlist (not just an indirect pass-through of tests 5-8), so a future refactor that regresses the allowlist fails immediately and legibly rather than as a confusing audit-write error deep in an action test.
10. `test "admin_block/3 on an already :admin_blocked file is a no-op — no StateMachine call, no new media_state_transitions row, no new audit_log entry, returns {:ok, :already_blocked}"` (AC9)
11. `test "admin_unblock/2 on an already :released file is a no-op — same no-op guarantees, returns {:ok, :already_released}"` (AC9)
12. `test "admin_block/3 from :quarantined returns {:error, {:invalid_transition, :quarantined, :admin_blocked}} and writes nothing"` (AC8)
13. `test "admin_unblock/2 from :quarantined returns {:error, {:invalid_transition, :quarantined, :released}} and writes nothing"` (AC8 — distinct from test 11, which covers the already-`:released` idempotent no-op, not a guard rejection)
14. `test "admin_delete/2 from :reserved or :scanning returns {:error, {:invalid_transition, from, :deleted}} and writes nothing"` (AC8 — Delete has no edge from either state in Story 1b's guard table)
15. `test "admin_rescan/2 from :released returns {:error, :invalid_state_for_rescan} (or equivalent) and does not enqueue an Oban job"` (AC8 — Rescan is only valid from :quarantined/:scan_failed)
16. `test "admin_block/3 with a non-empty reason stores it in media_state_transitions.metadata.reason and in the audit_log entry's metadata.reason identically"` (AC11)
17. `test "admin_block/3 with no reason (nil/empty string) succeeds with an empty/absent reason in both metadata payloads"` (AC11)
18. **Anonymity test (AC1):** `test "after admin_block/3, a download request for the file returns the exact same 451 M_NOT_FOUND body as Story 1c's admin_blocked fixture — this story introduces no additional distinguishing field, header, or timing signal"` — reuses/extends `media_download_gate_test.exs`'s existing `:admin_blocked` case rather than duplicating gate logic; asserts calling this story's `admin_block/3` end-to-end (not just seeding `state: :admin_blocked` directly) still produces the identical anonymous response.

Test file: `server/test/nebu/admin/media_live_test.exs` (LiveView-level, `live_isolated/3` per the
`Nebu.Admin.LogsLiveTest` convention):

19. `test "clicking Block on a :released row fires immediately (no modal) and the row's badge updates to :admin_blocked via the live socket"`
20. `test "clicking Unblock on an :admin_blocked row fires immediately and the row's badge updates to :released"`
21. `test "clicking Rescan on a :quarantined row fires immediately and an info flash confirms the rescan was queued"`
22. `test "clicking Delete opens a confirm modal; the row is unchanged until the modal is confirmed"` (AC10)
23. `test "confirming the Delete modal transitions the row to :deleted and closes the modal, returning focus to the row's action trigger"` (AC10)
24. `test "pressing Escape while the Delete modal is open cancels without transitioning the row"` (AC10)
25. **Permission test:** `test "a LiveView session without the admin claim cannot mount /admin/media at all (on_mount halt+redirect), so none of the four action event handlers are reachable"` — mirrors the existing `on_mount(:require_admin)` halt behavior already covered for other Admin LiveViews; this story does not add a *new* authorization mechanism, it inherits Story 5a's existing gate, and this test proves that inheritance rather than assuming it.

## Technical Requirements

### `Nebu.Media` public API additions (ADR-020 — Admin calls through here, never through
`Nebu.Media.StateMachine` directly)

Per Story 1b's own guardrail ("`Nebu.Admin` (Story 6, 13) must call through `Nebu.Media`'s public
module, not reach into `Nebu.Media.StateMachine` directly from the admin namespace"), this story
adds four functions to `server/lib/nebu/media.ex` (the existing public-API/handler module):

```elixir
@spec admin_block(media_id :: String.t(), admin_id :: Ecto.UUID.t(), reason :: String.t() | nil) ::
        {:ok, :admin_blocked} | {:ok, :already_blocked}
        | {:error, {:invalid_transition, atom(), atom()}} | {:error, :not_found}

@spec admin_unblock(media_id :: String.t(), admin_id :: Ecto.UUID.t()) ::
        {:ok, :released} | {:ok, :already_released}
        | {:error, {:invalid_transition, atom(), atom()}} | {:error, :not_found}

@spec admin_delete(media_id :: String.t(), admin_id :: Ecto.UUID.t()) ::
        {:ok, :deleted}
        | {:error, {:invalid_transition, atom(), atom()}} | {:error, :not_found}

@spec admin_rescan(media_id :: String.t(), admin_id :: Ecto.UUID.t()) ::
        {:ok, :rescan_queued}
        | {:error, :invalid_state_for_rescan} | {:error, :not_found}
```

Each function's shape:

1. Look up the current `state` (read path only — via existing `Nebu.Media.DB`, no new SQL needed
   beyond what 1c already added).
2. **Block/Unblock only** — short-circuit to the idempotent `{:ok, :already_*}` no-op (AC9) *before*
   calling `StateMachine.transition/4` if already in the target state. This check happens in
   `Nebu.Media`, not inside `Nebu.Media.StateMachine` — the state machine's guard table has no
   `:admin_blocked -> :admin_blocked` edge and correctly treats that as `:invalid_transition`; the
   idempotency behavior is this story's admin-facing UX decision layered on top, not a change to
   the guard table itself.
3. Call `Nebu.Media.StateMachine.transition(media_id, to_state, {:admin, admin_id}, metadata)`
   (Story 1b's guarded public API). Rescan is the exception — it does **not** call `transition/4`
   at all (AC4); it only validates the current state is `:quarantined` or `:scan_failed` and then
   enqueues the Oban job.
4. On `{:ok, _}` (or, for Rescan, on successful `Oban.insert/1`): call
   `Nebu.Compliance.AuditWriter.log(admin_id, action_string, "media", media_id, metadata, "success")`
   — see next section.
5. On `{:error, {:invalid_transition, _, _}}`: return the error as-is; **no** audit write (an
   invalid, rejected attempt is not itself a compliance-relevant admin action — nothing happened).

### Rescan — Oban enqueue, not a state-machine call

```elixir
def admin_rescan(media_id, admin_id) do
  case current_state(media_id) do
    state when state in [:quarantined, :scan_failed] ->
      %{"media_id" => media_id}
      |> Nebu.Workers.MediaScanWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          Nebu.Compliance.AuditWriter.log(admin_id, "media_rescanned", "media", media_id, %{}, "success")
          {:ok, :rescan_queued}

        {:error, reason} ->
          {:error, reason}
      end

    :not_found ->
      {:error, :not_found}

    _other ->
      {:error, :invalid_state_for_rescan}
  end
end
```

The worker's own already-specified flow (Story 4b) performs `quarantined -> scanning` via
`StateMachine.transition/4` with `actor: {:system, nil}` once it picks the job up — this story
never simulates or duplicates that transition.

### Audit-bridge call site and `@known_actions` update

`server/lib/nebu/compliance/audit_writer.ex` — add to `@known_actions` (AC7), in the same commit
as the four `Nebu.Media` functions that reference them:

```elixir
media_blocked
media_unblocked
media_deleted
media_rescanned
```

Follow the existing inline-comment convention in that file (each addition documents which story
introduced it), matching the pattern already used for `enable_temporary_capture`/
`disable_temporary_capture` and the Story 4c entries this story's sibling adds
(`media_infected_detected`, `media_scan_failed` — verify those are present if 4c has landed first;
if not, this story's commit must not depend on 4c's commit having merged first, add only this
story's four actions).

Metadata shape per action (mirrors 4c's `%{filename, sha256, uploader_id, clamav_signature}`
pattern, scoped to what's actually available/relevant per action):

- `media_blocked`: `%{reason: reason_or_nil}`
- `media_unblocked`: `%{}`
- `media_deleted`: `%{from_state: previous_state}`
- `media_rescanned`: `%{from_state: previous_state}`

No `room_id` in any of these payloads, for the same reason ADR-028/Story 4c gives:
`media_files` has no `room_id` column; room attribution is the deferred query-time join
(`audit_log.target_id` → `events.content`), not this story's concern.

### LiveView event handlers — `Nebu.Admin.MediaLive` (Story 5a's module, extended here)

```elixir
def handle_event("block", %{"media_id" => media_id, "reason" => reason}, socket) do
  admin_id = actor_id(socket.assigns.current_user)

  case Nebu.Media.admin_block(media_id, admin_id, blank_to_nil(reason)) do
    {:ok, :admin_blocked} -> {:noreply, put_flash(socket, :info, "File blocked.")}
    {:ok, :already_blocked} -> {:noreply, put_flash(socket, :info, "Already blocked.")}
    {:error, {:invalid_transition, _, _}} -> {:noreply, put_flash(socket, :error, "Cannot block this file in its current state.")}
    {:error, :not_found} -> {:noreply, put_flash(socket, :error, "File not found.")}
  end
end

def handle_event("unblock", %{"media_id" => media_id}, socket) do
  # mirrors "block" — {:ok, :released} / {:ok, :already_released} / error branches
end

def handle_event("open_delete_confirm", %{"media_id" => media_id}, socket) do
  {:noreply, assign(socket, confirm_delete_media_id: media_id)}
end

def handle_event("cancel_delete_confirm", _params, socket) do
  {:noreply, assign(socket, confirm_delete_media_id: nil)}
end

def handle_event("confirm_delete", %{"media_id" => media_id}, socket) do
  admin_id = actor_id(socket.assigns.current_user)

  socket = assign(socket, confirm_delete_media_id: nil)

  case Nebu.Media.admin_delete(media_id, admin_id) do
    {:ok, :deleted} -> {:noreply, put_flash(socket, :info, "File deleted.")}
    {:error, {:invalid_transition, _, _}} -> {:noreply, put_flash(socket, :error, "Cannot delete this file in its current state.")}
    {:error, :not_found} -> {:noreply, put_flash(socket, :error, "File not found.")}
  end
end

def handle_event("rescan", %{"media_id" => media_id}, socket) do
  admin_id = actor_id(socket.assigns.current_user)

  case Nebu.Media.admin_rescan(media_id, admin_id) do
    {:ok, :rescan_queued} -> {:noreply, put_flash(socket, :info, "Rescan queued.")}
    {:error, :invalid_state_for_rescan} -> {:noreply, put_flash(socket, :error, "This file is not eligible for rescan right now.")}
    {:error, :not_found} -> {:noreply, put_flash(socket, :error, "File not found.")}
  end
end

defp actor_id(current_user) do
  # Same shape/extraction as Nebu.Admin.UsersController.actor_id/1 — matrix_user_id, falling
  # back to sub.
  case current_user do
    %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
    %{"sub" => sub} when is_binary(sub) -> sub
    _ -> nil
  end
end
```

Row actions render conditionally by state, per `EXPERIENCE.md`'s `row actions` component pattern
(Block only from `:released`, Unblock only from `:admin_blocked`, Rescan only from
`:quarantined`/`:scan_failed`; Delete is present from every non-terminal-negative state that has a
`:deleted` edge). The row-level state comes from Story 5a's existing PubSub-driven row assigns — no
new realtime mechanism is introduced here.

### Confirm modal (Delete only)

CSP-safe LiveView modal component (no `window.confirm`, no `position: fixed` — the epic's explicit
constraint), following the `confirm-dialog` behavioral spec in `EXPERIENCE.md`: focus moves into
the dialog on open, returns to the row's Delete trigger on close, Escape cancels
(`phx-window-keydown="cancel_delete_confirm"` scoped to the modal, or an equivalent JS hook per the
existing CSP-safe modal convention used elsewhere in Admin), and the destructive confirm button is
never the default-focused element inside the modal (default focus goes to Cancel).

## File List

| File | Change Type |
|---|---|
| `server/lib/nebu/media.ex` | UPDATE — add `admin_block/3`, `admin_unblock/2`, `admin_delete/2`, `admin_rescan/2` |
| `server/lib/nebu/admin/media_live.ex` | UPDATE (Story 5a's module) — add `handle_event/3` clauses for `block`/`unblock`/`open_delete_confirm`/`cancel_delete_confirm`/`confirm_delete`/`rescan`, the confirm-modal assign/render, and conditional row-action rendering by state |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE — add `media_blocked`, `media_unblocked`, `media_deleted`, `media_rescanned` to `@known_actions` |
| `server/test/nebu/media_admin_actions_test.exs` | NEW |
| `server/test/nebu/admin/media_live_test.exs` | UPDATE (Story 5a's test file) — add this story's event-handler/modal/permission tests |

## Dev Agent Guardrails

### Do Not Change

- **Do not bypass `Nebu.Media.StateMachine`'s guard table for any action.** No raw
  `Ecto.Adapters.SQL.query/3` `UPDATE ... media_files ... SET state` anywhere in this story's new
  code — every state change goes through `transition/4`. (Story 1b's grep-based invariant test will
  catch a direct `UPDATE` outside `state_machine.ex`; do not weaken or special-case that check for
  this story's files.)
- **Do not perform a hard delete here.** Delete in this story only ever requests `:deleted`
  (soft-delete). `:deleted -> :hard_deleted` is Story 8's retention/lifecycle-policy scope — do not
  add a "permanently delete" action, a cron trigger, or any bytes-removal side effect to this
  story's `admin_delete/2`.
- **Do not call `Nebu.Media.StateMachine` directly from `Nebu.Admin.MediaLive`.** Every action goes
  through the new `Nebu.Media.admin_*` functions (ADR-020) — the Admin namespace has no direct
  dependency on the `StateMachine` module.
- **Do not add or check the `media_admin_override` role in this story.** That role gate belongs to
  Story 6c's Infected-Override action. This story's four actions use only the standard admin
  session gate already enforced by Story 5a's `on_mount`.
- **Do not implement 6b (detail view), 6c (override), or 6d (bulk actions).** This story is scoped
  to exactly the four routine, single-file actions named in its title.
- **Do not weaken the `:admin_blocked` anonymity contract from Story 1c/ADR-026.** No new admin
  action introduced here should add a distinguishing errcode, message, header, or timing signal to
  the *download* response for a blocked file — the block is only visible in the admin UI and the
  audit/transition logs, never leaked to the unauthenticated download path.
- **Do not skip the `AuditWriter.@known_actions` update in the same commit as the `Nebu.Media`
  changes that reference the new action strings.** Shipping the state-transition code without the
  allowlist update passes every `StateMachine`-level test while silently breaking the audit trail
  for all four actions — this is the exact repo-known failure mode AC7 exists to make an
  independently-testable, blocking criterion.

## Dependencies

**Depends on:**

- `1b-state-machine-module` — provides `Nebu.Media.StateMachine.transition/4` and its guard table;
  this story adds no new edges to that table (all required edges — `released↔admin_blocked`,
  `*→deleted`, and the `quarantined→scanning`/`scan_failed→quarantined` edges the Rescan-triggered
  worker relies on — already exist per 1b's guard table and 4a's later extension).
- `4c-infected-scanfailed-audit-bridge` — establishes the audit-bridge pattern (system-driven scan
  events writing to `audit_log` in addition to `media_state_transitions`, and the
  `AuditWriter.@known_actions` allowlist gotcha) that this story follows for admin-driven events.
- `5a-admin-media-table` — this story's four actions attach as row actions/event handlers to the
  `/admin/media` LiveView table 5a builds; this story does not create that route or table.
- `4b-media-scan-worker` — provides `Nebu.Workers.MediaScanWorker`, which Rescan re-enqueues; this
  story does not duplicate the worker's scan flow or its `scanning`-transition logic.

**Note:** Rescan is scoped to include `:scan_failed`-state files per the epic text, which requires
Story 4a's `scan_failed` ENUM value and its `scan_failed → quarantined` (or equivalent retry) guard
edge to already exist. 4a is transitively required through the 4b dependency chain (4b depends on
4a); this story does not independently extend the guard table for `scan_failed`.

**Downstream:** Story 6b's detail view surfaces the same `media_state_transitions`/`audit_log`
entries this story writes. Story 6d's bulk actions generalize this story's single-file
`admin_block`/`admin_delete`/`admin_rescan` pattern to a `batch_id`-fan-out; 6d should reuse this
story's `Nebu.Media` functions per-file rather than reimplementing the transition+audit pairing.

## Dev Agent Record

### Corrections

- **Design/architecture gap (caller-approved option A):** `Nebu.Media.StateMachine.transition/4`'s
  `{:admin, admin_id}` actor requires an `Ecto.UUID.t()` (`media_state_transitions.actor_id` was a
  `UUID` column), but this app has no UUID-shaped user/admin identity anywhere in its real data
  model — admin sessions carry a Matrix-ID string (`current_user["matrix_user_id"]`), the same
  shape `audit_log.actor_user_id`/`users.user_id` already use. 6a is the first real caller of
  `{:admin, admin_id}` (1b's own tests only ever used a synthetic `Ecto.UUID.generate()`), so this
  mismatch had never been exercised end-to-end before. Fixed via migration
  `000029_media_state_transitions_actor_id_text` (`actor_id` UUID → TEXT, verified zero non-null
  rows pre-migration — zero-risk) and a `state_machine.ex` change dropping the `Ecto.UUID.dump!/
  load!` round-trip. AC1/AC6's own `@spec admin_id :: Ecto.UUID.t()` in the Technical Requirements
  section above is stale relative to this fix — the real type is `String.t()`.
- **AC1 anonymity fix (Kassandra security-review, self-caught before commit):** AC1's text above
  ("HTTP 451 with errcode `M_NOT_FOUND`") describes the ORIGINAL (wrong) 1c behavior. This story's
  own security review found `Nebu.Media.download_gate(:admin_blocked)` still returned a
  distinguishable `451` status (only the errcode/body were anonymized), which Kassandra's own prior
  sanctum memory had already flagged as insufficient anonymity ("Anonymity by identical BODY but
  distinguishable STATUS is not anonymity," dormant since 1c, "then live" once 6a's mutation path
  shipped). Fixed to a byte-identical `404 + M_NOT_FOUND` — same status AND body as
  `:infected`/`:deleted`/`:hard_deleted`/a genuine unknown-`media_id`. See ADR-026's 2026-07-19
  correction, `1c-download-gate-enforcement.md`'s own Dev Agent Record correction, and this story's
  Acceptance Test 18 (updated to assert identical status, not just identical body).
- **AC8 test 12 story-text-vs-guard-table correction:** the story's own Acceptance Test 12 named
  `:quarantined` as an invalid Block source state, but Story 1b's real guard table (extended by 4a)
  DOES have a `:quarantined -> :admin_blocked` edge — an admin can legitimately block a file mid-scan.
  `:infected` (no edge to `:admin_blocked`) is used instead; the test still proves AC8's real
  guard-rejection behavior.
