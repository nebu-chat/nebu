# Epic room-naming-and-default-rooms — Security Review — 2026-05-28

## Scope

- **Epic:** room-naming-and-default-rooms
- **Base:** 43006900 (`feat(media): add Media Gateway support with S3 bucket integration`)
- **HEAD:** 9d8bd9bc (`chore(pipeline): mark admin-auto-join-rooms as done`)
- **Stories covered:**
  - `personal-self-room` — personal room created at first login via non-blocking `Task` in `validate_token/2`
  - `admin-auto-join-rooms` — admin UI toggle (`is_auto_join`), new users auto-joined at first login
  - `direct-room-heroes` — populate `m.heroes` / joined/invited counts in `/sync` response
- **Reviewer:** Kassandra
- **Verdict:** **APPROVED — CLEAN at CRITICAL/HIGH** (2 MEDIUM advisories, 3 LOW)

---

## Summary

| Severity | Count | Block? |
|---|---|---|
| CRITICAL | 0 | — |
| HIGH | 0 | — |
| MEDIUM | 2 | Advisory — address before next epic touches `update_room_settings` |
| LOW | 3 | Advisory |

Follow-up stories required: **0** (no CRITICAL/HIGH).
Accepted risks: **0**.

**Epic security gate: PASS.** The new attack surfaces in this epic (gRPC `is_auto_join` field, fire-and-forget login `Task`, `attach_heroes` DB read) are all routed through the existing gateway auth wall (sessionGuard + CSRF + admin role) and the existing PSK boundary on the Core gRPC port. SQL is fully parameterised. The `m.heroes` data is only attached to rooms the syncing user is already a joined member of — no IDOR. Personal-room creation does not bypass signing-key handling (uses the server signing key consistently with all other server-emitted events).

The two MEDIUMs are a pair: they describe the same architectural seam — `update_room_settings/2` discards `_stream` metadata AND emits no `audit_log` entry — which the epic widened (not introduced) by adding a security-relevant boolean (`is_auto_join`) to that RPC's payload.

---

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| F-1 | MEDIUM | admin-auto-join-rooms | `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex:333` | `update_room_settings/2` accepts `_stream` (discards trusted identity); now sets `is_auto_join` — sensitive policy field — without verifying the gRPC caller | New |
| F-2 | MEDIUM | admin-auto-join-rooms | `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex:333-363` | No `audit_log` entry emitted when `is_auto_join` is toggled. Gateway comment claims "Core audit log records actor_user_id" — false; no audit_writer call exists in this RPC | New |
| F-3 | LOW | personal-self-room | `server.ex:1656-1684` + `room_manager/lib/nebu/room/db.ex:824-828` | Concurrent first-login race can leave one orphan personal-room row (the losing UPDATE matches zero rows; orphan room still has m.room.create / m.room.member / m.room.name written by the losing branch) | New |
| F-4 | LOW | admin-auto-join-rooms | `core/apps/room_manager/lib/nebu/room/server.ex:261-287` (called from `server.ex:1700-1722`) | `Nebu.Room.Server.join` does not check `m.room.join_rules` or ban state. Marking `is_auto_join=true` will force-add new users to any room regardless of intended membership policy. Pre-existing weakness; this epic makes it reachable on every new-user signup. | New (architectural / informational) |
| F-5 | LOW | direct-room-heroes | `dev/dex/config.yaml:78-99` | Three new dev users (alice / bob / charlie) share one bcrypt password hash. Dev-only fixture (ADR-012 example-only credentials) — reminder, not a finding | Informational |

---

## Detail

### F-1 — `update_room_settings/2` accepts `_stream` (anonymous-on-Core RPC for sensitive policy field) — MEDIUM

**Location:** `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex:333`

```elixir
def update_room_settings(%Core.UpdateRoomSettingsRequest{} = req, _stream) do
  room_id = req.room_id
  max_members = req.max_members
  …
  if not is_nil(req.is_auto_join) do
    case admin_db_module().update_room_auto_join(room_id, req.is_auto_join) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("update_room_settings: update_room_auto_join failed …")
    end
  end
  %Core.UpdateRoomSettingsResponse{ok: true}
end
```

