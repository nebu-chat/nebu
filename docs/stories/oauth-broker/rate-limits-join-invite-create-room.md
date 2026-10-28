---
story_id: rate-limits-join-invite-create-room
title: "Per-user rate limits for POST /join, POST /rooms/{roomId}/invite and POST /createRoom (createRoom charged per invitee) and caps on PENDING invitations (per inviter, per invitee, per inviter-invitee pair): closes follow-up ey, the last release gate of the createRoom / sync batch"
type: bugfix
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-19
branch: feature/migrate-to-oauth2
---

# Story: rate limits for `/join`, `/invite`, `/createRoom` and pending-invitation caps (follow-up `ey`)

As a Matrix user (Element Web) of a Nebu server, I want a colleague who abuses the invite feature to be unable to flood my room list with
invitations (fifty rooms a minute, each with an attacker-chosen name and topic), so that invitations, which Element shows since story
sync-membership-partition, stay a usable feature and not a harassment channel.
As an operator, I want the three membership write endpoints (`POST /createRoom`, `POST /rooms/{roomId}/invite`, `POST /join/{roomIdOrAlias}`) to
have per-user rate limits with defaults that a normal user (and the e2e suite) never hits, documented and tunable, so that the createRoom / sync
batch can be released to Element-based deployments.

Follows `sync-membership-partition` (invitations are VISIBLE now: the invite-spam vector of Kassandra M-2 is LIVE) and
`create-room-invites-direct` (the shared invite path `do_invite!/5`, the 50-entry `invite` cap, the D14 validation order). Closes `ey`. After this
story the RELEASE GATE of the batch is lifted; `ex` stays the gate for BUILDING a ban route (there is none).

## Premises verified against the code (2026-10-19, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `39d54c21`)

Checked in the code and tests of this branch, in the local spec copy `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html`
and in the Element Web **1.12.15** bundle (copied out of the stopped container `nebu-oauth-dev-element-1`, `/usr/share/nginx/html`, chunks
`init.js`, `element-web-app.js`, `7878.js`, `296.js`, `i18n/en_EN.*.json`). No dev container runs (no `bin/nebu rpc` probe): the premises are code-level
and are pinned by the acceptance tests.

### The rate limiter (`server/lib/nebu/web/plugs/rate_limit.ex`, `rate_limit_sweeper.ex`)

| Question | Verified state |
|---|---|
| Algorithm | Token bucket per key in ONE named public ETS set `:nebu_http_rate_limit_buckets`, rows `{key, tokens, last_ms}`; refill `elapsed * rate_per_min / 60 000`, capped at `burst`; a request takes ONE token or is denied (a denied request consumes nothing: the refilled value is stored). Read-then-insert without CAS: a benign race lets slightly MORE through (documented in the moduledoc). |
| Keys | `key: :ip` (default) = the BARE `Nebu.Web.ClientIP.bucket/1` value, i.e. **shared by every `:ip` tier** (sync 600/min burst 100, mutual_rooms 120/30, login 30/10, preview_url 30/10, media upload 600/5: protected.ex l.1920-1926 says so); `key: :user` = `{tier, conn.assigns[:current_user]}` (falls back to the IP without a user). `take/3` (`key, rate_per_min, burst`) takes one token from an arbitrary key; `respond_limited/2` sends the envelope. There is no multi-token / multi-bucket take. |
| 429 body | `429`, `{"errcode":"M_LIMIT_EXCEEDED","error":"Rate limit exceeded","retry_after_ms":N}` with `N = retry_after_s * 1000` plus `Retry-After: <s>` (seconds, >= 1), halted. |
| Existing per-user tiers | `account_data` 60/min burst 30 (`key: :user`, protected.ex l.38), `room_summary` 300/min burst 60 (`key: :user`, l.1860). Per-IP: sync 600/min burst 100 (l.73), mutual_rooms 120/30 (l.1928, `:ip`). All tier values are COMPILE-TIME module attributes (`@x RateLimit.init(...)`): there is no env / admin override for any tier today. |
| Configuration precedent for abuse limits | `config/runtime.exs` l.99-114: `NEBU_ROOM_ACCOUNT_DATA_MAX_ROWS_PER_USER` / `_MAX_BYTES` / `_MAX_TOTAL_BYTES`, strictly positive integers within int64 apply, anything else keeps the default (never crashes); read at runtime by `Application.get_env(:nebu, key, default)` (`room_account_data_store.ex` l.59-70). Inside `if config_env() in [:prod, :dev]`. |
| Sweeper | `Nebu.Web.RateLimitSweeper` deletes buckets idle > 1 h every 10 min (test env: never). Its correctness argument (`sweep_idle/0` doc): **every bucket refills completely within one hour (`burst / rate <= 60 min`)**, so evicting an idle bucket never grants budget. A new tier (and any env override) MUST keep `burst / rate_per_min <= 60`. |
| Disable switch | `NEBU_RATE_LIMIT_DISABLED=true` or `:nebu_http, :rate_limit_disabled == true` -> no-op (plug AND `take/3`). `scripts/e2e-ci.sh` l.65 **exports `NEBU_RATE_LIMIT_DISABLED=true` unconditionally**; `make test-integration` sets it too; `docker-compose.yml` l.106 defaults it to `false`. |
| ExUnit | Rate limits are ENABLED in ExUnit (no global disable in `config/test.exs` / `test_helper.exs`). The HTTP suites of this batch call `T.reset_rate_limits/0` (`test/nebu/oauth/oauth_test_support.exs` l.86): limiter ON, clock FROZEN at 1 000 000 (no refill), buckets emptied; `T.restore_rate_limits/0` puts the prior env back. Under a frozen clock a user has exactly `burst` tokens for the whole test. 20 files set `:rate_limit_disabled` themselves. |
| Cluster | The table is node-local ETS (moduledoc "Per node, no coordination needed", sweeper "every node runs its own sweeper"). The cluster-safety skill (ADR-020) forbids Redis / external brokers and requires that code works identically on one node and in a cluster; it says nothing about rate-limit state. With N nodes and a load balancer without user affinity, a user's effective budget is up to N x (burst, rate) (`docker-compose.scale.yml` runs several nodes). |

### The three routes and the invite path

| Question | Verified state |
|---|---|
| Routes | `post "/client/v3/createRoom"` (protected.ex l.1245-1349), `post "/client/v3/join/:room_id_or_alias"` (l.1352-1362), `post "/client/v3/rooms/:room_id/invite"` (l.1368-1397). **None has a rate limit** (`ey` premise CONFIRMED). `POST /rooms/{roomId}/join` and knock are unrouted (scope doc l.64); `PUT .../state/m.room.member` is refused (403, l.2310). So these three are the only client paths that create invitations or joins. |
| createRoom validation (D14 of create-room-invites-direct) | `validate_create_room_request/1` (server.ex l.819-852): name -> topic -> creation_content -> room_version -> alias -> initial_state aliases -> preset / visibility -> override -> `invite` shape (cap **50 RAW entries**, `@invite_max_entries`, l.857) -> `invite_3pid` -> invitee domains -> creator lock-out -> alias-taken read -> **invitee existence read (the last DB read)**. Everything before the room exists; a rejected request creates nothing. |
| createRoom step 8 | `emit_invites/5` (l.2797-2809): `do_invite!(..., wake: false)` per invitee in list order, wake-ups after the last one (D9); any failure raises -> `cleanup_orphan_room/1` (best effort). |
| `POST /invite` | `invite_user/2` (l.2563-2603): shape -> room running (404) -> inviter member (403) -> invite level (403) -> local domain (403) -> existence (404) -> `do_invite!(..., retry_reject: true)`. |
| `do_invite!/5` (l.2620-2649) | member -> 403; latest membership `ban` -> 403; `pending_before = invite_pending!/2` (read BEFORE the write); `membership == "invite" and pending_before` -> **already invited: no-op, nothing written**; else `write_invitation!/4` (row upsert, then the signed invite event, unforget, wake). |
| `InviteDB.insert_invitation/3` | ONE row per `(room_id, invitee_id)`; `ON CONFLICT DO UPDATE` **re-arms**: `inviter_id` and `invited_at` replaced, `accepted_at` / `rejected_at` cleared. So a re-invite of a declined / left user makes the row PENDING again, and an invite over a pending row-only invitation moves the row to the new inviter. |
| Other invitation writers (not through `do_invite!`) | Admin force-add `admin_add_room_member/3` (server.ex l.2151-2190: row, then the authorized join accepts it at once) and `upgrade_room` (l.6905: one row-only pending invitation per member of the old room, `inviter_id` = the upgrader). |
| Schema / indexes (000001_init.up.sql l.256-266) | `room_invitations (room_id, inviter_id, invitee_id, invited_at, accepted_at, rejected_at)`, PK `(room_id, invitee_id)`, `room_invitations_invitee_idx (invitee_id)`. **There is NO index led by `inviter_id`**: a per-inviter COUNT is a sequential scan today -> a migration is needed. Latest migration on this branch: `000049` (main is at `000039`): the new one is **`000050`**. |
| Error mapping | `Nebu.Matrix.Http.map_error/1`: `permission_denied` + an `errcode` -> `403 <errcode> <message>` (opt-in, l.65-66); `resource_exhausted` is taken (`403 M_ROOM_FULL`). `Nebu.Matrix.Error` has `status`, `message`, `errcode` (no retry field). |
| Join cost | `join_room/2` (l.1652): `lookup_room` only (no lazy start), `authorize_join!/2` (member, latest membership, join rule, pending invitation, taken-back check), the member insert + member event, `accept_invitation`, an audit row `room_joined` per real join. Join / leave flapping writes one member event per join into the room timeline. |
| `/versions` | `@versions_offered` v1.1-v1.15 (OAuth offered) / v1.1-v1.11 (http_public.ex l.314-315), `unstable_features` only `uk.half-shot.msc2666.query_mutual_rooms`. **v1.18 is never advertised.** |
| Ignore list | Sync side only (D8 of sync-membership-partition: a pending invitation whose inviter is in `m.ignored_user_list` is in no section). The invite WRITE path does not read it. |
| Profile oracle (Kassandra L-1) | `GET /profile/{userId}` (`HttpPublic.get_profile/3`, http_public.ex l.1039) is unauthenticated, cached 60 s, reads `Profile.DB.get_profile/1` without a deactivation filter: a deactivated user answers 200; the invite existence read answers 404 for unknown AND deactivated users. A createRoom `invite` list probes up to 50 ids per request. |
| `/sync` invite cost (Kassandra L-3) | `build_invite_rooms/2`: stripped state for EVERY pending invitation (one batched statement each for state and inviter member events since cycle 1); no cap per response. |

### Spec (Matrix CS API v1.18, local copy)

