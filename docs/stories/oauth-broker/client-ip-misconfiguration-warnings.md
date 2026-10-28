---
story_id: client-ip-misconfiguration-warnings
title: "Client-IP misconfiguration: warn loudly where it is reliably detectable (untrusted forwarding header, collapsed device addresses, deploy-time check), correct the 'fail-safe' wording (epic SEC gate 3, G3-2)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-13
branch: feature/migrate-to-oauth2
---

## Summary

Epic SEC gate 3 (`docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-2026-10-13.md`, finding **G3-2**, MEDIUM): with the default `tls_mode = alb` topology (UpCloud `alb` / `dynamic`, Stackit `alb`) and an empty `lb_real_ip_cidrs`, the VM nginx sees only the load balancer as `$remote_addr`, overwrites `X-Forwarded-For` with it, Nebu trusts nginx (`<compose_subnet .10>/32`) and therefore resolves EVERY client to the LB address. All per-IP buckets and all per-source caps (consent 20 per source, authorize / account login requests 300, pending registrations 100, `GET /login` 300/min, `GET /oauth2/authorize` 600/h) become global: one anonymous source can lock every user out of OAuth login. The negative spoof test passes anyway. The gate-3 disposition was "docs / operator"; 07-deployment and ADR-033 already carry the gating POSITIVE test (activation step 0, group A).

Owner direction: "Check whether Nebu can fail closed or warn loudly at start/activation when the client IP is unresolvable or no trusted proxy exists in an obviously proxied deployment. Block activation only if reliably detectable. No guessing: if not reliably detectable, documentation + warning only."

This story implements exactly what the code evidence shows to be reliably detectable (see "Detectability analysis"), and nothing that would need guessing:

1. **W1 (server, per request, throttled):** a request carrying `X-Forwarded-For` whose DIRECT peer is not trusted is a fact the plug already sees (the header is dropped today without a trace). One throttled WARNING per node and 10 minutes, no address, no header value.
2. **W2 (server, periodic, data-driven):** an Oban cron job reads one aggregate over `devices` (active in the last 24 h) and WARNs when at least 10 active devices of at least 5 users were all seen from at most 2 addresses (the signature of a collapsed client address). Counts only, never an address.
3. **W3 (deploy time, deterministic):** an OpenTofu `check` block in both reference templates warns on every `plan` / `apply` when the template configuration guarantees the collapse (`alb` / `dynamic` with an empty `lb_real_ip_cidrs`; UpCloud TCP-mode `none` / `acme`).
4. **W4: no blocking of `oauth_enabled`.** Nothing in the server can reliably tell a collapsed address from a legitimate one; the POSITIVE test stays a MANUAL gate.
5. **W5 (docs):** "fail-safe" becomes "safe against spoofing, NOT safe for availability" everywhere it describes the shared bucket; the positive test and the new warnings are documented in the deploy READMEs / RUNBOOK; the consent cap 20 is added where the "small global caps" sentence is missing it.

`oauth_enabled` stays OFF. No migration, no new index, no new environment variable, no `server_config` key, no UI, no Matrix API change.

### Detectability analysis (evidence; this is the basis of D1-D4)

| Candidate signal | Reliable? | Evidence |
|---|---|---|
| G3-2 itself (alb, empty `lb_real_ip_cidrs`) seen from INSIDE Nebu per request | **No** | `Nebu.Web.Plugs.ClientIP.call/2`: the peer is nginx `.10` (trusted), `X-Forwarded-For` holds exactly one element written by nginx (`proxy_set_header X-Forwarded-For $remote_addr`, `deploy/tofu/examples/upcloud/cloud-init.tftpl` ~l.244-285), `resolve/3` returns `{:forwarded, <LB address>}`. That is byte-for-byte the same shape as a correct deployment with a real client; the LB address is a private address in `network_cidr`, indistinguishable from a legitimate intranet client (private client addresses are normal in intranet deployments). Nebu cannot see the LB topology. **W1 does NOT fire in this case** (the peer is trusted). |
| G3-2 at deploy time | **Yes** | The template variables decide it deterministically: `local.lb_https_frontend_mode` / `tls_mode` and `var.lb_real_ip_cidrs` (UpCloud `server.tf` l.18-28, Stackit `server.tf`). An HTTP-mode LB terminates the TCP connection, so nginx's `$remote_addr` is always the LB unless `lb_real_ip_cidrs` makes nginx's realip module resolve the client. UpCloud TCP-mode frontends (`none`, `acme`) lose the client address without PROXY protocol (07-deployment "TCP-mode load balancers ... the client address is lost", follow-up ap3). Stackit NLB (`acme` / `none`) source preservation is UNVERIFIED (ap7): no check there (no guessing). |
| `X-Forwarded-For` from an UNTRUSTED direct peer | **Yes (as a fact; its cause is ambiguous)** | The plug evaluates `ClientIP.trusted?(peer)` already; the header is present in `conn.req_headers`. It proves that SOMETHING in front of Nebu writes the header: a proxy that is not listed (empty `NEBU_TRUSTED_PROXY_CIDRS` behind a proxy, Helm without the value (bu), a pinned address that does not match the real peer (ap7: the `acme` gateway `.1`, the `alb` `.10`), a changed compose subnet) or a client / client-side forward proxy that sets the header itself. Hence a WARNING, never a block. |
| `Forwarded` / `X-Real-IP` (from any peer) | Detectable, **excluded** | The static contract test `server/test/nebu/web/client_ip_contract_test.exs` ("the string literals `"forwarded"` and `"x-real-ip"` occur nowhere", TP6) forbids touching them in `server/lib`. Amending a security contract for a secondary signal is not worth it here (follow-up). |
| Trusted peer WITHOUT `X-Forwarded-For` | **No** | `acme`: any host-local process that calls `127.0.0.1:8008` (health probes, operator `curl`) arrives from the compose gateway `.1`, which is trusted; such requests legitimately carry no header. |
| All recently active devices share one or two addresses | **Heuristic but strong; warning only** | `devices.last_seen_ip` holds `ClientIP.get/1` (login `http_public.ex` ~l.629, every authenticated request `router/protected.ex` `touch_device_last_seen/1` ~l.2367, throttled 60 s, `DeviceKeyStore.touch_last_seen/3`). A collapse makes every active device show the LB address(es). A real deployment whose users ALL sit behind one NAT for 24 h shows the same (residual, documented; the text tells the operator to run the positive test). |
| "No trusted proxy configured" (`trusted() == []`) | **No** | Legitimate for `tls_mode = none` (Stackit NLB, direct exposure) and for deployments without a proxy. |
| Block activation | **No reliable predicate** | Activation is SQL-only (`INSERT INTO server_config ... 'oauth_enabled'`, 07-deployment "Activation steps" step 1; no admin writer for `oauth_*` keys); the server only reads the key through `Nebu.OAuth.Config` (cache). There is no activation code path that could refuse, and none of the reliable signals above proves the collapse inside the server. |

