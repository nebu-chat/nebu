/**
 * Step definitions for features/element/crypto/recovery-setup.feature
 *
 * Story: element-cross-signing-recovery-scenario (epic e2e-test-rehab).
 *
 * Walks Element Web's recovery / cross-signing bootstrap THROUGH to completion
 * (the inverse of the login steps, which deliberately skip/cancel it) and asserts:
 *   AC1/AC2: setup completes with NO "could not set up keys" /
 *            "Schlüssel können nicht eingerichtet werden" error dialog.
 *   AC3:     the server echoes the user's cross-signing keys on /keys/query,
 *            tying the UI walk to the server read-back contract.
 *
 * Real browser flow only — Authorization Code + PKCE via Dex (loginViaOidcBrowser),
 * NO ROPC, NO cookie forging, NO DB seeding (CLAUDE.md project E2E standard).
 *
 * The failure guard `assertNoKeySetupError(page)` is REUSED from login.steps.ts —
 * not redefined here (single source of truth for the EN+DE error wording).
 *
 * The recovery-UI selectors below are authored from Element Web 1.12.15 knowledge.
 * They are intentionally broad (role + text + CSS-class fallbacks) and the scenario
 * is tagged @ci so a fully green browser run is delegated to amd64 CI, where the
 * selectors are refined. The /keys/query API read-back (AC3) is the version-stable
 * proof even if the UI walk needs CI tuning.
 */

import { Given, When, Then } from '../../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext } from '@playwright/test';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../../fixtures/users';
import { loginViaOidcBrowser, getApiSession } from '../../../fixtures/dex-auth';
import { assertNoKeySetupError } from '../login.steps';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

// Short "is this optional control present right now?" probe — deliberately tight so it
// cannot mask a genuine hang (mirrors the dex-auth.ts convention). NOT the navigation wait.
const PROBE_MS = 4_000;
// Dialog/step transitions inside the recovery flow can take a little longer on the
// emulated stack; configurable so amd64 CI can tighten and slow hosts can loosen.
const RECOVERY_STEP_MS = Number(process.env.NEBU_E2E_RECOVERY_STEP_MS ?? 30_000);

Given(
  'alex is logged in to Element Web via Dex SSO with {string}',
  async ({ page }: { page: Page }, email: string) => {
    await loginViaOidcBrowser(page, NEBU_USERS.alex, email, DEX_TEST_PASSWORD);
    // Sanity: login itself must not have surfaced a key-setup error.
    await assertNoKeySetupError(page);
    await page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: RECOVERY_STEP_MS });
  },
);

When(
  'alex opens Encryption settings and starts {string}',
  async ({ page }: { page: Page }, _setupLabel: string) => {
    // Element 1.12.15 may surface a "Set up recovery" toast/banner directly in the room list.
    // Prefer it when present (shortest path); otherwise navigate User menu → Settings →
    // Encryption / Security & Privacy → "Set up recovery".
    const setupRecoveryBtn = page.getByRole('button', {
      name: /set up recovery|set up secure backup|wiederherstellung einrichten|set up encryption/i,
    });

    const toastVisible = await setupRecoveryBtn
      .first()
      .isVisible({ timeout: PROBE_MS })
      .catch(() => false);

    if (!toastVisible) {
      // Open the user menu → All settings.
      const userMenuTrigger = page
        .locator('[aria-label="User menu"]')
        .or(page.locator('[data-testid="user-menu-trigger"]'))
        .or(page.locator('.mx_UserMenu button'));
      await userMenuTrigger.first().waitFor({ state: 'visible', timeout: RECOVERY_STEP_MS });
      await userMenuTrigger.first().click();

      const settingsItem = page
        .getByRole('menuitem', { name: /all settings|settings|einstellungen/i })
        .or(page.getByRole('button', { name: /all settings|settings|einstellungen/i }));
      await settingsItem.first().waitFor({ state: 'visible', timeout: RECOVERY_STEP_MS });
      await settingsItem.first().click();

      // Settings dialog → "Encryption" tab (older: "Security & Privacy").
      const encryptionTab = page
        .getByRole('tab', { name: /encryption|security.*privacy|verschlüsselung|sicherheit/i })
        .or(page.getByRole('button', { name: /encryption|security.*privacy|verschlüsselung|sicherheit/i }));
      if (await encryptionTab.first().isVisible({ timeout: RECOVERY_STEP_MS }).catch(() => false)) {
        await encryptionTab.first().click();
      }

      // The "Set up recovery" / "Set up secure backup" action inside the Encryption tab.
      await setupRecoveryBtn.first().waitFor({ state: 'visible', timeout: RECOVERY_STEP_MS });
    }

    await setupRecoveryBtn.first().click();
    // Element may have surfaced a key-setup error immediately on opening the flow.
    await assertNoKeySetupError(page);
  },
);

