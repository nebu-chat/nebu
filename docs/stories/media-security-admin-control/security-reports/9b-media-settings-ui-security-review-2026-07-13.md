# Security Review — 9b-media-settings-ui

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Date:** 2026-07-13 · **Epic:** media-security-admin-control
**Story flag:** `security_review: optional` — run anyway by coordinator decision (webhook SSRF surface,
admin-auth-gated config-mutation endpoint, audit-actor attribution).

## Verdict: APPROVED (0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 LOW, 3 INFO)

## Scope

`server/lib/nebu/admin/media_settings_controller.ex` (post code-review cycle 1 — `changed_keys/2`,
documented `persist/2` non-atomicity), `media_settings_html.ex`, `templates/media_settings/index.html.heex`,
`router.ex`/`layouts.ex` diffs, plus the persistence seam it calls into (`server/lib/nebu/media/config.ex`,
Story 9a, already reviewed) and the reused guard (`server/lib/nebu/media/ssrf.ex`).

## Findings

### LOW-1 — Admin can set media_config values that neutralize downstream security controls, with no explicit guard beyond the controller's own operationally-generous bounds

`max_file_size_bytes` bounds are `{1, 5_368_709_120}` — a fully-authenticated admin could set it to `1`,
which (per Story 3/9a's own documented contract: "files above this size are never scanned") would cause
ClamAV to skip scanning EVERY file larger than 1 byte, i.e. functionally disable malware scanning
cluster-wide without ever touching `config.exs` or clamd's own config. Same class of risk for
`max_pending_per_user`/`max_stall_ms` set to extreme-but-in-bounds values (DoS-adjacent misconfiguration).
This is an **accepted admin-trust-boundary risk, not a vulnerability**: the actor is already a fully
privileged, OIDC-authenticated instance admin (`:require_admin`) who could achieve the identical effect
via a redeploy with a changed `config.exs`, or by disabling ClamAV outright via existing admin surface. No
new privilege is created by this page; it only makes an existing admin capability faster. Rated LOW
(informational) rather than MEDIUM because: (a) every `media_config_updated` write is unconditionally
audited with old/new values (AC6, Story 9a's `AuditWriter` call) — a security-relevant self-disablement
is NOT silent, it is a permanent compliance-log entry naming the admin who did it; (b) the story's own
scope is explicitly "make config admin-editable at runtime," which necessarily includes this class of
"trusted actor can misconfigure" risk, same as `/admin/logs/config`'s existing ability to set retention to
effectively-zero. Recommendation (non-blocking): if a future story wants a stronger guardrail here, add a
confirmation step or a hard ceiling floor (e.g. `max_file_size_bytes` minimum meaningfully above the
`max_upload_size_bytes` default's realistic small-file case) — not required for this story to ship.

## Verified CLEAN (specific angles requested by the coordinator, independently checked)

- **`:require_admin` plug coverage:** `plug Nebu.Admin.Auth, :require_admin` (line 83) is a MODULE-level
  plug, applying to every action in `Nebu.Admin.MediaSettingsController` — both `index/2` AND `save/2`.
  No action-specific `plug ... when action in [...]` scoping that could accidentally exempt `save/2`.
- **Actor attribution cannot be client-spoofed:** `actor_id/1` reads `conn.assigns[:current_user]`
  (`"matrix_user_id"` then `"sub"`, falling back to the fixed literal `"system:media_config"`) — this
  value is populated by `Nebu.Admin.Auth`'s session-based auth flow (OIDC-verified identity stored in the
  session by the login/callback path), NEVER from request params/body. A non-admin session cannot reach
  `save/2` at all (redirected at the plug); an admin session cannot forge a DIFFERENT admin's identity into
  this field since it's derived server-side from their own verified session, not attacker-controlled input.
  This directly satisfies 9a's own carried-forward INFO note ("upsert/3 does no authz on actor — 9b must
  enforce admin authz + server-verified actor, never client string") — confirmed held.
- **CSRF protection genuinely in force:** `:browser` pipeline (`router.ex`) applies `plug
  :protect_from_forgery` unconditionally; the `:admin_csrf_bypass` seam that could disable it is set ONLY
  in `config/test.exs` (`admin_csrf_bypass: true`) — grepped `config/`/`runtime.exs`, confirmed absent from
  `dev.exs`/`prod` config/runtime paths. `POST /admin/media/settings` is not on the (empty-for-this-path)
  `@csrf_bypass_excluded_paths` list either. CSRF-protected in every non-test environment.
- **webhook_url validation — no divergence/bypass between the controller's own check and
  `Nebu.Media.Config.upsert/3`'s internal re-check:** both operate on the SAME already-trimmed string (the
  controller trims via `String.trim/1` BEFORE calling `Config.upsert`; `Config`'s own `validate_value/2`
  does not re-trim, so it sees the identical value the controller validated — no whitespace-based
  smuggling window between the two checks). Both independently require `%URI{scheme: "https"}` then call
  `Nebu.Media.SSRF.check/1` — genuinely the SAME function, not re-derived, satisfying AC3/the Do-Not-Change
  guardrail. No TOCTOU/DNS-rebinding gap is INTRODUCED by this story: `SSRF.check/1`'s documented
  non-pinning caveat (resolves-then-discards the IP, does not carry it to the actual future send) is a
  pre-existing property of the shared guard, already flagged and correctly handed off to Story 7 (the
  actual webhook SENDER, which is the real TOCTOU-relevant sink) by 9a's own security review (F-2 MEDIUM,
  carried forward, unchanged by this story). This story only STORES a validated URL; it never sends an
  outbound request itself, so it does not introduce a NEW instance of that gap.
