# Code review cycle 0: consent-arming-hardening (2026-10-13)
No MAJOR / CRITICAL; 2 MINOR, 5 INFO. Server side clean (headers, hashes computed from the shared script, ids rendered only with their notices, SSO page unchanged, ADR-020 direction Nebu.OAuth -> Nebu.Web).
- M1 follow-up row `ct` factually wrong for the main SSO path (`armAndContinue` already moves to (4,4)): narrow or delete.
- M2 the Dex-approval probes wait a full 6 s when the browser already moved to /oauth2/consent: race the approval wait against the consent page (pattern in e2e/fixtures/oauth-admin.ts:40-47).
INFO: id `cq` skipped without a note; unscoped Dex probes elsewhere (cs); COOP same-origin kept on consent (cr); UX deltas of the shared script (D6); e2e AC6 statically verified only.
