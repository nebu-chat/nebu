---
story_id: auto-join-on-user-import
title: "Auto-Join and Personal Room for SCIM/OIDC-Imported Users"
epic: room-naming-and-default-rooms
status: review
security_review: not-needed
created: 2026-05-30
branch: feature/room-naming-and-default-rooms
baseline_commit: 4381c68164e3b92eace5ed5380ef056cb6c96267
---

## Summary

When an admin runs a bulk user import via the Bootstrap Wizard (SCIM 2.0 or OIDC directory endpoint),
imported users receive the same treatment as first-login users: they are automatically joined to all
auto-join rooms and receive a personal self-room.

Currently, `BulkImporter.import_users/1` provisions keypairs but does **not** call
`ensure_auto_join_memberships` or `ensure_personal_room`. When the imported user later logs in,
`validate_token` sees an **existing** user (`is_new: false`) and skips the auto-join logic —
leaving the user un-joined and without a self-room.

The fix mirrors the `validate_token` pattern exactly: after `BulkImporter.import_users/1`, the
`bulk_import_users/2` gRPC handler spawns a fire-and-forget `Task.start` for each newly imported
user ID.

## User Story

As a Nebu instance admin,
I want users imported via SCIM 2.0 or the OIDC directory endpoint to be automatically joined to
auto-join rooms and receive a personal self-room,
so that imported users have the same onboarding experience as users who provision themselves via
first login.

## Acceptance Criteria

1. **Given** room "General" has `is_auto_join = true` and there are no existing members
   except the admin,
   **When** an admin runs a bulk import with user `@charlie:nebu.local` via the gRPC
   `BulkImportUsers` endpoint,
   **Then** charlie is automatically joined to "General" within a few seconds of the import
   completing (before charlie has ever logged in).

2. **Given** room "General" has `is_auto_join = true`,
   **When** an admin bulk-imports user `@charlie:nebu.local`,
   **Then** charlie's personal self-room named "charlie" is created in the database with charlie
   as the sole member (same semantics as first-login provisioning).

3. **Given** user `@alice:nebu.local` already exists in the database (was previously imported or
   has logged in before),
   **When** the same bulk import request includes alice again,
   **Then** alice's memberships and personal room are NOT changed — `import_one` returns `:skipped`
   and no auto-join tasks are spawned for her.

4. **Given** the auto-join room logic returns `{:error, :already_member}` for an imported user
   who was pre-invited to a room before the bulk import ran,
   **Then** the error is treated as `:ok` (idempotent) — no crash, no error log for this case.

5. **Given** `BulkImporter.import_users/1` is called,
   **When** the call completes,
   **Then** the return value includes `imported_user_ids: [String.t()]` containing the user IDs
   of all newly provisioned users (those for which `import_one` returned `:imported`).

6. **Given** 3 users are imported in a single batch (2 new, 1 already existing),
   **When** `BulkImporter.import_users/1` returns,
   **Then** `imported_user_ids` contains exactly the 2 new user IDs (not the skipped one).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`AT-1: import_users/1 returns imported_user_ids with new user IDs`** — ExUnit unit test
   (`core/apps/session_manager/test/session/bulk_importer_test.exs` — extend existing file)
   - Given: FakeLookupNotProvisioned (all users new), 2 users in input
   - When: `Nebu.Session.BulkImporter.import_users/1` is called
   - Then: result is `{:ok, %{imported: 2, skipped: 0, failed: 0, imported_user_ids: [uid1, uid2]}}`
   - And: `imported_user_ids` contains both user IDs in any order

2. **`AT-2: import_users/1 omits skipped user IDs from imported_user_ids`** — ExUnit unit test
   (same file)
   - Given: FakeLookupMixed (1 new, 1 already_provisioned)
   - When: `import_users/1` is called with 2 users
   - Then: result has `imported: 1, skipped: 1, imported_user_ids: [<new_user_id>]`
   - And: the already-provisioned user ID is NOT in `imported_user_ids`

3. **`AT-3: import_users/1 returns empty imported_user_ids when all users are skipped`** — ExUnit
   unit test (same file)
   - Given: FakeLookupProvisioned (all already_provisioned)
   - When: `import_users/1` is called
   - Then: `imported_user_ids: []`