The handler signature uses `_stream` — the gRPC `Nebu.Grpc.Metadata.trusted_identity/1` extraction is absent. Compare with every other admin-shaped RPC in the same file (`set_user_role`, `archive_room`, `update_server_config`, `gdpr_delete_user`, `bulk_import_users` after Epic 14 remediation, etc.), all of which extract `{user_id, system_role}` from the stream and reject anonymous callers.

**Why this is now MEDIUM:** Pre-this-epic, this RPC only carried `max_members` (a soft cap). This epic adds `is_auto_join` to the same proto message. `is_auto_join=true` on a room causes **every future first-login** to be auto-subscribed to that room — a persistent, server-wide membership policy. Flipping it is at least as security-relevant as `archive_room` or `set_role`.

**Why not HIGH:**
- The Go gateway enforces `bodyLimit64KiB(csrf(sessionGuard(...)))` on `POST /admin/rooms/{roomId}/settings` (`cmd/gateway/main.go:454`) — admin role + CSRF + body limit at the public boundary.
- The Core gRPC port is segregated by the internal PSK / Compose-secret boundary (ADR-008). To reach Core directly, an attacker needs network position inside the cluster plus the PSK.

**Why still MEDIUM:**
- The same pattern was flagged HIGH in Epic 14 (F-2 `bulk_import_users`) precisely because **the Core port has been exposed in production topologies before** (Stackit / VM deployments without strict L3 isolation).
- A misconfiguration (Core gRPC bound to `0.0.0.0` instead of internal interface, missing firewall rule) would let any caller who can reach the port flip `is_auto_join=true` on any room, with no authentication and no audit trace.
- This is **inconsistent** with sibling admin RPCs — a developer reading the file may copy this pattern into a new admin RPC.

**Remediation:**

```elixir
def update_room_settings(%Core.UpdateRoomSettingsRequest{} = req, stream) do
  {actor_id, system_role} = Nebu.Grpc.Metadata.trusted_identity(stream)

  if is_nil(actor_id) or actor_id == "" do
    raise GRPC.RPCError,
      status: GRPC.Status.unauthenticated(),
      message: "missing trusted identity"
  end

  unless system_role in ["instance_admin"] do
    raise GRPC.RPCError,
      status: GRPC.Status.permission_denied(),
      message: "instance_admin role required"
  end
  …
end
```

Add a regression test analogous to `auto_join_rooms_test.exs` that asserts the RPC raises `GRPC.Status.unauthenticated()` when the stream has no `x-user-id` metadata.

---

### F-2 — No `audit_log` entry for `is_auto_join` toggle — MEDIUM

**Location:** `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex:348-360`

The `is_auto_join` branch updates `rooms.is_auto_join` and exits. No `audit_writer_module().log(...)` call.

Sibling admin operations all emit audit_log entries:
- `archive_room` (`server.ex:2248`): `audit_writer_module().log(actor_id, "room_archived", …)`
- `set_user_role`: emits `user_role_changed`
- `update_server_config`: emits `server_config_updated`
- `gdpr_delete_user`: emits `user_gdpr_deleted`
- `bulk_import_users` (post-Epic-14 fix): emits `users_bulk_imported`

**Gateway side claim, in `gateway/internal/admin/rooms.go:401-402`:**

```go
// gRPC path — enrich context with admin identity so Core audit log records actor_user_id.
grpcCtx := contextWithAdminIdentity(r.Context(), AdminSubFromContext(r.Context()))
```

This comment **promises** that Core logs the actor for this RPC. It does not. The gateway populates the metadata, but Core's `update_room_settings/2` neither reads the metadata (F-1) nor writes any audit row.

**Risk shape:**
- A malicious or careless instance_admin can repeatedly toggle `is_auto_join` on/off across rooms — onboarding new users to whichever rooms are flagged true at the moment of their first login — with no audit trail to show who flipped what when.
- Post-incident forensics ("how did everyone end up in #all-hands?") have no record to query.

