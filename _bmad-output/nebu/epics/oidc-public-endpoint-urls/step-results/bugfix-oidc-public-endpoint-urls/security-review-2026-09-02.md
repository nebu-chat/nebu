# Security Review — bugfix-oidc-public-endpoint-urls

**Reviewer:** Kassandra (headless)
**Date:** 2026-09-02
**Branch:** `bugfix/oidc-public-endpoint-urls`
**Diff scope:** `git diff --staged` — 22 files, +632/-56.
Server code: `server/lib/nebu/matrix/oidc_metadata.ex` (MSC2965 field synthesis),
`server/lib/nebu/matrix/http_public.ex` (auth_metadata handler),
`server/lib/nebu/web/oidc_config.ex` (doc-only). Infra: `dev/dex/config.yaml`,
`docker-compose.yml`, `Makefile`. Docs: `CHANGELOG.md`, `README.md`,
`docs/getting-started.md`. Tests: 2 Elixir test files, 6 e2e files.

**Verdict: APPROVED — no CRITICAL, no HIGH. Commit is not blocked.**
3 MEDIUM + 2 LOW advisories below.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| M-1 | MEDIUM | `server/lib/nebu/matrix/oidc_metadata.ex:123-165` | Client-facing URLs synthesized from the *fetched* document's `issuer` with no check against the configured issuer (OIDC Discovery §4.3 / RFC 8414 §3.3) | Pass the configured issuer into `ensure_msc2965_fields/2`; reject a document whose `issuer` differs; build synthesized URLs from the configured issuer |
| M-2 | MEDIUM | `server/lib/nebu/matrix/oidc_metadata.ex:107-108` | Advertises `revocation_endpoint` (and `registration_endpoint`) that are known 404s — a client's token revocation silently does nothing while appearing to succeed | Point `revocation_endpoint` at a route that actually revokes, or omit it; correct the "RFC 8414 MUST" justification (both are OPTIONAL in RFC 8414) |
| M-3 | MEDIUM | `CHANGELOG.md` (remediation block) | Documented operator fix mutates the OIDC trust-anchor config via raw SQL: no audit-log entry, omits `oidc_jwks_uri`, and silently no-ops under RLS for any non-superuser role | Add `oidc_jwks_uri` to the UPDATE; state the audit-trail gap and the `-U nebu` superuser requirement explicitly |
| L-1 | LOW | `dev/dex/config.yaml:13`, `docker-compose.yml:154-157` | `*.localtest.me` places a third-party DNS zone in the dev auth path and shares a registrable domain with every other local `*.localtest.me` app (SameSite / cookie-domain isolation loss) | Pin resolution locally via `extra_hosts` + `/etc/hosts` as the primary path, or use a project-owned hostname |
| L-2 | LOW | `server/lib/nebu/matrix/http_public.ex:187`, `oidc_metadata.ex:182-205` | Unauthenticated, un-rate-limited endpoint now performs a full JSON decode + re-encode per request over an unbounded upstream body | Synthesize once at cache-fill time in `fetch_cached/1`; add a max-body guard to `do_fetch/1` |

---

## Detail

### M-1 — Synthesis base is the fetched `issuer`, never validated against the configured issuer  [MEDIUM]

`maybe_put_placeholder_url/3` reads `doc["issuer"]` — a field that arrives from the
network — and concatenates a path onto it to produce two **new URLs that Nebu then
serves to every Matrix client** as authoritative OAuth endpoints. `fetch/1` /
`do_fetch/1` never assert that the returned document's `issuer` equals the issuer
Nebu asked for, which OIDC Discovery §4.3 and RFC 8414 §3.3 both make a MUST for the
relying party.

The fail-closed guard added in this cycle (`issuer_base/1`) was reviewed for
*malformedness* — scheme and host present — not for *authenticity*. It accepts any
syntactically valid absolute URI, including one belonging to somebody else. So a
substituted discovery document does not merely pass through: the diff makes Nebu
actively *manufacture* two additional attacker-origin URLs and hand them to clients
under its own name.

