# Security Review — bugfix-mutual-rooms

**Reviewer:** Kassandra (nebu-agent-kassandra, `references/security-review.md`)
**Diff scope:** `git diff --staged` on branch `bugfix/upcloud-s3-iam-sts-endpoints` — 8 files,
+1088/-10. Production surface: `server/lib/nebu/web/router/protected.ex` (new routes
`GET /_matrix/client/v1/mutual_rooms` and the MSC2666 unstable alias
`GET /_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms`),
`server/lib/nebu/matrix/event_dispatcher/server.ex` (`get_mutual_rooms/4` and helpers),
`server/lib/nebu/matrix/page_token.ex` (new shared cursor codec),
`server/lib/nebu/matrix/space_hierarchy.ex` (refactored onto that codec),
`server/lib/nebu/web/router.ex` (`unstable_features` flag). Tests:
`matrix_mutual_rooms_test.exs` (new), `page_token_test.exs` (new), `matrix_router_test.exs`.
**Date:** 2026-10-05
**Classification:** CLEAN (no CRITICAL, no HIGH)
**Verdict:** APPROVED — nothing blocks the commit.

This story carried `security_review: required` because its entire purpose is comparing two
different users' membership sets. Three prior code-review cycles established functional
correctness of the 12 ACs; this review did not re-derive that. It applied an adversarial lens and,
per this project's convention, **verified claims by execution rather than from training-data
recall of PCRE/Postgres/Plug semantics**. Every empirical result below was produced by running
code against Elixir 1.20.4 / OTP 28 and a throwaway `postgres:16-alpine` instance; the probe
scripts and the container were discarded afterwards.

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/matrix/user_id.ex:27` → `protected.ex:1237-1243` → `event_dispatcher/server.ex:2377-2399` | `@user_id_regex`'s domain class `[^\s:]+` accepts 249 of 256 byte values, including `NUL` and the Unicode line separators `U+0085`/`U+2028`. A `NUL` forces a Postgres encoding error, which routes into the new `mutual_rooms_id_set!/1` failure branch and interpolates the **raw, client-controlled bytes** into a warning-level `Logger` line — and returns an on-demand `503 M_UNAVAILABLE` | Anchor and tighten the regex: `~r/\A@[a-z0-9._=\-\/+]+:[A-Za-z0-9.\-]+\z/`. Independently, do not interpolate unvalidated identifiers into log messages — log `inspect(user_id)` |
| 2 | LOW | `server/lib/nebu/matrix/user_id.ex:27` → `protected.ex:1240` | PCRE `$` matches **before a final newline**, so `?user_id=@<self-mxid>%0A` passes `UserId.valid?/1` while failing the byte-equality self-check, bypassing AC8: returns `200 {count:0,joined:[]}` where MSC2666 requires `400 M_INVALID_PARAM` | Same regex fix as Finding #1 (`\A`/`\z` anchors). No separate change needed |
| 3 | MEDIUM<br>(PRE-EXISTING) | `server/lib/nebu/web/plugs/rate_limit.ex:91,119-139` | The ETS token bucket is keyed by **IP alone**. `tier` is read in `init/1` and never used by `call/2`/`take_token/4`, so all tiers share one bucket per IP. `refilled = min(burst, …)` means a **single** `mutual_rooms` request (burst 30) clamps a bucket `/sync` had filled to 100 down to 29, for every other client on that IP | Key the bucket by `{ip, tier}`. `tier` is already captured in the opts map — `call/2` only needs to destructure it and pass it into `take_token/4` |
| 4 | LOW | `event_dispatcher/server.ex:2344-2351`; `protected.ex:1192-1200` | Unbounded fan-out: the unstable alias (`unpaginated: true`) emits the entire intersection with no size cap, and **both** routes recompute `MapSet.new` + `intersection` + `Enum.sort` over the caller's full room set on *every* request — pagination bounds the response, not the work | Cap the unstable alias's `joined` at a hard server-side ceiling, and bound `get_rooms_for_user/1` with a `LIMIT` sentinel so an extreme room count degrades rather than amplifying |

INFO items (no severity, recorded for the audit trail and future reviews) are in their own section.

---

### Detail

**Finding #1 — Over-permissive `user_id` domain class puts attacker-controlled bytes into the
application log and gives any authenticated user an on-demand 503** [MEDIUM]

`Nebu.Matrix.UserId.valid?/1` is the only content gate between `?user_id=` and the database on
this endpoint (`protected.ex:1239`). Its grammar is:

```elixir
@user_id_regex ~r/^@[a-z0-9._=\-\/+]+:[^\s:]+$/
```

The localpart class is correctly tight. The **domain** class is not: `[^\s:]` means "any byte that
is not ASCII whitespace and not a colon". `\s` in a non-Unicode Erlang `re` pattern is the ASCII
set `[ \t\n\v\f\r]` only. A byte sweep of all 256 values in the domain position:

```
accepted as a single-byte domain : 249 of 256
  includes NUL (0x00) and every C0 control except \t \n \v \f \r
  includes DEL (0x7F)
  includes all 128 high-bit bytes (so U+0085 NEL and U+2028 LINE SEPARATOR both pass)