## Story

As an **operator deploying Nebu behind a load balancer or reverse proxy**,
I want Nebu and the deploy templates to tell me loudly when every client is (or very likely is) collapsed into one client address,
so that I do not enable OAuth (or run `/login`) in a state where one anonymous source can lock every user out, while Nebu never blocks or guesses on signals it cannot prove.

## Decisions

- **D1 W1: throttled WARNING for a forwarding header from an untrusted peer.**
  - Where: `Nebu.Web.Plugs.ClientIP.call/2`, tuple-peer clause only. When the direct peer is NOT trusted (this includes `trusted() == []`) AND `List.keymember?(conn.req_headers, "x-forwarded-for", 0)` is true, call `Nebu.Web.ClientIP.note_untrusted_forwarding/0` (`@doc false`). The resolution result, `conn.private` values and the header handling are UNCHANGED (the header is still ignored). The trusted path is unchanged (no extra work). The non-tuple peer clause is unchanged.
  - Hot path: only `List.keymember?/3` on the untrusted path (no `get_req_header/2`, no string building, no allocation); the throttle check is `:persistent_term.get/2` + `:atomics.get/2`; only the winner of the throttle builds the log line.
  - Throttle: a dedicated node-local `:atomics` slot (NOT `Nebu.Web.Plugs.RateLimit.take/3`: `take/3` returns `:ok` unconditionally when `NEBU_RATE_LIMIT_DISABLED` is set, which would log per request in integration / e2e environments). `configure/1` creates a fresh `:atomics.new(1, signed: true)`, initialises it to `now_s - 600` (so the first occurrence logs immediately; `System.monotonic_time/1` may be negative, never use 0 as a sentinel) and stores the ref in `:persistent_term` under a NEW key (e.g. `{Nebu.Web.ClientIP, :xff_warn}`) next to the trusted set (boot and test only, like the existing key). `note_untrusted_forwarding/0`: `last = :atomics.get(ref, 1)`; if `now - last >= 600` and `:atomics.compare_exchange(ref, 1, last, now) == :ok` then log; otherwise nothing. Exactly one line per node per 600 s, also under concurrency. No ref in `:persistent_term` (plug used without `configure/1`) = no log, no crash.
  - Clock seam: `now_s/0` = `System.monotonic_time(:second)`; in `Mix.env() == :test` builds ONLY, a zero-arity function in `Application.get_env(:nebu_http, :client_ip_warn_clock_fn)` overrides it (compile-guarded like `Nebu.OAuth.Config.seam/2`, l.129).
  - Text (static, one line, WARNING; no peer address, no header value, no header length, no request path, no user):
    `client IP: a request carried X-Forwarded-For but its direct peer is not in NEBU_TRUSTED_PROXY_CIDRS, so the header was ignored. If Nebu runs behind a proxy or load balancer, every client behind it shares ONE rate-limit bucket and per-source cap (one source can lock all users out of login): list the proxy in NEBU_TRUSTED_PROXY_CIDRS (07-deployment, "Client IP behind a reverse proxy"). A client can also send this header itself. Logged at most once per 10 minutes per node.`
  - Cluster safety: node-local, informational only, decides nothing (ADR-020 / TP11 hold).
- **D2 W2: periodic collapse check over `devices`.**
  - New Oban worker `Nebu.Workers.ClientIPCheckWorker` (`use Oban.Worker, queue: :oauth_cleanup, max_attempts: 1`; existing queue, limit 1; no new queue). Cron entry in `server/config/config.exs` `Oban.Plugins.Cron` crontab: `{"37 */6 * * *", Nebu.Workers.ClientIPCheckWorker}` (every 6 hours, at minute 37 to avoid the :00 / :05 / :10 / :23 jobs). Cron enqueues on the Oban leader only, so one evaluation per cluster per run; a concurrent duplicate run would only log a duplicate line (harmless read).
  - Cadence rationale: the signal needs 24 h of traffic anyway, and in the documented residual (a real single-NAT deployment) an hourly WARNING would be 24 lines a day that cannot be silenced (no config key, follow-up). 4 lines a day is loud enough.
  - Data: new facade function `Nebu.Matrix.device_address_spread(since_ms)` (ADR-020: `devices` is Matrix domain; the worker never touches `Nebu.Matrix.DeviceKeyStore` directly) delegating to `Nebu.Matrix.DeviceKeyStore.address_spread/1`, inline SQL (ADR-018):

    ```sql
    SELECT count(*), count(DISTINCT user_id), count(DISTINCT last_seen_ip)
      FROM devices
     WHERE last_seen_ts >= $1 AND last_seen_ip IS NOT NULL AND last_seen_ip <> ''
    ```

    run in a short transaction whose first statement is `SET LOCAL statement_timeout = '5s'`. Returns `{:ok, %{devices: n, users: u, addresses: a}}` or `{:error, reason}`; never raises. The statement never SELECTs an address, so no address can reach the worker or the log.
  - No index, no migration: `devices` has only its PK `(user_id, device_id)` and `idx_devices_user` (migration 000010); an index on `last_seen_ts` would be written by every throttled `touch_last_seen` (loses HOT updates on the hottest `devices` write) to save one sequential scan every 6 hours. A sequential scan of `devices` (one row per device) is cheap at Nebu's scale; the statement timeout bounds the worst case. Read-only, no locks beyond MVCC snapshot reads (never waits on the revoke's row locks, G3-1).
  - Decision function (pure, public `@doc false` for tests): `Nebu.Workers.ClientIPCheckWorker.assess(%{devices: n, users: u, addresses: a})` returns `:collapsed` iff `n >= 10 and u >= 5 and a in 1..2`, else `:ok`. Constants as module attributes (`@min_devices 10`, `@min_users 5`, `@max_addresses 2`, `@window_ms 24 * 3_600_000`). `a <= 2` (not `== 1`): an LB with two nodes gives two addresses (UpCloud output `lb_private_addresses` is a list). `u >= 5`: three users on one or two addresses are far more often a real small office than a collapse; small deployments with a collapse are not detected (residual, the positive test stays the gate).
  - Log on `:collapsed` (one WARNING, static text plus the three counts and the OAuth state; never an address):
    `client IP: all <n> devices of <u> users active in the last 24 h were seen from at most <a> client address(es). Behind a load balancer or proxy that does not pass the client address on (for example tls_mode alb / dynamic with an empty lb_real_ip_cidrs) every client shares ONE rate-limit bucket and per-source cap, so one source can lock all users out of login. Run the POSITIVE client-IP test (07-deployment, "Client IP behind a reverse proxy"); if all your users really share one network address (single NAT), this is expected. oauth_offered=<true|false>`
    `oauth_offered` = `Nebu.OAuth.oauth_aware?()` (public API, fail closed, never raises).
  - `:ok` logs nothing. `{:error, reason}` logs ONE WARNING `client IP: device address check failed: <postgres SQLSTATE | struct name>` (same `log_reason/1` shape as `OAuthFlowPurgeWorker`) and `perform/1` returns `{:error, reason}` (no retry: `max_attempts: 1`, the next cron run is the retry).
  - Clock seam for the worker test (compile-guarded, `Mix.env() == :test` only): `:client_ip_check_now_ms_fn` (zero-arity) overrides `System.system_time(:millisecond)` when computing `since_ms = now - @window_ms`. `last_seen_ts` is BIGINT epoch-millis written by `DeviceKeyStore.now_ms/0` (verified: `DeviceKeyStore.now_ms/0` is `System.system_time(:millisecond)`, l.458; use the same clock).
  - Personal data (ap5): with `NEBU_TRUSTED_PROXY_CIDRS` set, `last_seen_ip` is a real client address. The shared address is NOT logged (not even when it is "only" the LB address: the worker cannot know that). Counts are not personal data.