- **Rate limiting:** "Homeservers SHOULD implement rate limiting ... it should return a standard error response of the form `{"errcode": "M_LIMIT_EXCEEDED", "error": "string", "retry_after_ms": integer (optional, deprecated)}`. Homeservers SHOULD include a `Retry-After` header for any response with a 429 status code." ([Changed in v1.10]: `retry_after_ms` deprecated in favour of `Retry-After`.) Nebu sends both (clients of all ages read one of them).
- **Rate-limited flags:** `POST /join/{roomIdOrAlias}`: **Yes**; `POST /rooms/{roomId}/invite`: **Yes** (429 listed); `POST /createRoom`: **No** (no 429 in its response list); `POST /rooms/{roomId}/join` and `POST /knock/{roomIdOrAlias}`: **Yes** (both unrouted in Nebu: when either is ever routed it MUST charge the SAME `join` tier, `{"join", user}`, so that no limiter-free join path exists). `M_LIMIT_EXCEEDED` is a common errcode any endpoint may return, so limiting createRoom is a **divergence from the endpoint's Rate-limited flag** (not a spec violation), like `room_summary` (RU7 of story oauth-room-summary-unrecognized).
- **Invite permission [Added in v1.18]:** `m.invite_permission_config` (`default_action: "block"`); "When invites to a given user are blocked, the user's homeserver MUST respond to ... `POST /rooms/{roomId}/invite`, `POST /createRoom` (due to a user in the invite list; it is possible for one of the invited users to be rejected whilst the room creation as a whole succeeds), `PUT .../state/m.room.member/{stateKey}` ... with 403 `M_INVITE_BLOCKED`", and blocked invites "MUST NOT be served over ... `GET /sync`". A MUST only for a server that claims v1.18; Nebu claims at most v1.15.
- **Ignoring users:** "Servers must not send room invites from ignored users to clients. Servers may optionally decide to reject the invite, however." (Sync side done: D8 of the previous story.)
- **`GET /profile/{userId}`:** "404 There is no profile information for this user or this user does not exist"; "403 The server is unwilling to disclose whether the user exists".
- **`M_RESOURCE_LIMIT_EXCEEDED`** (the errcode the room-account-data caps use today) "MUST have an `admin_contact` field": not used by this story.

### What Element Web 1.12.15 does