accepted inside the localpart     : +-./0123456789=_abcdefghijklmnopqrstuvwxyz   (correct)
```

The exploit chain was verified end to end, leg by leg:

1. **Transport.** `Plug.Conn.fetch_query_params/1` passes `%00` and `%E2%80%A8` through unaltered.
   Verified: `"user_id=%40a%3Ax%00"` → `<<64, 97, 58, 120, 0>>`. (Plug *does* reject structurally
   invalid UTF-8 — `%FF` raises `Plug.Conn.InvalidQueryError`, `plug_status: 400` — which closes
   the invalid-UTF-8 variant of this. `NUL` is valid UTF-8 and is not covered by that check.)
2. **Validation.** `Regex.match?(@user_id_regex, "@a:x" <> <<0>> <> <<0xE2,0x80,0xA8>> <> "forged_log_entry")`
   → `true`. The payload also passes the self-check (it is not byte-equal to the caller).
3. **Database.** Against a real PostgreSQL 16, `SELECT room_id FROM room_members WHERE user_id = $1
   AND left_at IS NULL` with that parameter returns
   `{:error, %Postgrex.Error{postgres: %{code: :character_not_in_repertoire, message: "invalid byte
   sequence for encoding \"UTF8\": 0x00"}}}`. The connection remains usable afterwards
   (`SELECT 1` → `:ok`), so there is no pool poisoning.
4. **Sink.** That `{:error, reason}` lands in the branch this diff introduces
   (`event_dispatcher/server.ex:2390-2399`):

   ```elixir
   Logger.warning(
     "mutual_rooms: get_rooms_for_user failed for #{user_id}: #{inspect(reason)}"
   )
   ```

   Verified output, with the handler surviving:

   ```
   15:49:55.320 [warning] mutual_rooms: get_rooms_for_user failed for @a:x^@<U+2028>forged_log_entry: SOMEREASON
   logger handlers still installed: [:default, :ssl_handler]
   ```

5. **Response.** `map_error/1` maps `unavailable()` to the constant `"Core is temporarily
   unavailable"` (`http.ex:73-74`), so the raised `inspect(reason)` is **not** reflected to the
   client — code review's trace of that was correct. The client gets `503 M_UNAVAILABLE`.

Two distinct consequences:

*Log integrity.* A client-chosen byte sequence reaches a warning-level log record verbatim, and
the same payload can carry a `U+2028`/`U+0085` line separator **followed by attacker-controlled
text** — the `\n` route is capped at a single trailing byte by the `$` anchor, but these are not,
because they sit inside the domain class. Any downstream pipeline that splits on Unicode line
terminators (several JVM- and JS-based ingesters do; `promtail`/`journald` split on `\n` only)
renders that as a separate, forged log line. This is the *application* log, not the tamper-evident
`audit_log` table — which is why this is MEDIUM and not higher. For a compliance-native product
the distinction matters but does not make it harmless.

*Monitoring and cost.* `?user_id=@a:b%00` is a one-request, always-reproducible `503
M_UNAVAILABLE` plus an error-shaped "database unavailable" warning. At this endpoint's 120/min
tier that is ~172,800 fabricated DB-outage warnings per day per IP — alert fatigue against a
signal operators are supposed to trust, plus the log-ingest cost.

Why MEDIUM, not HIGH: it is trivially reachable with standard user credentials (one `GET`), which
argues for HIGH, but the impact contains no data exposure, privilege escalation, or IDOR, and the
multi-line half of the log forgery depends on the downstream log consumer's line-splitting
behaviour — a chained condition. MEDIUM is the honest placement.

