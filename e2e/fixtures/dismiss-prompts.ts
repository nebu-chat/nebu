import type { Locator, Page } from '@playwright/test';

/**
 * Element Web (1.12.x) asks twice before it lets a user without a verified device in: "Confirm your digital identity"
 * (button "Skip verification for now") and then "Are you sure?" (button "I'll verify later"). A single click leaves the
 * second prompt on screen and `.mx_LeftPanel` never appears. Clicks the dismiss button of every prompt in turn, at most
 * `maxClicks` times, and stops as soon as the room list is there or no dismiss button shows up.
 */
export async function dismissVerificationPrompts(page: Page, dismissPattern: RegExp, maxClicks = 3): Promise<void> {
  for (let i = 0; i < maxClicks; i++) {
    const panel: Locator = page.locator('.mx_LeftPanel');
    if (await panel.isVisible().catch(() => false)) return;
    const btn = page.getByRole('button', { name: dismissPattern }).first();
    if (!(await btn.isVisible({ timeout: 3_000 }).catch(() => false))) return;
    await btn.click({ timeout: 5_000 }).catch(() => { /* the prompt closed itself before the click landed */ });
    await page.waitForTimeout(500);
  }
}
