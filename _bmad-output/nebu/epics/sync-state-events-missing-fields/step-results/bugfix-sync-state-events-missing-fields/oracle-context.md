## 1. Endpoints / Event Types / Behavioral Rules (MUST requirements)

- `GET /_matrix/client/v3/sync` — `rooms.join.<room_id>.state.events` and `rooms.join.<room_id>.timeline.events` are **both typed `ClientEventWithoutRoomID`** (spec `client-server-api/index.html:15472-15488` for `state`, `:15672-15687` for `timeline`, `:15489-15553` for the shared type) — no state-vs-timeline schema carve-out.
- `ClientEventWithoutRoomID` required fields (MUST be present, non-null): `content` (object), `event_id` (string), `origin_server_ts` (integer, epoch ms), `sender` (string), `type` (string).
- `state_key` (string): present iff the event is a state event — always true here, so every `state.events` entry MUST carry it.
- `unsigned` (UnsignedData): **optional**, not Required — confirms AC3's premise. `unsigned.age` (int, ms since sent) is the relevant opportunistic field; also `membership`, `prev_content`, `redacted_because`, `transaction_id`, none required.
- `state.events` semantics: full sync → full current state snapshot; incremental sync → only state that changed since `since` (or full state if `full_state:true`); represents state **at the start of `timeline`**, not after it.
- Lazy-loading MUST-rules (orthogonal, don't regress): server MUST include the syncing user's own membership event on join/full-state; during a `limited` gap, server MUST return membership events for changes in the gap regardless of redundancy.
- `GET /sync`: Requires auth = Yes; Rate-limited = No.

## 2. Error Codes / HTTP Status / Edge Cases to Test

- No sync-specific errcodes apply to this bug — `/sync` is not rate-limited (no 429 obligation); only error surface is standard auth (`401 M_UNKNOWN_TOKEN`/`M_MISSING_TOKEN`), unrelated to AC1-AC5.
- Real test surface is structural/value-fidelity, not error-code based:
  - `event_id`/`origin_server_ts` non-nil, correctly typed, **matching the real persisted event** (not placeholder/synthetic) — for `m.room.create`, `m.room.member`, `m.room.power_levels`, `m.room.name`, `m.room.canonical_alias`, generic state.
  - Initial sync (no `since`) AND incremental sync (`since` present) both covered.
  - `state.events` must reflect state at **start** of timeline, not end — don't let the fix accidentally pull timeline-window values when threading real event_id/ts through.
  - `limited:true` ⇒ `prev_batch` present (regression guard, unrelated but same endpoint — don't break while touching this code).
  - **Guardrail for any future invite/leave work (currently out of scope, still `{}`):** stripped-state paths (`rooms.invite.invite_state`, `rooms.knock.knock_state`) MUST stay `event_id`-free per spec — don't let a blanket real-value fix leak real IDs into stripped state if that gap is ever closed later.
  - `rooms.invite`/`rooms.leave` still empty `{}` where currently so (AC4 regression guard).