**Remediation.** Change the grammar in `user_id.ex:27` to:

```elixir
@user_id_regex ~r/\A@[a-z0-9._=\-\/+]+:[A-Za-z0-9.\-]+\z/
```

Verified non-regressive: `@alice:localhost`, `@alice:test.local`, `@a.b_c=d-e/f+g:nebu.example.org`,
`@kai:NEBU.Example.ORG`, `@0:a`, `@user:192.168.0.1`, `@u:dev-host.internal` all still match
(0 regressions); all seven hostile payloads above are rejected; the accepted-domain byte class
drops from 249 to 64. Note that port-bearing server names (`host:8448`) are rejected by the
**current** regex too (`[^\s:]` excludes `:`), so this is not a new limitation. Add
`Nebu.Matrix.UserIdTest` cases pinning the trailing-`\n`, `NUL`, `U+0085` and `U+2028` rejections —
without them this regresses silently. Independently and as defence in depth, switch the log line
to `inspect(user_id)` so no identifier can ever be emitted as raw bytes regardless of what the
validator lets through.

**Blast radius beyond mutual_rooms.** `UserId.valid?/1` has four other call sites. They are
*incidentally* protected, not by design:

- `admin/rooms_controller.ex:227` and `admin/spaces_controller.ex:264` apply `String.trim/1`
  **before** `valid?/1`. Verified: `String.trim/1` strips trailing `\n`, `U+0085` and `U+2028`
  (Unicode-whitespace-aware) — so the line-separator class never reaches those. It does **not**
  strip `NUL`, `SOH` or `DEL`, which still pass `valid?/1` after trimming.
- `admin_add_room_member/3` (`event_dispatcher/server.ex:1036`) is backstopped by
  `local_domain?/1`'s exact `domain == server_name` comparison, so any contaminated domain is
  rejected as `:foreign_domain` before any write. This is the *only* real authorization boundary
  there, exactly as its own comment says.
- `admin_remove_room_member/3` (`:1111`) has no such backstop, but a contaminated id matches no
  `room_members` row and resolves to `:not_member`.

So `mutual_rooms` is the **first** call site that forwards a raw, un-trimmed query parameter
through `valid?/1` into a DB query and a log sink. The regex is the shared root cause; fixing it at
`user_id.ex:27` closes the class everywhere rather than papering over it at one call site.

---

**Finding #2 — PCRE `$` matches before a trailing newline, bypassing the AC8 self-check** [LOW]

Confirmed exactly as the code reviewer suspected (INFO-10, cycle 3), and confirmed by execution
rather than from recall:

```
Regex.match?(~r/^@[a-z0-9._=\-\/+]+:[^\s:]+$/, "@alice:test.local\n")  => true
"@alice:test.local\n" == "@alice:test.local"                           => false
=> self-check bypassed                                                 => true
Regex.match?(~r/\A…\z/, "@alice:test.local\n")                         => false   (anchors fix it)
```

Elixir's `~r//` compiles without `PCRE_DOLLAR_ENDONLY`, so `$` matches at end-of-subject *or*
immediately before a single final `\n`. Exactly one trailing `\n` is reachable — `\r\n`, `\n\n`,
and `\n` followed by any text all fail, since `[^\s:]` cannot itself match `\r` or `\n`. Verified.

Exploitability: the reviewer's assessment that there is **no data leak** is correct, and I verified
the mechanism rather than accepting it. `room_members.user_id` is `TEXT` compared with `=` under a
deterministic collation, so `"@alice:test.local\n"` cannot match the row for `"@alice:test.local"`.
Against a real PostgreSQL: exact id → `[["!r:test.local"]]`; trailing-LF id → `[]`. The result is
`200 {count: 0, joined: []}` where MSC2666 requires `400 M_INVALID_PARAM` — a spec-conformance
defect in an anti-abuse guard, not a disclosure. LOW.

There is no variant of this that leaks: for the self-check bypass to return data it would need a
byte-*different* id that resolves to the *same* DB row, and the caller's own mxid is server-minted
through `UserId.sanitize/1` (`[a-z0-9._=\-\/+]` only) plus the configured `server_name`, so no such
near-miss exists.