| Flow | Verified behaviour (bundle) |
|---|---|
| `POST /createRoom` 429 (any error) | `createRoom` (init.js): `JoinRoomError` dispatch + dialog "Failure to create room" / "Server may be unavailable, overloaded, or you hit a bug." (`M_UNSUPPORTED_ROOM_VERSION` has its own text). **No retry.** The DM flow uses the same function. |
| `POST /join` 429 from the room view | `RoomViewStore` join: `JoinRoomError`, then `showJoinRoomError`: dialog "Failed to join" with the `MatrixError` message (contains the server's `error` text). **No retry.** |
| "Accept all" / "Reject all" invites (`manageInvites`, element-web-app.js) | on `M_LIMIT_EXCEEDED`: `await sleep(t.retry_after_ms \|\| 2500)` and retry the same room: **retries, honours `retry_after_ms`.** Leave of several rooms: the same (`retry_after_ms ?? 100`). Space "Add existing rooms": retries after `retry_after_ms`. |
| Invites (`MultiInviter.doInvite`, init.js; invite dialog, Space invites) | `M_LIMIT_EXCEEDED` -> **silent retry every 5 s (fixed 5e3, ignores `retry_after_ms`) until it succeeds**; `M_FORBIDDEN` -> "You do not have permission to invite people to this room." **and `_fatal = true` (the rest of the batch is not invited)**; `M_NOT_FOUND` -> "User does not exist"; any other errcode -> "Unknown server error" (non-fatal). `M_INVITE_BLOCKED` is not in the switch ("Unknown server error"). |
| Invite blocking UI | The setting "Allow users to invite you to rooms" (`invite_controls`) is shown only when the server advertises the UNSTABLE feature **`org.matrix.msc4155`** (`doesServerSupportUnstableFeature("org.matrix.msc4155")`) and writes **`org.matrix.msc4155.invite_permission_config`** (`blocked_users: ["*"]`), not the stable `m.invite_permission_config` (the stable event type exists only as an enum constant in matrix-js-sdk). On Nebu the setting is hidden. |
| Decline dialog | "Decline invitation" offers an "ignore user" option ("You will not see any messages or room invites from this user.") that writes `m.ignored_user_list`, which the sync already honours (D8). Its "report room" option calls `POST /rooms/{roomId}/report`, which Nebu does not route (not in scope; the decline itself works, story sync-membership-partition e2e `@ac8-decline-invite`). |
| e2e API helpers (`e2e/fixtures/dex-auth.ts` `createRoom` / `inviteUser` / `joinRoom`) | wrapped in `retryOnRateLimit` (3 retries, sleeps `retry_after_ms`): a 429 is HIDDEN by the helpers unless it persists for 3 retries; only the server log shows it. |

### e2e load (what the defaults must not hit)

The element-web project: 26 scenarios, ONE worker, 14.7 min on a fresh stack (log of sync-membership-partition), users alex / marie / kai
(`e2e/fixtures/users.ts`), each scenario creates 0-3 rooms (API helpers or Element UI; Element's Space wizard creates the Space plus up to three
rooms within a second), invites 0-1 users and joins 0-2 rooms; no scenario leaves more than one pending invitation behind (join / decline / spaces
scenarios accept or decline; the K9 / K10 scenarios are `@known-failure` and excluded by default). CI and the sibling runs use a FRESH stack; a reused
dev stack accumulates rows (two search scenarios failed on a reused stack in the previous run: order dependence, not this story).

### Sizing evidence (ONE story, smaller than sync-membership-partition)

| Area | Size |
|---|---|
| Limiter | `RateLimit.take_all/1` (all-or-nothing over 1-2 buckets, cost per bucket) ~40 lines; tier accessor module + env parsing + boot warning ~80 lines. |
| Routes | three route heads charge their tiers before anything else (~40 lines). |
| Core | `InviteDB.pending_invite_counts/3` (one statement); the cap check in `validate_create_room_request/1` (after the existence read) and in `do_invite!/5` (before `write_invitation!/4`); `caps:` option for step 8 (~80 lines). |
| DB | migration `000050` (one partial index + down). |
| Tests | unit limiter / config (~15), real-DB counts (~10), HTTP tiers + caps (~35), docs (~15), re-pins of 3 docs suites. |
| Docs | scope doc rows (3 + sync), 07-deployment gate + release notes, 08-concepts tier table, CHANGELOG, follow-ups (`ey` closed, notes, `fh` / `fi`). |
| Why one story | the tiers alone leave the invitee's list unbounded across time (the gate names both); the caps alone leave the write cost and the existence oracle unbounded; both share the same routes, docs and release note. Invite blocking (MSC4155 / v1.18) is a separate feature with its own settings model: split (`fh`). |

## Decisions

- **D1 (three per-user tiers, defaults).** Bucketed by USER (`{tier, user_id}`), never by IP (NAT-safe, and they never draw from the shared bare-IP
  bucket of sync / login / mutual_rooms). Defaults (per node, see D9):

  | Tier (key) | Charged by | Refill | Burst | Full refill | Normal-use evidence |
  |---|---|---|---|---|---|
  | `create_room` (`{"create_room", user}`) | 1 per `POST /createRoom` | 10 / min | 20 | 2 min | Element's Space wizard: 4 creates in a second; e2e: < 1 create / min per user |
  | `invite` (`{"invite", user}`) | 1 per `POST /rooms/{roomId}/invite`; **n per `POST /createRoom` with n invitees** | 20 / min | **50** | 2.5 min | one createRoom with the maximum 50 invitees passes from a full bucket; inviting 100 people through Element: 50 at once, the rest silently retried every 5 s by `MultiInviter` (~2.5 min) |
  | `join` (`{"join", user}`) | 1 per `POST /join/{roomIdOrAlias}` (also an idempotent re-join) | 12 / min | 30 | 2.5 min | "Accept all" of 100 invitations: 30 at once, then one per 5 s (Element retries with `retry_after_ms`); e2e: a handful per user per run |

  Every tier has `burst / rate <= 60 min` (the sweeper invariant). The `invite` burst is `>= @invite_max_entries` (50), so a valid createRoom is never
  unsatisfiable; this is pinned by a test that reads both values.
- **D2 (charging rules and order).** The charge runs FIRST in each route head, before the body checks (like the existing plugs): a malformed request
  costs its units too (only abusers send them, and charging before validation is what bounds the existence oracle of D7). `POST /createRoom` charges
  ONE all-or-nothing `take_all` over `[{create_room, 1}, {invite, n}]` where `n` = the number of DISTINCT string entries of `params["invite"]` when it
  is a list of at most 50 entries, else `0` (a list of 51+ entries is a 400 anyway and must not drain the bucket: the existing test "51 distinct /
  51 duplicates are 400" stays green under a frozen clock); `n = 0` skips the invite bucket. If either bucket cannot pay, NOTHING is consumed and the
  answer is the standard 429 with the LARGER of the two waits. `POST /invite` and `POST /join` take one token. The 429 is
  `Nebu.Web.Plugs.RateLimit.respond_limited/2` (unchanged envelope, `retry_after_ms` + `Retry-After`).
- **D3 (`RateLimit.take_all/1`, new public function).** `take_all([{key, cost, rate_per_min, burst}])` -> `:ok | {:deny, retry_after_s}`: refills every
  listed bucket, and consumes `cost` from each only if EVERY bucket holds at least its cost; otherwise stores the refilled values unchanged and returns
  the max over the buckets of `ceil((cost - tokens) / rate_per_ms / 1000)` (>= 1). `cost > burst` is charged as `burst` (never an unsatisfiable
  request; unreachable with the D5 validation, pinned by a unit test). Same table, same `:rate_limit_clock_fn` and disable seams, same benign race
  (not atomic across concurrent requests of the SAME user on the same node: may let a little more through, never less). `take/3` keeps its signature
  and behaviour (it may delegate). No new ETS table.
- **D4 (where the values come from).** A small accessor module `Nebu.Web.RateLimitTiers` (plain module, no state) with `create_room/0`, `invite/0`,
  `join/0` -> `{rate_per_min, burst}` read at REQUEST time from `Application.get_env(:nebu_http, ...)` with the D1 defaults, and `invalid_settings/0`
  for the boot warning. `config/runtime.exs` (inside the existing `if config_env() in [:prod, :dev]` block, next to the room-account-data loop)
  parses, with the same "strictly positive integer within int64, else keep the default, never crash" rule:
  `NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN`, `NEBU_RATE_LIMIT_CREATE_ROOM_BURST`, `NEBU_RATE_LIMIT_INVITE_PER_MIN`, `NEBU_RATE_LIMIT_INVITE_BURST`,
  `NEBU_RATE_LIMIT_JOIN_PER_MIN`, `NEBU_RATE_LIMIT_JOIN_BURST` (keys `:nebu_http, :rate_limit_<tier>_per_min` / `_burst`) and
  `NEBU_INVITE_MAX_PENDING_PER_INVITER`, `NEBU_INVITE_MAX_PENDING_PER_INVITEE`, `NEBU_INVITE_MAX_PENDING_PER_PAIR` (keys `:nebu, :invite_max_pending_*`).
  The accessor falls back to the DEFAULT PAIR of a tier when the configured pair breaks an invariant: `burst / rate_per_min > 60` (sweeper), or an
  invite burst `< 50`; a HALF-configured pair takes the default for the absent value and is then checked as a pair. `Nebu.Web.RateLimitTiers.invalid_settings/0` returns
  the env variable NAMES of the rejected pairs (both variables of a pair) and `Nebu.Web.RateLimitTiers.warn_invalid_settings/0` (called from `Nebu.Application`
  start) logs ONE `Logger.warning` per rejected setting, value-free (the variable NAME and the rule, never the value). Accessors never divide by zero:
  a non-integer, zero or negative app-env value falls back to the default (tiers and caps). No Admin UI and no `server_config` keys (ADR-022 is about OIDC; these are operational knobs like the room-account-data caps). The existing
  tiers stay compile-time (not touched).
- **D5 (`NEBU_RATE_LIMIT_DISABLED`).** Disables the three tiers (same switch as every bucket). It does NOT disable the pending caps (D6): they are
  state limits like the room-account-data caps, not rate limits, and the e2e suite (which runs with the switch on) must exercise them.
  `scripts/e2e-ci.sh` changes `export NEBU_RATE_LIMIT_DISABLED=true` to `export NEBU_RATE_LIMIT_DISABLED="${NEBU_RATE_LIMIT_DISABLED:-true}"` (CI behaviour
  unchanged; the E2E verification run B sets it to `false`).
- **D6 (pending-invitation caps; the cluster-wide hard bound).** A PENDING invitation = a `room_invitations` row with `accepted_at IS NULL AND rejected_at
  IS NULL`. Three caps, defaults: **per inviter (all rooms) 500**, **per invitee (all inviters) 100**, **per (inviter, invitee) pair 10**. An invitation
  write that would ADD a pending row is refused when, counted BEFORE the write, `inviter_pending + k > per_inviter` (k = the number of new rows of the
  request), or for an invitee `pair_pending + 1 > per_pair`, or `invitee_pending + 1 > per_invitee`; first failure wins in this order (inviter, then the
  invitees in list order: pair before invitee total). Answers (403, fixed texts, no id or number echoed, `permission_denied` + errcode, so
  `map_error/1` needs no change):
  - per inviter: `403 M_FORBIDDEN` "You have too many pending invitations: wait until some of them are accepted or declined";
  - per pair: `403 M_FORBIDDEN` "You have too many pending invitations to this user";
  - per invitee: `403 M_FORBIDDEN` "The invited user has too many pending invitations".
  Why 403 and not 429: the cap does not clear after a fixed time (only when invitees act), and Element's `MultiInviter` retries `M_LIMIT_EXCEEDED`
  every 5 s FOREVER regardless of the status code: a 429 or a `403 M_LIMIT_EXCEEDED` would hang the invite dialog. `M_FORBIDDEN` stops the batch
  (Element: "You do not have permission to invite people to this room", fatal) which is the right outcome; other clients show the `error` text.
  `M_RESOURCE_LIMIT_EXCEEDED` is not used (spec: MUST carry `admin_contact`; Element shows a server-wide resource banner). `M_USER_LIMIT_EXCEEDED`
  (v1.18) was considered and rejected: Nebu advertises at most v1.15; it MUST carry `info_uri`; it is account-scoped ("the user has exceeded a limit
  of THEIR account") while the per-invitee cap limits someone ELSE's account, not the requester's; and Element 1.12.15's `MultiInviter` shows
  "Unknown server error" for it and continues the batch (non-fatal), where `M_FORBIDDEN` stops it. The per-invitee text tells an
  authorised inviter that SOMEONE invited that user at least 100 times pending: accepted (LOW, documented).
- **D7 (where the caps are checked; re-arm interplay).**
  - **createRoom:** in `validate_create_room_request/1` AFTER the existence read (new last step of the D14 order: `... -> alias-taken -> existence (404)
    -> pending caps (403)`), with `k` = the de-duplicated invitee count; the room does not exist yet, so every invitee is a new pending row: the check is
    exact and the request is all-or-nothing (no room, no row, no event, no audit row, no wake-up). Step 8 calls `do_invite!` with `caps: :prechecked`
    (no second check: a failure there would create and then delete a room).
  - **`POST /invite`:** inside `do_invite!/5` (default `caps: :check`), AFTER the member / ban / already-invited decision and BEFORE `write_invitation!/4`:
    only a write that adds a pending row is checked. `pending_before == true` (the invitee already holds a pending row for this room: an already-invited
    no-op, or a row-only / legacy invitation that the write turns into an event-backed one) is NOT checked and always proceeds (it adds no row; the
    re-arm may move such a row to the new inviter: an accepted inaccuracy of at most one row per room, documented). A re-arm of an ACCEPTED or REJECTED
    row (re-invite after a decline / leave / kick) adds a pending row and IS checked. Order of `POST /invite` answers: shape 400 -> room 404 -> inviter
    403 -> level 403 -> domain 403 -> existence 404 -> member 403 -> ban 403 -> already-invited 200 -> **caps 403** -> write.
  - **Not capped (but counted):** Admin force-add (operator action, accepted at once) and `upgrade_room` (row-only invitations of the members, inviter =
    the upgrader). Their pending rows count towards the caps of later client invitations (an upgrader of a 600-member room cannot invite anyone until
    members follow the tombstone: documented, raise `NEBU_INVITE_MAX_PENDING_PER_INVITER` if needed).
  - **Concurrency (REVISED in review cycle 1, Kassandra M-1c, D16):** the pre-check above is count-then-write and only decides the
    answer; the ROW is written by `InviteDB.insert_invitation_capped/4`, which counts again under the transaction advisory locks of the
    inviter and the invitee, so N concurrent client invitations can never exceed a cap on any node. (The first cut was a soft cap by
    design; the advisory-lock variant was rejected there because the invite path had no transaction: the lock now covers only the count and the
    row insert, not the signed invite event.) Follow-up `fi` (b).
  - **The ignore list** (REVISED): see D16 (a): the per-invitee total does not count the rows of ignored or deactivated inviters (the pair and inviter counts stay raw).
- **D8 (the count read, migration 000050).** `InviteDB.pending_invite_counts(inviter_id, invitee_ids, limit)` -> `{:ok, %{inviter: n, invitees: %{invitee
  => %{total: t, from_inviter: p}}}}` | `{:error, reason}`; ONE statement (inline, parameter-bound, ADR-018), counts BOUNDED by `limit` (`>= max cap + 1`,
  e.g. `count(*)` over a `LIMIT`ed subquery, so a user with 100 000 rows costs at most `limit` index entries); invitees without pending rows are
  present with zeros; `[]` invitees answers the inviter count only. A failing read is fail-closed: `500` (createRoom: before the room exists; POST
  /invite: before the write), value-free ERROR log (error class only). Migration `000050_room_invitations_pending_inviter_idx` (raw SQL, `.up.sql` /
  `.down.sql`): `CREATE INDEX IF NOT EXISTS room_invitations_pending_inviter_idx ON room_invitations (inviter_id, invitee_id) WHERE accepted_at IS NULL
  AND rejected_at IS NULL;` (serves the inviter count and the pair count; the invitee total uses `room_invitations_invitee_idx`); down: `DROP INDEX IF
  EXISTS room_invitations_pending_inviter_idx;`. A plain `CREATE INDEX` (the table is small; `Nebu.Release.migrate/0` runs files in a transaction, so
  `CONCURRENTLY` is not available). EXPLAIN (ANALYZE, BUFFERS) on a seeded DB in the Completion Notes; a Seq Scan on `room_invitations` is a blocker.
- **D9 (cluster semantics, said honestly).** The three tiers are PER NODE (ETS): with N nodes behind a load balancer that does not pin a user to a
  node, a user can spend up to N x the budget (N x 20 creates, N x 50 invites at once). The pending caps (D6) are in PostgreSQL and therefore
  CLUSTER-WIDE: they are the hard bound on what a victim sees, the tiers bound the write cost per node. A cluster-wide token bucket (Postgres-backed
  or `:pg`-replicated) is follow-up `fi` (a). No `:pg` / Horde change in this story.
- **D10 (`/sync` needs no invite cap: decided).** Kassandra L-3 asked for a per-response cap of `rooms.invite`. Rejected: the client cannot page
  `rooms.invite`, and since an invitation is delivered incrementally only while it is NEW (D5 of sync-membership-partition), a capped (hidden)
  invitation would appear only after the next INITIAL sync: silent loss of an invitation the user can neither see nor decline. Instead the per-invitee
  cap (100) bounds the list at the source and refuses the 101st invitation VISIBLY to the inviter, and the pair cap (10) bounds what one inviter can
  put there. Residual (documented, `fi` (c)): uncapped writers (upgrade, Admin force-add, rows older than this story) can exceed 100; the initial sync
  then still lists them all (as today). No change to the sync code; a test pins that `rooms.invite` lists every pending invitation (no hidden cap).
  The "oldest dropped" alternative was rejected: it lets an attacker evict a legitimate invitation. **Amended in review cycle 1 (Kassandra M-2, D18):** no cap on the NUMBER of entries, but a per-response BYTE budget for the stripped state of the invitations.
- **D11 (invite blocking: OUT, new follow-up `fh`).** Not a MUST for Nebu (`/versions` advertises at most v1.15; the v1.18 MUST binds servers that claim
  v1.18). Element 1.12.15 would not use the stable event anyway: its "Allow users to invite you to rooms" toggle needs `org.matrix.msc4155` in
  `unstable_features` and writes `org.matrix.msc4155.invite_permission_config` (`blocked_users` / `allowed_users` globs), a richer model than
  `default_action: block`. Doing it properly (both forms, `M_INVITE_BLOCKED` on createRoom with the "room creation may still succeed" rule, PUT state,
  sync suppression, the `/versions` flag) is its own feature. The gate can close without it: the abuse vector is bounded by D1 + D6, and the victim's
  per-user tool exists (Element's decline dialog "ignore user" -> D8 hides every invitation of that user).
- **D12 (the ignore list on the WRITE side: OUT, decided).** The spec MUST ("must not send") is the sync side (done, D8); refusing the invitation is a
  MAY. Refusing would tell the inviter that he is ignored (Element keeps ignoring private), so Nebu keeps accepting and hiding. Recorded in `fa`.
- **D13 (Kassandra L-1, the deactivated-user oracle: accepted, OUT).** Making `GET /profile` of a deactivated user a 404 changes an unauthenticated,
  cached public read that clients use to render former members (compliance archives keep their messages readable) and is a separate behaviour change.
  The oracle needs an authenticated user, and D2 now bounds it: an id probe through createRoom costs one invite unit per id (50 at once, then 20 / min
  per node), through `POST /invite` one unit per request after the member / level checks. Recorded as accepted in `fi` (d) with the option.
- **D14 (createRoom's own cost: decided).** The `create_room` tier bounds rooms per user per time, `POST /rooms/{id}/upgrade` included (D17: review cycle 1 found that an upgrade creates a room and bypassed the tier) (a `visibility: public` create writes one audit row
  `room_visibility_changed`: at most 20 at once, then 10 / min per node; alias squatting of `eo` is rate-bounded now, the namespace policy stays an
  owner decision). No total "rooms per user" cap (no evidence of need; stale rooms are an Admin concern).
- **D15 (not changed).** The existing tiers and their values (sync, login, account data, room_summary, mutual_rooms, media), the 429 envelope, the
  sweeper, `Nebu.Web.ClientIP`, the 50-entry `invite` cap, the invite / join decision order apart from the new cap step, `/sync`, `/versions`, the
  profile read, Admin force-add / upgrade writers, `M_ROOM_FULL`. No `:pg` change.

- **D16 (review cycle 1, Kassandra M-1: the victim's slots and hard caps).** (a) The per-invitee TOTAL of `pending_invite_counts/3` does not count
  pending rows of a DEACTIVATED inviter (`users.is_active`; they count again on reactivation) nor of an inviter on the invitee's
  `m.ignored_user_list` (read in the same statement from `account_data.content_json`, guarded by `pg_input_is_valid`, an absent / malformed /
  non-object list ignores nobody); the pair count and the inviter count stay raw. (b) Deactivation: there is exactly one path
  (`deactivate_user` -> `Admin.DB.set_is_active/2`); rejecting the pending rows there would send the invitees a `rooms.leave` and a reactivation
  could not undo it, so the exclusion in (a) frees the slots instead (documented in `fi` (c)). (c) `InviteDB.insert_invitation_capped/4` (count +
  row in ONE transaction under `pg_advisory_xact_lock` of the inviter and the invitee, keys sorted: no deadlock) writes every row that adds a pending
  row, createRoom step 8 included (a cap broken only by a concurrent request is a 403 and createRoom deletes the room again); the core's pre-check
  stays for the exact answer and the all-or-nothing createRoom; `InviteDB.first_cap_violation/3` is the one pure decision of both. An
  `invite_db_module` without the capped insert (the unit fakes) is served by `insert_invitation/3`, exactly as `inviter_member_events/1` is.
  DELTA GATE (Kassandra H-1, HIGH): the ignore list is attacker-sized account data (up to 1 MB); the first cut of (a) parsed it twice PER PENDING ROW
  inside the counted subquery (664 KB x 100 rows = 1.9 s, 964 KB x 60 rows = the PostgreSQL backend OOM-killed). It is now parsed ONCE PER INVITEE
  in a `LEFT JOIN LATERAL` on the unnest (`ig.ignored`); the counted subquery only does `jsonb_exists` on the parsed value (720 KB list: 11 ms,
  EXPLAIN in the step-results). (c) gets `SET LOCAL lock_timeout = '2s'` (L-2): `lock_not_available` -> `{:error, :lock_timeout}` -> `503 M_LIMIT_EXCEEDED`
  (fixed text, value-free warning, nothing written; `Http.map_error/1` honours an errcode on `unavailable`). The `function_exported?` fallback is
  never taken for the real `Nebu.Matrix.Room.InviteDB` (I-1). PostgreSQL 16+ (`pg_input_is_valid`) is named in the release note (I-8).
- **D17 (review cycle 1, Kassandra L-1 / code review MINOR-4).** `POST /rooms/{roomId}/upgrade` charges ONE `create_room` unit FIRST (before the body
  checks), through `with_membership_charge/3`.
- **D18 (review cycle 1, Kassandra M-2: byte budget of `rooms.invite`).** `Server.limit_invite_state/3`: an OPTIONAL stripped event (topic, avatar,
  canonical alias, encryption, join rules, name) above 64 KiB is dropped; while the response total exceeds 8 MiB the largest optional events are
  dropped, one type at a time (topic, avatar, canonical alias, encryption, join rules, name). The member events (the invitation
  itself) are never dropped and an `m.room.create` above 64 KiB is reduced to its spec keys (creator, room_version, type, predecessor); the log names
  a count only. The optional stripped state is bounded; create and member content stays unbounded until `ep` (the write-time 65536-byte event limit, the NEXT story).
- **D19 (review cycle 1, code review MINOR-1: the limiter is atomic per bucket).** `take/3`, the plug and `take_all/1` charge with a compare-and-swap
  (`:ets.select_replace/2` on the exact old row, `:ets.insert_new/2` for a first touch, retry on conflict); `take_all/1` refunds the buckets it
  already charged when a later bucket cannot pay. One node never lets more than the burst through, however many simultaneous requests a user sends.
- **D20 (review cycle 1, docs).** No "hard bound" wording: the caps are a cluster-wide count bound (hard against concurrent client invitations,
  uncapped writers counted not refused); the gate and the release notes name `fi` (a)-(e), `ep` and the slot-filling residual; `docker-compose.yml`
  passes the nine variables through; the index lock window is in the release note; the migration header carries no dev-environment note.

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused: ... `fh` onward" and a grep of the file finds no `fh` / `fi` row: the new ids are `fh`, `fi`)

- **`fh` — Invite blocking (`m.invite_permission_config`, v1.18, and MSC4155).** Server side of invite permission: the stable
  `m.invite_permission_config` (`default_action: "block"`) and the unstable `org.matrix.msc4155.invite_permission_config` (`blocked_users` /
  `allowed_users` / `ignored_users` globs) that Element 1.12.15 writes only when `/versions` lists `org.matrix.msc4155`; `403 M_INVITE_BLOCKED` on `POST
  /rooms/{roomId}/invite`, `POST /createRoom` (spec: a blocked invitee may be skipped while the room is created) and a member-PUT if one is ever routed;
  suppression of blocked invitations in `/sync` (MAY re-serve when unblocked). A spec MUST once Nebu advertises v1.18. Non-gating.
- **`fi` — Rate-limit / invite-cap residuals.** (a) the three per-user tiers are per node (ETS): N nodes = up to N x the budget without user affinity;
  a cluster-wide bucket (Postgres or replicated) if multi-node abuse matters; (b) the pending caps are soft under concurrency (count-then-write: overshoot
  <= in-flight requests of one inviter); (c) uncapped writers (`upgrade_room`, Admin force-add, pre-story rows) can exceed the per-invitee cap and their
  rows count towards the caps of later client invitations; there is no way for an inviter to withdraw a pending invitation (a kick of a pending invitee
  is not possible: `fb`), so a capped inviter depends on the invitees, and rows to DEACTIVATED invitees count forever (a cleanup on deactivation, or
  excluding deactivated invitees from the count, is the fix); (d) Kassandra L-1 accepted: `GET /profile` answers 200 for a deactivated user while the
  invite path answers 404 (an authenticated, now rate-bounded oracle); option: profile 404 for deactivated users; (e) the tier values are env-only:
  the Helm chart has no values for them (see `bu` for the same gap of `NEBU_TRUSTED_PROXY_CIDRS`). Non-gating.
- **Notes to existing rows:** `ey` -> CLOSED (one line each: the tiers and defaults, the per-invitee charge, the caps and their texts, `/sync` no cap (D10),
  invite blocking split to `fh`, write-side ignore decided out (D12), L-1 accepted (`fi` (d)), L-3 closed by the caps); `fa` ((b): invite permission
  moved to `fh`; the write-side ignore refusal is decided OUT (D12): sync-side suppression only); `eo` (the createRoom tier bounds alias claims per time;
  the namespace policy stays an owner decision); `ex` (the join tier now bounds the re-join loop it mentions; still the gate for the ban route); `fb`
  (pending caps cannot be freed by the inviter while there is no revoke; `fi` (c)).

## Acceptance Criteria

1. **`RateLimit.take_all/1` (unit, `test/nebu/web/rate_limit_take_all_test.exs`, `async: false`, frozen clock through the existing seam).** (a) one
   bucket, cost 1: identical results to `take/3` for the same sequence (burst passes, the next is denied, `retry_after_s >= 1`); (b) cost n: a bucket
   holding `n - 1` tokens denies and keeps its tokens (a following cost-1 take succeeds); (c) two buckets: when the SECOND cannot pay, the FIRST is not
   charged (read its row before / after) and `retry_after_s` is the larger wait; when both can pay both are charged; (d) `cost > burst` is charged as
   `burst`; (e) the clock seam refills by `elapsed * rate`; (f) `:rate_limit_disabled` makes it `:ok` without touching the table; (g) keys of
   `take_all` and of the plug's `{tier, user}` form address the SAME bucket (a token taken by one is missing for the other).
2. **Tier configuration (unit, `test/nebu/web/rate_limit_tiers_test.exs`, `async: false`, env restored in `on_exit`).** Defaults exactly `{10, 20}`,
   `{20, 50}`, `{12, 30}` and caps `500 / 100 / 10`; a configured valid pair applies at request time (no recompile); a pair with `burst / rate > 60`
   falls back to the DEFAULT PAIR of that tier; an invite burst `< 50` falls back; `invalid_settings/0` names each rejected setting by its env
   variable name; the boot warning is one line per rejected setting and contains no configured value (capture the log). The invariant
   `burst / rate_per_min <= 60` holds for every DEFAULT tier and `invite burst >= @invite_max_entries` (read through a public accessor or a test-only
   function of the core: no copied literal). `config/runtime.exs` parsing: the nine variables accept strictly positive int64 integers and ignore
   `"0"`, `"-1"`, `"abc"`, `"1e3"`, `""` and a value above int64 (a `Config.Reader.read!/2` run of the file with a patched env, or the
   room-account-data parsing test pattern if one exists: dev's choice, record it).
3. **The tiers over HTTP (`test/nebu/matrix/membership_write_limits_http_test.exs`, `@moduletag :integration`, real stack via `Nebu.Web.Router`,
   `async: false`, `T.reset_rate_limits/0` in `setup` and `T.restore_rate_limits/0` in `on_exit`, `Nebu.Test.ServerName.pin!/1`, random users).**
   (a) `createRoom`: 20 requests of user A pass (200), the 21st is `429` with body EXACTLY `{"errcode":"M_LIMIT_EXCEEDED","error":"Rate limit
   exceeded","retry_after_ms":N}` (`N` a positive multiple of 1000) and `Retry-After` = `N / 1000`; NO room was created by the 21st (count A's rooms in
   `rooms` / `room_members` before and after); user B is unaffected (200); A can still `GET /sync`, send a message and `PUT` account data (independent
   tiers, no shared IP bucket). (b) Advancing the frozen clock by 6 000 ms gives A exactly one more create. (c) The 429 comes BEFORE validation: with
   A's create bucket empty, a body that is not JSON answers 429 (not `M_NOT_JSON`). (d) **Per-invitee charge:** A creates a room with 50 provisioned
   invitees (200; 50 rows) -> A's next `POST /rooms/{id}/invite` is 429 and writes no row and no event; a fresh user C with 30 invite units spent (30
   `POST /invite` 200) sends a createRoom with 21 invitees -> 429, NO room, NO row, and C's `create_room` bucket still has its 20 tokens (20 further
   createRooms without invitees pass: the all-or-nothing of D2); with 20 invitees it passes. (e) The charge of a list: 51 entries -> 400
   `M_INVALID_PARAM` and NO invite unit charged (afterwards 50 invitations still pass); 50 duplicates of one id -> 1 unit; a list of 3 malformed ids ->
   400 and 3 units charged. (f) `join`: 30 joins of public rooms pass, the 31st is 429 and the user is NOT a member of that room (no member row, no join
   event, no `room_joined` audit row); an idempotent re-join is charged. (g) `POST /invite` 429 precedes the room checks (a 429 for an unknown room id with
   an empty bucket). (h) `:rate_limit_disabled = true`: 60 creates, 120 invites, 60 joins of one user all pass.
4. **The count read (real DB, `test/nebu/matrix/room/invite_caps_db_test.exs`, `@moduletag :integration`, rows written through `InviteDB` writers and
   `T.sql!/2` for fixtures, random ids).** `pending_invite_counts/3`: counts only pending rows (an accepted and a rejected row of the same pair are not
   counted; a re-armed row counts once); the inviter count spans rooms; `from_inviter` counts only the given inviter's rows to that invitee; `total`
   counts every inviter's pending rows to that invitee; an invitee without rows is present with zeros; counts stop at `limit` (seed `limit + 5` rows:
   the answer is `limit`); ONE statement for 50 invitees (telemetry handler on the repo query event, as the previous story's AC1 did); the migration
   created `room_invitations_pending_inviter_idx` (catalog query) and with `SET LOCAL enable_seqscan = off` inside a transaction the plan of the
   statement uses the partial index and `room_invitations_invitee_idx` (EXPLAIN text contains both index names, no `Seq Scan on room_invitations`); a DB
   error answers `{:error, _}` (the call with a closed / invalid parameter type, or a sandbox-free way the dev records).
5. **The caps over HTTP (same HTTP suite; the caps lowered per test through `Application.put_env(:nebu, :invite_max_pending_*, n)`, restored in
   `on_exit`; real DB).** (a) **pair cap** (set to 3): A invites B into 3 rooms (200) -> the 4th `POST /invite` is `403` with EXACTLY `{"errcode":
   "M_FORBIDDEN","error":"You have too many pending invitations to this user"}`, no row, no event, no wake-up (B's long-poll `timeout=500` takes >=
   450 ms); B declines one -> A's next invitation to B passes; C (another inviter) can still invite B. (b) **re-arm:** with the pair cap reached, A
   re-invites B into a room B had DECLINED -> 403 (a re-arm of a rejected row adds a pending row); an already-invited no-op (B pending in R, latest
   membership `invite`) at the cap -> 200 `{}` and nothing written; a row-only pending invitation (`InviteDB.insert_invitation/3` only) of B to R at the
   cap -> `POST /invite` 200 and the invite event is written (`pending_before`, no new row). (c) **inviter cap** (set to 5): createRoom with 6 invitees ->
   403 "You have too many pending invitations: wait until some of them are accepted or declined", and NOTHING was created (A's room count, the
   `rooms` rows, `room_invitations`, `events`, the audit table and the invitees' `user:` groups (a test process subscribed receives nothing) are
   unchanged); with 5 invitees -> 200. (d) **invitee cap** (set to 2): D and E invite B (2 rows) -> F's createRoom with `[G, B]` -> 403 "The invited user
   has too many pending invitations", nothing created (G got no row either); F's `POST /invite` of B -> the same 403. (e) **order:** createRoom with an
   unknown invitee AND a capped one -> 404 `M_NOT_FOUND` (existence before caps); a malformed list -> 400 before the cap read (the count read is not
   called: a telemetry or seam check); `POST /invite` of a banned user at the cap -> 403 "The invited user is banned from this room" (ban before caps);
   of a member -> 403 "already in this room". (f) **not capped:** Admin force-add (`EventDispatcher.Server.admin_add_room_member/3`, the call the
   force-add tests use) of B at B's invitee cap succeeds; `upgrade_room` of a room whose members include B at the cap succeeds and writes the row-only
   invitation. (g) Caps are NOT disabled by `:rate_limit_disabled`. (h) A failing count read: createRoom 500 and no room (unit with a fake `InviteDB`
   module through the existing `db_module_invite/0` seam, or HTTP with a fault the dev records), value-free log (no user id in the log line).
6. **`/sync` has no hidden invite cap (HTTP).** With the invitee cap set to 150, 120 pending invitations of B (written through `InviteDB` +
   `Room.DB.insert_event/1` fixtures or the real invite path with the tiers disabled) -> B's initial sync lists all 120 in `rooms.invite` (pins D10:
   no per-response cap was added).
7. **Unit coverage of the core seam (`test/nebu/matrix/event_dispatcher/invite_caps_test.exs`, unit fakes of `invite_db_module` / `rooms_db_module` as in
   `create_room_invites_test.exs`).** The count read is called ONCE per createRoom THAT HAS INVITEES (with the de-duplicated list; none otherwise, so the `[]` path of D8 has no production caller:
   it is pinned at function level on the real DB) and ONCE per `POST /invite` that would
   add a row, after EVERY other check (non-member inviter, invite level, foreign / unknown invitee, member, ban: none of them reads the counts), and NOT for the already-invited no-op, `pending_before`, step 8 (`caps: :prechecked`), Admin force-add, upgrade; `k` for createRoom is the
   de-duplicated count; the first failure order of D6.
8. **Docs (`test/nebu/matrix/membership_write_limits_docs_test.exs`, `File.read!`).** (a) `docs/matrix-api-scope.md`: the createRoom row names the
   `create_room` tier (10 / min, burst 20) and the per-invitee `invite` charge, the 429 as a divergence from the endpoint's Rate-limited flag (spec: createRoom "Rate-limited: No"; `M_LIMIT_EXCEEDED` is a common errcode),
   the three pending caps and their 403 texts, D7 order; the `POST /join` row the join tier (12 / min, burst 30); the `POST /rooms/{roomId}/invite` row
   the invite tier (20 / min, burst 50), the caps, `M_INVITE_BLOCKED` not implemented (`fh`); the `GET /sync` row: `rooms.invite` has no per-response
   cap, bounded by the per-invitee cap (D10). (b) `docs/architecture/07-deployment.md`: the **RELEASE GATE** paragraph (keep the bold `**RELEASE GATE`
   prefix so the docs helpers find it) is rewritten: the gate is LIFTED by this story (`ey` CLOSED: per-user tiers for createRoom / invite / join, the
   per-invitee charge, the pending caps; invite blocking split to `fh`); the batch may be released to Element-based deployments; `ex` remains the gate
   for BUILDING a ban route; the existing release-note points stay, plus a new point: the limits (the D1 table, per node, the three caps), the
   variables to tune them (the nine names), the `burst / rate <= 60` and invite burst `>= 50` rules, what users see in Element (D6 / premise table:
   createRoom dialog, join dialog, silent invite retry, "You do not have permission to invite" for a cap), `NEBU_RATE_LIMIT_DISABLED` disables the
   tiers but not the caps, the per-node honesty sentence (D9). (c) `docs/architecture/08-concepts.md`: a "Rate limiting (per user) - room membership
   writes" block with the three tiers and the caps next to the existing per-IP tables. (d) `CHANGELOG.md` `[Unreleased]`: one entry (behaviour change:
   the three tiers, the caps, the variables, the 403 texts, migration 000050). (e) `follow-ups.md`: `ey` CLOSED (status column `closed`, prefix
   "CLOSED by story rate-limits-join-invite-create-room (<date>):", the old row text kept after the closure sentence so the existing pins on `ey`
   (`createRoom`, `50`, `invite`, `rate limit`, `/join`, `/createRoom`, "`ev` is shipped", `VISIBLE`, `` `ex` ``) stay true), the notes on `fa`, `eo`,
   `ex`, `fb`, the new rows `fh`, `fi`, the id line: "`fh`-`fi`: rate-limits-join-invite-create-room" and "unused: ... `fj` onward".
9. **Tests that pin the OLD gate text are changed deliberately (Change Log entry each, old -> new):**
   - `test/nebu/matrix/sync_membership_partition_docs_test.exs` "07-deployment: the RELEASE GATE says ev and ez are CLOSED ..." (l.196-208): `must not be
     released` -> refuted; the gate names this story and "`ey`" CLOSED / lifted; "M_INVITE_BLOCKED" and "per-inviter cap" stay asserted (the new text
     mentions both); `` `ex` `` + "ban route" stay. The id-line test (l.137, "`fh` onward") -> "`fj` onward".
   - `test/nebu/matrix/create_room_invites_docs_test.exs` (l.220-229): `must not be released` -> refuted, "`ey`" stays; id line l.137 -> "`fj` onward".
   - `test/nebu/matrix/create_room_presets_docs_test.exs` (l.229-232 `deploy_section` "must not be released") -> the gate is lifted (refute) while
     "rooms.invite" and the other release-note assertions stay; id line l.120 -> "`fj` onward".
   - Any further suite that fails because of the tiers or caps is fixed in the TEST (more users, random inviters, a test-scoped
     `:rate_limit_disabled` in an `async: false` module), never by raising a default; each listed in the Change Log.
10. **No regression.** `create_room_invites_http_test.exs` (incl. "exactly 50 provisioned invitees are 200" and "51 distinct / 51 duplicates are 400"
    under the frozen clock), `create_room_invites_test.exs`, `create_room_presets_http_test.exs`, `create_room_input_validation_http_test.exs`,
    `sync_membership_partition_http_test.exs`, `join_room_test.exs`, `invite_user_test.exs`, `upgrade_room_test.exs`, the admin member management suites,
    `rate_limit_test.exs`, `rate_limit_sweeper_test.exs`, `matrix_client_compat_test.exs`, `regression_sync_load_test.exs` stay green unchanged (except AC9).
    The full suite with `--include integration` on a FRESH DB: no new failure family. Suites with FIXED user ids that invite across tests (accumulating
    pending rows over runs on a long-lived throwaway DB) are found by a grep and listed; a fresh DB is the reference.
11. **e2e (see "E2E verification").** Run A green except the rows of `e2e/KNOWN-FAILURES.md`; run B: zero `429` answers on the three routes in the
    full server log.
12. **Oracle gate tests (HTTP, the suite of AC3 / AC5 unless stated).** (a) **`Retry-After` on EVERY 429 path:** the 429 of `POST /join`, of `POST
    /rooms/{roomId}/invite` and of `POST /createRoom` (create bucket and invite bucket denial each) carries `Retry-After` as an integer `>= 1` and
    `retry_after_ms == Retry-After * 1000`. (b) **`take_all` denial over HTTP:** user C with an invite bucket that needs a LONGER wait than its create
    bucket (and, in a second case, the reverse) sends a createRoom with invitees: header and body carry the LARGER of the two waits and agree with each
    other. (c) **cap 403 bodies:** for each of the three caps the body is EXACTLY `{"errcode": "M_FORBIDDEN", "error": <the fixed text>}` (no
    `admin_contact`, no `retry_after_ms`, no further key), `content-type` `application/json`, and `refute errcode == "M_LIMIT_EXCEEDED"`. (d) **ignored
    inviter:** B puts A into `m.ignored_user_list`; A's `POST /invite` of B answers `200 {}` (byte-identical to a non-ignored invite: the ignore state does
    not leak), the row exists and COUNTS towards the caps (with the pair cap set to 1 a second invitation by A is the pair 403), and B's initial and
    incremental `/sync` do not list it in `rooms.invite`. (e) **re-join positive control:** a joined user's `POST /join` answers `200 {"room_id": ...}`,
    writes no second join event (count `m.room.member` events of the user in the room) and the user's `join` bucket went down by exactly 1 (read the ETS
    row or spend the remaining budget: the 30th join of the test is then the last that passes). (f) **charge before the no-op:** an already-invited target
    (`POST /invite` would be the 200 no-op) with the inviter's invite bucket EMPTY answers 429, not 200. (g) **no limiter-free join path:** `POST
    /_matrix/client/v3/rooms/{roomId}/join` and `POST /_matrix/client/v3/knock/{roomIdOrAlias}` (authenticated and not) answer `404 M_UNRECOGNIZED`
    (still unrouted; a future route must use the `join` tier, premise).

13. **Review cycle 1 (new tests; every SQL / concurrency rule on the real DB).** (a) `test/nebu/matrix/room/invite_caps_cycle1_db_test.exs`: the invitee
    total excludes deactivated and ignored inviters (pair and inviter counts raw; malformed lists ignore nobody; still ONE statement for 50 invitees);
    `first_cap_violation/3`; `insert_invitation_capped/4` decisions (no row on refusal, a re-arm of a decided row counts); N concurrent capped inserts never
    exceed the invitee / pair / inviter cap (several rounds), no deadlock when users invite each other. (b) `test/nebu/matrix/membership_write_limits_cycle1_http_test.exs`:
    the upgrade spends one `create_room` unit and is a 429 before the body check; 16 concurrent `POST /invite` with the pair cap 3 give exactly 3 x 200;
    ignored / deactivated inviters do not fill the invitee cap; a 70 KiB topic is left out of `invite_state` while both invitations stay.
    (c) `test/nebu/web/rate_limit_take_all_concurrency_test.exs`: 80 simultaneous requests pass exactly the burst (take_all one bucket, take/3, the plug,
    two buckets) and the refunds are complete. (d) `test/nebu/matrix/invite_state_budget_test.exs` (unit): the budget rules. (e)
    `test/nebu/matrix/membership_write_limits_cycle1_docs_test.exs`: the docs / compose / migration-header fixes. The id-line pins of the four docs suites
    moved from `fj` to `fk` (the follow-up `fj` is new).
14. **Delta gate (Kassandra H-1 HIGH, L-1, L-2, L-3, I-1, I-8).** (a) `test/nebu/matrix/room/invite_caps_ignore_list_cost_db_test.exs` (real DB, memory-safe sizes
    for the correct statement): a ~920 KB ignore list with 200 pending rows (half ignored) is counted in < 1 s with the exact result, for the pre-check read, for
    a count over 3 invitees with a big list each AND for the capped insert (which counts under the locks); a 1 MB non-JSON blob, a 1 MB array, an object whose
    `ignored_users` is a string or an array ignore nobody and cost nothing. Verified RED on the per-row SQL (4 of 7 fail on a 3 GiB PostgreSQL container) and green now.
    (b) `invite_caps_cycle1_db_test.exs`: the capped insert gives up after about 2 s with `:lock_timeout` when the invitee lock is held, writes nothing, works afterwards,
    and a lock on another invitee does not delay it; `membership_write_limits_cycle1_http_test.exs`: `POST /invite` is `503 M_LIMIT_EXCEEDED` (fixed body, value-free log,
    no row, no event) while the lock is busy and 200 after; an `m.room.create` above 64 KiB is reduced to creator / room_version / type in `rooms.invite`, a small one
    is untouched. (c) docs: "the optional stripped state is bounded; create and member content stays unbounded until `ep`" (07-deployment, 08-concepts, scope doc, D18), D7 points to D16 (a),
    PostgreSQL 16+ named; source pins (the fallback exception for the real module, `lock_timeout`, the lateral join, no per-row ignore subquery).

## Acceptance Tests

- `server/test/nebu/web/rate_limit_take_all_test.exs` (new, unit): AC1.
- `server/test/nebu/web/rate_limit_tiers_test.exs` (new, unit): AC2.
- `server/test/nebu/matrix/room/invite_caps_db_test.exs` (new, `@moduletag :integration`, real `Nebu.Repo`): AC4.
- `server/test/nebu/matrix/membership_write_limits_http_test.exs` (new, `@moduletag :integration`, real stack): AC3, AC5, AC6, AC12. Copy the private helpers of
  `create_room_invites_http_test.exs` (`make_room/2`, `invite!/3`, `join!/2`, `tick/0`, `invitation_rows/1`, `assert_rejected/5`: `defp`s, so copy
  them, as the sibling suites did), `T.provision_user!/1`, `T.sql!/2`, `T.reset_rate_limits/0`, `Nebu.Test.ServerName.pin!/1`. To advance the frozen clock: re-put
  `:rate_limit_clock_fn` with a later constant (restored by `T.restore_rate_limits/0`).
- `server/test/nebu/matrix/event_dispatcher/invite_caps_test.exs` (new, unit fakes): AC7.
- `server/test/nebu/matrix/membership_write_limits_docs_test.exs` (new): AC8.
- Re-pinned: AC9.

**SQL-dependent behaviour MUST be pinned on the real DB** (the pending predicate, the bounded counts, the one-statement property, the index use);
a fake that returns ready counts proves nothing about the SQL (a fake hid a real defect in an earlier story). Rate-limit behaviour is pinned over HTTP
with the frozen clock (no `Process.sleep`).

## E2E verification

No new scenario (`ui: false`; the Element-side behaviour on 429 / 403 is verified in the bundle, premise table). Two runs of the full `element-web`
project on a FRESH, isolated stack built from THIS commit (`make redeploy`-equivalent image build; the e2e-ci script builds the server image when
`NEBU_E2E_PREBUILT` is unset):

0. Preparation: `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000 (on 2026-10-19 `nebu-oauth-dev-minio-1` is still up: stop it,
   never touch the shared `nebu` project); `COMPOSE_PROJECT_NAME=nebu-oauth-e2e` for both runs; the stack is torn down with `down -v` between the runs
   (fresh DB each time; a reused stack makes the search scenarios order-dependent).
