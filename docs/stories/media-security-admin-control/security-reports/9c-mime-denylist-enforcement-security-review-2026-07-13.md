# Security Review — 9c-mime-denylist-enforcement

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Date:** 2026-07-13 · **Epic:** media-security-admin-control
**Story flag:** `security_review: required` — MIME-based upload-rejection control (defense-in-depth alongside ClamAV).

## Verdict: APPROVED — CLEAN (0 CRITICAL, 0 HIGH, 1 MEDIUM, 3 INFO)

No CRITICAL or HIGH findings — nothing blocks the commit. One MEDIUM (advisory, address before
epic end) and three INFO. The MEDIUM is a genuine defense-in-depth weakness in the matcher, not a
live exploit (the function is unwired).

## Scope

Staged diff for story 9c:

- `server/lib/nebu/media.ex` — new public `mime_denylist_rejected?/1` + private `parse_mime_denylist/1`
- `server/test/nebu/media/mime_denylist_test.exs` — new ATDD suite (10 tests)
- `server/test/nebu/media/media_upload_test.exs` — new `@blocked_upload_types` regression test
- `docs/stories/media-security-admin-control/9c-mime-denylist-enforcement.md` — Dev Agent Record
- step-results docs (scope-adaptation, oracle-context, code-review, test-review)

Corroborating (read, not in diff): `server/lib/nebu/media/config.ex` (Story 9a — the `Config.get/0`
read path + `mime_denylist` validation), `base_content_type/1`→`base_type/1` and `@blocked_upload_types`
in `media.ex`, `priv/migrations/000023_media_config.up.sql` (the 9a GRANT).

**Central fact governing this review:** the function is a **standalone, unwired unit**. No route or
handler calls it (Story 2b `upload_async/3` has not landed — independently re-verified: no
`:media_id` PUT route in `web/router/media.ex`, no `upload_async/3` in `media.ex`). Its runtime
attack surface today is therefore **zero**; the entire security question is about the *latent decision*
this function encodes and how it will behave once Story 2b wires it in.

## Findings

### MEDIUM-1 — Case-sensitive MIME matcher: a defense-in-depth control that (a) depends on an unenforced caller contract and (b) silently fails open for mixed-case admin config

`server/lib/nebu/media.ex` — `mime_denylist_rejected?/1` / `parse_mime_denylist/1`

The matcher does `String.starts_with?(content_type, prefix)` with **no normalization on either
side**. MIME types are case-insensitive by RFC 6838, so a case-sensitive matcher is semantically
wrong for the domain, and this produces two distinct silent-bypass paths:

**(a) Unenforced caller-normalization contract.** The function is correct *only if* the caller
pre-lowercases and param-strips the Content-Type (which `base_content_type/1`→`base_type/1` does:
`split(";") |> first |> trim |> downcase` — I verified this; the `@doc`'s description of it is
**accurate**, including the correct statement that Plug lowercases header *field names* but never
*values*). But this is a documented-*but-unenforced* contract on a security control. A future Story
2b call site that resolves Content-Type any other way (or forgets the `base_content_type/1` hop)
silently re-opens a case bypass: admin blocks `application/x-msdownload`, client declares
`Content-Type: Application/X-MSDownload`, upload slips through. The documentation is now honest about
this, which is good — but "we wrote a comment asking the next dev to remember" is the weakest
possible enforcement for a security decision, and the codebase gives no compile-time or test-time
signal if 2b violates it.

