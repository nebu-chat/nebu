# Oracle gate (Matrix CS API v1.18) — create-room-input-validation
## MUST / spec rules
- createRoom order: 1 m.room.create, 2 creator join, 3 power_levels (+override), 4 canonical_alias if room_alias_name, 5 preset events (join_rules/history_visibility/guest_access), 6 initial_state in list order, 7 name/topic, 8 invite/invite_3pid. initial_state beats preset, is overridden by name/topic.
- room_version: absent = server default; unsupported = 400 M_UNSUPPORTED_ROOM_VERSION. creation_content.creator/room_version always overwritten by the server.
- createRoom 400 codes (not closed): M_BAD_JSON/M_NOT_JSON, M_ROOM_IN_USE, M_INVALID_ROOM_STATE, M_UNSUPPORTED_ROOM_VERSION; 403 if creation not allowed.
- room_alias_name: alias #<localpart>:<own server> created, mapped to room, becomes canonical alias, m.room.canonical_alias event sent.
- Alias grammar: #localpart:domain; localpart any non-surrogate code point except ':' and NUL; whole alias (incl. '#' and domain) <= 255 BYTES. No permission model for creating aliases in the spec (squatting is spec-compliant = server policy, eo).
- PUT state m.room.canonical_alias: SHOULD check NEW aliases are grammar-valid and point to the room; aliases being removed / already present are NOT validated; 400 M_INVALID_PARAM = bad syntax, 400 M_BAD_ALIAS = does not point to the room.
- m.room.canonical_alias content: alias absent, null OR EMPTY = no canonical alias; alt_aliases list of strings, may be set while alias is empty.
- POST /rooms/{id}/upgrade: new_version REQUIRED; 400 (M_UNSUPPORTED_ROOM_VERSION), 403 M_FORBIDDEN without tombstone permission; "moves local aliases to the new room" (not done: em).
- m.room_versions capability: default = version for new rooms, available = supported; nothing requires listing all versions; one version does not conflict with /versions v1.15; servers SHOULD default to v12 (Nebu "10" is an allowed SHOULD deviation).
- m.room.name: absent/null/empty = no name; no length limit in v1.18. Size limits: event <= 65536 bytes canonical JSON, state_key/type <= 255 bytes; no depth limit.
## Verdicts / corrections to the story
- D1/AC1 OK (default must be in available). D1/AC2 non-string room_version M_BAD_JSON OK (keep consistent), "" -> M_UNSUPPORTED_ROOM_VERSION OK.
- D1/AC3 WRONG: upgrade with absent or "" new_version falling back to "10" violates "Required": absent -> 400 M_MISSING_PARAM (or M_BAD_JSON), "" -> M_UNSUPPORTED_ROOM_VERSION, non-string (e.g. 10) -> 400 M_BAD_JSON. (If leniency is kept, document it as a deviation.)
- D2: stricter-than-grammar rejections (whitespace, C0, DEL, empty localpart) OK as Nebu policy, label them so; lone surrogate "\ud800" must be rejected (assert the actual 400). Byte limit is BYTES (multibyte 255/256 test).
- D3/AC4: unit order must read power_levels < canonical_alias < preset events < initial_state < name/topic. Derived alias after initial_state is not spec behaviour (document).
- D4/AC8/AC9 WRONG as written: alias "" must be treated like null (200), not a grammar failure (Element sends alias:"" with alt_aliases only). State the code choice (PUT codes instead of M_INVALID_ROOM_STATE on initial_state).
- D5a depth>32 OK (no spec limit, rejecting is allowed). D5b OK. D5c name cap 255 code points OK as policy; PUT name "" / {} / null must still be 200; {"name": 42} -> defined 400.
- D6, D7, AC6/7/13/14 OK.
## Missing tests
- Upgrade: new_version absent / "" / 10 (number) per chosen behaviour; "10" -> 200; 403 M_FORBIDDEN w/o tombstone PL with a valid version.
- PUT canonical_alias: {alias:"",alt_aliases:[own]} 200; {alias:""} 200; moving existing alt alias into alias 200; duplicate across alias/alt_aliases = same as once.
- PUT m.room.name {name:""} 200, {name:42} 400.
- createRoom room_alias_name "\ud800" 400; multibyte localpart at exactly 255 / 256 bytes.
- room_alias_name + preset public_chat: canonical_alias event before join_rules/history_visibility/guest_access.
- valid-but-taken alias AND invalid room_version: assert the D7 first-failure code.
- capabilities: default in available (explicit assert).
- INFO follow-up: 1 MB body cap lets an event exceed the 65536-byte MUST -> 413 M_TOO_LARGE for createRoom initial_state and PUT state (new follow-up).