The upstream-substitution precondition is pre-existing and out of this diff's scope
(see "Pre-existing, out of scope" below) — which is why this is MEDIUM and not
higher. But the check is spec-mandated, cheap, and belongs exactly where this diff is
already working. Concretely:

```elixir
def ensure_msc2965_fields(raw_json, configured_issuer)
# 1. if doc["issuer"] != configured_issuer -> reject (log + {:error, :issuer_mismatch})
# 2. synthesize from configured_issuer, not from doc["issuer"]
```

Step 2 alone removes the untrusted field from the synthesis path entirely and does
not weaken any behaviour the new tests assert — the honest-issuer architecture means
the two values are equal by construction, so a mismatch is precisely the case worth
refusing. Note that `oidc_metadata_test.exs` currently *asserts* synthesis follows the
document's own origin even when it looks wrong ("architecture regression: NO origin
rewriting", the `http://dex:5556/dex` case); that test encodes "don't rewrite," which
is right, but it should not be read as "trust whatever origin arrives."

### M-2 — Advertising a `revocation_endpoint` that does not exist  [MEDIUM]

`ensure_msc2965_fields/1` synthesizes `revocation_endpoint` as
`<issuer>/token/revoke` and `registration_endpoint` as `<issuer>/clients/register`.
The module's own docstring states the premise plainly: *"Dex does not implement
dynamic client registration or token revocation, so these are placeholder paths."*
Dex v2.45.1 (`docker-compose.yml:137`) implements neither RFC 7009 nor RFC 7591, and
its `http.ServeMux` routes are exact-match — both synthesized paths are 404s.

The security consequence is on the revocation side. `auth_metadata` now tells every
Matrix client: *revoke tokens here*. The Oracle context for this very story records
the client-side contract — "§token-revocation (RFC 7009): client POSTs to
`revocation_endpoint` sourced from auth_metadata — this field must be a real,
client-usable URL." A client that acts on it POSTs the credential, receives 404, and
— depending on how tolerant its logout path is — may drop the token locally and
report success while the token stays valid upstream until expiry. Dev Dex issues
`idTokens: 24h` (`dev/dex/config.yaml:31`). The user-visible outcome is "I signed
that session out" when nothing was revoked. That is a genuine defense-in-depth
failure, and it is *created* by this diff: before it, the field was absent and a
client had no revocation endpoint to believe in.

Secondary, worth correcting because it is the stated justification for fabricating
these fields: the code comments and docstrings call all three "MSC2965/RFC 8414
MUST-fields." RFC 8414 §2 marks `registration_endpoint` and `revocation_endpoint`
**OPTIONAL** — only `issuer` is REQUIRED there. MSC2965 is the sole driver. Fabricating
an endpoint is a design decision the project should make knowingly, not one an RFC
compels.

Remediation, in preference order:
1. Point `revocation_endpoint` at a Nebu-owned route that genuinely revokes the
   session (Nebu already owns refresh/session state — `Nebu.Matrix.SsoLogin`,
   `/_matrix/client/v3/refresh`). This makes the advertised contract true.
2. If the field must exist only to keep the Dart SDK's non-nullable parse alive,
   document the known-404 in `CHANGELOG.md` so the "logout does not revoke" gap is
   recorded rather than discovered.
3. Fix the RFC 8414 attribution in the docstrings and comments.

`registration_endpoint` is the milder half — a failed DCR attempt is an availability
degradation, not a false security assurance — but the same reasoning applies.

### M-3 — Raw-SQL operator remediation: un-audited, incomplete, and RLS-fragile  [MEDIUM]

The `CHANGELOG.md` upgrade note documents:

```
docker compose exec postgres psql -U nebu -d nebu -c "UPDATE server_config SET value = '...' WHERE key = 'oidc_issuer';"
```

The SQL string itself is a static literal with no interpolation — **no injection
surface**, as suspected. Three other problems, though:

**(a) No audit-log entry.** `oidc_issuer` selects which token issuer Nebu trusts —
arguably the single most security-relevant row in `server_config`. Nebu is
compliance-native with an append-only `audit_log`, and this procedure changes that
value with no record that it ever happened, by whom, or from what. An auditor
reconstructing "when did this instance start trusting a different IdP?" finds
nothing. ADR-022 (bootstrap-only OIDC) is what closes the door on an Admin-UI path,
so the gap is understood — but it should be *stated* in the CHANGELOG, not left
implicit in a copy-paste command.

**(b) Incomplete — omits the JWKS trust anchor.** `server_config` holds
`oidc_jwks_uri` as a *separate* key (`server/lib/nebu/web/oidc_config.ex:302,318`;
written by the wizard via `server/lib/nebu/admin/auth.ex:1127`). It is the source of
the **signature-verification keys**. The documented command updates `oidc_issuer`
only, leaving `oidc_jwks_uri` at `http://dex:5556/dex/keys`. In dev both names
resolve to the same container, so nothing breaks — which is the worse outcome: the
procedure *appears* to work while the advertised issuer host and the key-material
host have silently diverged. Copied as a template for a real IdP move (and operator
runbooks do get copied), it keeps pulling signing keys from the host being
decommissioned.

**(c) Silently no-ops for any non-superuser role.** `server_config` carries
`FORCE ROW LEVEL SECURITY` (`server/priv/migrations/000001_init.up.sql:42-43`). The
*effective* `config_update_mutable` policy is the last one created —
`000020_admin_temporary_captures.up.sql` — and it does **not** list `oidc_issuer`;
`000002_add_missing_structures.up.sql:359-361` dropped and recreated the policy
without it, and no later migration restored it (the allowlist in `000001` is
superseded). The command only works because `-U nebu` is the dev container's
`POSTGRES_USER`, i.e. a superuser, and superusers bypass RLS outright. An operator
who adapts the command to the runtime role (`nebu_app`, per
`docker-compose.yml:69`) gets `UPDATE 0`, restarts as instructed, and lands back in
the same `bad_issuer` outage with no error to explain it.

Remediation: add `oidc_jwks_uri` to the UPDATE (or tell operators to re-run the
Bootstrap Wizard, which the note already offers as the alternative — consider making
it the *primary* recommendation); state that this is an un-audited direct DB write;
note that it requires the superuser role and that `nebu_app` cannot perform it under
RLS.

### L-1 — `*.localtest.me`: external DNS zone in the dev auth path, shared registrable domain  [LOW]

Two distinct mechanisms, both dev-only:

**(i) Third-party zone.** `dex.localtest.me` resolves through a public zone the
project does not control. The compose network alias (`docker-compose.yml:154-157`)
covers *container-side* resolution — Docker's embedded DNS answers the alias before
forwarding externally — and `Makefile:281` pins the Playwright container with
`--add-host`. The developer's **browser** is the leg still on public DNS. If that
zone lapses or is hijacked, the browser sends Dex login credentials and the OAuth
authorization code to whatever address it returns, over plain HTTP.

**(ii) Registrable-domain sharing — the part worth naming as a class.**
`dex.localtest.me` and any *other* local dev app the developer runs on a
`*.localtest.me` hostname (a popular convention, which is exactly why it was chosen
here) share the registrable domain `localtest.me`. Browsers compute *site* from the
registrable domain, so those origins are **same-site** with Dex: `SameSite=Lax` and
`SameSite=Strict` on Dex's session cookie provide no isolation between them, and a
cookie set with `Domain=.localtest.me` by any of them is transmitted to Dex's origin
(cookie tossing). `oauth2.skipApprovalScreen: true` (`dev/dex/config.yaml:25`)
removes the interaction step that would otherwise sit in front of the authorize
endpoint.

