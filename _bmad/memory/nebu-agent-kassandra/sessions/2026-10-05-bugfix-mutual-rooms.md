## Session — bugfix-mutual-rooms (MSC2666 `GET /_matrix/client/v1/mutual_rooms` + unstable alias)

**Scope:** `git diff --staged`, 8 files / +1088-10, branch `bugfix/upcloud-s3-iam-sts-endpoints`.
Production surface: `web/router/protected.ex` (two new routes, one handler),
`matrix/event_dispatcher/server.ex:2333-2419` (`get_mutual_rooms/4`),
`matrix/page_token.ex` (new shared cursor codec), `matrix/space_hierarchy.ex` (refactor onto it),
`web/router.ex` (`unstable_features` flag). Story flagged `security_review: required` because the
endpoint's whole purpose is comparing two users' membership sets.
Report: `docs/stories/security-reports/bugfix-mutual-rooms-security-review-2026-10-05.md`

**Finding summary:** 0 CRITICAL, 0 HIGH, 2 MEDIUM, 2 LOW, 7 INFO — **APPROVED / CLEAN**.

- F-1 MEDIUM (new): `UserId.@user_id_regex` domain class `[^\s:]+` accepts 249/256 bytes incl. NUL,
  all C0 controls except `\t\n\v\f\r`, DEL, and all high-bit bytes (so U+0085 NEL and U+2028 LS
  pass). `%00` survives `fetch_query_params` → passes `valid?/1` → Postgres rejects it
  (`character_not_in_repertoire`, "invalid byte sequence for encoding UTF8: 0x00") → lands in the
  NEW `mutual_rooms_id_set!/1` failure branch → `Logger.warning("... for #{user_id}: ...")` emits
  the raw client bytes verbatim + `503 M_UNAVAILABLE` on demand, 120/min. U+2028 in the same payload
  supplies a line break WITH attacker-controlled text after it (the `\n` route cannot — `$` caps it
  at one trailing byte). Impact = log forgery + fake-DB-outage alert noise, no data exposure → MEDIUM.
- F-2 LOW: PCRE `$` matches before a final `\n` → `?user_id=@<self>%0A` passes `valid?/1`, fails the
  byte-equality self-check → `200 {count:0,joined:[]}` instead of AC8's 400. No leak (text `=` is
  byte-exact; verified against real PG). Same root cause as F-1.
- F-3 MEDIUM (PRE-EXISTING, explicitly not attributed to this diff): `RateLimit` ETS bucket keyed by
  IP alone; `tier` read in `init/1`, never used in `call/2`/`take_token/4`.
- F-4 LOW: unstable alias returns the whole intersection uncapped; BOTH routes recompute the full
  `MapSet.new` + intersection + sort per request (pagination bounds the response, not the work).

**New patterns discovered:**

1. **`[^\s:]+`-style negated classes are a false sense of validation.** Erlang `re` `\s` is ASCII
   `[ \t\n\v\f\r]` only, so a "not whitespace" class admits NUL, every other C0 control, DEL, and
   all 128 high-bit bytes. Any shared shape-validator built from a negated class should be
   re-expressed as a positive allow-list. Sibling of the project's existing default-deny-not-
   enumerated-allow rule, applied to character classes.
2. **Elixir `~r//` `$` is not end-of-string.** No `PCRE_DOLLAR_ENDONLY`, so `$` matches before a
   single trailing `\n`. Every validator that pairs a regex shape check with a separate
   byte-equality guard (self-check, domain check, allow-list compare) is bypassable by appending
   `%0A` unless anchored `\A`/`\z`. Grep for `~r/^...$/` on security-relevant validators.
3. **"Fix that wakes a latent validator gap."** Family member of the existing fix-that-wakes-dead-
   code pattern. `UserId.valid?/1` had 4 prior call sites, ALL incidentally protected — the two
   admin controllers run `String.trim/1` first (verified: trim DOES strip `\n`/U+0085/U+2028, does
   NOT strip NUL/SOH/DEL), and `admin_add_room_member` is backstopped by `local_domain?`'s exact
   `domain == server_name`. `mutual_rooms` is the FIRST call site to forward a raw, un-trimmed query
   param through it into both a DB query and a log sink. Rule: when a shared validator gains a new
   call site, re-derive what was protecting the OLD call sites — it is often not the validator.
4. **Anti-enumeration done right is structural, not a suppressed 404.** AC5 holds because nothing
   on the path CAN observe existence: `get_rooms_for_user/1` is a bare parameterised SELECT with no
   `users` join, no profile/session lookup, no existence branch. Measured timing (400 samples/case,
   real PG 16, loopback, warmed): nonexistent 6596 µs median vs existing-500-rows 5245 µs — delta
   NEGATIVE, below noise; BEAM intersection leg 0 vs 1 µs. The work scales with ROW COUNT, not with
   EXISTENCE, so a real user in 0 rooms is indistinguishable from a ghost in both body and timing.
   This is the reusable template for future "must not confirm account existence" endpoints.