Remediation is Finding #1's regex change; no separate work.

---

**Finding #3 — Shared per-IP rate-limit bucket: `tier` is accepted and never used** [MEDIUM,
PRE-EXISTING — not introduced by this diff]

`RateLimit.init/1` stores `tier` (`rate_limit.ex:86`). `call/2` destructures only
`%{rate_per_ms: …, burst: …}` (`:91`) and `take_token/4` keys ETS on `ip` alone (`:119-131`). All
six configured tiers — `/sync` (600/min, burst 100), `mutual_rooms` (120/min, burst 30, new),
media upload, media preview, `/login` (30/min, burst 10), `/refresh` (30/min, burst 10) — therefore
share **one bucket per IP**.

I re-implemented `take_token/4`'s arithmetic faithfully and ran it rather than reasoning about it:

```
=== Clamp effect: one mutual_rooms call on a bucket /sync had filled ===
after 1 mutual_rooms (burst 30): :ok  bucket={29.0, 0}
-> /sync burst headroom on this IP: 100 -> 29.0

=== Sustained drain, then a co-located /login ===
bucket after 40 mutual_rooms in 1ms: {0.0, 0}
co-located victim's /login:          :deny     <- 429 for an unrelated user
```

So the answer to the question this review was asked — *can repeated `mutual_rooms` calls push other
users' `/login` attempts into 429s from behind a NAT/CGNAT/corporate proxy?* — is **yes,
mechanically**, and the clamp half needs only **one** request, not a sustained flood.

But the adversarial conclusion is that this adds **no net attack capability**, and saying otherwise
would be inflation:

| path | auth required | sustained drain | burst clamp imposed on the shared bucket |
|---|---|---|---|
| `/login` | **no** | 30/min | 10 |
| `mutual_rooms` | yes | 120/min | 30 |
| `/sync` | yes | 600/min | 100 |

`/login` is reachable **unauthenticated** and shares the same bucket, so an attacker with no
account at all can already pin an IP's bucket at zero and 429 every co-located user's `/login`,
`/sync` and media call. `/sync` is a 5× stronger authenticated drain. `mutual_rooms` lands strictly
between the two. Its *clamp* (30) is also strictly weaker than `/login`'s (10) — any `/login` on
that IP already truncates the bucket to 10.

The real finding is the plug's design, which this story merely exercises for the sixth time: `tier`
exists in the API, is documented in the moduledoc's usage example, and is silently discarded. Any
future reader configuring a tighter tier for a sensitive endpoint will believe they have isolated
it when they have not. That is a defence-in-depth weakness with a one-line fix, so it is recorded
as MEDIUM, **non-blocking and explicitly not attributed to this diff**. Fix: make the ETS key
`{ip, tier}` by destructuring `tier` in `call/2` and threading it into `take_token/4`. Note that
this is a behaviour change to a shared control — it should land in its own change with its own
regression test, not be bolted onto this bug fix.

---

**Finding #4 — Unbounded intersection: the response is capped on one route, the work on neither**
[LOW]

`get_mutual_rooms/4` always materialises the full picture before paging:

```elixir
caller_rooms = mutual_rooms_id_set!(caller_id)      # :2344
target_rooms = mutual_rooms_id_set!(user_id)        # :2345
shared = caller_rooms |> MapSet.intersection(target_rooms) |> Enum.sort()   # :2347
page = shared |> Enum.drop(offset) |> Enum.take(limit)                      # :2351
```

Two separate observations:

*Response size (the item code review raised as INFO-8).* On the unstable alias `limit = total`
(`:2349`), so `joined` is the complete intersection with no ceiling, at 120/min. Reaching an
interesting size requires both users joined to a very large number of rooms, which an attacker can
only engineer with a second account they control — and `createRoom` carries no rate limit of its
own (a pre-existing gap already recorded in MEMORY). The amplification is real but self-inflicted,
loud, and expensive to set up. The stable v1 route, which every new client uses, is correctly
capped at 50.

*Server-side work, which is the sharper half and was not raised.* Pagination bounds the
**response**, not the **computation**: every page request re-reads the caller's *entire*
`room_members` row set and rebuilds a `MapSet` of it before dropping into the window. The cost
therefore scales with the **caller's own** room count, which the caller fully controls, and is
independent of the target — `?user_id=@nonexistent:server` still pays it in full. `MapSet.intersection/2`
iterates the smaller set, so the intersection and sort are cheap; the DB round-trip and
`MapSet.new/1` over N rows are not. This is an asymmetric cheap-request/expensive-response
primitive that also occupies an Ecto pool connection per call.

