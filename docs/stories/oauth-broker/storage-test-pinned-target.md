---
story_id: storage-test-pinned-target
title: "Storage test connection connects to the checked address (follow-up do, part a): no DNS-rebinding window between the SSRF check and the request"
type: bugfix
severity: low
epic: oauth-broker
status: review
security_review: required
matrix: false
ui: false
created: 2026-10-15
branch: feature/migrate-to-oauth2
---

# Story: the pinned SSRF target reaches the request (follow-up `do`, part a only)

Source: follow-ups row `do` (SEC delta gate forms-sweep X3-2, Kassandra design review). `Nebu.Media.StorageConfig.validate_candidate_endpoint/1` calls `Nebu.Media.SSRF.checked_target/2`, keeps only `:ok` and
throws the `{:ok, %{scheme, host, ip}}` away; `default_test_connection/1` then issues `ExAws.S3.head_bucket/1`, and ExAws / hackney resolve the host AGAIN: a DNS server can answer a public address to the check and a private
one to the request (DNS rebinding, time-of-check / time-of-use). Owner decision 2026-10-15: ONLY part a. Part b (the stored-secret rule of the test connection is not applied on the storage SAVE path) is NOT implemented: the owner has a separate feature in mind;
follow-ups.md: "split out: own feature (owner idea), not part of this epic".

## Decisions

- **D1.** `validate_candidate_endpoint/1` returns the checked target (`{:ok, %{scheme, host, ip}}`) instead of discarding it, `test_connection/1` carries it to the request.
- **D2 (how the request is pinned).** The request of the test connection connects to the CHECKED IP: the URL / connect address is the IP, the `Host` header (the SigV4 signature is computed over the original host) and, for https, the TLS SNI and the certificate hostname verification keep the ORIGINAL host name
  (so a certificate for the host is still required and a rebinding to a private IP cannot be reached). Implementation: a small `ExAws.Request.HttpClient` module (e.g. `Nebu.Media.PinnedHttpClient`) selected per request through the ExAws config override of `config_overrides/1` (`http_client:`) that rewrites the connect address to the pinned IP and passes
  `server_name_indication` / `Host`; or an equivalent that provably never resolves the host name again. The dev agent chooses, justified and tested; the SigV4 signing, the existing `use_ssl` / port handling and the transport-downgrade guard stay.
- **D3 (what the pinned IP is).** The first resolved address, all addresses were checked (existing `check_host`); the existing `allow_private` opt-in (`NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS`) is unchanged.
- **D4 (scope of "the save path").** `upsert/1` (save) performs no request: it validates; there is no second resolution to pin. The pinned target is carried where a request follows (the test connection). The operational S3 calls (`Nebu.Media.Storage`, `ExAws.request()` with the stored endpoint) resolve the stored host per request: a rebinding AFTER a successful save / test is a residual
  of the stored operator-trusted endpoint (admin-only, fresh sign-in, strict gate), recorded in follow-ups.md as a new item, not fixed here.
- **D5 (tests).** A rebinding simulation: a resolver seam returning a public address for the check and a private one afterwards (or a stub name server); the request must go to the FIRST (checked) address and never to the second; a request to the second would fail the test. Plus: Host header / SNI keep the original host name, a literal IP endpoint works unchanged,
  an https endpoint still needs a certificate valid for the host name, an unresolvable host / blocked address still fails as before (no request).

## Acceptance Criteria

1. `validate_candidate_endpoint/1` (or its successor) returns the checked target; no caller discards it where a request follows.
2. The test connection's HTTP request connects to the checked IP: in the rebinding simulation (1st resolution public, 2nd private) no connection is attempted to the second address.
3. The request carries the ORIGINAL `Host` header (and the SigV4 signature stays valid: a MinIO / stub accepts it); https keeps SNI and certificate hostname validation for the ORIGINAL host name (a certificate for the IP only is refused).
4. A literal-IP endpoint, `use_ssl: false` endpoints and the `allow_private` opt-in behave as before; blocked / unresolvable endpoints still fail BEFORE any request with the same error atoms.
5. The test connection still never persists, still never sends stored credentials to another endpoint (story admin-forms-gate-sweep), unchanged.
6. Docs: 07-deployment (what is pinned, the residual of the operational calls), ADR-033 SO11 / the media docs where the guard is described; follow-ups.md: `do` part a closed, part b "split out: own feature (owner idea), not part of this epic", a new item for the operational-calls residual.

