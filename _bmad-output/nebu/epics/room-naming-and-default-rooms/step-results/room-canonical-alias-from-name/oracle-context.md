# Oracle / Matrix-spec context — room-canonical-alias-from-name

## Spec rules (m.room.canonical_alias + room aliases)
- Room alias format: `#<localpart>:<server_name>` (sigil `#`). Total alias ≤ 255 bytes incl. `#` and `:domain`.
- `m.room.canonical_alias` is a state event, state_key "", content `{"alias": "#general:localhost", "alt_aliases": [..]}`. We set `alias`. Empty/absent alias means no canonical alias.
- Alias localpart grammar is permissive in the spec, but for safety/interop restrict to `[a-z0-9._=\-/+]`; lowercase the name, replace runs of other chars with `-`, trim leading/trailing `-`, bound length so the full alias ≤ 255B.
- Aliases must be unique on the server (an alias maps to exactly one room). `m.room.aliases` is deprecated — do NOT use it. Canonical alias points at an alias that should be registered in the room directory.
- Nebu MVP intentionally excludes federation/identity/key, but the *client* room-directory endpoint `/_matrix/client/v3/directory/room/{roomAlias}` (resolve + PUT) is NOT federation — it is optional here; emitting the canonical_alias state event is the minimum for Element/Admin UI display.

## Infra findings (verified)
- Server name: `Application.get_env(:event_dispatcher, :server_name, "nebu.local")` (same source generate_room_id/2 and user_id use; NEBU_SERVER_NAME env).
- `emit_state_event/5` (private, server.ex ~4274) builds/signs(Ed25519)/persists/fans-out a state event and returns {:ok, event_id} | {:error, reason}. Reuse it (inline or expose).
- `m.room.canonical_alias` already in @writable_state_types (server.ex ~1706) and already READ by build_room_summary/3 (sync, server.ex ~1958 via state_event_string) and space hierarchy — so emitting the event surfaces it in sync + hierarchy automatically. No proto change needed.
- NO room_aliases table, NO directory endpoint exist today. Latest migration = 000007; next = 000008.
- m.room.name emit + rooms.name denormalisation pattern is at server.ex ~378-411 — mirror it.

## Design decision
- Add migration 000008: `room_aliases` table — `alias TEXT PRIMARY KEY, room_id TEXT NOT NULL REFERENCES rooms(room_id), created_at BIGINT`. Gives server-wide alias uniqueness + alias→room resolution foundation.
- Register the derived alias with collision handling (#general, #general-2, …) inside a unique-constraint-safe insert loop.
- Emit m.room.canonical_alias (state_key "") via emit_state_event after registration; non-fatal on any failure (log warning, room still created) — mirrors name/type handling.
- Optional (only if cheap): GET /_matrix/client/v3/directory/room/{alias} resolve via room_aliases. Not required for the user's display fix.
