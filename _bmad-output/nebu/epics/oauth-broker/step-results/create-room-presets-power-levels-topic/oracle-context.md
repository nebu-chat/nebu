# Oracle gate (Matrix v1.18) — create-room-presets-power-levels-topic
## MUST
- createRoom order: create, creator join, power_levels (override applied), alias, preset events, initial_state in list order, name/topic, invites; "MUST apply normal state resolution incl. power level checks for each event".
- Preset table: private_chat = invite/shared/can_join; trusted_private_chat = same + invitees get the creator's power level (normative, belongs to eb); public_chat = public/shared/forbidden. No preset: SHOULD derive from visibility (public -> public_chat, private -> private_chat); visibility defaults to private. initial_state takes precedence over preset events, is overridden by name/topic.
- v10 join auth order: sender != state_key reject; banned reject; invite/knock allow only if membership invite or join; restricted/knock_restricted invite/join or authorising user; public allow; otherwise reject. v10 invite: target joined or banned -> reject (a banned user never holds a pending invite). Join 403 errcode unspecified: M_FORBIDDEN correct.
- v10 power levels: values MUST be integers (no strings), range [-(2^53)+1, 2^53-1]; events/notifications objects of integers; users keys valid user ids.
- Directory visibility is only the published-directory flag, not a join rule.
## Verdicts
- D1 member -> ban -> rule order OK; creator join exempt OK; fail-closed 500 on read error OK; 403 M_FORBIDDEN fixed text OK.
- D1 "join_rules absent = invite": OK as Nebu/Synapse POLICY but NOT spec text (strict v10 would reject even invited users): document as policy, remove "spec default" wording.
- D1 `private` / unknown / malformed allowed with invite: WRONG per v10 (only invite/knock accept invites). Decision: deny (403) for private/unknown/malformed; only absent => invite policy.
- /rooms/{roomId}/join is a spec endpoint Nebu does not route; D1 must apply when added: record in scope docs.
- D2 OK (skip preset event when initial_state sets same (type,"") is Synapse parity, not spec; match state_key "" only). Invitee PL for trusted_private_chat belongs to eb and is spec-normative.
- D3 OK. D4 OK (M_INVALID_PARAM for wrong enum acceptable). D5 content OK; caps are Nebu policy (label); `{}`/null/"" accepted on PUT/initial_state.
- D5 top-level `topic: ""` -> no event: WRONG. Included "" must write {"topic": ""} (overwrites initial_state topic, as Synapse); top-level null -> 400 M_BAD_JSON.
- D6 OK. D7 shallow merge OK; M_INVALID_ROOM_STATE lock-out OK; ints only, ±(2^53-1), users key check OK; present JSON null value must be rejected (M_BAD_JSON).
- D8 initial_state power_levels skip = documented deviation (er); keep the warning + label.
## Missing tests
- visibility public + preset private_chat -> join rule invite, rooms.visibility public; public + trusted_private_chat -> invite.
- invite of a banned user -> 403; unban without new invite in invite room -> join 403; self-leave then rejoin in invite room 403; rejected invite then join 403; public room same -> 200.
- knock room: invite -> 200, none -> 403. knock_restricted + ban + allow-room member -> 403.
- override {"ban": null}, {"users": {"@a:x": 1.0}}, {"users_default": -9007199254740992}, {"notifications": 5} -> 400 M_BAD_JSON; lock-out: {"events": {"m.room.join_rules": 101}} (also with an initial_state join_rules entry replacing the skipped preset event) and m.room.history_visibility 101 -> 400 M_INVALID_ROOM_STATE.
- initial_state join_rules entry with non-empty state_key -> preset join_rules still written.
- top-level topic "" + initial_state topic -> {"topic": ""} wins; PUT m.room.topic with m.topic differing from topic -> 200; m.text [] -> 200.
- 403 body {"errcode":"M_FORBIDDEN","error":<fixed>} on both join refusals, no state leaked; unknown room stays 404.
- unit decision table for private/unknown/malformed rows (deny).
