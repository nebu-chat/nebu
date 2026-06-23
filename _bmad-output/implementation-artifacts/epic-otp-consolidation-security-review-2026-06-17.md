# SEC Gate 2 — Epic Security Review: `otp-consolidation`

**Reviewer:** Kassandra 🔐
**Date:** 2026-06-17
**Diff reviewed:** `git diff 710004f9..HEAD` (branch `feature/otp-consolidation`)
**Commits:** scaffold (ADRs+stories) · stage-1 de-umbrella · stage-2 Matrix/Media/Admin rename · docs/Go-removal
**Verdict:** ✅ **CLEAN — 0 CRITICAL, 0 HIGH.** Epic may proceed. Two LOW/informational notes recorded below.

---

## Nature of the change

A behavior-preserving structural refactor + documentation: a nine-app Mix umbrella was
consolidated into one OTP application (`:nebu`), modules were renamed into
`Nebu.Matrix`/`Media`/`Admin`/`Web`/`Compliance` namespaces (word-boundary `sed`), files
relocated, and Go references purged from docs. The unit suite passes at parity (556 passed
/ 2 skipped) and the integration path (Repo under `:nebu`) was exercised. My job here was
**not** to re-review the underlying auth/media/audit logic (covered in prior epics) but to
prove the move did not silently disarm any control.

## Controls verified intact

| # | Control | Evidence | Result |
|---|---------|----------|--------|
| 1 | OIDC bearer auth on protected routes | `lib/nebu/web/router/protected.ex:26` `plug Nebu.Web.Plugs.OidcPlug`; `Nebu.Web.Router` forwards all non-public `/_matrix` through Protected | ✅ on path |
| 2 | Token denylist + rate-limit booted eagerly | `lib/nebu/application.ex:31-32` `Nebu.Web.TokenDenylist.init_table()` + `Nebu.Web.Plugs.RateLimit.init_table()` at boot (closes R-2 fail-open race) | ✅ |
| 3 | Login brute-force rate limit | `lib/nebu/matrix/http_public.ex:64-67` RateLimit (30/min, burst 10, tier "login") on the public login route | ✅ |
| 4 | JWKS cache | started via `jwks_cache_children` (`:nebu_http, :start_jwks_cache` default true) | ✅ |
| 5 | Admin session cookie flags / secret_key_base | endpoint `otp_app: :nebu` reads `config :nebu, Nebu.Admin.Endpoint` (secret_key_base, runtime+test); `secure`/`http_only` + `:admin_session_secure` read under `:nebu_http` and that key is still set in config — no orphaned read | ✅ no orphan |
| 6 | Repo under unified `:nebu` key | `config :nebu, Nebu.Repo` (runtime prod/dev + test); `otp_app: :nebu`; integration tests connect and run | ✅ |
| 7 | gRPC AuthInterceptor | `lib/nebu/matrix/event_dispatcher/endpoint.ex:7` `intercept(Nebu.Matrix.Grpc.AuthInterceptor)` still wired | ✅ |
| 8 | gRPC port 9000 not host-exposed | `docker-compose.yml:123` explicit "gRPC port 9000 is NOT published to the host" (the published `9000:9000` is MinIO, a different service) | ✅ internal-only |
| 9 | Config-key orphaning sweep | every security-relevant `get_env`/`compile_env` atom (`:nebu`, `:nebu_http`, `:signature`, `:compliance`, `:event_dispatcher`) has a matching config setter; `:presence`/`:session_manager` are runtime DI seams with in-code defaults (never static config) — expected | ✅ |
| 10 | Rename did not corrupt SQL / roles / atoms | `priv/migrations/*.sql` only **relocated** (content byte-identical; the rename script ran on `lib`/`test`/`config` only); no `Nebu.*` module name leaked into string/atom literals; `compliance_officer` role + `@valid_roles` intact (lowercase, unmatched by `\bCompliance\b`) | ✅ |
| 11 | Deleted `gateway/` `media/` dirs | untracked Go-era build artefacts (binaries + `node_modules`); no `.go`, no config, no secrets (secrets live in gitignored `.secrets/`) | ✅ no secret loss |

## Findings

**None at CRITICAL or HIGH.** Two informational notes:

### LOW-1 (informational) — vestigial gRPC listener on port 9000
`Nebu.Application` still starts `{GRPC.Server.Supervisor, … port: 9000, start_server: true}`
even though the Go gateway that dialed it is gone (ADR-021). The listener is bound only on
the internal compose network (not host-published) **and** is guarded by
`Nebu.Matrix.Grpc.AuthInterceptor`, so this is not an exposure today. It is dead surface,
however. **Recommendation (follow-up story):** set `start_server: false` (or drop the child)
when the gRPC-removal cleanup lands; until then, keep 9000 unpublished and the interceptor wired.