1. **Run A (CI parity, the regression gate):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e scripts/e2e-ci.sh element` (limits disabled as in CI). Pass: every
   scenario of the default tag expression green except the rows of `e2e/KNOWN-FAILURES.md` (K9 / K10 are excluded by their tags). Log:
   `_bmad-output/nebu/epics/oauth-broker/step-results/rate-limits-join-invite-create-room/e2e-run-a.log`. The pending caps are ACTIVE in this run (D5):
   a 403 "too many pending invitations" in any scenario is a finding (a default too low).
2. **Run B (defaults are never hit):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_RATE_LIMIT_DISABLED=false NEBU_E2E_KEEP=1 scripts/e2e-ci.sh element`,
   then `docker compose -p nebu-oauth-e2e logs --no-color server > .../e2e-run-b-server.log` and `docker compose -p nebu-oauth-e2e down -v
   --remove-orphans`. Pass: the `Nebu.Web.Plugs.RequestLogger` INFO lines (path template + status) show **zero** responses with status 429 for
   `/_matrix/client/v3/createRoom`, `/_matrix/client/v3/join/:...` and `/_matrix/client/v3/rooms/:.../invite` (record the exact grep and its count;
   the e2e helpers retry 429 silently, so a green run alone proves nothing). 429s of the pre-existing PER-IP tiers (login, sync, media: all Playwright
   traffic shares 127.0.0.1) are counted and recorded, they are not findings of this story; scenarios that fail only because of them are listed (run A
   is the gate). Log: `e2e-run-b.log` + `e2e-run-b-server.log` in the same directory.

   **Reused dev stacks (no `e2e/README.md` exists, so the note lives here):** the pending caps are state limits and are NOT disabled by
   `NEBU_RATE_LIMIT_DISABLED`; the pair cap (10) is reached on a REUSED dev stack after about ten e2e runs that leave unaccepted invitations behind
   (CI uses a fresh stack per run: not affected). Symptom: a 403 "too many pending invitations" in a scenario; fix: `down -v` or raise
   `NEBU_INVITE_MAX_PENDING_PER_PAIR` for the dev stack.