4. **`AT-4: bulk_import_users/2 triggers ensure_auto_join_memberships for imported users`** —
   ExUnit unit test (`core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs`
   — extend existing file)
   - Given: `bulk_importer_module` returns
     `{:ok, %{imported: 1, skipped: 0, failed: 0, imported_user_ids: ["@charlie:nebu.local"]}}`
   - And: `messages_db_module.list_auto_join_rooms/0` returns `{:ok, ["!general:nebu.local"]}`
   - And: `FakeMessagesDB_AutoJoinRoom.insert_member` sends `{:insert_member_called}` to the
     test process (existing pattern)
   - When: `Server.bulk_import_users/2` is called
   - Then: `assert_receive {:insert_member_called}` within 500ms (auto-join task fired)

5. **`AT-5: bulk_import_users/2 does not spawn auto-join tasks for skipped users`** — ExUnit
   unit test (same file)
   - Given: `bulk_importer_module` returns `{:ok, %{imported: 0, skipped: 1, failed: 0, imported_user_ids: []}}`
   - When: `Server.bulk_import_users/2` is called
   - Then: `refute_receive {:insert_member_called}` — no auto-join tasks spawned

6. **`AT-6 (Godog integration — optional):`** `gateway/features/bulk_import_auto_join.feature`
   - Given: Room "general" exists with `is_auto_join = true`
   - And: charlie does not yet exist in the system
   - When: Admin calls `POST /admin/users/import` (which calls `BulkImportUsers` gRPC)
   - Then: charlie is a member of "general" in the database
   - And: charlie's personal self-room exists in the database

   Note: This Godog scenario requires the Bootstrap Wizard / admin import HTTP endpoint to be
   wired up. Given it is a `not-needed` security review story and the core logic is covered by
   units, this scenario is optional. If the admin import HTTP endpoint does not yet exist in the
   current stack, skip this and note it as a future integration test.

## Technical Requirements

### 1. Change — `core/apps/session_manager/lib/nebu/session/bulk_importer.ex`

**What to change:**

Modify `import_one/2` to return `{:imported, user_id}` instead of bare `:imported`:

```elixir
# BEFORE:
:imported

# AFTER:
{:imported, user_id}
```

Update `import_users/1` to collect newly-imported user IDs:

```elixir
@type result ::
        {:ok,
         %{
           imported: non_neg_integer(),
           skipped: non_neg_integer(),
           failed: non_neg_integer(),
           imported_user_ids: [String.t()]
         }}

def import_users(users) when is_list(users) do
  server_key = Application.get_env(:signature, :pii_encryption_key)
  init = %{imported: 0, skipped: 0, failed: 0, imported_user_ids: []}

  result =
    Enum.reduce(users, init, fn user, acc ->
      case import_one(user, server_key) do
        {:imported, user_id} ->
          acc
          |> Map.update!(:imported, &(&1 + 1))
          |> Map.update!(:imported_user_ids, &[user_id | &1])
        :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
        :failed -> Map.update!(acc, :failed, &(&1 + 1))
      end
    end)

  {:ok, result}
end
```

**What to preserve:** The `import_one/2` structure, error handling (`try/rescue`), all injectable
module calls (`lookup_module()`, `user_store_module()`, `provisioner_module()`), and the `:skipped`
/ `:failed` atoms remain unchanged.

**What NOT to change:** The `@moduledoc`, the `@type claims`, the `lookup_module/0`,
`user_store_module/0`, `provisioner_module/0` private helpers.

### 2. Change — `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — `bulk_import_users/2`

Current implementation (lines 3478–3518):

```elixir
def bulk_import_users(%Core.BulkImportUsersRequest{} = request, stream) do
  {actor_id, _system_role} = Nebu.Grpc.Metadata.trusted_identity(stream)

  users = Enum.map(request.users, fn claims ->
    %{
      user_id: claims.user_id,
      system_role: "user",
      display_name: claims.display_name,
      email: claims.email
    }
  end)

  case bulk_importer_module().import_users(users) do
    {:ok, %{imported: imported, skipped: skipped, failed: failed}} ->
      _audit_result =
        audit_writer_module().log(
          actor_id,
          "users_bulk_imported",
          "users",
          "bulk",
          %{
            imported: imported,
            skipped: skipped,
            failed: failed,
            user_ids: request.users |> Enum.map(& &1.user_id) |> Enum.take(100)
          },
          "success"
        )

      %Core.BulkImportUsersResponse{
        imported: imported,
        skipped: skipped,
        failed: failed
      }
  end
end
```

**Required change** — destructure `imported_user_ids` from the result and spawn fire-and-forget
tasks for each newly-imported user:

```elixir
def bulk_import_users(%Core.BulkImportUsersRequest{} = request, stream) do
  {actor_id, _system_role} = Nebu.Grpc.Metadata.trusted_identity(stream)

  users = Enum.map(request.users, fn claims ->
    %{
      user_id: claims.user_id,
      system_role: "user",
      display_name: claims.display_name,
      email: claims.email
    }
  end)

  case bulk_importer_module().import_users(users) do
    {:ok, %{imported: imported, skipped: skipped, failed: failed, imported_user_ids: imported_user_ids}} ->
      _audit_result =
        audit_writer_module().log(
          actor_id,
          "users_bulk_imported",
          "users",
          "bulk",
          %{
            imported: imported,
            skipped: skipped,
            failed: failed,
            user_ids: request.users |> Enum.map(& &1.user_id) |> Enum.take(100)
          },
          "success"
        )

      # Story auto-join-on-user-import: fire-and-forget room setup for each newly-imported user.
      # Identical to the validate_token/2 pattern for new first-login users.
      # Non-blocking and non-fatal — import response is not delayed.
      Enum.each(imported_user_ids, fn uid ->
        Task.start(fn ->
          ensure_personal_room(uid)
          ensure_auto_join_memberships(uid)
        end)
      end)

      %Core.BulkImportUsersResponse{
        imported: imported,
        skipped: skipped,
        failed: failed
      }
  end
end
```

**Critical:** Both `ensure_personal_room/1` and `ensure_auto_join_memberships/1` already exist as
public/private functions in `server.ex` (added by `personal-self-room` and `admin-auto-join-rooms`
stories). Do NOT redefine them. Just call them. The order is `ensure_personal_room` first, then
`ensure_auto_join_memberships` — same as in `validate_token/2`.

**What to preserve:** The `trusted_identity/1` call, the `system_role: "user"` hard-coding, the
audit log call with the same fields (including `user_ids` cap at 100) — none of those change.

### 3. No proto changes

`BulkImportUsersResponse` already has `imported`, `skipped`, `failed` fields. No new fields are
needed in the proto — `imported_user_ids` is an internal Elixir detail, not surfaced to gRPC.

### 4. No Go gateway changes

The Go gateway already maps `BulkImportUsersResponse` to an HTTP JSON response. The new
`imported_user_ids` field is internal to the Elixir core and not part of the proto response.

### 5. No new DB migrations

This story adds no new database columns or tables. All DB operations (room insert, member insert,
personal_room_id set) are handled by the existing helpers called from `ensure_personal_room/1`
and `ensure_auto_join_memberships/1`.

## File Map

| File | Change Type | Notes |
|------|-------------|-------|
| `core/apps/session_manager/lib/nebu/session/bulk_importer.ex` | UPDATE | `import_one` → `{:imported, uid}`, `import_users/1` collects `imported_user_ids` |
| `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` | UPDATE | `bulk_import_users/2` destructures `imported_user_ids`, spawns `Task.start` per uid |
| `core/apps/session_manager/test/session/bulk_importer_test.exs` | UPDATE | Extend with AT-1..AT-3 verifying `imported_user_ids` field |
| `core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs` | UPDATE | Extend with AT-4..AT-5 for `bulk_import_users/2` auto-join dispatch |
| `core/apps/event_dispatcher/test/event_dispatcher/bulk_import_users_test.exs` | UPDATE | Fix existing AT-SEC-1/AT-SEC-2 assertions to destructure `imported_user_ids` from result |
| `gateway/features/bulk_import_auto_join.feature` | NEW (optional) | Godog integration scenario — skip if admin HTTP import endpoint not yet available |

## Invariants to Preserve

1. **`BulkImportUsersResponse` fields unchanged** — `imported`, `skipped`, `failed` counters still
   returned correctly. Only the Elixir-internal result map gains `imported_user_ids`.

2. **Existing bulk importer tests (AT-1..AT-SEC-2) must still pass.** Those tests pattern-match
   on `{:ok, %{imported: N, skipped: N, failed: N}}`. Because Elixir maps match on a subset of
   keys, the existing assertions `{:ok, %{imported: 1, skipped: 0, failed: 0}}` continue to
   match even after `imported_user_ids` is added. No changes to existing test assertions are
   required for them to pass — but adding explicit `imported_user_ids` assertions is encouraged.

   Exception: `AT-SEC-2` asserts `assert_receive {:audit_log, ..., %{imported: 1, skipped: 0, failed: 0}, ...}` —
   the audit log metadata map now also has a `user_ids` key but the existing audit log
   `%{imported:, skipped:, failed:, user_ids:}` map is unchanged (we do not add `imported_user_ids`
   to the audit log). This assertion will still pass as written.