### LOW-2 (informational) — `max_restarts: 1_000_000` on stateful/Horde supervisors
`Nebu.StatefulSupervisor` and the Horde room `DynamicSupervisor` were given a very high
restart intensity. This is a **net availability improvement**: the previous Horde default
(3 restarts / 5 s) meant three room crashes would terminate the entire room-hosting
supervisor (a one-bad-room-kills-all-rooms amplification). Isolating crash-prone
per-process state with high tolerance is the correct posture for a room-per-process model.
**Residual watch-item:** if a future change makes a room/session crash *attacker-triggerable*
on poisoned input, the process would now restart indefinitely (CPU burn) rather than
failing loudly. Worth a per-process circuit-breaker if that ever becomes reachable. Not a
finding today (no such input path; transient children; in-process only).

### Signing-key guard — assessed, no issue
The server Ed25519 key in `Nebu.Application.start/2` is now generated only when
`:persistent_term.get(:nebu_signing_key)` is nil (was unconditional). Within a VM the key is
stable (no cross-boundary reuse — it is the single server key by existing design); across an
OS restart `persistent_term` is cleared and a fresh key is generated via `:crypto` CSPRNG
(unchanged from before). The guard only prevents a redundant same-VM regeneration that would
otherwise invalidate in-flight signatures — strictly safer. No predictability or reuse defect.

## Notes for the sanctum

- No new instance of the recurring `:httpc` empty-`ssl`-opts TLS gap (no new outbound HTTPS introduced).
- The OIDC fail-open / denylist-backbone families were not re-touched by this refactor (auth logic moved verbatim; `OidcPlug`/`TokenDenylist` wiring preserved).
- This epic is a good example of "structural refactor, verify controls didn't move out from under themselves" — the high-value checks were config-atom orphaning and supervisor-tree boot order, both clean.

---

## Addendum — SEC Gate 1 for two follow-up stories (post-Gate-2)

**Stories:** `deploy-ci-env-cleanup`, `grpc-legacy-removal` (both `security_review: required`).
**Diff:** `ad084323..HEAD`. **Verdict:** ✅ CLEAN — and a net security improvement.

### deploy-ci-env-cleanup
- **No admin auth orphaned.** Every deploy option (docker-compose, helm secrets, stackit
  cloud-init, AWS ECS task def) still provides `NEBU_ADMIN_OIDC_CLIENT_SECRET(_FILE)` after
  the cleanup; the bare `NEBU_OIDC_CLIENT_SECRET` that fed admin login was **renamed**, not
  dropped. No non-admin OIDC secret remains wired to the app. ✅
- **`NEBU_ALLOW_INSECURE_OIDC_ISSUER` removal** does not weaken prod: the Elixir app never
  had an insecure-issuer gate keyed on it (JWKS TLS verification is `https`-gated in
  `JwksCache`; ADR-era Go control). Removing the unread var changes no runtime behavior. ✅
- All removed vars verified unread by `core/` before removal. Secrets remain file/secret-store
  sourced (no plaintext introduced). `terraform.tfstate` untouched.
- Pre-existing gap surfaced (NOT introduced here): the AWS ECS task definition sets the admin
  OIDC **secret** but no admin **client id** — recommend a follow-up to add it.

### grpc-legacy-removal
- Removing `Nebu.Matrix.Grpc.AuthInterceptor` removes the **only external (network) gRPC
  entry point** to the command layer — a reduction of attack surface, not a control loss.
  The network listener is gone entirely (port 9000 not opened).
- **In-process auth unchanged:** protected routes still run `plug Nebu.Web.Plugs.OidcPlug`
  (`protected.ex:26`); the trusted identity `Nebu.Matrix.Grpc.Metadata.trusted_identity/1`
  reads is built by the OIDC-verified HTTP layer (`http.ex`), independent of the deleted
  interceptor. ✅
- `NodeRegistration` removal drops a registration handshake with the deleted gateway — not an
  inbound-request auth gate. No control lost. ✅
- Kept in-process command/DTO layer (`Server`, `Core.*`, `Metadata`, `GRPC.RPCError`, `:grpc`)
  — unit suite 548 green, release boots with no gRPC port.

No CRITICAL/HIGH. Epic `otp-consolidation` remains CLEAN.
