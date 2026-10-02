## Session — bugfix-oidc-public-endpoint-urls (headless security gate)

**Mode:** `--headless`. No PULSE.md exists in the sanctum — fell back to
`references/security-review.md` + CREED + MEMORY (Accepted Risks / Recurring
Patterns). Worth noting for a future rebirth: SKILL.md's headless branch points at a
file that has never been created.

**Scope:** `git diff --staged` on `bugfix/oidc-public-endpoint-urls`, 22 files
+632/-56. Server: `oidc_metadata.ex` (new `ensure_msc2965_fields/1`),
`http_public.ex` (auth_metadata pipes through it), `oidc_config.ex` (doc-only).
Infra: `dev/dex/config.yaml` (issuer → `http://dex.localtest.me:5556/dex`),
`docker-compose.yml` (network alias), `Makefile`. Docs: CHANGELOG/README/
getting-started. Tests: `oidc_metadata_test.exs` (new), `matrix_router_test.exs`,
6 e2e files.

**Finding summary:** 0 CRITICAL, 0 HIGH, 3 MEDIUM, 2 LOW → **APPROVED**, commit not
blocked. Report:
`_bmad-output/nebu/epics/oidc-public-endpoint-urls/step-results/bugfix-oidc-public-endpoint-urls/security-review-2026-09-02.md`

- M-1 synthesis base is the FETCHED `issuer`, never checked against the configured
  one (missing OIDC Discovery §4.3 / RFC 8414 §3.3 relying-party check)
- M-2 `revocation_endpoint` (+ `registration_endpoint`) advertised as known 404s →
  a revocation clients believe in that never happens
- M-3 CHANGELOG raw-SQL remediation: no audit entry, omits `oidc_jwks_uri`, silently
  `UPDATE 0` for any non-superuser under FORCE RLS
- L-1 `*.localtest.me` — third-party zone in the dev auth path + registrable-domain
  sharing voids SameSite isolation vs other local `*.localtest.me` apps
- L-2 unauthenticated, un-rate-limited `auth_metadata` now decodes+re-encodes JSON
  per request over an uncapped upstream body (synthesize at cache-fill instead)

**New patterns discovered:** 4 rows added to MEMORY.md Recurring Patterns —
(1) fail-closed guard validated for SHAPE but never for AUTHENTICITY; (2) fabricated
OPTIONAL endpoint to satisfy a client parser = a promise the server cannot keep;
(3) documented raw-SQL operator remediation — un-audited, incomplete, RLS-silent;
(4) shared registrable domain for a dev hostname silently voids SameSite isolation.

**Accepted risks this session:** none recorded. Phil has not signed off on anything
new — do not treat any finding above as accepted on a later rebirth.

**Answers to the four questions the caller asked specifically:**
1. CHANGELOG SQL injection — none. Static literal, no interpolation. Its defects are
   audit/completeness/RLS (M-3), not injection.
2. `*.localtest.me` spoofing/MITM — real but LOW, and the interesting half is the
   registrable-domain/SameSite one, not DNS spoofing (see L-1). Network reach did NOT
   widen: dex already published `5556:5556`, so `localhost:5556` was equally
   reachable before.
3. Malicious/compromised IdP tricking the synthesis — yes, and this was the gap the
   two prior cycles left: the guard was reviewed for crashes, and provenance was
   never asked about (M-1). No string-injection primitive though — `URI.parse`
   rejects pseudo-schemes (`host: nil`), `trim_trailing` collapses slashes.
4. `--add-host` in prod — clean. Exactly one occurrence, `Makefile:281`, inside
   `test-e2e-element`'s `docker run`. No `extra_hosts` in compose, nothing in
   `deploy/tofu/`, no Dockerfile, no CI config. Also confirmed no `server/lib/` code
   reads `NEBU_OIDC_ISSUER` (test-only) — ADR-022 holds.

**Follow-up:**
- Architecture verdict: the honest-issuer redesign is RIGHT. Rejecting the
  rewrite-based cycle 1 was correct — do not relitigate it.
- Pre-existing, NOT findings against this diff, recorded in the report's out-of-scope
  section so a later session does not mistake them for clean:
  (a) `http://` discovery documents are unauthenticated (`do_fetch/1` verifies TLS
  for https only — earlier Kassandra F-2, accepted under ADR-012). Substituting one
  gets a 5-min cached window: verbatim echo to all clients, browser SSO 302 to the
  attacker's `authorization_endpoint`, and code + CLIENT SECRET POSTed to their
  `token_endpoint`. This is M-1's precondition.
  (b) `deploy/tofu/examples/stackit` `oidc_mode = "dex"` runs exactly that plain-HTTP
  discovery on a PUBLIC VM with a security-group rule opening 5556 to browsers
  (`RUNBOOK.md:35-37,163`). There (a) is no longer loopback-local. **Deserves its own
  decision — hard guard against `oidc_mode = "dex"` without TLS, or a formal
  accepted-risk entry. Raise this next time OIDC or the Stackit deploy is touched.**
  (c) `e2e/tests/features/admin/bootstrap.spec.ts:39-41` seeds `oidc_client_secret`
  as PLAINTEXT while prod treats that column as AES-256-GCM (`admin/db.ex:706-716`).
  Unchanged by this diff; a fixture that bypasses the encryption invariant cannot
  catch a regression in it.
  (d) Housekeeping: `deploy/tofu/examples/stackit/terraform.tfstate*` hold plaintext
  PROD PostgresFlex passwords (`nebu_app`, `nebu_migrate`). Correctly gitignored
  (`.gitignore:68-70`) and untracked — verified via `git ls-files` — so not a
  disclosure, but one `git add -f` from being one. Rotate if that path was ever
  shared.
- MEMORY.md is ~180KB against memory-guidance.md's 200-line budget. The Recurring
  Patterns table is where the growth is. Ask Phil about a curation pass — several
  Go-gateway-era rows are dead now that the gateway is gone (ADR-019/021).