## Tasks

- [x] `Nebu.Web.Plugs.RateLimit.take_all/1` (D3) + moduledoc section; `take/3` unchanged.
- [x] `Nebu.Web.RateLimitTiers` accessors + `invalid_settings/0` (D4); `config/runtime.exs` parsing of the nine variables; boot warning in `Nebu.Application`.
- [x] Route heads in `protected.ex`: createRoom (D2 `take_all`, invite count rule), `POST /invite`, `POST /join` (one token each), before any other check.
- [x] Migration `000050_room_invitations_pending_inviter_idx.{up,down}.sql` (D8).
- [x] `InviteDB.pending_invite_counts/3` (D8); the cap check in `validate_create_room_request/1` (after the existence read) and in `do_invite!/5`
      (`caps: :check | :prechecked`, D7); fixed texts (D6); cap accessors in the core (`Application.get_env(:nebu, ...)`, defaults 500 / 100 / 10).
- [x] `scripts/e2e-ci.sh`: `NEBU_RATE_LIMIT_DISABLED` overridable (D5).
- [x] Tests (Acceptance Tests) and the AC9 re-pins (Change Log).
- [x] Docs AC8 (scope doc, 07-deployment gate + release notes, 08-concepts, CHANGELOG, follow-ups).
- [x] EXPLAIN (ANALYZE, BUFFERS) of the count statement on a seeded DB (Completion Notes).
- [ ] E2E runs A and B with logs (the orchestrator may run them; NOT run by the dev step: the e2e suites were out of scope for it).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (the count is inline
  SQL in `Nebu.Matrix.Room.InviteDB`, the migration raw SQL, no repository / service module: `Nebu.Web.RateLimitTiers` holds config accessors only, like
  `Nebu.Web.SessionConfig`), ADR-019 / ADR-021 (plain modules, in-process), ADR-020 (everything is in `Nebu.Matrix` / `Nebu.Web`; no cross-domain call),
  cluster-safety (no `Process.register`, no new global state: the ETS table exists; D9 is documented, not "fixed").