5. **Prefix-parameterised token codecs: `String.starts_with?/2` is a prefix test, not a namespace
   test.** `PageToken.decode("a:1", encode("a:", 15)) == {:ok, 5}` — silent cross-namespace accept
   with a WRONG offset whenever one prefix is another prefix followed by digits; `decode("", …)`
   accepts any numeric token. Today's `h1:`/`mr1:` pair is disjoint and the moduledoc's invariant
   holds, but it holds by accident of `Integer.parse(rest) == {n, ""}`, and the test pins only that
   one pair. The THIRD prefix added to this module can break the stated invariant with a green suite.

**Verified-clean highlights (checked against code, not trusted from the 3 prior code-review cycles):**
- IDOR CLEAN: `joined ⊆ MapSet.intersection(caller_rooms, target_rooms)`; `caller_id` is
  `conn.assigns[:current_user]`, server-derived in BOTH OidcPlug branches (`sess.user_id` row /
  `UserId.from_claims(verified)`), never request input. Forged `from` → 400 BEFORE both DB reads;
  out-of-range offset → `[]`; `unpaginated:true` forces `offset=0` in the backend, not by caller
  convention; HPP (`user_id` twice / `user_id[]` / `from[]`) all fail closed through the
  `is_binary/1` guard + catch-all clauses; the inter-read race can only surface a room the CALLER
  was in moments earlier, never a target-only room.
- **Caller-side invite leak closed by SCHEMA, not by a test:** `room_members` rows are written only
  on actual join (`@sql_insert_member`); invites live in a separate `room_invitations` table. The
  ATDD suite tests only the TARGET-side invite exclusion. Worth remembering: the dangerous direction
  (caller merely invited → would reveal the target's membership in a room the caller hasn't joined)
  is untested and relies on that table split staying as it is.
- Routing: `uk.half-shot.msc2666` does NOT prefix-collide with the unauthenticated
  `org.matrix.msc2965` forwards, and `/client/v1/mutual_rooms` does not collide with
  `/client/v1/media`; both routes fall through to `forward "/_matrix", to: Protected` → OidcPlug.
- `SpaceHierarchy.decode_token/1` refactor is behaviour-preserving: old inline impl vs new
  `PageToken.decode/2` over 21 inputs + 4 non-binary types → **0 mismatches**.
- No `inspect(reason)` reaches a client surface: `map_error/1` returns the CONSTANT "Core is
  temporarily unavailable" for `unavailable()` and discards the raised message; the only
  `invalid_argument` raised here is the literal "invalid pagination token".
- Hostile offsets safe: 400-digit forged offset decodes in 19 µs; `Enum.drop/2` on a list terminates
  on the empty tail (5 µs), it does not count down the bignum.
- No new audit action → `AuditWriter.@known_actions` correctly untouched (MEMORY #49 checked).

**Rate-limit bucket conclusion (asked for explicitly — recorded so it is not re-litigated):**
Mechanically YES: simulated `take_token/4` shows ONE mutual_rooms request (burst 30) clamps a bucket
`/sync` had filled to 100 down to **29.0**, and 40 requests in 1 ms drive it to 0.0 so a co-located
`/login` is `:deny`. But net capability added = **zero**: `/login` is UNAUTHENTICATED on the same
bucket (30/min, clamp 10 — a tighter clamp than mutual_rooms'), and `/sync` is a 5× stronger
authenticated drain (600/min, burst 100). Do not inflate this to HIGH in a future review — the real
defect is the plug discarding a `tier` it advertises in its own moduledoc usage example, which is a
one-line fix that deserves its OWN change + regression test, not a rider on a bug fix.

**Accepted risks this session:** none newly accepted. (The regex gap is a FINDING with a verified
non-regressive fix, not an accepted risk — do not let it decay into one.)

**Follow-up:**
- F-1/F-2: one change at `user_id.ex:27` → `~r/\A@[a-z0-9._=\-\/+]+:[A-Za-z0-9.\-]+\z/`. Verified
  non-regressive: 7/7 realistic legitimate ids still match (incl. uppercase domains, IP-literal
  domains, full localpart punctuation set), 7/7 hostile payloads rejected, accepted-domain byte
  class 249 → 64. Port-bearing server names (`host:8448`) are rejected by the CURRENT regex too, so
  that is not a new limitation. Pin trailing-`\n`/NUL/U+0085/U+2028 rejection in `UserIdTest` or it
  regresses silently. Also switch the F-1 log line to `inspect(user_id)` as defence in depth.
- F-3: key the bucket `{ip, tier}`; separate change, own regression test.
- F-4: hard ceiling on the unstable alias's `joined`; `LIMIT` sentinel on `get_rooms_for_user/1`.
- Watch-flag: no 401 regression test exists for the unstable alias path — a future `router.ex`
  forward reordering could move it onto an unauthenticated router with the suite green.
- Watch-flag: adding a THIRD prefix to `PageToken` requires re-checking the cross-namespace
  invariant (INFO-2) — a prefix ending in a digit-adjacent delimiter breaks it silently.
- Open question logged for Phil, not actioned: this is the first Nebu endpoint whose purpose is to
  answer a question about ANOTHER user, and it writes no `audit_log` row. MSC2666/Synapse do not
  require one. If that is deliberate it should be recorded; the same question recurs for any future
  user-directory/presence lookup.
