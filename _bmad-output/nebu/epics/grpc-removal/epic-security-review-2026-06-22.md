# Epic Security Review — `grpc-removal` (SEC Gate 2, mandatory epic-end)

- **Reviewer:** Kassandra (adversarial security review)
- **Date:** 2026-06-22
- **Scope:** whole-epic diff `git diff 147ea442..HEAD -- server/`
- **Epic commits:**
  - `0e2949b2` native `Nebu.Matrix.Error`/`Status` replace `GRPC.RPCError`/`GRPC.Status`
  - `8d64031d` `EventDispatcher.Server` is a plain module (dropped `use GRPC.Server`); de-grpc metadata; dead `event_bus/2` streaming handler deleted
  - `aa7c4dc7` drop `:grpc` + `:protobuf` deps; `Core.*` are plain structs
  - `36e538cf` docs (ADR-005 superseded, ADR-021 + arc42)

## Verdict: **CLEAN** — no CRITICAL / HIGH findings.

The epic is genuinely behavior-preserving from a security standpoint. Every change is a
mechanical type/name swap, a dead-code deletion, or a dependency removal of a stack that
nothing reached at runtime. No authorization decision, error-envelope output, identity
extraction, default-value semantic, or HTTP/TLS surface changed in a way an attacker can
exploit. Findings below are INFO-only (tracked cleanups, no security impact).

---

## 1. Error mapping / info-disclosure — `Nebu.Matrix.Http.map_error/1`

`map_grpc_error/1` → `map_error/1` is **byte-for-byte equivalent**. Old code switched on
`GRPC.Status.<x>()` integers; new code switches on `Nebu.Matrix.Status.<x>()` atoms via the
identical `cond` ladder, with identical branch order and identical outputs:

| status | HTTP | errcode | message |
|---|---|---|---|
| not_found | 404 | M_NOT_FOUND | "Room not found" (fixed) |
| permission_denied | 403 | M_FORBIDDEN | "You are not a member of this room" (fixed) |
| invalid_argument | 400 | M_INVALID_PARAM | `message \|\| "Invalid parameter"` |
| resource_exhausted | 403 | M_ROOM_FULL | "Room is full" (fixed) |
| failed_precondition | 400 | M_BAD_STATE | `message \|\| "Bad state"` |
| unavailable | 503 | M_UNAVAILABLE | "Core is temporarily unavailable" (fixed) |
| unauthenticated | 401 | M_UNKNOWN_TOKEN | "Unauthenticated" (fixed) |
| `true ->` (default) | 500 | M_UNKNOWN | "Internal server error" (fixed) |

- The two branches that pass an internal `message` through to the client
  (`invalid_argument`, `failed_precondition`) **already did so pre-epic** — this is not a
  new disclosure introduced by the refactor. The raised messages on those paths are
  validation strings ("invalid power_levels_json", "M_ROOM_ARCHIVED: room is archived"),
  not secrets, stack traces, or DB internals.
- The `true ->` default still maps everything unknown (including `:internal`) to a fixed
  `500 / M_UNKNOWN / "Internal server error"` — `internal` errors that carry
  `inspect(reason)` in their `message` are **NOT** leaked, because `:internal` falls through
  to the default branch, which discards the message. No status changed which envelope it maps to.

**No regression.**

## 2. Auth / trusted-identity — `Nebu.Matrix.RequestMetadata` (was `Grpc.Metadata`)

`Grpc.Metadata` → `RequestMetadata` is a rename with **identical logic**: same
`@user_id_key "x-user-id"`, `@system_role_key "x-system-role"`, `@default_role "user"`,
same `get_header/2` reading `stream.http_request_headers`, same `user_id/1`, `system_role/1`
(absent → `"user"`), `trusted_identity/1`. Only the `@spec` types and moduledoc changed
(`GRPC.Server.Stream.t()` → `map()`), which is accurate — the argument was always the
`%{http_request_headers: ...}` map built by `Nebu.Matrix.Http.stream/1` /
`Nebu.Matrix.actor_stream/1`, never a real gRPC stream.