**(b) Mixed-case admin config — NOT covered by the documentation, unmitigated even with perfect 2b
wiring.** `Nebu.Media.Config`'s `valid_mime_denylist?/valid_mime_token?` (config.ex, 9a, untouched
here) accepts mixed-case tokens — it only rejects whitespace and requires a `/`. It does **not**
downcase. So an admin entering `Application/Zip` (or 9b's UI storing verbatim) yields a prefix that
will **never** match a correctly-normalized incoming `application/zip`, *even when 2b wires the
caller-normalization contract perfectly*. The admin believes they blocked a type; the denylist
silently does nothing. No audit entry flags the mismatch — it just doesn't work. This is a
fail-open of the operator's stated intent, and the `@doc` (which only addresses the caller contract)
does not warn about it at all. (Code-review noted this as I3 and punted it to "9b's UI" — but 9b
does not normalize either, and the matcher is the natural chokepoint.)

**Why MEDIUM, not HIGH:** the control is (1) not yet wired (zero live surface), (2) explicitly a
*secondary* control — AC3 concedes a client can bypass any header-based check by lying about
Content-Type, and ClamAV (Story 3/4) inspects the actual bytes regardless. So the malware subset is
still covered. The residual gap is the *policy* subset (e.g. blocking benign-but-unwanted
`application/zip`), which ClamAV does not backstop.

**Remediation (cheap, closes both facets at once — recommended):** make the function self-normalizing
so the security decision no longer depends on an unenforced contract *or* on admins typing lowercase:

```elixir
def mime_denylist_rejected?(content_type) when is_binary(content_type) do
  normalized = String.downcase(content_type)
  %{mime_denylist: mime_denylist} = Nebu.Media.Config.get()

  mime_denylist
  |> parse_mime_denylist()
  |> Enum.any?(&String.starts_with?(normalized, String.downcase(&1)))
end
```

This is idempotent with the existing `base_content_type/1` caller-side downcase (no harm when both
run), makes the matcher robust to a mis-wired 2b, fixes the mixed-case-admin fail-open, and aligns
with MIME case-insensitivity semantics. If the team instead keeps the case-sensitive design as a
deliberate contract, then **(i)** add an explicit MUST-VERIFY to the Story 2b wiring checklist that
the caller routes Content-Type through `base_content_type/1`, and **(ii)** record the mixed-case
admin-config fail-open as an accepted risk or push a downcasing step into config.ex/9b — do not leave
it undocumented. **This is advisory (address before epic end), not commit-blocking.**

### INFO-1 — Stale RED-phase moduledoc in `mime_denylist_test.exs`

The test moduledoc originally asserted "every test below fails to compile/run right now… that IS the
required RED state" and "Do NOT implement the function." The lower half of the moduledoc was updated
to say the function is now GREEN, but the framing is internally mixed. Not a security issue; noted
for accuracy (matches code-review M2). Cosmetic.

### INFO-2 — `mime_denylist_rejected?(nil)` raises rather than returns

The guard `when is_binary(content_type)` means a caller that passes `nil` (e.g. `base_content_type/1`
returns `nil` when the header is absent, *without* the `|| "application/octet-stream"` default) gets
a `FunctionClauseError` → 500, not a bypass. This is **fail-loud, not fail-open** — acceptable, and
arguably preferable to silently treating a missing Content-Type as "allowed." The documented call
site correctly applies the `|| "application/octet-stream"` default (matching the oracle's spec note
that Content-Type defaults to `application/octet-stream`). No change required; noted so the 2b wiring
keeps the default in place.

### INFO-3 — No content/PII in logs (AC9-family check, clean)

The function makes no `Logger` calls; `Config.get/0` logs only loader/ETS *errors* (no values). No
scanned-content or Content-Type-value leakage vector introduced. (Cross-ref MEMORY #84 crash-report
vector: this is a pure function, holds no attacker bytes in a GenServer mailbox — not applicable.)

## Verified CLEAN (angles independently checked)

- **Documentation accuracy (explicitly requested):** the `@doc` on `mime_denylist_rejected?/1`
  correctly describes `base_type/1`'s `split(";",parts: 2)|>first|>trim|>downcase` behavior and
  correctly states Plug lowercases header field *names*, not *values*. **Accurate.** The residual
  risk it leaves unenforced is captured in MEDIUM-1.
- **Empty-token "deny everything" trap:** `parse_mime_denylist/1` does `Enum.reject(&(&1 == ""))`, so
  `""` → `[]` and `"a,,b,"` drops the empty tokens. Verified this closes the
  `String.starts_with?(x, "")`-is-always-true landmine (which would otherwise silently deny *every*
  upload). Directly tested (`"application/zip,,text/html,"` → `image/png` allowed). AC4 solid.
- **No caching / per-call read (AC1/AC5):** function calls `Config.get/0` on every invocation; no
  module-level memoization. The only cache is `Config`'s own ETS/`:pg`/TTL (9a). Tested via the
  mid-test seam mutation. Correct.
- **No MIME sniffing / no magic-byte inspection (AC3):** pure prefix string match; no byte reads. As
  specified.
- **`@blocked_upload_types` independence:** `upload/1` and `@blocked_upload_types` untouched; the two
  lists are never merged. New regression test (`text/html` → 400 M_BAD_JSON, `refute_received
  {:stored,...}`) is genuine and guards against a future refactor conflating them. Good — closes a
  real prior coverage gap (test-review MAJOR).
- **No injection / no new attack surface:** no SQL, no new migration, no new route, no auth surface,
  no secret handling, no shell. Config values are admin-only and validated at the 9a write boundary;
  parsing is bounded string ops over admin-controlled data — no DoS amplification.
- **MEMORY #86 (9a GRANT prod fail-open) — RESOLVED, re-verified:** `000023_media_config.up.sql` now
  contains `GRANT SELECT, INSERT, UPDATE, DELETE ON media_config TO nebu_app;` (line 56, with the
  MigrationsGrantTest cross-reference comment). So `Config.get/0` is functional in prod and this
  story's control does **not** silently read compile-time defaults there. The consumer added here
  does not inherit or re-open that fail-open. (Note only: 9c *default* `mime_denylist = ""` means the
  control ships disabled-by-default — expected/by-design, AC4, admin opts in.)

## Memory Integration

New durable pattern worth curating (recurring class): **"Security control whose correctness depends
on an unenforced caller-side normalization contract."** Same shape as MEMORY #78 (regex `$` vs `\z`
sink-dependence) and the #28/#2 "documented-but-not-enforced" family — a defense-in-depth predicate
is only as strong as the weakest future caller that reaches it, and a case-sensitive matcher on a
case-insensitive domain (MIME per RFC 6838) is self-normalizable at near-zero cost. Rule for future
review: when a security predicate delegates normalization to its caller *by documentation*, either
(a) make the predicate self-defending, or (b) demand a test/lint that fails when a caller skips the
normalization — a `@doc` note is the weakest enforcement tier. Also record: the "mixed-case admin
config silently fails to match" fail-open is orthogonal to the caller contract and survives even
perfect wiring — must be closed at the matcher or at config normalization, not by the wiring doc.