- **D3 W3: deploy-time check in the reference templates (OpenTofu `check` block, warning, never an error).**
  - New file `deploy/tofu/examples/upcloud/client_ip_check.tf`:
    - assert 1 (HTTP-mode LB without realip): `condition = !(contains(["alb", "dynamic"], var.tls_mode) && length(var.lb_real_ip_cidrs) == 0)`; message: tls_mode `<mode>` with an empty `lb_real_ip_cidrs`: nginx sees only the load balancer, every client shares ONE rate-limit bucket and per-source cap (safe against spoofing, NOT safe for availability). Do NOT enable `oauth_enabled` until `lb_real_ip_cidrs` is set (after the negative test) AND the positive test passed (README "Reverse-proxy routes, client-IP trust and access logs").
    - assert 2 (TCP-mode frontend): `condition = contains(["alb", "dynamic"], var.tls_mode)`; message: tls_mode `<mode>` uses a TCP-mode UpCloud load balancer frontend; without PROXY protocol (not supported, follow-up ap3) the client address is lost and every client shares ONE bucket. Do NOT enable `oauth_enabled` in this topology.
  - New file `deploy/tofu/examples/stackit/client_ip_check.tf`: assert 1 only (`var.tls_mode == "alb"` with an empty `lb_real_ip_cidrs`). NO assert for Stackit `acme` / `none` (NLB source-address preservation unverified, ap7: no guessing).
  - A `check` block only produces a warning on `plan` / `apply` (it never blocks a deploy: the shared bucket is the default and today's behaviour; OAuth is off by default). A non-empty `lb_real_ip_cidrs` silences it, which does NOT prove correctness (the message of assert 1 and the README say so; the positive test stays the gate).
  - Must pass `tofu fmt -check -recursive deploy/tofu/` and `tofu validate` in both examples (CI job `validate-iac`, `make test-iac-validate`, image `ghcr.io/opentofu/opentofu:1.9`; `check` blocks are supported since OpenTofu 1.6). The `check` block must not reference a resource attribute (only variables / locals), so it is evaluated at plan time and needs no provider data.
- **D4 W4: no blocking, no new switch.** `oauth_enabled` activation is not gated in code. Rationale (recorded in ADR-033 and 07-deployment): (a) the only state that proves G3-2 is the template topology, which Nebu cannot see; (b) the LB address is a private address and indistinguishable from a legitimate intranet client; (c) W1 and W2 are either ambiguous (client-written header) or statistical (single NAT); (d) activation is an SQL write with no server code path that could refuse it. The POSITIVE client-IP test stays a MANUAL, GATING precondition (activation step 0, group A). The warnings are aids, and their ABSENCE proves nothing (a small deployment, a collapse to three or more LB addresses, or a correct-looking list with a forward-only LB all stay silent).
- **D5 W5: documentation (all text in English; same wording in every file).**
  - "fail-safe" describing the shared bucket becomes "safe against spoofing, NOT safe for availability" (plus "do not enable `oauth_enabled` in this state" where the file addresses the operator). Files: `deploy/tofu/examples/{upcloud,stackit}/README.md`, `deploy/tofu/examples/stackit/RUNBOOK.md` (UpCloud has no RUNBOOK), `deploy/tofu/examples/{upcloud,stackit}/terraform.tfvars.example`, `deploy/tofu/examples/{upcloud,stackit}/variables.tf` (`lb_real_ip_cidrs` description), `deploy/tofu/examples/{upcloud,stackit}/cloud-init.tftpl` (nginx comment block, ~l.247 / ~l.204), follow-ups row ap6 (append "(safe against spoofing, NOT for availability; see G3-2)" rather than rewriting history). Leave `docs/architecture/07-deployment.md` l.314 (already "fail-safe for spoofing, NOT for availability") and the unrelated "fail safe" uses (`oauth_idp_revalidation`, 06-runtime, 08-concepts, 05-building-blocks) untouched.
  - The READMEs (both) and the Stackit RUNBOOK gain, right after the existing "**Negative test (required before `oauth_enabled`).**" block, a "**Positive test (required before `oauth_enabled`, GATING).**" block: two clients on different networks through the real public path (LB + proxy, not a direct port) must show DISTINCT real `last_seen_ip` values (admin users page or `GET /_matrix/client/v3/devices`), never the LB / proxy address; hammer `POST /_matrix/client/v3/login` from one, the other still gets answers. With an empty `lb_real_ip_cidrs` on `alb` / `dynamic` (or UpCloud `none` / `acme`) it fails by design: do NOT enable OAuth. Mention the `tofu plan` warning (D3) and the two server log lines (D1, D2).
  - `docs/architecture/07-deployment.md`: (1) in "Client IP behind a reverse proxy", a new bullet "Misconfiguration warnings (story client-ip-misconfiguration-warnings)" documenting the three warnings (exact log prefixes `client IP: a request carried X-Forwarded-For` and `client IP: all ... devices`, the `tofu plan` check names), what each proves and does not prove, and how to react (W1: list the real proxy peer, check `docker network inspect` / the pinned addresses (ap7), or ignore if clients send the header themselves on a direct deployment; W2: run the positive test; set `lb_real_ip_cidrs` after the negative test; a single-NAT deployment can ignore it); (2) activation step 0: append "The `tofu plan` client-IP check (reference templates) must be clean and the server log must not show the two `client IP:` warnings of the last 24 h; their absence does NOT replace the positive test." (3) group A: add one bullet "No `client IP:` warning in the server log and no client-IP `check` warning in `tofu plan`." (4) the step-2 "small global caps" sentence already names 20: unchanged. (5) the Stackit / UpCloud cloud-init paragraphs (~l.1287) unchanged.
  - ADR-033 section "Trusted-proxy client IP": amend **TP13** ("The plug logs nothing per request EXCEPT one throttled WARNING per node and 10 minutes when an untrusted peer sends `X-Forwarded-For` (story client-ip-misconfiguration-warnings); no line ever carries an address or a header value") and **TP14** (keep the existing sentences; add: "Nebu warns where a misconfiguration is reliably visible (W1 header from an untrusted peer, W2 collapsed device addresses, W3 template check) but cannot detect a wrong list in general; activation is never blocked in code"). Add **AH12** the consent cap: "(consent 20 per source, 300 in-flight logins, 100 pending registrations)". Do not write the sentence `Nebu cannot detect a wrong list. Trusting` (pinned as refuted by `adr_033_test.exs`).
  - `docs/stories/oauth-broker/follow-ups.md`: row `as` gets the consent cap in its "small global caps" sentence ("(consent 20, authorize / account login 300, pending 100)"); new rows (D7); the section header "From story client-ip-misconfiguration-warnings (2026-10-13)" at the end; the status table row "gate G3-2" (l.25) gets "server warnings + template check added (story client-ip-misconfiguration-warnings); the positive test stays MANUAL and gating". Historical story files (`oauth-dcr-abuse-hardening.md`, `oauth-trusted-proxy-client-ip.md`) are NOT edited.
- **D6 Existing pinned tests: amend, never delete.** `server/test/nebu/web/client_ip_test.exs` test "TP13: the plug logs NOTHING per request" sends an untrusted peer `{198, 51, 100, 9}` with `X-Forwarded-For: 203.0.113.7` while trusting `10.0.0.0/8`; with D1 it produces exactly one W1 line. Rename it to "TP13: the plug logs no address and at most the throttled untrusted-forwarding warning" and assert: the trusted-peer calls log nothing, the untrusted call logs exactly one W1 line, no line contains `203.0.113.7`, `198.51.100.9` or `10.0.0.5`. The contract test `client_ip_contract_test.exs` stays unchanged and green (the W1 code lives in the two allowed files; no `"forwarded"` / `"x-real-ip"` literal is introduced).
- **D7 Follow-ups to append** (ids per D12: `cf`-`ci`, further ones from `cq`; `co` / `cp` are reserved; grep the file before appending):
  - (cf) Admin dashboard notice for the W2 result (`Nebu.Admin.DashboardLive` has no warning-notice pattern today, only stat cards; adding one is a UI story with e2e). non-gating.
  - (cg) Detect a trusted proxy that sends only `Forwarded` / `X-Real-IP` (ignored by TP6) and warn; needs an amendment of the TP6 static contract. non-gating.
  - (ch) W2 cannot be acknowledged / silenced by a single-NAT deployment (would need a `server_config` key, which needs a `config_update_mutable` migration, cf. `as`). non-gating.
  - (ci) Stackit `acme` / `none` template check once NLB source-address preservation is verified (ap7). non-gating.

- **D8 (orchestrator, 2026-10-13) W2 thresholds and cadence accepted:** 10 devices / 5 users / at most 2 addresses, every 6 hours (`37 */6 * * *`). The residual is documented: a collapse with fewer than 5 users goes undetected, and a real single-NAT deployment gets up to 4 WARNINGs a day that cannot be silenced (follow-up ch).
- **D9 (orchestrator) W3 on every default UpCloud plan accepted:** the default `tls_mode = "none"` is a TCP-mode frontend that loses the client address, so the warning is correct and stays.
- **D10 (orchestrator) Queue:** keep the existing `oauth_cleanup` queue (limit 1) for `Nebu.Workers.ClientIPCheckWorker`; no new queue. The queue name does not fit a read-only check (see Dev Notes).
- **D11 (orchestrator) Log level:** WARNING in all cases (never ERROR), also when OAuth is offered. `oauth_offered` goes into the Logger metadata (`Logger.warning(msg, oauth_offered: bool)`) AND stays in the message text as `oauth_offered=<true|false>` (AC11 asserts the text; the default console format does not print metadata).
- **D12 (orchestrator) Follow-up ids:** `ca`-`ce` are taken and `co`, `cp` are reserved by story legacy-sso-redirect-confirmation. The new ids are `cf`, `cg`, `ch`, `ci` (D7); any further ids continue at `cq`. The dev greps `follow-ups.md` before appending.

## Acceptance Criteria

### W1: untrusted forwarding header (unit, `server/test/nebu/web/client_ip_test.exs`, `async: false`, `ExUnit.CaptureLog` at `:warning`)

1. With `ClientIP.configure(nil)` (no trusted proxy), `Nebu.Web.Plugs.ClientIP.call/2` for peer `{198, 51, 100, 9}` and `x-forwarded-for: 203.0.113.7` logs exactly ONE WARNING that starts with `client IP: a request carried X-Forwarded-For` and contains `NEBU_TRUSTED_PROXY_CIDRS`, `ONE rate-limit bucket` and `07-deployment`; the log contains neither `198.51.100.9` nor `203.0.113.7`. The conn's `:nebu_client_ip` is `"198.51.100.9"`, `:nebu_client_ip_source` is `:peer`, `:nebu_client_bucket` is `"198.51.100.9"` (resolution unchanged).
2. The same with `configure("10.0.0.0/8")` and an untrusted peer `{198, 51, 100, 9}`: one line. A TRUSTED peer `{10, 0, 0, 5}` with the header logs nothing (any header value: valid, garbage, empty, oversized). A peer without the header logs nothing (trusted or not). An IPv6 untrusted peer (`{0x2001, 0xdb8, 0, 0, 0, 0, 0, 1}`) and an IPv4-mapped untrusted peer behave like the IPv4 case (one line, no address of any form in the log).
3. Throttle (fake clock `:client_ip_warn_clock_fn`): 100 untrusted requests with the header at the same instant log exactly ONE line; at `+599 s` another request logs nothing; at `+600 s` exactly one more line. Parallel: 50 tasks calling the plug concurrently after the interval elapsed produce exactly ONE line (`compare_exchange`).
4. The throttle is independent of `NEBU_RATE_LIMIT_DISABLED` / `:nebu_http, :rate_limit_disabled`: with the latter set to `true`, 10 requests still log exactly one line (restore in `on_exit`).
5. `configure/1` resets the throttle (a fresh `configure` makes the next occurrence log immediately). Without any throttle ref in `:persistent_term` (erase the key in the test, restore after), the plug neither logs nor raises.
6. A request carrying ONLY `forwarded: for=203.0.113.7` or ONLY `x-real-ip: 203.0.113.7` from an untrusted peer logs nothing (TP6 unchanged; test files are not scanned by the contract test, so plain header literals are fine in `server/test`).
7. The amended TP13 test of D6 passes; `client_ip_contract_test.exs` is unchanged and green; all existing `client_ip_test.exs` / `client_ip_integration_test.exs` / `oauth_abuse_caps_test.exs` / `source_key_test.exs` / `oauth_discovery_rate_limit_test.exs` tests stay green unchanged except the D6 amendment.
8. Static (in the same test file or a new static test): the plug's untrusted path uses `List.keymember?` (no `get_req_header` call on the untrusted branch), and the W1 log call sits in `server/lib/nebu/web/client_ip.ex` (not in a third file).

### W2: collapsed device addresses (`server/test/nebu/workers/client_ip_check_worker_test.exs`; DB parts `@tag :integration`)

9. `assess/1` table test: `%{devices: 10, users: 5, addresses: 1}` and `addresses: 2` -> `:collapsed`; `devices: 9` -> `:ok`; `users: 4` -> `:ok`; `addresses: 3` -> `:ok`; `addresses: 0` (no data) -> `:ok`; `devices: 1000, users: 300, addresses: 2` -> `:collapsed`.
10. `Nebu.Matrix.device_address_spread/1` against the real DB with fixtures placed in the FUTURE so the shared test database's other rows can never match (no sandbox in this suite): insert devices for 5 fresh users (unique prefix) with `last_seen_ts = T - 3_600_000` where `T = now + 10 years in ms`, call with `since_ms = T - 86_400_000`; assert the exact counts (devices, users, addresses), that rows with `last_seen_ip` NULL or `''` and rows older than `since_ms` are not counted, and that the returned map has exactly the keys `:devices`, `:users`, `:addresses` (no address value). Clean up the fixture rows in `on_exit` (by user prefix).
11. Worker end to end with the clock seam `:client_ip_check_now_ms_fn = fn -> T end`: (a) 10 devices of 5 users all on `"10.0.0.4"` -> `perform/1` returns `:ok` and logs exactly one WARNING starting with `client IP: all 10 devices of 5 users`, containing `at most 1 client address(es)`, `POSITIVE client-IP test`, `single NAT` and `oauth_offered=false`; the log does NOT contain `10.0.0.4`; (b) the same fixtures spread over 3 addresses -> no log line; (c) 2 addresses (two LB nodes `10.0.0.4`, `10.0.0.5`) -> one line with `at most 2`, neither address in the log.
12. Error path: with the compile-guarded worker seam `:client_ip_check_spread_fn` (a one-arity function receiving `since_ms`; returns `{:error, %Postgrex.Error{postgres: %{code: :query_canceled}}}`), `perform/1` returns `{:error, _}`, logs exactly one WARNING starting with `client IP: device address check failed:` that carries only the SQLSTATE / struct name, and never raises. (`DeviceKeyStore` hard-codes `Nebu.Repo`, there is no repo seam to reuse; `safe_query/2` already maps a stopped repo to `{:error, :repo_not_started}`, which must also be handled.)
13. Static wiring: the `Oban.Plugins.Cron` crontab contains `{"37 */6 * * *", Nebu.Workers.ClientIPCheckWorker}`; `__opts__/0` has queue `oauth_cleanup` and `max_attempts: 1`; `Nebu.Workers.ClientIPCheckWorker` does not reference `DeviceKeyStore` (calls `Nebu.Matrix.device_address_spread/1` only, ADR-020); `DeviceKeyStore.address_spread/1` SQL does not select `last_seen_ip` as an output column (static check: the SELECT list contains `count(DISTINCT last_seen_ip)` and no bare `last_seen_ip`) and runs under `SET LOCAL statement_timeout`.
14. No migration file is added (`ls server/priv/migrations` unchanged), no new env variable is read (`System.get_env` / `Application.get_env(:nebu_http, ...)` additions are only the three compile-guarded test seams `:client_ip_warn_clock_fn`, `:client_ip_check_now_ms_fn`, `:client_ip_check_spread_fn`, each read only under `Mix.env() == :test`), no `server_config` key.

### W3: templates (`deploy/tofu/examples/{upcloud,stackit}`)

15. `client_ip_check.tf` exists in both examples with the asserts of D3; `tofu fmt -check -recursive deploy/tofu/` and `tofu init -backend=false && tofu validate` pass in both (`make test-iac-validate` or the CI job `validate-iac`). Record the command output in the Dev Agent Record. If the toolchain cannot run in the isolated environment, state that explicitly and run at least `tofu fmt -check` via the `ghcr.io/opentofu/opentofu:1.9` image (`docker run --rm`, no compose).
16. A static ExUnit test (new `server/test/nebu/client_ip_misconfiguration_docs_test.exs`, no DB) asserts: both `client_ip_check.tf` files contain a `check "` block referencing `lb_real_ip_cidrs` and `oauth_enabled`; the UpCloud file additionally covers the TCP-mode frontend (`"alb", "dynamic"` and `ap3`); the Stackit file has no assert for `acme` / `none`.

### W5: docs (same static test file as AC16)

17. No occurrence of `fail-safe` that describes the shared bucket remains in `deploy/tofu/examples/{upcloud,stackit}/{README.md,terraform.tfvars.example,variables.tf,cloud-init.tftpl}` and `deploy/tofu/examples/stackit/RUNBOOK.md` (assert: no line matches `/shared bucket, fail-safe|bucket \(fail-safe|one shared bucket,\s*$|fail-safe\)/` and every file that mentions `lb_real_ip_cidrs` with "empty" also contains `NOT safe for availability`).
18. Both READMEs and the Stackit RUNBOOK contain a `Positive test (required before \`oauth_enabled\`` block with `DISTINCT` and `last_seen_ip`, mention the `tofu plan` check and the server line prefix `client IP:`.
19. `docs/architecture/07-deployment.md` "Client IP behind a reverse proxy" contains both log prefixes, the words "does NOT replace the positive test" (or "absence ... proves nothing"), and activation step 0 references the `client IP:` warnings; the existing `adr_033_test.exs` pins (`p1_deploy_subsection`, AC9.1, Kassandra #1/#3) stay green.
20. ADR-033 TP13 / TP14 / AH12 amended per D5 (AH12 contains `consent 20`); `adr_033_test.exs` stays green (`refute section =~ ~r/Nebu cannot detect a wrong list\. Trusting/` included).
21. `follow-ups.md`: rows cf-ci exist (D12); row `as` names the consent cap 20; the G3-2 status row names this story; `adr_033_test.exs` / `oauth_client_revocation_docs_test.exs` / `oauth_revoke_lock_bounds_static_test.exs` follow-up pins stay green.

### Regression and logging law

22. Full OAuth / client-IP / worker suites green in the isolated env (`quick.sh "mix test --include integration test/nebu/web test/nebu/oauth test/nebu/workers test/nebu/client_ip_misconfiguration_docs_test.exs"`), plus `test/nebu/deploy_config_test.exs` and `test/nebu/admin/admin_bootstrap_live_test.exs` (they pin `deploy/tofu/examples/stackit/cloud-init.tftpl`).
23. No log line introduced by this story contains an IP address, a header value, a user id, a device id, a token or chat content (Kassandra checks both laws; the W2 line carries only three integers and a boolean).

## Acceptance Tests / test notes

- **ATDD first** (pipeline ATDD role): AC1-AC8 extend `server/test/nebu/web/client_ip_test.exs` (it is already `async: false` and restores the Logger level / env; reuse its `req/2` helper and `proxy_lines/1` filter; the W1 text matches `proxy|trusted|forwarded`, so `proxy_lines` already picks it up). Reset the clock seam and `configure(nil)` in `on_exit`.
- AC9-AC13 new file `server/test/nebu/workers/client_ip_check_worker_test.exs`: `assess/1` cases run without DB; DB cases `@tag :integration`. Oban is NOT started in the test env (`config.exs` comment, `repo_children/0`): call `Nebu.Workers.ClientIPCheckWorker.perform(%Oban.Job{args: %{}})` directly (pattern: `oauth_code_store_test.exs` "AC11 — purge worker wiring (static)"). Insert `devices` rows with explicit SQL (`INSERT INTO devices (user_id, device_id, last_seen_ts, last_seen_ip, created_at, updated_at)`), future timestamps per AC10, unique `@<prefix>-<n>:test` user ids.
- `Logger` level in the test env is `:warning` (`server/config/test.exs`): the W1 / W2 lines are WARNING, `capture_log` at default level sees them.
- AC15 needs the OpenTofu image; it is not a docker compose run and is allowed by the brief. Do not run `make redeploy` / `make test-integration*`.
- No Gherkin / e2e: `ui: false`, `matrix: false`; the e2e stack's nginx (`docker/nginx-element-e2e.conf`) may now produce one W1 line per 10 minutes in the server log if it forwards `X-Forwarded-For` to an untrusted Nebu; no e2e test asserts an empty server log (verify with `grep -rn "client IP" e2e/` = nothing).

## Manual verification (operator, appended to 07-deployment group A by D5)

1. `tofu plan` on UpCloud `dynamic` without `lb_real_ip_cidrs` prints the client-IP check warning; with `lb_real_ip_cidrs = ["<lb>/32"]` it does not.
2. On a deployed `alb` VM without `lb_real_ip_cidrs`, after a day with at least 5 users, the server log shows the W2 line; after setting `lb_real_ip_cidrs` (and passing the negative test) it disappears within one run after the active devices have been seen again.
3. A deployment that runs behind a proxy with an empty `NEBU_TRUSTED_PROXY_CIDRS` (or with a wrong pinned address, ap7) shows the W1 line within seconds of the first proxied request.

## Dev Notes

### Files and functions (current state -> change -> preserve)

- `server/lib/nebu/web/plugs/client_ip.ex` (51 lines). Today: `call/2` (tuple peer) reads `ClientIP.trusted()`, reads `x-forwarded-for` lines ONLY for a trusted peer, `resolve/3`, `store/4`; moduledoc says "Logs nothing (TP13)". Change: compute `trusted_peer?` once; on the untrusted branch, if `List.keymember?(conn.req_headers, "x-forwarded-for", 0)` call `ClientIP.note_untrusted_forwarding()`; moduledoc TP13 sentence updated. Preserve: never halts, never raises, never reads the body, never rewrites `remote_ip`, the stored `conn.private` keys and values, the non-tuple clause.
- `server/lib/nebu/web/client_ip.ex`. Today: pure resolver, `configure/1` writes `{__MODULE__, :trusted}` to `:persistent_term` and logs boot lines (`log_config/2`); moduledoc "Only boot lines are logged". Change: `configure/1` also (re)creates the throttle atomics under a second `:persistent_term` key; new `note_untrusted_forwarding/0` (`@doc false`), private `now_s/0` with the compile-guarded seam; moduledoc "Logging (TP13)" updated. Preserve: every boot log line and its count (tests count `[warning]` / `[info]` lines of `configure/1`: the throttle setup must NOT log), `parse_cidrs/1`, `resolve/3`, `bucket/1`, the `@max_*` bounds.
- `server/lib/nebu/matrix/device_key_store.ex`: new `address_spread/1` next to `list_devices/1` (~l.261), mirrors `safe_query/2` (l.464: `{:error, :repo_not_started}` when the repo is down, rescue to `{:error, e}`) but runs inside `Nebu.Repo.transaction/1` with `SET LOCAL statement_timeout = '5s'`; check `now_ms/0` (used for `last_seen_ts`) for the clock to mirror in the worker.
- `server/lib/nebu/matrix.ex`: `@doc` + `@spec` + `defdelegate device_address_spread(since_ms), to: Nebu.Matrix.DeviceKeyStore, as: :address_spread` near `list_user_devices` (~l.738).
- `server/lib/nebu/workers/client_ip_check_worker.ex` (new): moduledoc in the style of `oauth_flow_purge_worker.ex` (cadence, cluster safety, logs counts only, story reference); `perform/1`, `assess/1`, `log_reason/1`.
- `server/config/config.exs`: crontab entry with a comment naming the story (G3-2) and the cadence rationale (D2, D8). Do not touch `queues:`. Queue naming (D10): the worker uses `oauth_cleanup` even though it only reads. Say so in the worker moduledoc and the crontab comment ("existing limit-1 housekeeping queue, no new queue").
- `deploy/tofu/examples/{upcloud,stackit}/client_ip_check.tf` (new); doc files of D5. `cloud-init.tftpl`: only the nginx comment block (~l.243-252 UpCloud, ~l.200-210 Stackit) changes; this text is part of the rendered `user_data` (no `ignore_changes`), but this branch already changes both templates substantially versus `main` (story P5), so the comment edit adds no extra VM churn for the release. Keep every string pinned by `server/test/nebu/deploy_config_test.exs` (`NEBU_POSTGRES_SSL: "true"`, the `NEBU_DB_URL:` / `NEBU_DB_URL_MIGRATE:` env lines, no `NEBU_DB_URL=postgresql` in the `.env` block, every `location /admin/ { ... }` block with `proxy_set_header   Upgrade` / `Connection`) and by `admin_bootstrap_live_test.exs` (a `location /admin/` block).

### Files that may be edited safely (doc pins checked)

| File | Pinned by | Safe edit |
|---|---|---|
| `deploy/tofu/examples/*/README.md`, `stackit/RUNBOOK.md`, `*/terraform.tfvars.example` | nothing (only `tofu fmt` does not read them) | yes |
| `deploy/tofu/examples/*/variables.tf` | `tofu fmt` / `tofu validate` | description strings only; keep valid HCL, run `tofu fmt` |
| `deploy/tofu/examples/*/cloud-init.tftpl` | `deploy_config_test.exs`, `admin_bootstrap_live_test.exs` (Stackit), `tofu validate` (templatefile vars) | comment text only, no `${...}` / `%{...}` changes |
| `docs/architecture/07-deployment.md` | `adr_033_test.exs` (`p1_deploy_subsection`, AC9.1, Kassandra #1/#3: keep `203.0.113.99`, `NEGATIVE test`, `over IPv4 AND over IPv6`, `empty or invalid list never allows spoofing`, `too-broad list does`, `verified to APPEND`, `LB-shared bucket`, `Privacy and retention`, `/64`, ...), `oauth_client_revocation_docs_test.exs`, `oauth_revoke_lock_bounds_static_test.exs` ("Revoking a client") | additive edits only; do not reword pinned phrases |
| `docs/architecture/adr/ADR-033-*.md` | `adr_033_test.exs` (TP8 / TP14 regexes: TP14 must still contain `/32`, `127.0.0.1`, `rootless`, `APPEND`, `ap4`; the alb rows `ONLY IF` + `APPEND`) | additive |
| `docs/stories/oauth-broker/follow-ups.md` | `adr_033_test.exs` row regexes, `oauth_client_revocation_docs_test.exs` `table_row/2`, `oauth_revoke_lock_bounds_static_test.exs` | append rows; edit row `as` / `ap6` text only by appending |

### Guardrails

- ADR-018 inline SQL; ADR-020 public API (`Nebu.Matrix.device_address_spread/1`; the worker may call `Nebu.OAuth.oauth_aware?/0`); ADR-019 single app; cluster safety: node-local throttle is informational only.
- Logging laws (memory): no addresses (personal data, ap5), no header values, no tokens, no chat content.
- Test names < 200 characters (CI runs Elixir 1.19).
- `server/lib`, `server/test` only by the pipeline dev / ATDD roles.
- Do not use `RateLimit.take/3` for the W1 throttle (D1, `NEBU_RATE_LIMIT_DISABLED`).
- Do not introduce the literals `"forwarded"` / `"x-real-ip"` anywhere in `server/lib` (contract test).

### Previous story intelligence

- `oauth-trusted-proxy-client-ip` (P1): TP1-TP14, the contract test, `configure/1` as boot / test writer, `async: false` tests, log counting by feature lines.
- `revoke-lock-bounds`: statement / lock bounds via `SET LOCAL ...` inside a short transaction; static tests that pin docs; follow-up rows appended with a section header.
- `oauth-dcr-abuse-hardening` (AH12): the per-source caps become global behind a wrong list; the throttled `per-source ... cap reached` line is the existing hint (unchanged; W1 / W2 complement it).

## Out of scope

- Blocking or delaying `oauth_enabled` (D4); any new env variable, `server_config` key, migration or index.
- `Forwarded` / `X-Real-IP` detection (TP6 contract; follow-up cg); a trusted proxy without `X-Forwarded-For` (not reliable).
- Admin dashboard notice (follow-up cf; `ui: false`).
- Helm value for `NEBU_TRUSTED_PROXY_CIDRS` and its boot warning (bu), PROXY protocol (ap3), Stackit NLB check (ap7, follow-up ci), `X-Forwarded-Proto` gating (ap2).
- Verifying the LB append semantics or LB addresses (ap6 / ap7, operator).
- Editing historical story files or the security report.

## Follow-ups

Append to `docs/stories/oauth-broker/follow-ups.md` under "## From story client-ip-misconfiguration-warnings (2026-10-13)": rows cf, cg, ch, ci of D7 (D12: grep first; any further ids start at `cq`, never `co` / `cp`). All non-gating. G3-2 itself stays a MANUAL, GATING operator item (positive test); this story adds aids, it does not close the gate.

## Tasks

- [x] ATDD: AC1-AC8 in `client_ip_test.exs` (incl. the D6 amendment), AC9-AC14 in `workers/client_ip_check_worker_test.exs`, AC16-AC21 in `client_ip_misconfiguration_docs_test.exs` (RED first)
- [x] D1: throttle atomics in `configure/1`, `note_untrusted_forwarding/0`, clock seam, plug branch, moduledocs (TP13)
- [x] D2: `DeviceKeyStore.address_spread/1`, `Nebu.Matrix.device_address_spread/1`, `Nebu.Workers.ClientIPCheckWorker`, crontab entry
- [x] D3: `client_ip_check.tf` in both examples; `tofu fmt` / `tofu validate`
- [x] D5: README / RUNBOOK / tfvars.example / variables.tf / cloud-init comments; 07-deployment; ADR-033 TP13 / TP14 / AH12; follow-ups (as, ap6, G3-2 status row, new rows)
- [x] Regression run (AC22) and logging-law self-check (AC23); Dev Agent Record

## Dev Agent Record

### Implementation plan

Server first (W1 throttle in `Nebu.Web.ClientIP` + plug branch, W2 facade / store function / worker / cron), then the OpenTofu
`check` blocks (W3), then the documentation (W5), each driven by the staged tests (RED -> GREEN).

### Files changed

- `server/lib/nebu/web/client_ip.ex` (W1: `@xff_key` atomics slot created by `configure/1`, `note_untrusted_forwarding/0`, compile-guarded `now_s/0` seam, moduledoc TP13)
- `server/lib/nebu/web/plugs/client_ip.ex` (untrusted branch: `List.keymember?` then `note_untrusted_forwarding/0`; resolution unchanged)
- `server/lib/nebu/matrix/device_key_store.ex` (`address_spread/1`), `server/lib/nebu/matrix.ex` (`device_address_spread/1` defdelegate)
- `server/lib/nebu/workers/client_ip_check_worker.ex` (new), `server/config/config.exs` (cron `37 */6 * * *`)
- `deploy/tofu/examples/{upcloud,stackit}/client_ip_check.tf` (new); `README.md` (both), `stackit/RUNBOOK.md`, `terraform.tfvars.example`, `variables.tf`, `cloud-init.tftpl` (comment text only) of both examples
- `docs/architecture/07-deployment.md`, `docs/architecture/adr/ADR-033-authorization-server-broker-model.md` (TP13 / TP14 / AH12), `docs/stories/oauth-broker/follow-ups.md` (rows `as`, `ap6`, G3-2 status row, section with cf-ci)
- Staged tests (unchanged by dev): `server/test/nebu/web/client_ip_test.exs`, `server/test/nebu/workers/client_ip_check_worker_test.exs`, `server/test/nebu/client_ip_misconfiguration_docs_test.exs`

### Decisions taken while implementing (inside D1-D7 only)

- `address_spread/1` uses `Nebu.Repo.transaction/1` with the existing private `query/2` (`Ecto.Adapters.SQL.query`), maps a failed statement to `Nebu.Repo.rollback(reason)` so the caller gets `{:error, %Postgrex.Error{}}` (a timeout is `query_canceled`), a stopped repo to `{:error, :repo_not_started}` inside the function body, and rescues / catches exits to `{:error, _}` (never raises).
- The worker also handles an unexpected seam / facade result with one `device address check failed: unexpected result` WARNING and `{:error, {:unexpected_result, _}}`.
- `oauth_offered` is read through `Nebu.OAuth.oauth_aware?/0` only when the line is actually logged (no read on the `:ok` path).
- `@spec` is placed before `@doc false` on `note_untrusted_forwarding/0` because the static test pins `@doc false\s+def note_untrusted_forwarding`.
- `check` block name `client_ip_resolution` in both examples (one block, two asserts for UpCloud, one for Stackit); messages are single-line strings with the exact conditions of D3.
- Rendered `user_data` changes only through the comment block of both `cloud-init.tftpl` (accepted, story D-note).

### Test results (isolated env: throwaway Postgres + `quick.sh`, `--include integration`; `tofu fmt` / `validate` output)

- `client_ip_test.exs` + `client_ip_check_worker_test.exs` + `client_ip_contract_test.exs` + `client_ip_integration_test.exs` (4 files): 250 passed. Together with `client_ip_misconfiguration_docs_test.exs`, `deploy_config_test.exs`, `admin_bootstrap_live_test.exs`: 378 passed, 0 failed.
- `test/nebu/web` + `test/nebu/workers`: 814/815 passed; the one failure is `Nebu.Web.LogStore.RetentionTest` (DEBUG / INFO max-count cap, a known pre-existing family, `known.txt`).
- `test/nebu/oauth` + `test/nebu/migration`: 2658 passed, 0 failed. `test/nebu/matrix`: 1895/1896 passed (2 skipped); the one failure is `RegressionSyncLoadTest` (200 concurrent /sync, known family).
- `mix compile --force`: no warning in any file touched by this story (`mix compile --warnings-as-errors` fails only on the pre-existing type warning in `lib/nebu/matrix/event_dispatcher/server.ex:4961`).
- OpenTofu (`ghcr.io/opentofu/opentofu:1.9`, run on a copy of `deploy/tofu` in the scratchpad, `docker run --rm`, no compose): `tofu fmt -check -recursive deploy/tofu/` OK; `tofu init -backend=false && tofu validate` in `examples/upcloud` and `examples/stackit`: "Success! The configuration is valid." (provider download worked). `tofu plan` was not run (needs cloud credentials), so the warning output of the `check` blocks is verified by the static test only.
- `grep -rn "client IP" e2e/`: no match.

### Review cycle 1 (code review m1-m3 + security review #1 MEDIUM, #2 LOW; fixed by the dev role)

- SEC #1: the gate requires NO W2 line (`client IP: all ... devices`); a W1 line (`client IP: a request carried X-Forwarded-For`) only has to be explained (own negative test against a direct port, client-written header on a direct deployment) and is never silenced by widening `NEBU_TRUSTED_PROXY_CIDRS` (list only an exact, verified proxy address). Changed: `07-deployment.md` (negative-test bullet of group A, group A bullet, activation step 0, "Misconfiguration warnings"), the "Two aids exist" paragraphs of both READMEs and the Stackit RUNBOOK, and the static W1 text in `server/lib/nebu/web/client_ip.ex` (now ends "(never widen the list to silence this line; your own negative test against a direct port also triggers it). Logged at most once per 10 minutes per node."; the test pins of the log text are prefix / substring pins and stay green).
- SEC #2 / CR m1: the UpCloud README positive-test sentences are rewritten (`alb` / `dynamic`: set `lb_real_ip_cidrs` after the negative test and repeat both tests; `none` / `acme`: cannot be fixed with this template, ap3, do NOT enable `oauth_enabled`); long lines wrapped.
- CR m2 / SEC #8: the docs now say that W1 cannot fire for the `alb` collapse with an empty `lb_real_ip_cidrs` (nginx is a trusted peer); only W2 and the `tofu plan` check see it (07 bullet, both READMEs, Stackit RUNBOOK).
- CR m3: Tasks ticked, status `done`. Release note (rendered `user_data` of both reference `cloud-init.tftpl` changes through the comment edits; existing VMs may show a replace diff) added to 07-deployment "Accepted risks and release notes to acknowledge before activation". INFO: the 07 bullet mentions that W2 can time out on very large `devices` tables (`device address check failed: postgres query_canceled`).
- Docs pins amended in `server/test/nebu/client_ip_misconfiguration_docs_test.exs` (this cycle's permission): AC19 step 0 now pins `client IP: all` and "must never be silenced by widening `NEBU_TRUSTED_PROXY_CIDRS`"; the group A test pins `No W2 line (`client IP: all`, the W1-only-explained sentence and "NEVER be silenced by widening"; the AC18 block test additionally pins "NEVER be silenced by widening" and "W1 cannot fire". No `.tf` file was touched.

### Completion notes

All staged tests green; no migration, no new env variable, no `server_config` key; `oauth_enabled` untouched. Story context created 2026-10-13 (bmad-create-story): detectability analysis from `Nebu.Web.ClientIP`, `Nebu.Web.Plugs.ClientIP`, the client-IP contract test, the `devices` schema (migration 000010), the Oban cron idiom (`config.exs`, `OAuthFlowPurgeWorker`), the admin dashboard (no notice pattern) and the reference templates.