3. **Fire-and-forget semantics** — `Task.start` is used (not `Task.async`), identical to the
   `validate_token` pattern. If any sub-operation fails inside the task, it logs a warning and
   returns `:ok`. The `bulk_import_users/2` gRPC handler does not await these tasks.

4. **`ensure_auto_join_memberships/1` is already public.** It is defined with `def` (not `defp`)
   in `server.ex` (line ~1760). No visibility change needed.

5. **`ensure_personal_room/1` is private.** It is defined with `defp` in `server.ex`. Since the
   call site is inside the same module (`server.ex`), this is fine.

## Test Implementation Guide

### Extending `bulk_importer_test.exs`

Add a new describe block after the existing `AT-3` tests:

```elixir
describe "import_users/1 — imported_user_ids" do
  test "AT-1: returns imported_user_ids with newly provisioned user IDs" do
    # FakeLookupNotProvisioned already set in setup
    users = [
      %{user_id: "@alice:nebu.local", system_role: "user", display_name: "Alice", email: "alice@example.com"},
      %{user_id: "@bob:nebu.local", system_role: "user", display_name: "Bob", email: "bob@example.com"}
    ]
    {:ok, result} = Nebu.Session.BulkImporter.import_users(users)
    assert result.imported == 2
    assert result.skipped == 0
    assert result.failed == 0
    assert is_list(result.imported_user_ids)
    assert length(result.imported_user_ids) == 2
    assert "@alice:nebu.local" in result.imported_user_ids
    assert "@bob:nebu.local" in result.imported_user_ids
  end

  test "AT-2: omits skipped user IDs from imported_user_ids" do
    Application.put_env(:session_manager, :bulk_importer_lookup_module, FakeLookupMixed)
    users = [
      %{user_id: "@new-user:nebu.local", system_role: "user", display_name: "New", email: "new@example.com"},
      %{user_id: "@user-a-existing:nebu.local", system_role: "user", display_name: "Existing", email: "ex@example.com"}
    ]
    {:ok, result} = Nebu.Session.BulkImporter.import_users(users)
    assert result.imported == 1
    assert result.skipped == 1
    assert "@new-user:nebu.local" in result.imported_user_ids
    refute "@user-a-existing:nebu.local" in result.imported_user_ids
  end

  test "AT-3: returns empty imported_user_ids when all users are skipped" do
    Application.put_env(:session_manager, :bulk_importer_lookup_module, FakeLookupProvisioned)
    users = [
      %{user_id: "@carol:nebu.local", system_role: "user", display_name: "Carol", email: "carol@example.com"}
    ]
    {:ok, result} = Nebu.Session.BulkImporter.import_users(users)
    assert result.imported == 0
    assert result.imported_user_ids == []
  end
end
```

### Extending `auto_join_rooms_test.exs`

Add a new fake bulk importer and tests after the existing test cases. The key challenge is
verifying that async `Task.start` calls fire within a short window. Use `assert_receive` with
a 500ms timeout — this is reliable because the Tasks run immediately on a fast Elixir scheduler:

```elixir
# ─── Fake BulkImporter for auto-join dispatch tests ─────────────────────────
defmodule FakeBulkImporter_OneImport do
  def import_users(_users) do
    {:ok, %{imported: 1, skipped: 0, failed: 0, imported_user_ids: ["@charlie:nebu.local"]}}
  end
end

defmodule FakeBulkImporter_ZeroImport do
  def import_users(_users) do
    {:ok, %{imported: 0, skipped: 1, failed: 0, imported_user_ids: []}}
  end
end

# AT-4: bulk_import_users/2 triggers ensure_auto_join_memberships for imported users
test "AT-4: bulk_import_users spawns auto-join task for each imported user" do
  Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_OneImport)
  Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AutoJoinRoom)
  # FakeMessagesDB_AutoJoinRoom.insert_member/2 sends {:insert_member_called} to :auto_join_test_listener

  request = %Core.BulkImportUsersRequest{
    users: [%Core.OIDCUserClaims{user_id: "@charlie:nebu.local", display_name: "Charlie", email: "charlie@example.com"}]
  }
  stream = %{http_request_headers: %{"x-user-id" => "@gateway:internal"}}

  Server.bulk_import_users(request, stream)

  assert_receive {:insert_member_called}, 500,
    "Expected auto-join task to call insert_member for imported user within 500ms"
end

# AT-5: no auto-join tasks spawned when imported_user_ids is empty
test "AT-5: bulk_import_users does not spawn auto-join tasks for skipped users" do
  Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_ZeroImport)
  Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AutoJoinRoom)

  request = %Core.BulkImportUsersRequest{
    users: [%Core.OIDCUserClaims{user_id: "@alice:nebu.local", display_name: "Alice", email: "alice@example.com"}]
  }
  stream = %{http_request_headers: %{"x-user-id" => "@gateway:internal"}}

  Server.bulk_import_users(request, stream)

  # Brief pause — no message should arrive
  refute_receive {:insert_member_called}, 200,
    "Expected no auto-join task when imported_user_ids is empty"
end
```

