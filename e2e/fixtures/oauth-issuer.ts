/**
 * The OAuth issuer the oauth scenarios switch on (`oauth_issuer_url`).
 *
 * Default: a FAKE https issuer (compared with `iss`, never fetched) on the plain-http compose stack at http://localhost:8008.
 * That works for everything except the consent / account POSTs: Nebu checks their `Origin` against the ISSUER origin
 * (ADR-033 FR8) and a Chromium cannot be made to send a foreign `Origin` (`route.continue({headers: {origin}})` is
 * ignored), so those scenarios answer "This request was refused" unless the browser really uses the issuer's origin.
 *
 * NEBU_E2E_OAUTH_ISSUER=<origin> runs the suite against the https front door of dev/tls (for example
 * https://nebu.localtest.me:7443): the issuer IS the origin of NEBU_BASE_URL / NEBU_ADMIN_URL, the Origin of every POST is
 * right by construction and the header rewrite of the steps is a no-op (same value). CI job `e2e-oauth-https`.
 */
export const E2E_ISSUER = (process.env.NEBU_E2E_OAUTH_ISSUER ?? 'https://nebu.e2e.example').replace(/\/+$/, '');
export const E2E_ISSUER_IS_REAL = process.env.NEBU_E2E_OAUTH_ISSUER !== undefined && process.env.NEBU_E2E_OAUTH_ISSUER !== '';