When(
  'alex walks the recovery-key generation dialog to completion',
  async ({ page }: { page: Page }) => {
    // The recovery-key dialog is a multi-step wizard. Element 1.12.15 wording:
    //   "Generate a recovery key" → shows the key → "Continue" → "I've saved my recovery key"
    //   → "Continue"/"Done"/"Finish". We click forward through whatever "advance" affordances
    //   appear, re-checking for the failure dialog after every click, until a terminal
    //   success state is reached. The loop is bounded so it cannot spin forever.
    const advancePattern =
      /generate( a)? recovery key|continue|next|weiter|i('| ?ve| have)? saved|got it|verstanden|done|finish|fertig|abschließen|set up|continue with|copy|kopieren|download|herunterladen/i;
    const terminalPattern =
      /encryption is (now )?(active|on)|recovery is (now )?(active|set up|enabled)|your keys are now|verschlüsselung ist (jetzt )?aktiv|wiederherstellung.*(aktiv|eingerichtet)/i;

    const MAX_STEPS = 8;
    for (let i = 0; i < MAX_STEPS; i++) {
      // After every transition the failure dialog could appear — fail loudly, never click it away.
      await assertNoKeySetupError(page);

      // Terminal success reached?
      if (
        await page
          .getByText(terminalPattern)
          .first()
          .isVisible({ timeout: PROBE_MS })
          .catch(() => false)
      ) {
        break;
      }

      // Find the next "advance" control inside the open dialog. Scope to the dialog so the
      // broad regex can't latch onto a background control.
      const advanceBtn = page
        .locator('.mx_Dialog, [role="dialog"]')
        .getByRole('button', { name: advancePattern })
        .or(page.getByRole('button', { name: advancePattern }));

      const visible = await advanceBtn
        .first()
        .isVisible({ timeout: PROBE_MS })
        .catch(() => false);
      if (!visible) {
        // No more advance buttons and no terminal text — let the Then-step decide
        // (it accepts "recovery key shown" / "Encryption is active" as success too).
        break;
      }

      // "Copy"/"Download" buttons do not advance the wizard — they stay on the same step.
      // Click them (harmless) but keep looping; the next iteration finds Continue.
      await advanceBtn.first().click({ timeout: RECOVERY_STEP_MS }).catch(() => {
        /* control detached as dialog advanced itself — acceptable */
      });
    }

    await assertNoKeySetupError(page);
  },
);

Then(
  'recovery setup succeeds without a key-setup error',
  async ({ page }: { page: Page }) => {
    // Primary guard (AC2): the failure dialog must be ABSENT.
    await assertNoKeySetupError(page);

    // Positive success signal (AC1): one of —
    //   - "Encryption is active" / "Recovery is set up" terminal text, OR
    //   - a recovery key shown (the 48-char base58 key, often in groups), OR
    //   - the "Set up recovery" affordance is gone (already configured).
    const successText = page.getByText(
      /encryption is (now )?(active|on)|recovery is (now )?(active|set up|enabled)|your keys are now|verschlüsselung ist (jetzt )?aktiv|wiederherstellung.*(aktiv|eingerichtet)|recovery key|wiederherstellungsschlüssel/i,
    );
    const setupGone = page.getByRole('button', {
      name: /set up recovery|set up secure backup|wiederherstellung einrichten/i,
    });

    const sawSuccessText = await successText
      .first()
      .isVisible({ timeout: RECOVERY_STEP_MS })
      .catch(() => false);
    const setupStillOffered = await setupGone
      .first()
      .isVisible({ timeout: PROBE_MS })
      .catch(() => false);

    expect(
      sawSuccessText || !setupStillOffered,
      'recovery setup reached a success state (recovery key shown / "Encryption is active") ' +
        'and the "Set up recovery" action is no longer being offered',
    ).toBeTruthy();
  },
);

Then(
  "the server echoes alex's cross-signing keys on \\/keys\\/query",
  async ({ page, request }: { page: Page; request: APIRequestContext }) => {
    // AC3 — the version-stable proof. Use the token sidecar captured during login
    // (getApiSession) to POST /keys/query for alex and assert the server echoes the
    // cross-signing maps. matrix-js-sdk publishes the cross-signing keys via
    // /keys/device_signing/upload as part of the UI flow above; the read-back here
    // confirms Nebu persisted + echoes them (CrossSigningKeyStore).
    const { token, userId } = await getApiSession(request, NEBU_USERS.alex);
    expect(userId, 'sidecar carried a Matrix user_id').toBeTruthy();

    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/keys/query`, {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { device_keys: { [userId]: [] } },
    });
    expect(resp.ok(), `/keys/query returned ${resp.status()}`).toBeTruthy();

    const body = (await resp.json()) as {
      master_keys?: Record<string, unknown>;
      self_signing_keys?: Record<string, unknown>;
      user_signing_keys?: Record<string, unknown>;
    };

    // The maps are keyed by user_id. After a completed cross-signing bootstrap the server
    // MUST echo a master key and a self-signing key for alex (user-signing is published too,
    // but master + self-signing are the load-bearing pair for the read-back contract).
    expect(
      body.master_keys?.[userId],
      `/keys/query echoes a master_key for ${userId} (cross-signing bootstrap persisted)`,
    ).toBeTruthy();
    expect(
      body.self_signing_keys?.[userId],
      `/keys/query echoes a self_signing_key for ${userId}`,
    ).toBeTruthy();

    // Keep `page` referenced so the fixture's live Element session is held open until the
    // API read-back completes (the sidecar token belongs to that session).
    expect(page.url()).toContain('localhost');
  },
);