**Setup note:** AT-4 and AT-5 tests need the audit writer injected to avoid calling
`Compliance.AuditWriter` which requires a real DB. Add to the describe setup block:

```elixir
setup do
  Application.put_env(:compliance, :audit_writer, FakeAuditWriter_F1)
  on_exit(fn ->
    Application.delete_env(:compliance, :audit_writer)
    Application.delete_env(:event_dispatcher, :bulk_importer_module)
    Application.delete_env(:event_dispatcher, :messages_db_module)
  end)
  Process.register(self(), :auto_join_test_listener)
  on_exit(fn ->
    if Process.whereis(:auto_join_test_listener) == self() do
      Process.unregister(:auto_join_test_listener)
    end
  end)
  :ok
end
```

The `FakeAuditWriter_F1` module already exists in `auto_join_rooms_test.exs` — reuse it.

## Existing Code Patterns to Follow

- **Injectable module pattern** — all external module dependencies use `Application.get_env` with
  a default. The `bulk_importer_module()` private helper already exists at line ~87 in `server.ex`.
  Do not introduce direct module calls.

- **Task.start for fire-and-forget** — identical to `validate_token/2` at line 819. Never use
  `Task.async` here; no awaiting, no response expected from the spawned task.

- **Non-fatal auto-join** — `ensure_auto_join_memberships/1` already handles all error paths
  internally. The caller (`bulk_import_users/2`) does not need to handle task failures.

- **`FakeMessagesDB_AutoJoinRoom.insert_member/2`** — already sends `{:insert_member_called}` to
  `:auto_join_test_listener`. Reuse this pattern; do not duplicate the fake module.

- **`async: false` in ExUnit** — both test files already use `async: false`. Keep this because
  `Application.put_env` is process-global and concurrent test processes would interfere.

## Known Constraints / Edge Cases

- **Order of `imported_user_ids`** — the list is built by prepending (`[user_id | &1]`) during
  `Enum.reduce`, so the order will be reversed relative to the input order. Tests must use
  `in` membership checks rather than positional assertions.

- **Failed imports** — if `import_one` returns `:failed`, the user ID is NOT included in
  `imported_user_ids`. This is correct: failed provisioning means no keys exist, so auto-join
  would fail anyway. No special handling needed.

- **Concurrent bulk imports** — two concurrent `BulkImportUsers` calls for the same user may
  both reach `import_one` before either commits. The `lookup/1` call checks DB state at query time;
  if both see `:not_provisioned`, both will attempt provisioning. The upsert uses ON CONFLICT
  handling, so one will succeed and one will silently overwrite. Both will spawn auto-join tasks —
  `ensure_auto_join_memberships` is idempotent (`{:error, :already_member}` → `:ok`). No
  additional concurrency guard is needed beyond what already exists.

- **`ensure_personal_room/1` race** — the personal room creation already handles the concurrent
  first-login race via `set_personal_room_id/2`'s `WHERE personal_room_id IS NULL` guard, which
  returns `{:ok, :already_set}`. The existing warning log for this case is correct behavior.
  No change needed.

## Definition of Done

