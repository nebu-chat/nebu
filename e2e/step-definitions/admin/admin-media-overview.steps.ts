/**
 * Step definitions for features/admin/admin-media-overview.feature
 *
 * Story: media-security-admin-control/5a-admin-media-table
 *
 * REUSE: the following steps are already defined elsewhere and are
 * intentionally NOT redefined here (Cucumber would error on a duplicate):
 *   - "the Nebu stack is running"          → common/stack-health.steps.ts
 *   - "bootstrap has been completed"       → admin/bootstrap.steps.ts
 *   - "the operator is logged in as admin" → admin/bootstrap.steps.ts
 *   - "the operator navigates to {string}" → admin/bootstrap.steps.ts
 *   - "the page shows {string}"            → admin/bootstrap.steps.ts
 *
 * Media rows are seeded directly via fixtures/db.ts's insertMediaFile (see
 * that module's header comment on the direct-DB-seed mechanism, already
 * approved for scenarios where real black-box traffic cannot deterministically
 * produce the precondition — a genuinely scanned "infected" row requires a
 * real async ClamAV round trip, which is far too slow/nondeterministic here).
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { insertMediaFile, clearMediaFiles } from '../../fixtures/db';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const MEDIA_ID_PREFIX = 'e2e-media-';

function mediaRow(page: Page, mediaId: string) {
  return page.locator(`[data-role="media-row"][data-media-id="${mediaId}"]`);
}

// Fresh per-scenario slate: this suite's own media_files rows never need to
// survive across scenarios, and other scenarios' leftover rows (same prefix)
// would otherwise pollute row-count assertions (e.g. "shows 50 rows").
Given('the media table has no leftover e2e-seeded rows', async () => {
  clearMediaFiles(MEDIA_ID_PREFIX);
});

Given('an infected media file {string} has been seeded', async ({}: object, mediaId: string) => {
  clearMediaFiles(mediaId);
  insertMediaFile({
    mediaId,
    state: 'infected',
    filename: `${mediaId}.exe`,
    clamavSignature: 'Eicar-Test-Signature',
  });
});

Given('a released media file {string} has been seeded', async ({}: object, mediaId: string) => {
  clearMediaFiles(mediaId);
  insertMediaFile({
    mediaId,
    state: 'released',
    filename: `${mediaId}.txt`,
  });
});

Given(
  '{int} released media files sharing uploader {string} have been seeded',
  async ({}: object, count: number, uploader: string) => {
    clearMediaFiles(`${MEDIA_ID_PREFIX}loadmore-`);

    for (let i = 0; i < count; i += 1) {
      insertMediaFile({
        mediaId: `${MEDIA_ID_PREFIX}loadmore-${i}`,
        state: 'released',
        uploaderUserId: `@${uploader}:test.local`,
        filename: `${MEDIA_ID_PREFIX}loadmore-${i}.bin`,
        // Strictly descending uploaded_at so keyset pagination has a stable,
        // deterministic order (each row 1s older than the previous).
        uploadedMsAgo: i * 1000,
      });
    }
  }
);

When(
  'the operator navigates to {string} filtered to uploader {string}',
  async ({ page }: { page: Page }, path: string, uploader: string) => {
    await page.goto(`${ADMIN_BASE_URL}${path}?uploader=${encodeURIComponent(uploader)}`);
    await page.waitForLoadState('networkidle');
  }
);

Then(
  'the media table shows a row for {string} with state {string}',
  async ({ page }: { page: Page }, mediaId: string, stateLabel: string) => {
    const row = mediaRow(page, mediaId);
    await expect(row).toBeVisible({ timeout: 15_000 });
    await expect(row).toContainText(stateLabel);
  }
);

Then('the media table shows a row for {string}', async ({ page }: { page: Page }, mediaId: string) => {
  await expect(mediaRow(page, mediaId)).toBeVisible({ timeout: 15_000 });
});

Then(
  'the media table does not show a row for {string}',
  async ({ page }: { page: Page }, mediaId: string) => {
    await expect(mediaRow(page, mediaId)).toHaveCount(0);
  }
);

When(
  'the operator clicks the {string} state filter pill',
  async ({ page }: { page: Page }, label: string) => {
    await page.getByRole('button', { name: label, exact: true }).click();
    await page.waitForLoadState('networkidle');
  }
);

Then('the media table shows {int} rows', async ({ page }: { page: Page }, count: number) => {
  await expect(page.locator('[data-role="media-row"]')).toHaveCount(count, { timeout: 15_000 });
});

When('the operator clicks {string}', async ({ page }: { page: Page }, buttonText: string) => {
  // Sentinel for the following "no full page navigation occurred" assertion —
  // a real full-page reload/navigation destroys this window property, while a
  // LiveView phx-click round trip (WebSocket/longpoll patch) never does.
  await page.evaluate(() => {
    (window as unknown as { __e2eNoReloadMarker?: boolean }).__e2eNoReloadMarker = true;
  });
  await page.getByRole('button', { name: buttonText, exact: true }).click();
  await page.waitForLoadState('networkidle');
});

Then('no full page navigation occurred', async ({ page }: { page: Page }) => {
  const marker = await page.evaluate(
    () => (window as unknown as { __e2eNoReloadMarker?: boolean }).__e2eNoReloadMarker,
  );
  expect(marker, 'expected the pre-click window marker to survive — a full page reload would clear it').toBe(
    true,
  );
});
