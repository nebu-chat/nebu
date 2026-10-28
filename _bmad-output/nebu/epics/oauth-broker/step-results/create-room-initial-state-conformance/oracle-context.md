# Oracle gate create-room-initial-state-conformance (nebu-oracle, 2026-10-16) — Matrix CS API v1.18, createRoom

## 1. Spec semantics
- Order (MUST): create -> creator join -> default power levels (+ power_level_content_override) -> m.room.canonical_alias (room_alias_name) -> preset events (join_rules / history_visibility / guest_access) -> initial_state in array order -> name / topic -> invite / invite_3pid. "normal state resolution rules ... including checking power levels for each event".
- Precedence: initial_state beats the preset; name / topic override m.room.name / m.room.topic in initial_state.
- StateEvent schema: type string REQUIRED, content object REQUIRED, state_key string (default "").
- The spec names no forbidden types. m.room.power_levels in initial_state is legal (overrides the default by order); the interplay with power_level_content_override is unspecified.
- 400 codes: M_BAD_JSON / M_NOT_JSON (malformed body), M_INVALID_ROOM_STATE (implied initial state invalid), M_ROOM_IN_USE, M_UNSUPPORTED_ROOM_VERSION. M_INVALID_PARAM is not specified for initial_state (acceptable for the 64 cap).

## 2. Skip or 400?
- Structure errors (not an array, entry not an object, type missing / not a string, state_key not a string, content missing / not an object): 400 M_BAD_JSON BEFORE the room exists (no orphan). Before: skipped silently, non-array ignored.
- m.room.encryption (ADR-011): keep skipping (Element sends it with default E2EE; a 400 / 403 would break every room creation). The PUT path answers 403. Asymmetry deliberate, to be documented.
- m.room.power_levels: skipping deviates from the spec but is safe (PL is GenServer-authoritative); the real solution (merge) belongs to the power_level_content_override follow-up.
- m.room.create / m.room.member: rejection would be closer to the spec; no client sends them, skipping is tolerable.
- m.space.parent guard skip: ok. A DB error persisting an entry should fail the creation (MUST apply): raise -> cleanup_orphan_room -> 500.

## 3. Gaps (verified: the router reads only name, creation_content, initial_state, is_direct)
(A) in this story: A1 structure validation 400 M_BAD_JSON; A2 m.room.name from initial_state does not update rooms.name (PUT path does); A3 forbidden list: add m.room.tombstone, m.room.third_party_invite; A4 name-derived canonical alias emitted after initial_state wins over an initial_state canonical_alias (decide + document); A5 per-entry persist failure -> raise.
(B) follow-ups: B1 topic ignored (Element sends it); B2 invite + is_direct ignored (DMs; check); B3 preset / visibility ignored; B4 room_alias_name ignored (M_ROOM_IN_USE); B5 room_version ignored (hard "10"; unknown -> 400 M_UNSUPPORTED_ROOM_VERSION); B6 power_level_content_override ignored; B7 m.room.canonical_alias content not validated (PUT and initial_state).

## 4. Required tests
- join_rules restricted -> persisted; entry without state_key -> "" ; same (type, state_key) twice -> later wins; initial_state m.room.name A + top-level name B -> B wins, A before B; initial_state m.room.name without name -> state name AND rooms.name; order create < member < power_levels < initial_state < m.room.name < canonical_alias; m.room.encryption -> 200 and no event; m.room.create / foreign m.room.member / m.room.power_levels not persisted, creator PL 100; m.room.tombstone not persisted; m.space.parent to unknown / not-member space skipped, own space persisted; initial_state object / string -> 400 M_BAD_JSON and no room; entries without type / type 123 / state_key 5 / content "x" / null / missing -> 400 M_BAD_JSON, no orphan; 65 entries -> 400 M_INVALID_PARAM, no room; [] / missing -> 200; malformed JSON body -> 400; DB error on an entry -> 500, room cleaned.