LOW, because it is strictly dominated by `/sync` — which at 600/min builds a full state snapshot of
every joined room and is a far better amplifier — and because the per-IP limiter caps repetition.
Fix: give the unstable alias a hard `joined` ceiling (truncate with a documented contract rather
than silently), and bound `get_rooms_for_user/1` with a `LIMIT` sentinel so a pathological room
count degrades instead of amplifying.

Hostile pagination inputs were checked separately and are sound: a 400-digit forged offset decodes
in 19 µs and `Enum.drop/2` on a list terminates on the empty tail (5 µs, returns `[]`) rather than
counting down the bignum — no DoS there.

---

### Verified clean — the eight angles this review was specifically tasked with

**(4) Anti-enumeration (AC5) — the core security property. CLEAN, and structurally so, not
incidentally.**

Both arms of the comparison were traced to the SQL. `Nebu.Matrix.Room.DB.get_rooms_for_user/1`
(`room/db.ex:289-306`) is a single parameterised statement — `SELECT room_id FROM room_members
WHERE user_id = $1 AND left_at IS NULL` — with no existence check, no join to `users`, no profile
or session lookup, and no branch that distinguishes "no such user" from "no rows". A nonexistent
id yields `{:ok, []}`; a real user with no shared rooms yields `{:ok, [rows]}` whose intersection
with the caller's set is empty. Both reach `%{count: 0, joined: [], next_batch: nil}` and both
render as **byte-identical** `{"count":0,"joined":[]}` with status 200 — `next_batch` is omitted by
`Map.put` only when truthy (`protected.ex:1224`), so neither case can emit a `null` tell. There is
no code path in the handler that branches on target existence at all. This is the right design:
the property holds because nothing in the implementation *can* observe existence, not because a
404 was suppressed somewhere.

On timing, I measured rather than hand-waved. 400 samples per case against real PostgreSQL 16,
after a 50-query warm-up, on loopback — conditions that *overstate* the signal by removing HTTP,
TLS, the rate limiter and all network jitter:

```
nonexistent user (0 rows)          median=6596 us   p10=2433   p90=20668
existing user, 0 shared (1 row)    median=4826 us   p10=1853   p90=11356
existing user, 500 rows            median=5245 us   p10=2828   p90=11413
```

The deltas are *negative* (nonexistent measured slower than existing-with-500) — the existence
signal is below the measurement noise of a local connection, let alone a remote one. The BEAM leg
is 0 µs vs 1 µs median for an empty vs 500-element target set. Crucially, the only quantity the
work actually scales with is **row count**, not **existence**: a real user in zero rooms is
indistinguishable from a nonexistent one in both response and timing, by construction. There is
therefore no existence oracle here. The residual — a coarse, heavily-damped signal about a target's
room-count magnitude — is recorded as INFO-6 rather than inflated into a finding.

**(5) IDOR / cross-user exposure — CLEAN. This is the question the story was flagged for and it
holds on every path I could construct.**

`joined` can only ever be a subset of `shared`, and `shared` is
`MapSet.intersection(caller_rooms, target_rooms)` where `caller_rooms` is derived from
`conn.assigns[:current_user]`. That value is server-derived in both `OidcPlug` branches — the
opaque path assigns `sess.user_id` from the session row (`oidc_plug.ex:111`), the JWT path assigns
`UserId.from_claims(claims, server_name())` after verification (`:144`). Neither ever reads request
input. Every attempted deviation fails safe:

- *Forged/garbage `from`.* Decoding is the first thing `get_mutual_rooms/4` does (`:2336`); failure
  raises `invalid_argument` → `400 M_INVALID_PARAM` **before** either DB read. It cannot
  "fall back to page 0" because the `with` has no success path for the error.
- *Out-of-range offset.* Applied by `Enum.drop/2` to `shared`, which is already the intersection —
  an offset past the end yields `[]`, never a different dataset. A negative offset is rejected by
  `PageToken.decode/2`'s `offset >= 0` guard.
