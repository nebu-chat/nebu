---
story_id: 6c-infected-override
title: "Admin Media Actions: Infected Override for False Positives"
epic: media-security-admin-control
status: done
security_review: required
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 6a gives admins four routine actions (Block/Unblock/Delete/Rescan), explicitly excluding
`:infected` files from any action except the universal Delete edge — `:infected → :released` is
**not** one of 6a's actions and, per Story 1b's guard table, is not even a legal transition today:
1b's `@transitions` map defines `infected: [:deleted]` and its own Technical Requirements state
plainly that "`infected` (beyond the single `-> deleted` edge) [is] terminal — `infected` files are
'nie ausgeliefert' (epic), never transition to `released`."

This story is the deliberate, narrow exception to that rule: a ClamAV false positive (a bad
freshclam signature flagging a legitimate file) is a real operational scenario, and an admin needs
a way out of it that is not "silently weaken the guard table." Three things make this exception
safe rather than a scanner bypass: (1) the new `:infected → :released` edge is reachable through
exactly one function, gated by a **role stricter than generic admin** (`media_admin_override`,
per the epic's explicit "nicht Teil der normalen Admin-Rolle") — a compromised-but-merely-admin
account cannot use it; (2) every call requires a **mandatory, server-validated** free-text reason,
never silently defaulted or reused; (3) the event is bridged into the global `audit_log`
(ADR-028) with that reason and the original ClamAV signature preserved, alongside 6a's/4c's
already-established audit-bridge pattern.

This story does **not** build bulk/cohort overrides — that is Story 6d's explicit, separately
scoped follow-up (tracked as deliberate scope-debt, not an oversight) for the exact scenario where
one bad signature flags many files at once. This story's per-file design must stay simple and
correct on its own terms without foreclosing 6d's later batch-fan-out extension (see Dev Agent
Guardrails).

## User Story

As an admin holding the `media_admin_override` role, I want to release a specific file out of
`:infected` back into `:released` when I have verified it is a false positive, by providing a
mandatory justification, so that a bad ClamAV signature does not permanently and silently strand a
legitimate file, while the override itself stays exceptional, accountable, and narrowly gated —
never a routine or unaudited scanner bypass.

## Acceptance Criteria

