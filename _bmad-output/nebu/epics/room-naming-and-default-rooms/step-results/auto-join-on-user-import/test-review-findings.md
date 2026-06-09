# Test Review Findings — auto-join-on-user-import

## MAJOR-1 — AC5 unit test does not exercise :already_member path (passes vacuously)
auto_join_rooms_test.exs: "ensure_auto_join_memberships is idempotent" uses FakeMessagesDB_NoAutoJoinRooms
which returns {:ok, []} → no join attempted → test passes regardless of :already_member handling.

Fix: use a FakeDB that returns {:ok, ["!general:nebu.local"]} so a join IS attempted.
Room.Server not running in tests → {:error, :noproc} exercises the non-fatal error path.
Alternatively document that :already_member is only tested via "AC5 (bulk path)" test.

## MINOR-1: AC5 bulk-path test name misleading (tests :noproc, not :already_member literally)
## MINOR-2: 150ms sleep is project convention — INFO only  
## MINOR-3: AC numbering mismatch between story and test comments — align before merge
## MINOR-4: bulk_importer_test.exs missing pure all-new scenario (AT-1 from story)
## MINOR-5: FakeMessagesDB_NoAutoJoinRooms missing get_room_heroes/2 stub (pre-existing)