- *`unpaginated: true`.* Forces `offset = 0` inside the backend (`:2342`) rather than trusting the
  caller's convention — correct, since `unpaginated?` and `from_token` are independent arguments to
  a public function. It widens `limit` to `total`, never the *source list*.
- *HTTP parameter pollution.* `?user_id=@a:b&user_id=@victim:b` → Plug keeps the last value;
  `q["user_id"]` is read exactly once (`:1206`), validated once, and the validated binding is what
  reaches the backend (`:1212`, `:1218`). No TOCTOU split-brain. `?user_id[]=…` yields a list, which
  falls through `is_binary/1` to the catch-all clause (`:1245`) → 400. `?from[]=…` likewise falls to
  `decode_mutual_rooms_token(_)` → `{:error, :invalid_token}` → 400. All fail closed.
- *Race between the two reads.* `caller_rooms` and `target_rooms` are read microseconds apart. If
  the **caller** leaves a room in that window, the room can still appear — but it is a room the
  *caller themselves* was in moments earlier, not a target-only room. If the **target** leaves, the
  room is correctly excluded. Across pages, membership churn can skip or repeat an entry, but every
  page is computed from a freshly-recomputed intersection for the *actual current caller*, so no
  page can ever contain a room the caller is not in. Not a cross-user leak in either direction.

I also checked the one structural way this could have leaked without any attacker input:
`room_members` rows are written only on an actual join (`@sql_insert_member`, `room/db.ex:51-58`);
invitations live in a **separate** `room_invitations` table (`:886`, `:897`). So a room the
**caller** was merely invited to can never enter `caller_rooms` and reveal the target's membership
in a room the caller has not joined. The ATDD suite tests only the target-side invite exclusion —
the caller-side case is closed by the schema, not by a test. Checked explicitly rather than assumed.

**(6) Pagination token — CLEAN on both questions asked.**

The token carries an integer offset and nothing else: `Base.url_encode64("mr1:" <> to_string(n))`.
No user id, no room id, no timestamp, no caller binding. Cross-prefix replay with the actual
in-tree prefixes fails closed in both directions, verified by execution:

```
decode("h1:",  encode("mr1:", 7)) => {:error, :invalid_token}
decode("mr1:", encode("h1:", 7))  => {:error, :invalid_token}
```

On the "can another user's token reveal anything" question: the token is a **bare offset with no
caller or target binding**, and that is genuinely fine here, for the reason the question
anticipated — the offset is always applied to an intersection freshly recomputed for the *actual*
caller and target of the *current* request, never to whatever dataset the token "came from". A
hand-forged `mr1:9999` decodes successfully (`{:ok, 9999}`) and does exactly nothing: it indexes
past the end of the current caller's own intersection and returns `[]`. There is no cross-user
state to replay, so there is nothing a stolen token could unlock. Two cosmetic observations are
recorded as INFO-1 and INFO-2.

The `SpaceHierarchy` refactor onto the shared codec is a behaviour-preserving change — verified by
running the **old inline implementation** and the new delegation side by side over 21 inputs
(valid, negative, leading-plus, leading-zero, trailing-garbage, empty, double-prefix,
NUL-suffixed, 200-digit, padded, non-base64, and four non-binary types): **0 mismatches**. No
regression to the existing `h1:` cursor.

**(7) Auth / rate-limit / validation ordering — CLEAN, verified from the route table rather than
from the comments.**

`Nebu.Web.Router.Protected`'s pipeline is `plug OidcPlug` → `plug :fetch_query_params` →
`plug :match` → `plug :dispatch` (`protected.ex:30-33`). `RateLimit.call/2` is invoked inside the
route body (`:1163`, `:1193`), i.e. after dispatch. Effective order per request:

1. **OidcPlug** — halts with 401 on missing/expired/garbage/revoked/deactivated. Nothing in this
   diff runs before it.
2. `fetch_query_params`
3. **RateLimit** → 429 + `Retry-After`
4. **Validation** — presence → `UserId.valid?/1` → self-check (`:1237-1243`), all DB-free
5. **Token decode** (`:2336`), then and only then the two DB reads (`:2344-2345`)