**Pattern match (MEMORY.md):** "Bulk operation with no audit_log entry" (Epic 14). The `is_auto_join` toggle is a one-row UPDATE but its effect is bulk (every future new user). Audit-completeness invariants must follow the **shape** of the action, not just the row count.

**Remediation:** Inside the `if not is_nil(req.is_auto_join)` block, after `:ok`:

```elixir
audit_writer_module().log(
  actor_id,  # from trusted_identity stream (F-1 remediation)
  "room_auto_join_changed",
  "room",
  room_id,
  %{"is_auto_join" => req.is_auto_join},
  "success"
)
```

Also add `"room_auto_join_changed"` to `@known_actions` in `compliance/audit_writer.ex`.

Also: update the gateway-side comment in `rooms.go:401-402` so it does not misrepresent the current behaviour.

---

### F-3 — Concurrent first-login race leaks orphan personal-room rows — LOW

**Location:**
- `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex:1656-1684` (ensure_personal_room)
- `core/apps/room_manager/lib/nebu/room/db.ex:824-828` (set_personal_room_id)

**Mechanism:**

`set_personal_room_id` uses `UPDATE users SET personal_room_id = $2 WHERE user_id = $1 AND personal_room_id IS NULL` — this guard correctly prevents `personal_room_id` from being **overwritten** in a race.

But the check-then-act pattern in `ensure_personal_room/1` is:

```elixir
case messages_db_module().get_personal_room_id(user_id) do
  {:ok, nil} ->
    {:ok, room_id} = create_personal_room(user_id, localpart)  # creates rows
    messages_db_module().set_personal_room_id(user_id, room_id)
```

Two simultaneous logins of the same new user (e.g. two browser tabs completing the OIDC dance at the same time) both see `personal_room_id IS NULL`, both call `create_personal_room`, both write a distinct `room_id` plus 4 events (m.room.create, m.room.member, m.room.power_levels, m.room.name) plus 1 row in `rooms` plus 1 row in `room_members`. Only one then wins the UPDATE; the loser leaves an **orphan room** that the user is the sole creator/member of but which is not the canonical personal room.

**Why LOW:**
- No security boundary is crossed. Both rooms are owned by the same user at PL 100.
- The orphan room appears in the user's `/sync` (because `room_members` has them as a member) — UX confusion, not exfiltration.
- Cleanup is non-trivial but bounded: at most one orphan per concurrent-login race.

**Not flagged as MEDIUM/HIGH** because:
- The orphan does not grant any privilege or data the user did not already have.
- The Matrix spec is permissive about "personal rooms" — clients may also create them client-side.

**Remediation (defensive):** Wrap the create + set into a transaction with `SELECT ... FOR UPDATE`, or move the existence check to be `INSERT INTO rooms ... ON CONFLICT (room_id) DO NOTHING` after first acquiring a per-user advisory lock (`pg_advisory_xact_lock(hashtext(user_id))`). Story-acceptable alternative: leave as-is, document the race in MEMORY.md, add a janitor that deletes rooms with `members=1, member==creator, personal_room_id != room_id`.

---

### F-4 — Auto-join bypasses (non-existent today) join_rule and ban checks — LOW (informational)

**Location:** `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex:1700-1722` → `Nebu.Room.Server.join/2` (`room_manager/lib/nebu/room/server.ex:261-287`).

`Nebu.Room.Server.handle_call({:join, user_id}, ...)` enforces only:
1. `MapSet.member?(members, user_id)` → `:already_member`
2. `max_members > 0 and size >= max_members` → `:room_full`
3. Otherwise: insert member, emit m.room.member join.

It does **not** check:
- `m.room.join_rules` (e.g. `invite`, `knock`, `restricted`)
- Existing `m.room.member` event with `membership: "ban"` for this user_id
- Soft-leave / kick history