- **XSS:** grepped both the controller and template for `Phoenix.HTML.raw`/`{:safe, ...}` — zero matches.
  All rendered values (including `state_from_params/1`'s echo of an operator's invalid submission back
  into the re-rendered form, AC6) go through ordinary HEEx `{...}`/`value={...}` interpolation, which
  auto-escapes. No unsafe-HTML sink anywhere in this diff.
- **ADR-018/020 compliance:** grepped for `Ecto.Changeset`/`Ecto.Schema`/`Postgrex`/`Ecto.Adapters.SQL` in
  the new controller/template — zero matches. Every persistence call is `Nebu.Media.Config.upsert/3`; the
  9a public-API seam's own SQL is parameterized (verified in the prior 9a review, unchanged here).
- **`persist/2`'s documented non-atomicity (code-review MINOR-1, now `changed_keys/2`-narrowed):** no
  security dimension — a partial multi-key write on a genuine mid-loop DB failure is an availability/data-
  consistency concern (already correctly triaged as MINOR by code-review, not security), not a privilege
  or confidentiality issue; each individual `upsert/3` call is independently validated and audited.

## INFO (non-blocking, carried for completeness)

- **INFO-1:** `mime_denylist` (Story 9a's 10th catalog key) is correctly OUT of this page's scope (AC1's
  literal 9-key list) — this page cannot be used to weaken or clear the MIME denylist Story 9c will add.
  No action needed; noted only to confirm scope boundary held.
- **INFO-2:** double `SSRF.check/1` invocation per webhook save (controller + `Config.upsert`'s own
  re-validation) — already flagged by code-review as INFO-1 (performance, not security); two DNS
  resolutions of an admin-supplied URL is not itself a security concern (no amplification vector — the
  admin already controls the input, and both checks reject identically).
- **INFO-3:** this endpoint has no dedicated rate limit beyond the general admin-auth gate — acceptable,
  matches every sibling admin settings controller (`/admin/config`, `/admin/logs/config`), not a
  story-specific gap.

## Summary for pipeline log

APPROVED, 0 CRITICAL/HIGH/MEDIUM, 1 LOW (accepted admin-trust-boundary risk, not a vulnerability) + 3 INFO.
No new MEMORY pattern warranted — this story confirms two PRIOR patterns (#44/#50 admin-configured-outbound-
URL SSRF, and 9a's own actor-authz carry-forward) were correctly closed/honored, rather than surfacing a
new one.
