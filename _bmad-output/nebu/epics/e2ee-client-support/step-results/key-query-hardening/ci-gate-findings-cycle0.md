# CI gate cycle 0 — findings to fix (cycle 1)

Full gate (redeploy + integration + e2e) on the cycle-0 code: e2e 147/0. Integration 38 failures vs 35 in the baseline. After analysis exactly ONE new real regression family remains, caused by the dev's adaptation of three existing suites:

## F1 — three adapted suites fail in the full run (and under `NEBU_SERVER_NAME=localhost`)

`createRoom: 403 M_FORBIDDEN "Users of other servers cannot be invited: this server does not federate"` at the line you added to make the stranger/peer share a room:
- `server/test/nebu/oauth/legacy_logout_per_device_test.exs` ~l.256 (`invite_room(f.stranger, [%{uid: f.uid, at: f.o.at}])`)
- `server/test/nebu/oauth/oauth_revoke_semantics_test.exs` ~l.335 (`invite_room(peer, [%{uid: s.user_id, at: s.at}])`)
- `server/test/nebu/compliance/user_deletion_global_data_test.exs` ~l.222 (`invite_room(b_session, [%{uid: a.uid, at: a_session.at}])`)

Cause: the OAuth test support builds user ids with the hard-coded `@server_name "test.local"` (`oauth_test_support.exs` ~l.495, `user_id_for/1`), while the invite path checks the invitee's domain against the RUNTIME `Application.get_env(:event_dispatcher, :server_name)` (`event_dispatcher/server.ex` `local_domain?/1`). In the full suite some other test leaves another server name in the application env (or the env differs), so the invite is refused. Under a plain `mix test` of the three files the runtime name is `test.local` and they pass, so the defect only shows in the full run. Reproduce: `NEBU_SERVER_NAME=localhost mix test --include integration <the three files>` fails 3/3 (the orchestrator can run this).

Fix them so that they do not depend on the runtime server name: either pin the application env to `test.local` for the test with a restoring `on_exit` (existing pattern: `admin_create_room_test.exs` ~l.148, `space_edit_audit_test.exs` ~l.136-152), or put the shared joined membership in place without the invite domain check (direct `room_members`/room rows the way other tests seed them). Prefer the small, existing pattern. Do not weaken any assertion. The same precondition must be applied to every test of these three files that now needs a shared room (check all).

## Not yours (do NOT touch)
- `SyncStreamPositionHttpTest` (`ModerationTestSupport.tick/0` timeout, documented flake `fj`), `AdminStaleRooms` (`list_rooms(50)` page filled by another suite's rooms), SsoLogin family, RoomsFallbackName, TraceMapNodeControls, ReleaseTest (56/57 gap), LogsLive.WarRoom: known/baseline families.
