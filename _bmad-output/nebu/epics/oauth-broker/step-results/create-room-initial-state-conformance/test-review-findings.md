# test-review create-room-initial-state-conformance (pre-dev, nebu-test-reviewer, 2026-10-16)
2 MAJOR, 5 MINOR, several INFO; all MAJOR and 4 MINOR applied before dev:
- MAJOR-1 (AC3 named an empty body, no test sent one): an empty body / `{}` is deliberately a VALID createRoom (Synapse allows a nameless room); tests now pin that (`create_raw(u, "")` 200) and JSON that is not an object (`[1]`, `42`, `"x"`: Plug wraps it as `_json`).
- MAJOR-2 (wrong error code): a body that is not valid JSON is `400 M_NOT_JSON` like login / account data / tags, valid non-object JSON and the initial_state shape errors are `400 M_BAD_JSON`: story D1/AC3, router and tests corrected.
- MINOR-1 AC6 asserted no status: the unit test now asserts `Nebu.Matrix.Status.internal()` and that the message names the entry type.
- MINOR-3 AC4 over HTTP checked no power levels / create: now exactly one m.room.create and no `@evil` in any persisted power_levels content.
- MINOR-4 AC5 only against the FakeDB: new HTTP test reads the real `rooms.name` (entry only, top-level wins, non-empty state_key untouched).
- MINOR-5 story D6 named a non-existing route (`directory/room`): corrected to `room_summary` (what the step uses).
- MINOR-2 (alias after initial_state wins, no test): NOT applied: the alias fake in create_room_canonical_alias_test.exs records no insertion order, the order is pinned by the code and the Oracle text; documented as D4.
- INFO: the two longest test names shortened concern noted (all < 255); pins beyond AC2 (`type: ""`, `state_key: null`, cap before shapes) kept and listed in the story.