- The default role remains `"user"`, **not** `"system"` / `"instance_admin"`. So an absent
  `x-system-role` header is default-deny everywhere it matters:
  - `update_room_settings/2` requires `system_role in ["instance_admin"]` → absent role
    (`"user"`) is rejected with `permission_denied`.
  - `get_room_state/2` (Story 7-19 IDOR fix) bypasses the membership check **only** when
    `system_role == "system"`; default `"user"` is forced through
    `MapSet.member?(state.members, caller_id)`. Preserved verbatim.
- In-process admin callers still inject `x-system-role => "instance_admin"`
  (`Nebu.Matrix.actor_stream/1`); HTTP user callers still inject `"user"`
  (`Nebu.Matrix.Http.stream/1`). No path now produces a nil/wrong role that would widen privilege.

**No privilege change.**

## 3. `Core.*` default-value semantics — plain `defstruct` vs proto3

The proto3-generated structs and the hand-written `defstruct`s have **identical defaults**:

- **proto3_optional fields → `nil`** (matches the elixir-protobuf library's handling of
  `proto3_optional: true`): `CreateRoomRequest.name`/`.topic`, `GetMessagesRequest.to_token`,
  `SetPresenceRequest.status_msg`, `EventBusRequest.since_token`,
  `UpdateRoomSettingsRequest.is_auto_join` — all `nil` in the new structs. ✔
- **Regular proto3 scalars → typed zero** (`:string`→`""`, ints→`0`, `:bool`→`false`):
  `is_direct: false`, `is_state_event: false`, `is_active: false`, `system_role: ""`,
  `visibility: ""`, `max_members: 0`, etc. ✔

Security-relevant consumers verified against these defaults:

- **`UpdateRoomSettingsRequest.is_auto_join`** (security-relevant: toggles bulk first-login
  membership). Old field: `proto3_optional: true, type: :bool` → default `nil`. New:
  `is_auto_join: nil`. The handler gate is `if not is_nil(req.is_auto_join)` —
  *nil = "not sent, leave unchanged"*, non-nil bool = "write". Because the default did **not**
  flip (nil → nil), the "leave unchanged" semantic is preserved; no path now silently writes
  `false`/`true`. The audit write (`room_auto_join_changed`) still fires only on explicit set.
- **`UpdateRoomSettingsRequest.visibility`** default-deny guard `req.visibility in
  ["public","private"]` is unaffected by the `visibility: ""` default — `""` and any forged
  value are silently ignored, value reaches the DB only as a bound parameter. Unchanged.
- **`AdminUserProto.system_role` / `.is_active`** are response-shaping fields (`""`/`false`),
  not authorization inputs; the authorization role comes from `RequestMetadata`, not these.

**No default flipped in a way that bypasses a guard or changes an authz outcome.**

## 4. Dropped `event_bus/2` streaming handler

Removed: `event_bus/2` and its private helpers `event_bus_loop/1`, `subscribe_to_all_rooms/0`,
`leave_all_room_groups/0`, `map_to_proto_event/1`, `do_send_reply/2` — confirmed fully
deleted (no orphans remain in `server.ex`; `grep` finds only one stale code comment, see
INFO-1).

- **Confirmed dead:** the only references to `event_bus`/its helpers were mutual (the handler
  and the helpers referenced only each other). No in-process caller existed — it was the
  network-facing server-streaming RPC the (now-removed) Go gateway dialed.
- **No security control lived only there.** The handler did event *fan-out forwarding* to the
  external gateway (join `"event_bus:gateways"` `:pg` group, subscribe to room groups, forward
  `{:new_event, ...}`). It performed **no** audit logging, **no** rate limiting, and **no**
  membership filtering — membership/authorization filtering for event delivery happens in the
  live `/sync` and `get_room_state` paths, which are untouched and still apply the
  Story 7-19 membership check. The `:pg` room groups themselves remain in use by the live
  paths; only the gateway-fanout subscriber was removed.
