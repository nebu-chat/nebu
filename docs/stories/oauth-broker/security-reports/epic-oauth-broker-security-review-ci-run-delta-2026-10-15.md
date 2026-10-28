# Epic oauth-broker: Kassandra delta gate over the server changes of the CI / e2e run (2026-10-15)

Scope: `git diff 493fba66..HEAD -- server/lib server/test/test_helper.exs server/mix.exs` (10 files): stories room-keys-version-post-stub (5b7f2a44), space-edit-audit (270b3ce8), media-retention-audit-atomic (34715348), storage-test-pinned-target (d8fc10c3). Read-only review; the per-story short reviews are next to this file.

**Verdict: CLEAN, APPROVED. Dormant merge PASS.** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 LOW (new, fixed in the same series), 6 INFO. The activation of `oauth_enabled` stays blocked independently (manual verification groups A-F, G3-2 positive client-IP test, written acceptance of residuals).

## Verification of the findings reported fixed
- Byte cap of the space audit metadata (`audit_slice/1`: 256 graphemes, then at most 1024 bytes of valid UTF-8): works (1 base + 100000 combining marks = 1023 bytes, valid; a 4-byte emoji across the boundary is cut cleanly).
- `released_delete_after_days`: 0 = off like nil: works (`retention_guard`: new nil / 0 = disabling; old 0 / nil / unknown -> a shortening, audit mandatory), consistent with the only reader `MediaReleasedAutoDeleteWorker.validated_window/0`.
- HTTP/2 `:authority`: `protocols: [:http1]` (hackney 4.8.5 `connect_direct/4`: ALPN offers http/1.1 only, no http3 upgrade). `@` in an endpoint refused on the save and test path before the SSRF check, user info stripped from the Host header. Retries = 1 only for the test connection (`config_overrides/1` has one caller). 302 / 303 / 307 / 308 are `{:redirect_not_followed, n}`.
- ClientIP contract test: `:inet.ntoa` of the pin client only writes the outbound target IP; the allowlist is narrow and has an "entry is real" test. (ArmScript: not part of the delta.)

## Interactions
- Space edit -> audit actor: a row exists only after `{:ok, event_id}` (member with state power), a nil / sub-only actor fails the membership check, the client PUT path writes no row (integration test with the real writer).
- `Nebu.Media.Config` transaction: `AuditWriter` repo is `Nebu.Repo` (nested = atomic), the audit closure rescues everything (the writer rescues only RuntimeError), the outer transaction rolls back with `{:audit, _}`; RLS UPDATE policy `media_config_update_mutable` (000034) lists the three keys; fixed lock order advisory lock -> row lock -> upsert -> audit; retry only on `{:error, {:audit, _}}` with the guard re-reading under the lock; cache refresh + `:pg` broadcast only after the commit; `:media_config_tx` is compile-guarded, `:media_config_writer` is set nowhere in `lib/` / `config/`.
- Pin client: chosen only through `config_overrides/1`, `pinned_target` is put after the SSRF check, fail closed, the parsed URL host must equal the parsed checked host, SNI + `verify_peer` + certifi unchanged, a proxy environment receives the IP URL (the pin holds).
- Room-keys stub: before the `match _` catch-all in the authenticated router, constant answer, no DB, body ignored; every other `room_keys/*` route stays `M_UNRECOGNIZED`.
- `test_helper.exs`: hard failure under `CI` without a reachable non-loopback IPv4 (the rebinding coverage cannot vanish silently); `mix.exs` `test_ignore_filters`: a narrow suffix.

## Findings
| # | Severity | Location | Finding | Status |
|---|---|---|---|---|
| 1 | LOW | `media/ssrf.ex` `resolve_name/1` | the resolver seam `:media_ssrf_resolver` was not compile-guarded (the sibling seam `:media_config_tx` is): a stray `put_env` would replace the DNS truth of the whole SSRF guard (storage, preview_url, webhooks); not reachable today (no setter) | FIXED: `if Mix.env() == :test` (prod compile verified) |
| 2 | INFO | `matrix.ex` `log_space_audit_failure/3` | the room id is interpolated into the log string | accepted (a validated id) |
| 3 | INFO | `media_settings_controller.ex` test connection | `inspect(reason)` in a log string is reachable with real server answers since the HEAD fix; today the body is empty (HEAD): if the test ever moves to GET / ListObjects an S3 error XML (`StringToSign`, `AWSAccessKeyId`) would land in the log: log status / kind only then | recorded |
| 4 | INFO | `persist/2` | no atomicity over several keys (documented); a refused shortening leaves earlier sorted keys committed | documented (D5) |
| 5 | INFO | `test_helper.exs`, recorder | the self-probe and recorders listen briefly on a non-loopback interface during `mix test` | no action |
| 6 | INFO | `pinned_http_client.ex` | `pool: false`: the connection lives with the request process (admin only, click gate, one attempt) | no action |
| 7 | INFO | overall | the resolver seam also affects preview_url / webhooks (tests restore it, `async: false`) | covered by #1 |

Carried over from the short reviews (accepted / follow-ups): LOW `du` (`deleted_days` / `infected_days` not read by the cleanup worker), LOW D2 (an unaudited lengthening / disabling leaves only a value-free ERROR line: alert / telemetry recommended), LOW `ds` (operational S3 calls resolve per request), INFO `dw` (SSRF block list gaps).