## Dev notes (from the pre-dev test review)

- The pin client (`Nebu.Media.PinnedHttpClient`, an `ExAws.Request.HttpClient`) is selected through `http_client:` / `http_opts: [pinned_target: target]` of `config_overrides/1`. `http_opts` REPLACES the hackney options: the client reads `Application.get_env(:ex_aws, :hackney_opts, [recv_timeout: 30_000])` itself and merges `ssl_options` (with `server_name_indication: String.to_charlist(host)`) by `Keyword.put`, never prepends (hackney takes the first `ssl_options` entry); this is also how a test CA reaches the client.
- Fail closed: no `pinned_target` in `http_opts`, or `uri.host != pinned.host` -> error, never a normal resolution. NO redirect following (`follow_redirect` stays off, a redirect would bypass the pin), no `proxy` option, `pool: false` (no keep-alive reuse across checks). IPv6 pins need brackets in the URL; a default port (443 / 80) is absent from the URL and from the signed host: handle and test it.
- hackney 4.x answers HEAD with the 3-tuple `{:ok, status, headers}`; `ExAws.Request.Hackney` only matches the 4-tuple (the production test connection raises a `CaseClauseError` today, any server): the client maps it to `{:ok, %{status_code:, headers:, body: ""}}`; a 403 / 404 / 5xx HEAD must arrive as `{:error, {:http_error, status, _}}`, never a crash.
- The resolver seam `:media_ssrf_resolver` is a test seam (read at call time, restored by the tests); it also serves `preview_url` and webhooks (same `checked_target/2`).
- Doc wording the pins expect: ADR-033 heading `- **SO11 addendum: the pinned storage test target` before `- **SO8 `; 07-deployment section "Admin configuration forms and their protection" and the row `| Test connection (storage form)`; follow-ups: the `do` row begins with `PART A CLOSED by story storage-test-pinned-target`, part b `split out: own feature (owner idea), not part of this epic`, plus a new row about the operational S3 calls (words `storage-test-pinned-target`, `operational`, `rebinding`).

## Tasks / Subtasks

- [x] T1 (D1, AC1) `validate_candidate_endpoint/1` returns `{:ok, target}`; `test_connection/1` puts it into the candidate as `:pinned_target` (with the real transport scheme); `upsert/1` ignores it (no request).
- [x] T2 (D5) resolver seam `:media_ssrf_resolver` in `Nebu.Media.SSRF` (host names only, read at call time).
- [x] T3 (D2, AC2, AC3) `Nebu.Media.PinnedHttpClient` (`ExAws.Request.HttpClient`): connects to the pinned IP, original `Host` / SNI / certificate hostname, fail closed, no redirect, `pool: false`, IPv6 brackets, default ports, hackney 4.x HEAD 3-tuple mapping; selected by `config_overrides/1`.
- [x] T4 (AC4, AC5) unchanged behaviour: literal IP, `use_ssl: false`, `allow_private`, blocked / unresolvable endpoints, stored-credential rule (pinned by the ATDD tests).
- [x] T5 (AC6) docs: 07-deployment, ADR-033 SO11 addendum, follow-ups (`do` part a closed, part b split out, new rows `ds`, `dt`), module docs of `StorageConfig` and `SSRF`.
- [x] T6 test-review findings: `:needs_iface_ip` tag + `test_helper.exs` exclusion / hard failure under `CI`, loopback unit tests of the pin client (`storage_pinned_http_client_test.exs`), vacuity guards, FakeAuditRepo in the upsert test, bounded hackney timeouts, port pair with 3 attempts.

## Dev Agent Record

### Implementation Plan