1. **AC1 — Only `:infected` files can be overridden.** The action is available, and the guard
   accepts it, exclusively from `media_files.state = :infected`. Attempting the override against
   any other state (`:released`, `:admin_blocked`, `:quarantined`, `:scanning`, `:deleted`,
   `:hard_deleted`, `:reserved`, `:scan_failed`) is rejected with
   `{:error, {:invalid_transition, from, :released}}` and writes neither a
   `media_state_transitions` row nor an `audit_log` entry. This is a **new guard-table edge**, not
   a relaxation of an existing one: Story 1b's `@transitions` map is extended in this story from
   `infected: [:deleted]` to `infected: [:deleted, :released]` — 1b's own Technical Requirements
   anticipated exactly this kind of extension ("so that ... any future lifecycle-policy story
   extend this map rather than restructuring the guard mechanism"), so this is additive, not a
   deviation from 1b's design.
2. **AC2 — Mandatory, non-empty, non-whitespace reason, validated server-side.** The override
   requires a free-text reason. An empty string, a `nil`/absent value, or a string that is only
   whitespace (after trimming) is rejected with `{:error, :reason_required}` **before** any
   `StateMachine.transition/4` call, any DB write, or any audit write is attempted. This validation
   lives in `Nebu.Media.admin_override_infected/3` itself — it is not merely a `required` HTML
   attribute or LiveView form validation that a direct/scripted call could bypass; a caller
   invoking the public API function directly with a blank reason gets the same rejection a UI user
   would.
3. **AC3 — The transition itself goes through `Nebu.Media.StateMachine.transition/4`, called only
   via `Nebu.Media`'s public API (ADR-020).** No code in `Nebu.Admin.MediaLive` calls
   `Nebu.Media.StateMachine` directly (same rule 6a established); `Nebu.Media.admin_override_infected/3`
   is the sole entry point, calling `transition(media_id, :released, {:admin, admin_id}, metadata)`
   with `metadata` containing at least `reason` and `original_signature`.
4. **AC4 — Every successful override writes an audit entry via `Nebu.Compliance.AuditWriter.log/6`,
   stamped with the acting admin as actor.** `actor_user_id` is the overriding admin's id (same
   `actor_id/1`-shaped extraction convention as 6a); `target_type: "media"`, `target_id: media_id`;
   `metadata` contains **at minimum** `reason` (the admin's free text) and `original_signature`
   (the ClamAV signature the file was originally flagged under, read from
   `media_files.scan_metadata["clamav_signature"]` — the exact key Story 4b's worker persists,
   *not* the epic's shorthand `"signature"` key, which does not exist in the actual schema; see
   Technical Requirements). A rejected attempt (AC1's invalid-state case or AC2's blank-reason
   case) writes **no** audit entry — an attempt that never took effect is not itself a completed
   compliance-relevant action.
5. **AC5 — New action atom registered in `AuditWriter.@known_actions` in the same commit.**
   `media_infected_override` is added to `server/lib/nebu/compliance/audit_writer.ex`'s
   `@known_actions` list. This is the same repo-known footgun 4c and 6a both flag independently:
   shipping `Nebu.Media.admin_override_infected/3` without this allowlist entry does not error or
   500 — the state transition commits (in its own prior `Repo.transaction/1`, per
   `StateMachine.transition/4`'s existing behavior) and the subsequent
   `AuditWriter.log/6` call silently returns `{:error, :audit_unknown_action}`, logged only at
   `Logger.error` level with no caller-visible failure. The file is released; the compliance trail
   silently is not. This is an explicit, independently-testable AC, exactly as in 4c/6a, not an
   implementation detail left to code review to catch informally.
6. **AC6 — Role restriction narrower than generic admin.** The override is gated by a distinct
   `media_admin_override` role/grant, **not** the standard `on_mount({Nebu.Admin.Auth,
   :require_admin}, ...)` session gate alone that 6a's four actions rely on. Per the epic's
   explicit scope note ("Nur für Admins mit separater Rolle `media_admin_override` (nicht Teil der
   normalen Admin-Rolle) — verhindert flächigen Scanner-Bypass"): an authenticated admin who lacks
   this specific grant (a) does not see the override action/button on an `:infected` row at all in
   the LiveView, and (b) if the event handler is somehow still invoked (e.g. a replayed/forged
   `phx-click` payload), `Nebu.Media.admin_override_infected/3` independently re-checks the grant
   and returns `{:error, :forbidden}` without touching the state machine or the audit log — the
   check is not UI-only, matching AC2's "not just UI-required" posture for the reason field.
7. **AC7 — Confirmation dialog with an escalated warning, distinct from 6a's plain Delete
   confirm.** A CSP-safe LiveView modal (no `window.confirm`) is required before the override
   fires, carrying the literal warning text from the epic: "Diese Datei wurde als Malware erkannt.
   Freigabe erfolgt auf eigene Verantwortung." — plus the mandatory reason input (AC2) inside the
   same modal. Focus-trap, focus-return-on-close, Escape-cancels, and default-focus-never-on-the-
   confirm-button all follow 6a's `confirm-dialog` behavioral spec (`EXPERIENCE.md`).
8. **AC8 — Not idempotent-still: every override requires a fresh reason, with no no-op
   short-circuit.** Unlike 6a's Block/Unblock (AC9 there defines an idempotent already-in-target-
   state no-op), this action has no "already overridden" short-circuit path to design around in the
   first place — once released, the file is `:released` and the override action is no longer
   offered for it (AC1). This AC exists to make explicit that a *second* override attempt on a
   *different* subsequent `:infected` classification of the same `media_id` (e.g. re-flagged after
   a rescan) is treated as a brand-new action requiring its own fresh, non-reused reason — no
   caching or pre-filling of a previous reason value anywhere in the write path.

## Acceptance Tests

Test file: `server/test/nebu/media_admin_actions_test.exs` (UPDATE — 6a's existing unit-level test
file for `Nebu.Media`'s admin-action public functions; this story adds
`admin_override_infected/3` alongside it):

1. `test "admin_override_infected/3 on an :infected file with a non-empty reason transitions :infected -> :released and returns {:ok, :released}"`
2. `test "admin_override_infected/3 writes exactly one media_state_transitions row with metadata containing reason and original_signature"`
3. `test "admin_override_infected/3 writes exactly one audit_log entry via AuditWriter with action \"media_infected_override\", target_type \"media\", target_id = media_id, actor_user_id = the overriding admin's id, and metadata containing reason and original_signature"` (AC4)
4. `test "media_infected_override is present in AuditWriter.@known_actions"` — a direct, standalone allowlist assertion in the shape of 6a's test 9 / 4c's test 4, so a future refactor that drops the entry fails immediately and legibly rather than as a confusing audit-write error (AC5)
5. `test "admin_override_infected/3 with an empty-string reason returns {:error, :reason_required}, calls neither StateMachine.transition/4 nor AuditWriter.log/6, and leaves the file's state unchanged"` (AC2)
6. `test "admin_override_infected/3 with a whitespace-only reason (e.g. \"   \") returns {:error, :reason_required}"` (AC2 — whitespace-only is not merely \"non-blank per String.length\", it must be trimmed before the emptiness check)
7. `test "admin_override_infected/3 with a nil reason returns {:error, :reason_required}"` (AC2)
8. `test "admin_override_infected/3 against a :released file returns {:error, {:invalid_transition, :released, :released}} and writes nothing"` (AC1)
9. `test "admin_override_infected/3 against a :quarantined, :scanning, :admin_blocked, :deleted, :scan_failed, or :reserved file returns {:error, {:invalid_transition, from, :released}} for each and writes nothing"` (AC1 — table-driven over every non-`:infected` state)
10. `test "Nebu.Media.StateMachine.allowed?(:infected, :released) is true and allowed?(:infected, :deleted) remains true"` — direct guard-table assertion that the new edge was added additively, without removing 1b's existing `infected -> deleted` edge (AC1)
11. `test "admin_override_infected/3 called by an admin lacking the media_admin_override grant returns {:error, :forbidden} and writes nothing, even against a genuinely :infected file with a valid reason"` (AC6 — permission test, proves the server-side check is independent of state/reason validity)
12. `test "admin_override_infected/3 called by an admin holding the media_admin_override grant succeeds under otherwise-identical conditions"` (AC6 — positive control paired with test 11)

Test file: `server/test/nebu/admin/media_live_test.exs` (UPDATE — 6a's existing LiveView test file,
`live_isolated/3` per the `Nebu.Admin.LogsLiveTest` convention):

13. `test "the override action/button is not rendered on an :infected row for an admin session without the media_admin_override grant"` (AC6)
14. `test "the override action/button is rendered on an :infected row for an admin session with the media_admin_override grant, and is absent on non-:infected rows"` (AC1/AC6)
15. `test "clicking the override action opens the confirm modal with the literal escalated warning text and a reason input; the row is unchanged until confirmed"` (AC7)
16. `test "confirming the override modal with a non-empty reason transitions the row to :released via the live socket and closes the modal, returning focus to the row's trigger"` (AC7)
17. `test "attempting to confirm the override modal with an empty reason keeps the modal open and surfaces a validation error, without firing admin_override_infected/3"` (AC2 — UI-level companion to unit test 5, confirms the form does not even attempt the call, not just that the call would reject it)
18. `test "pressing Escape while the override modal is open cancels without transitioning the row"` (AC7)

## Technical Requirements

### Migration — `media_admin_override` grant

`server/priv/migrations/000024_media_admin_override_role.up.sql` /
`.down.sql` (next available sequential pair after `000023`; re-verify against whatever has
actually landed in `server/priv/migrations/` at implementation time — do not assume `000024` is
still free if another story's migration merged first):

```sql
-- 000024_media_admin_override_role.up.sql
ALTER TABLE users ADD COLUMN media_admin_override BOOLEAN NOT NULL DEFAULT false;
```

```sql
-- 000024_media_admin_override_role.down.sql
ALTER TABLE users DROP COLUMN media_admin_override;
```

This is deliberately **orthogonal** to `users.system_role` (`'user' | 'instance_admin' |
'compliance_officer'`, `000001_init.up.sql`), not a fourth enum value: the epic is explicit that
`media_admin_override` is "nicht Teil der normalen Admin-Rolle" — a grant layered on top of, not a
replacement for, `instance_admin`. A user needs both `system_role = 'instance_admin'` (to pass the
existing `on_mount(:require_admin)` gate and reach `/admin/media` at all) **and**
`media_admin_override = true` (to see/use this one action). Granting/revoking the flag itself
(an admin UI for it, analogous to the existing `update_user_role` audit action) is explicitly
**out of scope** for this story — this story only adds the column and consumes it; provisioning it
is left to direct DB access or a future story, exactly as the epic's own "nicht Teil der normalen
Admin-Rolle" framing implies a deliberately separate, currently-manual grant path.

### Guard table extension — `server/lib/nebu/media/state_machine.ex` (Story 1b's module)

```elixir
@transitions %{
  # ... unchanged entries ...
  infected: [:deleted, :released]   # :released edge added by Story 6c (Infected-Override)
}
```

No other edge changes. `allowed_transitions(:infected)` now returns `[:deleted, :released]`;
`allowed?(:infected, :released)` becomes `true`. This is the only change this story makes to
`state_machine.ex` — no new module, no restructuring of `allowed?/2`/`transition/4`, per 1b's own
"structured ... so ... any future lifecycle-policy story extend this map" guardrail.

### `Nebu.Media` public API addition (`server/lib/nebu/media.ex`, extending 6a's `admin_*` group)

```elixir
@spec admin_override_infected(media_id :: String.t(), admin_id :: Ecto.UUID.t(), reason :: String.t() | nil) ::
        {:ok, :released}
        | {:error, :reason_required}
        | {:error, :forbidden}
        | {:error, {:invalid_transition, atom(), atom()}}
        | {:error, :not_found}

def admin_override_infected(media_id, admin_id, reason) do
  with :ok <- validate_reason(reason),
       :ok <- authorize_override(admin_id),
       {:ok, current_state} <- current_state(media_id),
       original_signature <- scan_signature(media_id) do
    metadata = %{reason: String.trim(reason), original_signature: original_signature}

    case Nebu.Media.StateMachine.transition(media_id, :released, {:admin, admin_id}, metadata) do
      {:ok, :released} = ok ->
        Nebu.Compliance.AuditWriter.log(
          admin_id,
          "media_infected_override",
          "media",
          media_id,
          metadata,
          "success"
        )

        ok

      {:error, _} = error ->
        error
    end
  end
end

defp validate_reason(reason) do
  if is_binary(reason) and String.trim(reason) != "" do
    :ok
  else
    {:error, :reason_required}
  end
end
```

Order matters and is deliberate: **reason validation and the role check both happen before any
state lookup or transition attempt** (AC2/AC6) — a blank reason or an unauthorized caller never
even reaches the guard table, so no `{:error, {:invalid_transition, ...}}` noise obscures the real
rejection reason. `current_state`/`scan_signature` reuse the same read-path helpers 6a's
`admin_block`/`admin_unblock` already introduced (no new SQL beyond what 1c/4b already added);
`scan_signature/1` reads `media_files.scan_metadata["clamav_signature"]` — the key Story 4b's
worker actually persists (`%{clamav_signature: signature, scanned_at: ...}` via
`db().update_scan_metadata/2`), not the epic narrative's shorthand `scan_metadata["signature"]`,
which is not a real column key.

### Authorization check — `authorize_override/1`

Inline SQL against the new column, following `Nebu.Media.DB`'s existing style (ADR-018, no Ecto
schema):

```elixir
@sql_check_override_role "SELECT media_admin_override FROM users WHERE user_id = $1"

defp authorize_override(admin_id) do
  case db().check_override_role(admin_id) do
    true -> :ok
    _ -> {:error, :forbidden}
  end
end
```

This lives in `Nebu.Media` (or a small addition to `Nebu.Media.DB`), reading the shared `users`
table directly — the same way `Nebu.Media.admin_block/3` already receives and trusts an
`admin_id` sourced from `Nebu.Admin.MediaLive`'s session without a cross-domain call back into
`Nebu.Admin`'s public API for that identity. ADR-020's public-API rule governs calls *into another
namespace's behavior*; reading a shared, foundational table (`users`) that multiple namespaces
already read directly (e.g. `Nebu.Admin.UsersController`'s own `system_role` query) is not itself
a cross-domain behavioral call.

### LiveView — `Nebu.Admin.MediaLive` (Story 5a/6a's module, extended again)

```elixir
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

def handle_event("confirm_override", %{"media_id" => media_id, "reason" => reason}, socket) do
  admin_id = actor_id(socket.assigns.current_user)

  case Nebu.Media.admin_override_infected(media_id, admin_id, reason) do
    {:ok, :released} ->
      {:noreply,
       socket
       |> assign(confirm_override_media_id: nil, override_reason: "")
       |> put_flash(:info, "File released from infected state.")}

    {:error, :reason_required} ->
      {:noreply, put_flash(socket, :error, "A justification is required to override this file.")}

    {:error, :forbidden} ->
      {:noreply, put_flash(socket, :error, "You do not have permission to perform this action.")}

    {:error, {:invalid_transition, _, _}} ->
      {:noreply, put_flash(socket, :error, "This file is no longer eligible for override.")}

    {:error, :not_found} ->
      {:noreply, put_flash(socket, :error, "File not found.")}
  end
end
```

`socket.assigns.media_admin_override?` is computed once at `mount/3` (reading the same
`check_override_role/1` the public API uses, via the current admin's id) so row-action rendering
can conditionally show/hide the override button per AC6/test 13-14 without a per-row DB round
trip.

### Confirm modal (Override)

Same CSP-safe LiveView modal family as 6a's Delete confirm (`EXPERIENCE.md`'s `confirm-dialog`
pattern: no `window.confirm`, no `position: fixed`, focus-trap, focus-return, Escape-cancels,
destructive button never default-focused) — extended with a required, server-validated (AC2)
free-text `<textarea>`/`<input>` bound to `override_reason`, and the literal escalated warning
copy from AC7. The confirm button stays disabled (client-side UX affordance only — AC2's real
enforcement is server-side) while the trimmed reason is empty.

## File List

| File | Change Type |
|---|---|
| `server/priv/migrations/000024_media_admin_override_role.up.sql` | NEW — adds `users.media_admin_override BOOLEAN NOT NULL DEFAULT false` |
| `server/priv/migrations/000024_media_admin_override_role.down.sql` | NEW — drops the column |
| `server/lib/nebu/media/state_machine.ex` | UPDATE (Story 1b's module) — add the `infected: [:deleted, :released]` guard-table edge |
| `server/lib/nebu/media.ex` | UPDATE — add `admin_override_infected/3`, `validate_reason/1`, `authorize_override/1` |
| `server/lib/nebu/media/db.ex` | UPDATE — add `check_override_role/1` (reads `users.media_admin_override`) alongside the existing read-path helpers |
| `server/lib/nebu/admin/media_live.ex` | UPDATE (Story 5a/6a's module) — add `handle_event/3` clauses for `open_override_confirm`/`cancel_override_confirm`/`confirm_override`, the override confirm-modal assign/render, `media_admin_override?` mount-time assign, and conditional override-button rendering on `:infected` rows |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE — add `media_infected_override` to `@known_actions` |
| `server/test/nebu/media_admin_actions_test.exs` | UPDATE (Story 6a's test file) — add this story's unit tests |
| `server/test/nebu/media/state_machine_test.exs` | UPDATE (Story 1b's test file) — add the guard-table-edge assertions (test 10) |
| `server/test/nebu/admin/media_live_test.exs` | UPDATE (Story 6a's test file) — add this story's LiveView tests |

## Dev Agent Guardrails

### Do Not Change

- **Do not allow an empty, absent, or whitespace-only reason through, at any layer.** The
  emptiness check in `Nebu.Media.admin_override_infected/3` (AC2) is the enforcement point of
  record — a LiveView-only `required` attribute or a disabled-until-non-empty confirm button is a
  UX nicety, never a substitute. Do not remove or weaken the server-side `validate_reason/1` check
  on the theory that the UI already prevents submission; the acceptance tests call the public
  function directly, bypassing the UI, specifically to catch this regression.
- **Do not weaken or relax the `infected -> released` guard-table edge into a general-purpose
  relaxation.** This story adds exactly one edge (`infected: [:deleted, :released]`); it does not
  add `infected -> admin_blocked`, `infected -> quarantined`, or any other new edge, and it does
  not remove the existing `infected -> deleted` edge.
- **Do not fold this action into 6a's Rescan or any other existing action as a side effect.** Per
  the epic's explicit framing ("kein Nebeneffekt von Rescan"), the only way `:infected → :released`
  happens is through this story's dedicated, separately-role-gated function — rescanning an
  `:infected` file is not itself a defined transition anywhere in this epic and must not be added
  here as a shortcut.
- **Do not check the `media_admin_override` grant only in the LiveView.** AC6 requires the check
  to be re-verified inside `Nebu.Media.admin_override_infected/3` itself, independent of whatever
  the LiveView already hid or allowed — the same "not just UI-required" posture AC2 applies to the
  reason field.
- **Forward-compatibility note re Story 6d (do not build, but do not structurally block):** the
  epic explicitly defers a *bulk*, signature-cohort-scoped override (Story 6d, tracked as
  follow-up scope-debt, not built in this pass) because a per-file mandatory reason does not scale
  to a false-positive storm across many files. This story's single-file design
  (`admin_override_infected(media_id, admin_id, reason)`, one `media_state_transitions` row, one
  `audit_log` entry per call) is the right shape for *this* story and must not be redesigned here
  to anticipate 6d. However, do not hardcode an assumption that would make 6d's later batch
  fan-out structurally impossible later — in particular: (a) do not require the LiveView modal
  itself to be the only possible caller of `admin_override_infected/3` (6d will call the same
  `Nebu.Media` function per-file from a batch loop, per 6a's own "Downstream" note establishing
  this exact reuse pattern); (b) do not bake a hidden one-reason-per-HTTP-request assumption into
  `Nebu.Media`'s function signature or the audit metadata shape beyond what this story needs —
  `metadata: %{reason, original_signature}` is already per-call and composable with a future
  `batch_id` key 6d would add alongside it, not one this story needs to reserve space for now. This
  is a flag for awareness during implementation, not an additional requirement to satisfy in this
  story.

## Dependencies

**Depends on:**

- `6a-routine-state-actions` — establishes the `Nebu.Media.admin_*` public-API pattern
  (transition-then-audit, `actor_id/1` extraction, the CSP-safe confirm-modal convention, and the
  `AuditWriter.@known_actions` allowlist gotcha) that this story extends with a fifth, more tightly
  gated action. This story adds to the same `server/lib/nebu/media.ex`,
  `server/lib/nebu/admin/media_live.ex`, and test files 6a created rather than duplicating them.
- `4c-infected-scanfailed-audit-bridge` — establishes the audit-bridge convention (system-driven
  `:infected`/`scan_failed` events bridging into `audit_log`, ADR-028) and, concretely, the
  `media_files.scan_metadata["clamav_signature"]` key this story's `original_signature` metadata
  field reads from — this story's audit entries are the admin-driven counterpart to 4c's
  system-driven ones for the same underlying `:infected` event.
- `1b-state-machine-module` — provides `Nebu.Media.StateMachine.transition/4`, `allowed?/2`, and
  the `@transitions` guard-table map this story extends with the new `infected -> released` edge;
  1b's own design ("structured ... so ... any future ... story extend this map") anticipates and
  sanctions exactly this kind of addition.

**Downstream:** Story 6d's bulk-override action is scoped to reuse this story's
`Nebu.Media.admin_override_infected/3` per-file inside a `batch_id`-fan-out loop (per 6a's
"Downstream" note and this story's forward-compatibility guardrail above), rather than
reimplementing the reason-validation/role-check/transition/audit sequence.

## Dev Agent Record

### Corrections

- **Migration renumbering:** the story's own Technical Requirements named `000024` (already taken
  by `000024_media_storage_config`, landed by Story 11a before this story's implementation pass).
  Verified `server/priv/migrations/` at implementation time — next free sequential pair was
  `000030` (000030-`media_admin_override_role`.{up,down}.sql), after `000029_media_state_transitions_actor_id_text`.
  Also extended `test/nebu/release_test.exs`'s `list_up_migrations/1` version-list assertion and
  `test/nebu/matrix/migrations_grant_test.exs`'s `@down_migrations` no-grant regression list to
  include the new file, mirroring 6a's own precedent for migration 000029.
- **GRANT verification (no new GRANT needed, confirmed not assumed):** this migration only
  `ALTER TABLE users ADD COLUMN media_admin_override ...` — `users` was created by
  `000001_init.up.sql`, which ends with a blanket
  `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app`. A table-level
  GRANT automatically covers columns added later via `ALTER TABLE ... ADD COLUMN` — there is no
  per-column GRANT in PostgreSQL. Cross-checked against `migrations_grant_test.exs`'s own AC1 (only
  migrations that `CREATE TABLE` need an explicit GRANT) — this migration doesn't, so none was added.
- **AC1 guard-table-alone insufficiency (found via this story's own ATDD, fixed before completion):**
  the story's Technical Requirements code sketch relies solely on `StateMachine.transition/4`'s
  generic `allowed?/2` guard to reject non-`:infected` source states. That is NOT sufficient: the
  shared `@transitions` guard table already legitimately allows `:scanning -> :released` (clean-scan
  result, 4b), `:admin_blocked -> :released` (admin_unblock, 6a), and `:scan_failed -> :released`
  (admin manual clear, 4a) for OTHER callers/actions — none of which know or care that
  `admin_override_infected/3` is the one calling `transition/4` this time. Acceptance Test 9's
  table-driven case caught this immediately: an override attempt against a genuinely-`:scanning`
  file incorrectly returned `{:ok, :released}` instead of being rejected. Fixed by adding an
  explicit `check_infected/1` guard (current state must be exactly `:infected`) between the
  `lookup_state/1` read and the `transition/4` call — same error shape AC1 requires
  (`{:error, {:invalid_transition, from, :released}}`), never reaching `transition/4` or the audit
  log for a non-`:infected` source. Re-verified against the full table-driven test (all 7
  non-infected states) plus the release/quarantined/admin_blocked/scan_failed/reserved/hard_deleted
  individual cases — all green after the fix.
- **AC1 Acceptance Test 9 completeness (MINOR-1, test-review):** added `:hard_deleted` to the
  table-driven reject-non-infected-states test's state list (previously covered 7 of the 8 states
  named in AC1, `:released` covered separately by Acceptance Test 8) — one line, no behavior change,
  closes the gap flagged in pre-dev test-review.