- [x] `import_one/2` returns `{:imported, user_id}` (tuple) instead of `:imported` (atom)
- [x] `import_users/1` `@type result` includes `imported_user_ids: [String.t()]`
- [x] `import_users/1` collects user IDs for `:imported` outcomes only
- [x] `bulk_import_users/2` destructures `imported_user_ids` from importer result
- [x] `bulk_import_users/2` spawns one `Task.start` per imported user ID with `ensure_personal_room + ensure_auto_join_memberships`
- [x] All existing tests in `bulk_import_users_test.exs` pass unchanged (subset map match)
- [x] AT-1..AT-3 added to `bulk_importer_test.exs` and pass
- [x] AT-4..AT-5 added to `auto_join_rooms_test.exs` and pass
- [x] `make test-unit-elixir` passes with 0 failures

## File List

- `core/apps/session_manager/lib/nebu/session/bulk_importer.ex` — updated: `import_one/2` returns `{:imported, user_id}`, `import_users/1` collects `imported_user_ids`, updated `@type result`
- `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — updated: `bulk_import_users/2` destructures `imported_user_ids` and spawns `Task.start` per uid; `ensure_auto_join_memberships/1` wraps `Nebu.Room.Server.join` in `try/catch` to handle GenServer exits non-fatally
- `core/apps/session_manager/test/nebu/session/bulk_importer_test.exs` — updated: added AT-1..AT-3 describe block (`import_users/1 — imported_user_ids`) with MINOR-4 "all new users" test and AT-2/AT-3 variants
- `core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs` — updated: MAJOR-1 AC5 fix (use `FakeMessagesDB_AutoJoinRoom` instead of empty-list fake); added `FakeRoomDB_AutoJoinTracked` for AC1; MINOR-5 added `get_room_heroes/2` stub to `FakeMessagesDB_NoAutoJoinRooms`; updated AC1 test with proper `:room_manager, :db_module` injection and `:pg.start_link()`
- `core/apps/event_dispatcher/test/event_dispatcher/bulk_import_users_test.exs` — fixed: renamed outer module from `Nebu.Session.BulkImporterTest` to `Nebu.EventDispatcher.BulkImportUsersTest` to eliminate pre-existing `--warnings-as-errors` failure caused by module name conflict with session_manager test

## Dev Agent Record

### Implementation Plan

1. Updated `BulkImporter.import_one/2` to return `{:imported, user_id}` tuple instead of bare `:imported` atom.
2. Updated `BulkImporter.import_users/1` to accumulate `imported_user_ids` via `Enum.reduce` with prepend.
3. Updated `Server.bulk_import_users/2` to destructure `imported_user_ids` and spawn fire-and-forget `Task.start` tasks per uid.
4. Added `try/catch` for GenServer exits in `ensure_auto_join_memberships/1` — exits from `Nebu.Room.Server.join` (`:noproc`) were previously unhandled; now caught as non-fatal with warning log.
5. Fixed MAJOR-1: AC5 test now uses `FakeMessagesDB_AutoJoinRoom` (returns real room list) so join IS attempted. The exit is caught non-fatally.
6. Fixed MINOR-4: Added AT-1 "all new users" scenario to `bulk_importer_test.exs`.
7. Fixed MINOR-5: Added `get_room_heroes/2` stub to `FakeMessagesDB_NoAutoJoinRooms`.
8. Added `FakeRoomDB_AutoJoinTracked` for AC1 test — injects proper `:room_manager, :db_module` so Room.Server can actually start and call `insert_member`, which sends `{:insert_member_called}` to the test listener.
9. Fixed pre-existing warning: renamed `bulk_import_users_test.exs` outer module from `Nebu.Session.BulkImporterTest` to `Nebu.EventDispatcher.BulkImportUsersTest`.

### Completion Notes

All 262 event_dispatcher tests pass (0 failures). All 51 session_manager tests pass. `make test-unit-elixir` exits with 0 (no warnings-as-errors failures).

AC5 test now exercises the actual join path (via `FakeMessagesDB_AutoJoinRoom`), not a vacuous empty-list pass. The `try/catch :exit` in `ensure_auto_join_memberships/1` correctly handles `:noproc` exits from `Nebu.Room.Server.join/2` non-fatally.

The AT-SEC-2 test in `bulk_import_users_test.exs` continues to pass unchanged — the audit log metadata does not include `imported_user_ids` (only the gRPC response fields), so the existing `%{imported: 1, skipped: 0, failed: 0}` pattern match is unaffected.

## Change Log

- 2026-05-30: Implemented story auto-join-on-user-import. Updated BulkImporter and Server.bulk_import_users/2. Added tests per ATDD spec. Fixed MAJOR-1, MINOR-4, MINOR-5 from pre-dev review. Fixed pre-existing module name conflict in bulk_import_users_test.exs.