Rated LOW deliberately, and the reasons matter: OAuth `state` **is** validated
constant-time on both callbacks (`server/lib/nebu/admin/auth.ex:980-993`;
`server/lib/nebu/matrix/sso_login.ex:349-362`), so login-CSRF remains blocked; and
network exposure is not widened — Dex already published `5556:5556`, so any remote
page could already reach `http://localhost:5556/dex/...`. What is lost is a layer of
browser-enforced isolation, in dev only.

Remediation: make local pinning the primary path rather than the fallback — add
`extra_hosts` for the dev containers and lead with the `/etc/hosts` line in
`README.md` / `docs/getting-started.md` (currently presented as the DNS-rebind
fallback), or move to a project-owned hostname. The `--add-host` pattern already
exists in the Makefile, so this is a small extension of what the diff does.

### L-2 — Per-request JSON decode + re-encode on an unauthenticated, un-rate-limited route  [LOW]

`http_public.ex:187` now wraps the cached body in `ensure_msc2965_fields/1` on the
response path. Previously the cached bytes went straight from `:persistent_term` to
`send_resp`; now every request pays `Jason.decode` + `Jason.encode!`.

The route has no throttle. `/login` and `/refresh` each carry an explicit
`RateLimit` plug (`http_public.ex:100,106,110,113`); `auth_metadata` is dispatched
from the bare `get "/"` clause (`http_public.ex:39-58`) with none — and the story's
own Oracle context confirms the spec position: *"No auth, not rate-limited."*
`do_fetch/1` (`oidc_metadata.ex:182-205`) sets no response-body cap on `:httpc`, so
the body size is bounded only by what the IdP returns (or, on an `http://` issuer, by
what an on-path party returns). Repeated unauthenticated requests then multiply
decode+encode work over that body. Amplification is modest for a normal discovery
document, which is why this is LOW rather than higher.

Remediation: call `ensure_msc2965_fields/1` **once**, at cache-fill time inside
`fetch_cached/1`, and store the synthesized bytes — the response path returns cached
bytes again, and the per-request cost disappears. Add a max-body guard to
`do_fetch/1` while there.

---

## Explicitly checked and clean

- **`--add-host` cannot reach production.** `--add-host=dex.localtest.me:127.0.0.1`
  occurs exactly once — `Makefile:281`, inside the `test-e2e-element` target's
  `docker run` for the Playwright image. No `extra_hosts` in `docker-compose.yml`, no
  host mapping in `deploy/tofu/`, none in any `docker/Dockerfile*`, none in CI config.
  Confirmed CI/dev-only.
- **`NEBU_OIDC_ISSUER=http://dex.localtest.me:5556/dex` (`Makefile`) is test-runner
  only.** No `server/lib/` code reads `NEBU_OIDC_ISSUER` — the only hits are in
  `server/test/`. ADR-022 holds: the server resolves the issuer solely from
  `server_config` via `Nebu.Web.OidcConfig`.
- **CHANGELOG SQL has no injection surface.** Static literal, no interpolation, no
  operator-supplied value. (Its other defects are M-3.)
- **`issuer_base/1` fail-closed guard is sound against malformed input.** Rejects
  non-binary, empty, relative, and scheme-only values; `URI.parse` yields
  `host: nil` for pseudo-schemes such as `javascript:`, so those are rejected too.
  `String.trim_trailing(issuer, "/")` collapses repeated trailing slashes correctly.
  The residual weakness is authenticity, not syntax — see M-1.
- **No origin rewriting anywhere.** Verified by reading the module, not just its
  comments: `ensure_msc2965_fields/1` mutates only the three named keys.
- **`sso_login.ex` and `admin/auth.ex` untouched**, and correctly so — the honest-
  issuer design fixes the SSO `Location` header by construction. Both callbacks
  validate `state` constant-time.
- **Dex client configuration unchanged.** `dev/dex/config.yaml` diff is the `issuer`
  line plus comments; `staticClients.redirectURIs` (all `localhost:8008` /
  `localhost:7070`) are untouched, so no redirect-URI allowlist widening. The
  README's `nebu-admin` → `nebu-gateway` correction matches the pre-existing
  single-client state from ADR-022, not a new grant.