- **Files and current state (HEAD `39d54c21`, read before editing):**
  - `server/lib/nebu/web/plugs/rate_limit.ex` (whole file, 256 lines): `take/3` l.123, `take_token/4` l.179 (reuse its refill math; keep the `rescue
    ArgumentError -> :ok` fail-open of a vanished table, which the moduledoc documents), `respond_limited/2` l.211, `bucket_key/2` l.227 (`{tier, user}`).
  - `server/lib/nebu/web/rate_limit_sweeper.ex` (the 1 h idle invariant: D1 / D4 keep it).
  - `server/lib/nebu/web/router/protected.ex`: tiers l.34-42 (`account_data`), l.73 (`sync`), l.1860 (`room_summary`), l.1928 (`mutual_rooms`, the
    shared-IP comment l.1920-1926); createRoom l.1245-1349 (`body_params/1`, the `cond` of shape checks: the charge goes BEFORE it), join l.1352-1362,
    invite l.1368-1397.
  - `server/lib/nebu/matrix/event_dispatcher/server.ex`: `validate_create_room_request/1` l.819-852, `@invite_max_entries` l.857 (expose it through a
    public function for the AC2 invariant test, e.g. `invite_max_entries/0`), `validate_invite_list/2` l.878, `ensure_invitees_exist!/1` l.935 (the
    fail-closed pattern to copy for the count read), `invite_user/2` l.2563, `do_invite!/5` l.2620, `invite_pending!/2` l.2680, `write_invitation!/4`
    l.2704, `emit_invites/5` l.2797, `admin_add_room_member/3` around l.2151-2190 (untouched), `upgrade_room` invitation rows l.6905 (untouched),
    `db_module_invite/0` (the seam for AC5 (h) / AC7).
  - `server/lib/nebu/matrix/room/invite_db.ex` (whole file): add `pending_invite_counts/3` next to `pending_invite?/2`.
  - `server/lib/nebu/matrix/http.ex` `map_error/1` l.56-100 (no change needed: `permission_denied` + errcode).
  - `server/config/runtime.exs` l.99-114 (the pattern), `server/lib/nebu/application.ex` l.32 (`init_table/0`) and l.168 (sweeper child): the boot warning
    goes next to them (no new child process needed).
  - `server/priv/migrations/000049_*` (naming), `server/lib/nebu/release.ex` (transactional apply).
  - `scripts/e2e-ci.sh` l.65.