- The pin lives in a client module, not in a second resolution-free connect path of hackney: ExAws calls `http_client.request/5` with `http_opts` of the config override, so the pin is per request and the operational `Nebu.Media.Storage` calls keep `ExAws.Request.Hackney`.
- The client owns the whole connection: `http_opts` replaces the hackney options, so it reads `config :ex_aws, :hackney_opts` itself and sets `follow_redirect: false`, `pool: false` and the SNI with `Keyword.put/3` (one `ssl_options` entry; hackney takes the first). SNI = host name as a charlist makes hackney verify the certificate against the name (`merge_ssl_opts`: verify host = SNI); an IP-literal host gets no SNI (hackney verifies against the IP as before).
- The transport (SNI or not) follows the URL scheme, not `target.scheme`: the SSRF check runs on a synthetic `http://` URL (bare `host[:port]` contract), so `test_connection/1` additionally sets the real scheme in the carried target.
- `URI.to_string/1` brackets an IPv6 host itself: the client passes the unbracketed address (a pre-bracketed one was bracketed twice, found by the unit test).
- A 3xx is returned as it is (`{:ok, %{status_code: 302, ...}}`), not followed; ExAws has no clause for a 302 and raises, which `default_test_connection/1` rescues into `{:error, _}` (the Admin UI shows the generic failure). hackney returns the 4-tuple for a redirect even on HEAD: both shapes are mapped.
- Proxy: the client adds no `proxy` option and removes none (hackney's environment proxy fallback is unchanged); a proxy still receives the IP URL, so the pin holds. Not covered by a test.

### Completion Notes

- Production defect found and fixed with the story: the real test connection raised a `CaseClauseError` against ANY server (hackney 4.x HEAD 3-tuple vs `ExAws.Request.Hackney`); documented in 07-deployment, ADR-033 and follow-ups `dt`.
- Tests: `storage_pinned_target_test.exs`, `storage_pinned_http_client_test.exs`, `storage_test_pinned_target_docs_test.exs` green with `--warnings-as-errors` (57 / 58 before the last docs fix, then green), neighbours (ssrf, storage_config, url_preview, webhook_delivery, alert_notifier, config, media settings controller / gate, docs tests that read 07-deployment / ADR-033 / follow-ups) green: 708 tests, 0 failures, 49 excluded (`:integration` / `:no_repo`).
- Mutation check: with the pin client replaced by the default hackney client 12 of the 24 end-to-end tests fail (rebinding, Host / SigV4, SNI, literal IP, first address).
- The recorder tests need a non-loopback IPv4 interface (tag `:needs_iface_ip`); `test_helper.exs` excludes them locally without one and fails hard when `CI` is set.

### File List

- server/lib/nebu/media/pinned_http_client.ex (new)
- server/lib/nebu/media/ssrf.ex
- server/lib/nebu/media/storage_config.ex
- server/test/test_helper.exs
- server/test/nebu/media/storage_pinned_target_test.exs
- server/test/nebu/web/client_ip_contract_test.exs (`pinned_http_client.ex` joins the `:inet.ntoa` allowlist, outbound)
- docs/architecture/11-risks.md
- server/test/nebu/media/storage_pinned_target_support.exs
- server/test/nebu/media/storage_pinned_http_client_test.exs (new)
- server/test/nebu/media/storage_test_pinned_target_docs_test.exs (unchanged, green)
- docs/architecture/07-deployment.md
- docs/architecture/adr/ADR-033-authorization-server-broker-model.md
- docs/stories/oauth-broker/follow-ups.md
- docs/stories/oauth-broker/storage-test-pinned-target.md

### Change Log

- 2026-10-15: implemented D1-D5 (pinned storage test target), pre-dev test review findings applied, docs AC6, status review.
- 2026-10-15: review fixes: `:inet.ntoa` allowlist (M1), self-probe in `local_ip/0` (m2), `retries` override of one attempt (m4), 3xx answers as errors through ExAws (m5), `protocols: [:http1]` (Kassandra LOW-1, tested against an ALPN h2 recorder), `@` in the endpoint refused and Host value without user info (INFO-2), proxy / NO_PROXY / first-address docs (m3, INFO-1), 11-risks row, follow-ups `dv`, `dw`.