**Why LOW today:** None of these state events are validated anywhere in the Elixir Core. The Matrix join_rule subsystem is not yet implemented in Nebu MVP. Ban events do not exist as a code path. So this is **architectural / informational** — not exploitable against any existing protection.

**Why worth flagging:** When `m.room.join_rules` / ban support is added (future epic), `is_auto_join` must be revisited as a **second authorisation path** that bypasses those checks. Otherwise an admin who marks a previously-restricted room `is_auto_join=true` will silently re-add previously-banned users at their next login.

**Pattern (carry into MEMORY.md):** *"Auto-join feature pre-dates ban/join_rule enforcement — when ban support lands, the auto-join code path must call the same check that the manual /join handler does."*

**Remediation when ban/join_rule is implemented:**
- Add `Nebu.Room.Server.handle_call({:auto_join, user_id}, ...)` that calls `handle_call({:join, ...})` with an extra "respect join_rule" branch.
- Or: gate `is_auto_join=true` to public rooms only at the UI layer (template `{{ if eq .ActiveRoom.Visibility "public" }}…`).

---

### F-5 — Dev dex users share bcrypt hash — LOW (informational, ADR-012 example-only)

**Location:** `dev/dex/config.yaml:78-99`

The three new test users (`alice`, `bob`, `charlie`) all carry the same bcrypt hash `$2a$10$E4ye88CWSgoigClMVojmGOu.gHlKe7L7RRf07QWZ60aZmZ7Rfak/6` — i.e. the same password. This is dev-only OIDC seeding for the Godog/Playwright tests; ADR-012 marks all `dev/` credentials as example-only.

**Not a finding** — recorded for completeness so the audit trail shows this was reviewed and dismissed.

---

## Cross-Story Patterns

### Pattern A — `update_room_settings/2` widening (F-1 + F-2 are the same architectural gap)

This is the **third recurrence** of the pattern `MEMORY.md: "gRPC handler ignoring stream metadata = anonymous-RPC bypass"` (introduced in Epic 14):
- Epic 14: `bulk_import_users/2` shipped with `_stream` — escalated to HIGH because the proto carried caller-controlled `system_role`. Fixed via stream extraction + `system_role` hard-coded to `"user"`.
- Epic 13.14 (audit_log RLS): formally accepted that DB-enforced immutability is application-only on managed PG.
- **This epic:** `update_room_settings/2` was already `_stream` (Story 6.8 legacy) but the field set was narrow (`max_members`). Adding `is_auto_join` raises the policy weight of the same handler.

**Recommendation for `_bmad/memory/nebu-agent-kassandra/MEMORY.md`:** add an explicit lint rule — *"Whenever a proto message is extended with a new field whose semantics extend beyond the existing handler's risk profile, re-audit the handler signature for `_stream` and the body for `audit_writer.log`."* I will add this to MEMORY.md at session close.

### Pattern B — Fire-and-forget `Task.start` from RPC handlers

`validate_token/2` now spawns `Task.start(fn -> ensure_personal_room(user_id); if is_new, do: ensure_auto_join_memberships(user_id) end)`. The Task:
- has no supervisor
- has no telemetry
- has no logged duration
- can crash silently (`Task.start` discards crashes by default)

**Not a security finding** — every error path inside the helpers explicitly catches and returns `:ok` with a `Logger.warning`. But the lack of supervision means:
- a runtime exception (e.g. `:persistent_term.get(:nebu_signing_key)` race at boot, BadMapError on `state.members`, etc.) would silently lose the self-room creation for that login.
- The user logs in successfully → no observable error → personal_room_id stays NULL → next login retries (eventually consistent).

If self-room creation becomes a hard requirement for compliance (e.g. "every user must have a personal storage room for E2EE keys"), this fire-and-forget shape will silently violate that invariant. Track as a pattern, not a finding.

---

## Accepted Risks

None this epic.

## Follow-up Stories Required

None blocking. Recommended (not required for epic completion):