- **Must be preserved:** the 429 envelope and header; the existing tiers' values and keys; `T.reset_rate_limits/0` semantics; every createRoom / invite
  answer and order apart from the new 429 (first) and the cap 403 (D7 position); createRoom all-or-nothing; the D9 wake deferral; the re-arm upsert;
  value-free logs (never a user id together with the count, never the configured values in the boot warning, never the invite list).
- **Security (Kassandra will check):** (1) the tiers key on the authenticated user, never on a client-chosen value, and do not share the bare-IP
  bucket; (2) the 429 comes before any DB read (no work for a throttled user); (3) the createRoom charge cannot be dodged (dedup counts distinct ids; a
  51+ list is refused before anything is read; `n` can never exceed the burst); (4) all-or-nothing: a 429 / 403 leaves no room, row, event, audit row or
  wake-up; (5) the caps fail closed on a failing count read; (6) the 403 texts echo no id and no number; the per-invitee text is the only signal about
  other users' invitations (accepted LOW); (7) the caps cannot be bypassed through the re-arm (rejected / accepted rows ARE counted) and the
  `pending_before` exemption adds no row; (8) env overrides cannot break the sweeper invariant or make createRoom unsatisfiable (D4); (9)
  `NEBU_RATE_LIMIT_DISABLED` does not disable the caps. **Residuals to name:** D9 per-node budget (`fi` (a)), soft caps (`fi` (b)), uncapped writers /
  no withdrawal (`fi` (c), `fb`), L-1 accepted (`fi` (d)), invite blocking (`fh`), `ex` (ban route), `fe` (node-local wake-ups), `fc`.
- **Previous-story intelligence (sync-membership-partition, create-room-invites-direct):** vacuous tests were the top test-review finding: every
  negative assertion has its positive control in the same test (AC3 (a): the 21st is refused AND B is fine; AC5 (a): the 4th is refused AND C can
  still invite B); real-DB pins for every SQL rule and the one-statement property; HTTP suites pin `:server_name`; `tick/0` between membership changes;
  the createRoom D14 order is pinned by first-failure tests (AC5 (e)); docs pins live in the story's own docs suite, older docs suites are re-pinned
  deliberately with a Change Log line; the CI image is Elixir 1.20 (`mix compile --force --warnings-as-errors` and the no-DB `mix test
  --warnings-as-errors` on `elixir:1.20-alpine`); the 150 ms `regression_sync_load_test` may need to be moved aside in the full run (record it).
- **Element facts:** premise table (chunk names for re-checks: `init.js` `doInvite` / `MultiInviter`, `createRoom` error path, `showJoinRoomError`,
  `org.matrix.msc4155`; `element-web-app.js` `manageInvites`; i18n keys `create_room.generic_error`, `invite.error_permissions_room`,
  `decline_invitation_dialog.ignore_user_help`, `settings.invite_controls`).
- **References:** follow-ups `ey`, `fa`, `fb`, `ex`, `eu`, `eo`, `es`, `eq` (`docs/stories/oauth-broker/follow-ups.md` l.499-517, id line l.41);
  Kassandra reports `security-reports/create-room-invites-direct-security-review-2026-10-16.md` (M-2, L-1, L-3, I-9),
  `create-room-presets-power-levels-topic-security-review-2026-10-16.md` (F-9), `sync-membership-partition-security-review-2026-10-17.md` (L-3);
  stories `sync-membership-partition.md` (D5 newness, D8 ignore list), `create-room-invites-direct.md` (D14 order, the shared invite path);
  `docs/architecture/07-deployment.md` l.272 (RELEASE GATE) and l.655 (rate limits in the OAuth area); `docs/architecture/08-concepts.md` l.432-452;
  `docs/matrix-api-scope.md` l.56 (sync), l.62 (createRoom), l.63 (join), l.66 (invite); spec `client-server-api/index.html` (Rate limiting, Invite
  permission, Ignoring users, createRoom / join / invite / profile endpoints); `skills/nebu-conventions/cluster-safety/SKILL.md`.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (bmad-dev-story, pipeline step dev, 2026-10-19).

### Debug Log

- Throwaway-Postgres runs on a Docker VM disk that had filled up (97 %, leaked anonymous volumes of earlier `docker rm -f`): `initdb` failed with "No space left on device" and the first full-suite attempt ran against a dead database. Fixed by `docker volume prune` (anonymous volumes only), then rerun on a fresh container with its own names.
- `sync_membership_partition_http_test.exs` fails (14 tests, `tick/0` -> `:timeout`) when it runs in the same invocation after `matrix_client_compat_test.exs` (seed 26170). Reproduced on a clean checkout of HEAD `39d54c21` (same 14 failures): a pre-existing order dependency (events stamped ahead of the clock), not this story.

### Completion Notes List

- `RateLimit.take_all/1`: all-or-nothing over any number of buckets; the refill math is shared with `take/3` through two small private helpers (`refilled_tokens/4`, `wait_seconds/2`), `take/3` is untouched in behaviour. A denial stores the refilled values and returns the LARGEST wait over the buckets that cannot pay; `cost > burst` is charged as `burst`; the table-vanished fail-open is kept.
- `Nebu.Web.RateLimitTiers`: config accessors only. A half-configured pair takes the default for the absent half and is checked as a pair (`burst <= 60 * rate`, invite burst `>= invite_max_entries/0`), an invalid pair falls back to the DEFAULT pair; a non-positive-integer app-env value counts as absent (no division by zero). `warn_invalid_settings/0` logs one warning per rejected variable, names the variable and the rule, never the value (called from `Nebu.Application.start/2`). The tier atoms are built at compile time (no `String.to_atom/1` on runtime data).
- `config/runtime.exs`: the nine variables in the existing `[:prod, :dev]` block with the room-account-data rule (strictly positive int64, anything else keeps the default). The AC2 parsing tests use `Config.Reader.read!/2` of the real file (the pattern pinned by the suite).
- Routes: `with_membership_charge/3` in `protected.ex` charges `[{{tier, user}, cost, rate, burst}]` through `take_all/1` BEFORE any body check or DB read. createRoom: 1 `create_room` unit plus `n` `invite` units (`n` = distinct string entries of a list of at most 50 raw entries, else 0); the handler body moved unchanged into `create_room_request/3`. `POST /invite` and `POST /join`: one token. Every denial is `respond_limited/2` (unchanged envelope, `Retry-After` seconds on every path).
- Core: `invite_max_entries/0`, `invite_max_pending/0` (call-time read, junk keeps the default), `check_invite_caps!/2` (ONE bounded read through `invite_db_module().pending_invite_counts/3`, first failure wins: inviter, then the invitees in list order, pair before invitee total; limit = max cap + 1, clamped to int64), fail closed (500, ERROR log with the error class only). createRoom: new LAST step of `validate_create_room_request/1` (after the existence read, only with invitees); step 8 calls `do_invite!` with `caps: :prechecked`. `POST /invite`: inside `do_invite!/5` after member / ban / already-invited and only when `pending_before` is false. Admin force-add and `upgrade_room` are untouched (not capped, but counted).
- `InviteDB.pending_invite_counts/3`: one statement (`UNION ALL` of the inviter row and one row per invitee over `unnest($2::text[])`), every count over a `LIMIT $3` subquery. Migration 000050 is a plain partial `CREATE INDEX IF NOT EXISTS ... (inviter_id, invitee_id) WHERE accepted_at IS NULL AND rejected_at IS NULL` plus the `DROP INDEX IF EXISTS` down file; the header avoids the words the static SQL scans look for (no GRANT / RLS change is needed for an index).
- Docs: the reference docs of the ATDD step were reviewed against the story and applied (scope doc rows, 07-deployment gate LIFTED + release note 7, 08-concepts block, CHANGELOG entry, follow-ups `ey` closed with its old text kept, notes on `fa` / `eo` / `ex` / `fb`, new rows `fh` / `fi`, id line -> `fj`).
- e2e runs A and B (AC11) done by the orchestrator on 2026-10-19: both 25 passed on a fresh isolated stack; the server log of run B (limits enabled) holds 0 `status: 429` lines and 0 cap 403s for 27 createRoom / 20 join / 18 invite calls (evidence: step-results/rate-limits-join-invite-create-room/e2e-run.md).
- EXPLAIN (ANALYZE, BUFFERS), seeded 20 000 rows (1 000 inviters x 20 rows, 2 000 invitees x 10 rows, a third accepted), 20 invitees, planner's own choice: `Index Only Scan using room_invitations_pending_inviter_idx` (inviter count, actual rows 13, 29 buffers; pair counts, `Index Cond: inviter_id = ... AND invitee_id = i.invitee`) and `Bitmap Index Scan on room_invitations_invitee_idx` (invitee total, `LIMIT` stops at the pending rows); NO Seq Scan on `room_invitations`; Execution Time 0.292 ms, 524 shared buffers (all hits). One invitee: 0.107 ms, 68 buffers. With `enable_seqscan = off` the plan is identical. Full output: `_bmad-output/nebu/epics/oauth-broker/step-results/rate-limits-join-invite-create-room/explain-pending-invite-counts.txt`.
- Tests (isolated throwaway Postgres): take_all 13, tiers 23 (incl. runtime.exs parsing), real-DB counts 13, migration 000050 8, unit seam 20, HTTP 38, new docs suite 15, the three re-pinned docs suites 26 + 17 + 28; `mix compile --force --warnings-as-errors` and the no-DB `mix test --warnings-as-errors` green on elixir:1.20-alpine (5805 passed, 7 skipped).