AC9 ("401 before any DB access") holds. I confirmed the *routing* independently, which matters more
than the pipeline here: `router.ex` forwards a fixed list of paths to the unauthenticated
`Nebu.Matrix.HttpPublic` (`/client/v3/login`, `/refresh`, `/auth`, `/v1/auth_issuer`,
`/v1/auth_metadata`, `/unstable/org.matrix.msc2965/*`, `/v3/profile`) plus `/media` and
`/client/v1/media`, before the catch-all `forward "/_matrix", to: Nebu.Web.Router.Protected`
(`:169`). Neither `/client/v1/mutual_rooms` nor
`/client/unstable/uk.half-shot.msc2666/user/mutual_rooms` matches any earlier forward — notably
`uk.half-shot.msc2666` does not prefix-collide with `org.matrix.msc2965`, and
`/client/v1/mutual_rooms` does not collide with `/client/v1/media`. Both routes land behind
`OidcPlug`. The ATDD suite does **not** cover this for the unstable alias (INFO-3).

**(8) Pre-existing items re-checked under a security lens — no severity upgrade.**

The broad `try/rescue e -> {:error, e}` in `mutual_rooms_id_set!/1` (`:2377-2403`) does **not**
reach any client-visible surface. `map_error/1` returns the constant `"Core is temporarily
unavailable"` for `unavailable()` (`http.ex:73-74`) and discards the raised message entirely, so the
`"database unavailable: #{inspect(reason)}"` string never leaves the process. I traced every other
`map_error/1` branch for a reflection path: only `invalid_argument` and `failed_precondition` echo
the raised `message`, and the only `invalid_argument` this code raises is the constant
`"invalid pagination token"` (`:2362-2364`), with no interpolated input. The 400 produced in the
router is likewise a fixed string (`:1210`). No reflected input anywhere in the response; the sole
interpolation sink is the `Logger` line, which is Finding #1.

The `0`/negative page-size type-guard gap is confirmed test-seam-only — `grep` over
`server/config/` finds no reference to `:mutual_rooms_page_size`, so no runtime or release path can
set it. Recorded as INFO-5 for shape, not severity.

---

### INFO — recorded for future reviews, no action required now

**INFO-1 — `PageToken`'s moduledoc overclaims.** It states the cursor is wrapped in Base64 "so a
client cannot read or forge internal state meaningfully". Base64 is an encoding, not obfuscation:
`Base.url_decode64!("bXIxOjUw")` is `"mr1:50"`, and a hand-built `mr1:9999` decodes cleanly to
`{:ok, 9999}`. The *security* conclusion is unaffected — the offset is caller-agnostic and applied
to a freshly-recomputed intersection, so forging it accomplishes nothing (see the (6) analysis
above). But the sentence invites a future author to treat these tokens as a trust boundary they are
not. Reword to state the actual property: the cursor carries no sensitive state and needs no
integrity protection *because* a forged offset cannot select a different dataset.

**INFO-2 — `String.starts_with?/2` is a prefix test, not a namespace test; the moduledoc's
cross-prefix invariant is true for today's pair but not for the codec.** The moduledoc asserts
unconditionally that "a mutual_rooms token can never be replayed as a hierarchy token and vice
versa, since the prefix check fails closed", and `page_token_test.exs` pins exactly that pair. The
guarantee actually comes from `Integer.parse(rest) == {n, ""}`, not from the prefix check. Where one
prefix is a prefix of another followed by digits, the codec silently accepts with a **wrong**
offset — demonstrated:

```
PageToken.decode("a:1", PageToken.encode("a:", 15))  =>  {:ok, 5}     # silent cross-namespace accept
PageToken.decode("",    Base.url_encode64("42"))     =>  {:ok, 42}    # empty prefix accepts anything
```

`"h1:"` and `"mr1:"` are disjoint, so nothing is exploitable today, and `decode("mr", encode("mr1:", 7))`
is saved by `Integer.parse`. But the third prefix added to this module could break the stated
invariant with a fully green suite. Cheap hardening: require the prefix to end in a non-digit (or
assert the delimiter explicitly), reject an empty prefix with a guard, and make the test a property
over *all registered* prefixes rather than a hand-written pair.

**INFO-3 — No 401 regression test for the unstable alias.** The auth-gate `describe`
(`matrix_mutual_rooms_test.exs:613-639`) exercises only `/client/v1/mutual_rooms`; the alias gets a
single no-DB 400 reachability test with a valid Bearer (`:669-674`). I verified the alias's auth
gate structurally (see (7)), but a future reordering of `router.ex`'s forwards — the exact class of
mistake the MEMORY entry about catch-all `location` blocks records — would move that path onto an
unauthenticated router with the suite still green. Add the three auth cases against
`@unstable_mutual_rooms_path`; they are no-DB and cost nothing.

