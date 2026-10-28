# code-review create-room-initial-state-conformance (nebu-code-reviewer, 2026-10-16, cycle 1)
0 MAJOR, 4 MINOR, 4 INFO. Router guard order (json_parse_error -> `_json` non-object -> cap -> shape -> create), no regression for the Admin caller (`initial_state_json ""`) or Element's DM / Space flows, orphan cleanup covers the new raise, rooms.name sync matches the PUT path.
All 4 MINOR applied (dev cycle 1):
- M1 docs missing from the diff (KNOWN-FAILURES.md K8 row, matrix-api-scope.md initial_state contract, follow-ups): written (docs step).
- M2 the new raise left no log line: one value-free ERROR (room id, type, error class / SQLSTATE only, never the content: a Postgrex error can carry a snippet of the JSON).
- M3 a NUL character in type / state_key / content would be a 500 after the room was created: now `validate_initial_state/1` rejects it (keys and values, nested) -> 400 M_BAD_JSON; unit + HTTP tests.
- M4 stale comment in create_room (three privileged types): rewritten around `@initial_state_forbidden_types`.
INFO: `{"_json": ...}` object body treated as non-object (irrelevant for real clients); `length/1` of the entry list is bounded by the 1 MB JsonBody cap; room_summary used by the e2e step has its own rate tier (300 / min), fine for one run.