- **No secrets introduced by the diff.** No credentials, keys, or tokens added; the
  dev Dex client secret and bcrypt hashes are pre-existing and unmodified.
- **`terraform.tfstate` files are gitignored** (`.gitignore:68-70`) and not tracked —
  `git ls-files deploy/tofu/examples/stackit/` confirms. Not a committed-secret issue.
  See the housekeeping note below.

---

## Pre-existing, out of scope — recorded so it is not mistaken for clean

Not findings against this diff. Flagged because they are the precondition M-1 depends
on, and silence here would be false comfort.

1. **Discovery documents fetched over `http://` are unauthenticated.**
   `do_fetch/1` enables `verify_peer` + hostname checking for `https` only
   (`oidc_metadata.ex:207-223`, from an earlier Kassandra finding F-2), leaving
   `http://` issuers with no integrity protection — an accepted dev posture under
   ADR-012. An on-path party who substitutes that document gets, for the 5-minute
   `:persistent_term` cache window: the document echoed verbatim to every Matrix
   client via `auth_metadata`; the browser SSO 302 aimed at their
   `authorization_endpoint` (`sso_login.ex:235`); and the authorization code plus the
   OIDC **client secret** POSTed to their `token_endpoint` (`sso_login.ex:640`). M-1
   adds two synthesized attacker-origin URLs on top. Inside a Docker bridge or on
   loopback this is a narrow position, hence the dev acceptance.
2. **`deploy/tofu/examples/stackit` `oidc_mode = "dex"` runs that same plain-HTTP
   discovery on a public VM.** Per `RUNBOOK.md:35-37,163`, Dex is exposed on host
   port 5556 over plain HTTP with a security-group rule opening it to browsers, and
   the server performs discovery via a public-IP hairpin. In that mode the exposure
   in (1) is no longer loopback-local: IdP passwords, authorization codes, ID tokens,
   and the client secret traverse the public internet unprotected. It is documented
   as "test/demo" and the RUNBOOK is candid that the endpoint is plain HTTP. Worth a
   dedicated decision — either a hard guard against `oidc_mode = "dex"` without TLS,
   or an explicit accepted-risk entry — rather than leaving it to a runbook footnote.
3. **`e2e/tests/features/admin/bootstrap.spec.ts:39-41`** seeds
   `oidc_client_secret` into `server_config` as plaintext, while production treats
   that column as AES-256-GCM ciphertext (`server/lib/nebu/admin/db.ex:706-716`,
   `bootstrap_live.ex:30`). Line unchanged by this diff. A fixture that bypasses the
   encryption invariant will not catch a regression in it.
4. **Housekeeping:** `deploy/tofu/examples/stackit/terraform.tfstate*` on the working
   disk contain plaintext production PostgresFlex passwords for `nebu_app` and
   `nebu_migrate`. Correctly gitignored and untracked, so not a disclosure — but one
   `git add -f` away from being one, and worth rotating if that path was ever shared.

---

## Summary

```
CRITICAL: 0
HIGH:     0
MEDIUM:   3  — advisory, address before epic end
LOW:      2  — advisory
```

**Verdict: APPROVED.** No CRITICAL or HIGH findings; nothing blocks this commit.

The architecture change is the right one. Fixing the leak at the source rather than
rewriting response bodies removes an entire class of desync bug, and the decision to
reject the rewrite design was correct. Two observations about the *review* rather
than the code: M-2 is a consequence the two prior review cycles did not weigh —
fabricating a `revocation_endpoint` was treated as a compatibility shim, and its
security meaning (a revocation a client believes in and that never happens) went
unexamined. And M-1 exists because the fail-closed guard added in cycle 1 was
validated for crash-safety and never for authenticity; "does this parse?" and "does
this belong to the party we asked?" are different questions, and only the first was
asked. Both are worth carrying forward as review habits, not just as fixes.