- The old `grpc_handler_test.exs` (renamed `handler_test.exs`) had an `event_bus/2` describe
  block; its removal is correct — it tested a now-nonexistent handler and asserted no security
  property (it asserted `:pg` membership + struct forwarding).

**No lost control.**

## 5. Dependency removal — `:grpc` / `:protobuf` and transitive deps

`mix.exs` dropped `{:grpc, "~> 0.8"}`; `mix.lock` dropped `cowboy`, `cowlib`, `flow`,
`gen_stage`, `googleapis`, `grpc`, `gun`, `protobuf`, `ranch` — all pulled in **only** by
`:grpc`. Verified nothing else needs them at runtime:

- **HTTP/TLS stack intact:** Bandit (`~> 1.5`) still present → `thousand_island` (1.5.0) +
  `hpax` (1.0.3) + `websock_adapter`; the listener does **not** use cowboy/ranch/gun.
- **Outbound HTTP (media/OIDC/JWKS) intact:** Finch → `mint` (1.9.0) + `castore`; TLS via
  Erlang `:ssl`. `hackney` (ex_aws) untouched. None of these depended on the removed deps.
- **No live `GRPC.` / `:grpc` / `protobuf` references remain** in `server/lib/` — only two
  moduledoc mentions in `error.ex` / `status.ex` explaining the native replacement.

**HTTP and TLS termination unaffected. No security-relevant component broken.**

## 6. New attacker surface / weakened validation / removed security tests

- **No new attacker-reachable surface.** Net effect is the *removal* of a network listener
  (the vestigial gRPC port 9000 path) and its only handler. The Matrix HTTP surface
  (Bandit + Plug + `OidcPlug`) is unchanged.
- **No weakened validation.** Every raise site swapped `GRPC.RPCError` → `Nebu.Matrix.Error`
  with the same `:status` and message; every rescue swapped the exception type to match. The
  `actor_stream/1` admin-identity injection (`x-system-role => "instance_admin"`) and all
  membership / power-level / instance_admin guards are textually preserved.
- **No security test deleted.** No test files were removed (`--diff-filter=D` is empty);
  files were renamed (`*grpc*` → neutral names) and their `GRPC.*` references swapped. The
  IDOR (Story 7-19), moderation-metadata, profile-self-guard, personal-room-leave guard, and
  request-metadata default-role tests are all retained. The only test block dropped is the
  `event_bus/2` streaming test for the deleted dead handler (correct).

---

## INFO-level (no security impact, optional cleanup)

- **INFO-1 — stale comment.** `server.ex:1418` (`get_metrics/2` doc comment) still references
  `subscribe_to_all_rooms/0`, which was deleted with `event_bus/2`. Cosmetic; no behavior.
- **INFO-2 — stale moduledoc.** `Nebu.Matrix.Http` moduledoc still says command functions
  "take `(request_struct, stream)`" and references "the Go handlers in
  `gateway/internal/matrix/*.go`" for response-shape parity — the Go gateway no longer exists.
  Documentation drift only; the contract it pins to is now self-defined by the Elixir code/tests.
- **INFO-3 — `RequestMetadata`/comments** still use the parameter name `stream` and the key
  `http_request_headers`, carried over from the gRPC era. Harmless naming legacy; the moduledoc
  correctly clarifies it is "a plain map ... never a real gRPC struct".

None of the INFO items block the epic.

---

## SEC Gate 2 result

**CLEAN.** No CRITICAL or HIGH findings. The `grpc-removal` epic is behavior-preserving for
all six security dimensions reviewed (error mapping, trusted-identity, default-value
semantics, dropped streaming handler, dependency removal, test coverage). The epic may be
marked `done` from a security standpoint. The three INFO items are tracked here for a future
docs/comment cleanup pass and require no follow-up story.