- REVIEW CYCLE 1 (code review 0 MAJOR / 6 MINOR, Kassandra CLEAN 2 MEDIUM / 2 LOW), all FIX NOW items done (D16-D20, AC13):
  - M-1a: the invitee total of `pending_invite_counts/3` excludes rows of deactivated inviters and of inviters on the invitee's `m.ignored_user_list` (same statement, `pg_input_is_valid` guard); EXPLAIN on 20 000 rows with 10 ignore lists: pending-inviter partial index, `room_invitations_invitee_idx`, `users_pkey`, `account_data_pkey`, no Seq Scan on `room_invitations` (0.757 ms, 20 invitees; the earlier Seq Scan of `account_data` was a 10-row table only). M-1b: DEVIATION: the deactivation rows are not rejected (one path, `deactivate_user`; rejecting would send `rooms.leave` to the invitees and a reactivation could not undo it); the exclusion frees the slots.
  - M-1c: `InviteDB.insert_invitation_capped/4` (count + row under the advisory locks of inviter and invitee), used for every row that adds a pending row (POST /invite and createRoom step 8); verified RED without the lock (3 of 16 DB tests fail) and green with it; `first_cap_violation/3` and `count_bound/1` are the shared pure helpers. The unit fakes are served by `insert_invitation/3` (a `function_exported?` fallback, like `inviter_member_events/1`), so the staged unit pins are unchanged.
  - M-2: `Server.limit_invite_state/3` (64 KiB per optional event, 8 MiB per response, never the invitation), applied by `build_invite_rooms/2` (initial and incremental sync).
  - L-1 / MINOR-4: `POST /rooms/{id}/upgrade` is charged one `create_room` unit first. L-2 / D20 docs, MINOR-2 comment, MINOR-3 inline claims, INFO-4 compose pass-through, I-6 lock-window note, INFO-6 migration header: done. Optional I-7 (warn on invalid cap variables) NOT done.
  - MINOR-1: the limiter (`take/3`, plug, `take_all/1`) takes tokens with a compare-and-swap (`:ets.select_replace/2`, `:ets.insert_new/2`), `take_all/1` refunds charged buckets when a later one denies; the new concurrency test is RED on the old lookup + insert code (25 of 80 passed a burst of 20 in round 1) and green now.
  - MINOR-6: follow-up `fj` (pre-existing `tick/0` flake); the id line moved to `fh`-`fj` / `fk` onward (the id-line pins of four docs suites were re-pinned: `fj` -> `fk`).
  - Not done: MINOR-5 (e2e, the orchestrator), the router "new membership route needs a charge" test (optional), `ep`.
- Tests of cycle 1 (isolated throwaway Postgres): cycle1 DB 16, cycle1 HTTP 8, limiter concurrency 4, invite_state budget 7, cycle1 docs 9; rate_limit_test 4, rate_limit_sweeper_test 8, create_room_invites_http 53, sync_membership_partition_http 50 (alone). Full suite on a fresh DB (`regression_sync_load_test` moved aside and restored), seed 782162: 8963/8985 passed, 8 skipped; failing names all in the known flaky families (TraceMapNodeControls 3, WarRoom 1, RoomsFallbackName 11, TemporaryCaptureManager 2, AdminOidcLogin 3, LogStore.Retention 1, MatrixClientCompat 1). `mix compile --force --warnings-as-errors` and the no-DB `mix test --warnings-as-errors` green on elixir:1.20-alpine (5825 passed, 7 skipped).

- DELTA GATE of review cycle 1 (Kassandra: BLOCKED on H-1 HIGH, L-1, L-2, L-3, I-1, I-8), all fixed (D16 addendum, AC14):
  - H-1: the ignore list is parsed once per invitee (LEFT JOIN LATERAL); new real-DB regression suite `invite_caps_ignore_list_cost_db_test.exs` (7 tests), RED on the per-row SQL (4 failures, 3 GiB container), green now; EXPLAIN (720 KB list, 20 000 rows): `account_data_pkey`, `room_invitations_invitee_idx`, `users_pkey`, the partial index, no Seq Scan on `room_invitations`, 11 ms for one invitee with the big list (12 ms for 20 invitees).
  - L-2: `SET LOCAL lock_timeout = '2s'`, `:lock_timeout` -> `503 M_LIMIT_EXCEEDED` (new opt-in clause in `Http.map_error/1`). I-1: the fallback is never used for the real `InviteDB`. L-1: `m.room.create` above 64 KiB reduced to its spec keys in the stripped invite state; wording "the optional stripped state is bounded; create and member content stays unbounded until `ep`". L-3: D7 rewritten. I-8: PostgreSQL 16+ in the release note.
### File List

- `server/lib/nebu/web/plugs/rate_limit.ex` (take_all/1, shared refill helpers, moduledoc)
- `server/lib/nebu/web/rate_limit_tiers.ex` (new)
- `server/lib/nebu/application.ex` (boot warning)
- `server/config/runtime.exs` (nine variables)
- `server/lib/nebu/web/router/protected.ex` (charges on createRoom / join / invite)
- `server/lib/nebu/matrix/event_dispatcher/server.ex` (caps, accessors, `caps:` option)
- `server/lib/nebu/matrix/room/invite_db.ex` (`pending_invite_counts/3`)
- `server/priv/migrations/000050_room_invitations_pending_inviter_idx.up.sql`, `.down.sql` (new)
- `scripts/e2e-ci.sh` (staged by the ATDD step)
- Tests (staged by the ATDD step, unchanged by the dev step): `server/test/nebu/web/rate_limit_take_all_test.exs`, `rate_limit_tiers_test.exs`, `server/test/nebu/matrix/room/invite_caps_db_test.exs`, `server/test/nebu/migration/000050_room_invitations_pending_inviter_idx_test.exs`, `server/test/nebu/matrix/event_dispatcher/invite_caps_test.exs`, `membership_write_limits_http_test.exs`, `membership_write_limits_docs_test.exs`, the adapted fakes and the three re-pinned docs suites
- Docs: `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/architecture/08-concepts.md`, `CHANGELOG.md`, `docs/stories/oauth-broker/follow-ups.md`
- Review cycle 1: `server/lib/nebu/web/plugs/rate_limit.ex` (compare-and-swap), `server/lib/nebu/matrix/room/invite_db.ex` (exclusions, `insert_invitation_capped/4`, `first_cap_violation/3`, `count_bound/1`), `server/lib/nebu/matrix/event_dispatcher/server.ex` (capped row write, `limit_invite_state/3`), `server/lib/nebu/web/router/protected.ex` (upgrade charge, comment), `server/priv/migrations/000050_room_invitations_pending_inviter_idx.up.sql` (header), `docker-compose.yml` (nine variables), `docs/stories/oauth-broker/security-reports/...` (read only), `_bmad-output/.../explain-pending-invite-counts.txt` (new EXPLAIN)
- Delta gate: `server/lib/nebu/matrix/http.ex` (503 with errcode), `server/lib/nebu/matrix/room/invite_db.ex` (lateral ignore list, `lock_timeout`), `server/lib/nebu/matrix/event_dispatcher/server.ex` (`:lock_timeout` answer, fallback guard, `stripped_content/1`); new test `server/test/nebu/matrix/room/invite_caps_ignore_list_cost_db_test.exs`; extended `invite_caps_cycle1_db_test.exs`, `membership_write_limits_cycle1_http_test.exs`, `membership_write_limits_cycle1_docs_test.exs`; docs 07-deployment, 08-concepts, scope doc
- Review cycle 1 tests (new): `server/test/nebu/matrix/room/invite_caps_cycle1_db_test.exs`, `server/test/nebu/matrix/membership_write_limits_cycle1_http_test.exs`, `server/test/nebu/web/rate_limit_take_all_concurrency_test.exs`, `server/test/nebu/matrix/invite_state_budget_test.exs`, `server/test/nebu/matrix/membership_write_limits_cycle1_docs_test.exs`; re-pinned (`fj` -> `fk`, `fh`-`fi` -> `fh`-`fj`): `membership_write_limits_docs_test.exs`, `sync_membership_partition_docs_test.exs`, `create_room_invites_docs_test.exs`, `create_room_presets_docs_test.exs`

### Change Log

- 2026-10-19 (delta gate): Kassandra H-1 (HIGH, per-row parse of the ignore list: DB OOM) fixed by parsing once per invitee; L-2 `lock_timeout` + 503, I-1 fallback guard, L-1 create content reduction and wording, L-3 D7, I-8 PostgreSQL 16+; AC14 added.
- 2026-10-19 (review cycle 1): D16-D20 and AC13 added (hard caps under advisory locks, invitee total without ignored / deactivated inviters, upgrade charged, invite_state byte budget, atomic limiter, docs and compose fixes, follow-up `fj`); AC8 pins changed deliberately: the id line is `fh`-`fj` / `fk` onward in the four docs suites (old -> new: `fh`-`fi` / `fj` onward).
- 2026-10-19 (dev): implemented D1-D15 (take_all, tiers + runtime.exs + boot warning, route charges, caps, `pending_invite_counts/3`, migration 000050, docs). AC9 re-pins were made in the ATDD step (old -> new: `must not be released` -> refuted, `fh` onward -> `fj` onward in the three docs suites).
- 2026-10-19 (test review, 0 MAJOR): D4 names the half-configured pair rule, `RateLimitTiers.warn_invalid_settings/0` and the accessor hardening; D7 / AC7 say the count read
  is made once per createRoom THAT HAS invitees (and after every other check on `POST /invite`); D8 `limit >= max cap + 1`; e2e note on reused dev stacks and the pair cap.
- 2026-10-19 (Oracle gate, no WRONG verdict): createRoom limiting worded as a "divergence from the endpoint's Rate-limited flag" (premise, AC8 (a));
  D6 records why `M_USER_LIMIT_EXCEEDED` (v1.18) was rejected; premise: `POST /rooms/{roomId}/join` and `POST /knock` are Rate-limited: Yes, unrouted, and
  must share the `join` tier when routed; AC12 adds the seven missing tests of the Oracle list (Retry-After on every 429 path, the larger wait of a
  `take_all` denial, exact cap 403 bodies, ignored inviter pin, re-join positive control, charge before the already-invited no-op, unrouted join / knock
  paths). Follow-up ids `fh` / `fi` unchanged.
- 2026-10-19 (create-story): story created from follow-up `ey` and the Kassandra findings M-2, L-1 (create-room-invites-direct), F-9 (presets), L-3
  (sync-membership-partition); premises verified at HEAD `39d54c21` and in the Element 1.12.15 bundle; decisions D1-D15; new follow-ups `fh`, `fi`.
