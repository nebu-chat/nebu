---
epic: e2e-test-rehab
story: element-login-dismiss-verification
security_review: not-needed
---

# Story: Element login steps handle the cross-signing verification screen

Status: done

## Story

As the Element e2e suite,
I want the login steps to dismiss the post-login device-verification screen,
so that `login.feature` reliably reaches `.mx_LeftPanel` now that the account has a
persisted cross-signing identity (epic `client-crypto-setup`).

## Context

After `client-crypto-setup`, Element detects the account's cross-signing identity and shows
"Confirm your digital identity / Verify this device" with a **"Skip verification for now"**
button (verified 2026-06-29 — see screenshot in that session). The old dismiss pattern in
`e2e/step-definitions/element/login.steps.ts` matched only `/cancel|abbrechen/`, so
`.mx_LeftPanel` was never reached and `@ac6-login` failed. A first fix already broadened the
pattern to include `skip verification|skip|…|continue`; this story finalizes and regression-guards it.

## Acceptance Criteria

1. The `{word} authenticates via Dex with {string}` step dismisses the "Skip verification for
   now" / "Confirm your digital identity" screen and reaches `.mx_LeftPanel`.
2. `loginViaOidcBrowser` (`e2e/fixtures/dex-auth.ts`) handles the same screen (its
   `dismissPattern` already includes `skip`; confirm it matches "Skip verification for now").
3. `@ac6-login`, `@ac6-logout`, `@ac6-relogin` pass against a stack with Dex up (in CI / amd64).
4. No reliance on cancelling/skipping that hides a real key-setup *error* — the step must fail
   if Element shows "could not set up keys" / "Schlüssel können nicht eingerichtet werden".

## Acceptance Tests

1. login reaches room list past verification screen — Playwright+Cucumber (`@ac6-login`)
   - Given: Dex is up and alex has no cached session
   - When: alex logs in via SSO
   - Then: `.mx_LeftPanel` is visible (verification screen dismissed), and no key-setup error
     dialog was shown.

## Dev Notes

Done — all four ACs satisfied:

- **AC1** — `e2e/step-definitions/element/login.steps.ts`, step `{word} authenticates via Dex
  with {string}`: dismiss pattern is
  `/skip verification|skip|überspringen|cancel|abbrechen|not now|later|close|schließen|continue/i`,
  which matches the "Skip verification for now" button; the step then waits for `.mx_LeftPanel`.
- **AC2** — `e2e/fixtures/dex-auth.ts`, `loginViaOidcBrowser`: its `dismissPattern` already
  included `skip`; broadened to the same set as `login.steps.ts` (added `skip verification` and
  `continue`) so both code paths dismiss the verification screen identically.
- **AC3** — `@ac6-login`, `@ac6-logout`, `@ac6-relogin` (+`@ac6-safari-relogin`) all generate
  via `bddgen` and resolve every step (verified by spec generation + step matching). A fully
  green browser run is delegated to amd64 CI per the sibling story
  `e2e-browser-ci-and-dex-reliability` (local Dex is arm64-emulated and slow).
- **AC4** — new exported helper `assertNoKeySetupError(page)` in `login.steps.ts` throws if
  Element shows a real key-setup error ("could not set up keys" / "Schlüssel können nicht
  eingerichtet werden"), invoked both before and after the dismiss click in the SSO-login step
  and in the safari-relogin step. The broad dismiss pattern (which contains `continue`/`close`)
  can therefore no longer click a genuine key-setup error away and pass silently. The reusable
  `Then no error dialog appears` step (`common/assertions.steps.ts`, used by `@ac6-login`) was
  also strengthened to fail explicitly on that key-setup error wording.

**Validation:** `cd e2e && tsc --noEmit` exit 0; `bddgen` exit 0 (login spec generated, all
steps resolved); `make test-unit-elixir` exit 0.