**INFO-4 — A cross-user membership disclosure with no audit trail.** This is the first Matrix
endpoint in Nebu whose entire purpose is to answer a question about *another* user, and it leaves
no record. MSC2666 does not ask for one and Synapse does not write one, so this is not a
conformance gap — but for a compliance-native product, "who queried whose shared rooms" is exactly
the kind of question an incident reviewer asks and cannot currently answer. Flagging the category,
not prescribing: if this is a deliberate decision it should be a recorded one, and if a future story
adds user-directory or presence-style lookups, the same question will recur for each of them.

**INFO-5 — Page-size seam has no type guard.** `max(Application.get_env(:event_dispatcher,
:mutual_rooms_page_size, 50), 1)` (`:2403`) relies on Erlang term ordering. For a non-integer value
(atom, binary, float) `max/2` returns the non-integer, which reaches `Enum.take/2` and raises
`FunctionClauseError` — **not** a `Nebu.Matrix.Error`, so `call_core/1` does not rescue it and the
request becomes a 500. Unreachable in production (no config path sets the key), so not a finding.
A `when is_integer(n) and n > 0` guard with a fallback would make the seam self-defending.

**INFO-6 — Residual room-count timing signal, recorded so it is not re-discovered as novel.** As
measured in (4), the work on this endpoint scales with row count, not with target existence, and
the signal is below loopback measurement noise. If a future change ever makes the per-row cost
materially larger (decryption, a join, a per-room authorization check), this becomes a coarse
oracle for *another user's room count* — a quantity the caller is not entitled to — and should be
re-measured at that point. Noted, not actioned.

**INFO-7 — The broad `rescue e -> {:error, e}` converts programming errors into 503s.** The clause
(`:99-103`) catches everything, not just DB failures: a misconfigured `rooms_db_module()` or a
behaviour mismatch would surface as "database unavailable" rather than crashing loudly. It is
fail-*closed*, which is the right direction, and the stated justification (an unstarted `Nebu.Repo`
raises rather than returning `{:error, _}`, and AC10's rate-limit probe drives full handler
requests) is legitimate. Worth knowing that it also masks configuration errors behind a misleading
message.

---

### Summary

CRITICAL: 0 — nothing blocks the commit
HIGH: 0 — nothing blocks the commit
MEDIUM: 2 — advisory (Finding #1 new; Finding #3 pre-existing, not introduced here)
LOW: 2 — advisory (Findings #2, #4)
INFO: 7 — recorded for the audit trail and future reviews

**Verdict:** APPROVED.

The property this endpoint exists to protect holds. The anti-enumeration guarantee (AC5) is not a
suppressed 404 — it is structural: no code on the path can observe whether the target exists, so
the response and the timing are identical for "unknown user" and "known user, nothing shared".
The IDOR surface this story was flagged for is closed by construction — `joined` is a subset of an
intersection whose caller arm is derived only from the verified token, and every hostile input I
could construct (forged cursor, out-of-range offset, the `unpaginated` flag, parameter pollution,
list-typed params, the inter-read race) fails closed or produces a subset of the caller's own
rooms. Caller-side invite leakage, the one way this could have leaked without any attacker input,
is closed by the schema rather than by a test, and I verified that rather than trusting it.

The one genuinely new finding is adjacent to all of that: the shared `user_id` validator is far
looser than anyone reading it would assume — its domain class admits 249 of 256 bytes — and
`mutual_rooms` is the first call site to forward a raw query parameter through it into both a
database query and a log sink. The resulting log injection and on-demand 503 are real and were
reproduced end to end, but they disclose nothing. The trailing-newline self-check bypass the code
reviewer flagged is confirmed, is the same root cause, and is correctly characterised as
non-leaking. The shared rate-limit bucket does couple `mutual_rooms` to `/login` across a NAT — and
is also strictly dominated by the unauthenticated `/login` drain that already exists on the same
bucket, so this story adds no capability an attacker does not already have. One regex fix at
`user_id.ex:27` closes two of the four findings everywhere they apply.