1. **F-1 + F-2 remediation story** (`fix/update-room-settings-trusted-identity`) — bundle stream extraction + audit_log emit + regression test. Estimated 1 story-day.
2. **F-3 race-hardening story** (optional, ship when QA reports the orphan-room observable) — wrap personal-room creation in an advisory lock or `ON CONFLICT (user_id) DO NOTHING` semantic.

---

## What Was Reviewed (Audit Trail)

- Full `git diff 43006900..HEAD` (3,991 insertions, 57 deletions across 50 files)
- Migration: `gateway/migrations/000001_init.up.sql` — new `users.personal_room_id TEXT REFERENCES rooms(room_id)` FK + new `rooms.is_auto_join BOOLEAN NOT NULL DEFAULT false` + partial index `rooms_auto_join_idx ON rooms (is_auto_join) WHERE is_auto_join = true`. No new RLS gaps (consistent with pre-existing posture: `rooms`/`users` have no RLS, only secondary tables do).
- All new SQL: parameterised via `Ecto.Adapters.SQL.query/3` with `$1`/`$2` placeholders. No string concatenation. Reviewed:
  - `Nebu.Room.DB.get_room_heroes/2` (`room_manager/lib/nebu/room/db.ex:650`) — UNION ALL of two parameterised SELECTs. Clean.
  - `Nebu.Room.DB.get_personal_room_id/1`, `set_personal_room_id/2` (`db.ex:824-840`) — single-row UPDATE with `WHERE personal_room_id IS NULL` race-guard. Clean.
  - `Nebu.Room.DB.list_auto_join_rooms/0` (`db.ex:905-918`) — no parameters, fixed predicate. Clean.
  - `Nebu.Admin.DB.update_room_auto_join/2` (`admin/db.ex:421-428`) — parameterised UPDATE. Clean.
- Gateway sync path: `gateway/internal/matrix/sync.go:382-405` (new `syncRoomSummary` struct) and `:790-816` (attach summary when proto3 zero values absent). `Summary *syncRoomSummary` is pointer + `omitempty`, so named rooms emit no `summary` key. IDOR risk: zero — summary is attached only to rooms in `joinedRooms` (`fetch_user_room_ids` → `Enum.flat_map(room_ids, ...)`), which is the caller's joined-room set.
- gRPC trust boundary: `validate_token/2` correctly calls `Nebu.Grpc.Metadata.trusted_identity(stream)` and raises `GRPC.Status.unauthenticated()` on empty user_id (`server.ex:728-735`). The `Task.start` spawned from this handler inherits `user_id` from the validated metadata, so all subsequent room creation / auto-join is bound to the authenticated identity.
- CSRF + body limit + admin session guard: `POST /admin/rooms/{roomId}/settings` is wrapped with `bodyLimit64KiB(csrf(sessionGuard(...)))` (`cmd/gateway/main.go:454`). Unchanged by this epic. CSRF token is read from form via the existing double-submit-cookie pattern.
- Signing key handling in `create_personal_room/2` (`server.ex:1741-1834`): uses `:persistent_term.get(:nebu_signing_key)` — the server signing key, consistent with all other server-emitted events (m.room.create, m.room.member, m.room.power_levels, m.room.name). No new key material introduced; no key in error logs or argv.
- No new HTML-rendered content — `gateway/internal/admin/templates/rooms.html` adds a checkbox toggle; the only new template binding is `{{ if .ActiveRoom.IsAutoJoin }}checked{{ end }}` which is a boolean Go template attribute, not user-controlled HTML. No XSS surface added.
- No new public/unauthenticated HTTP routes.
- No new secrets in source, no MD5/SHA1/DES, no JWT validation changes, no body-size-limit changes, no new rate-limit-exempt paths.

---

## Final Verdict

**APPROVED / CLEAN at CRITICAL/HIGH.**

Epic security gate: **PASS.** Commit and merge to `develop` are not blocked.

Two MEDIUM advisories should become a single remediation story before any future epic widens `update_room_settings` further. The audit-log gap (F-2) is the more urgent of the two — without it, forensic queries cannot reconstruct who flipped `is_auto_join` on which room when.

— Kassandra, 2026-05-28
