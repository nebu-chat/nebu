/**
 * Step definitions for features/admin/stale_rooms.feature
 *
 * Story rm2-stale-room-filter (epic: room-management-elixir) — ATDD, written FIRST.
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "the operator navigates to {string}"
 *
 * RoomsLive is a LiveView master/detail; the list view carries a status filter
 * (all|active|archived|stale) and a per-row status badge:
 *   - badge-warning "Stale"   for active rooms with 0 active members
 *   - badge-success "Active"  for active rooms with members
 *   - badge-ghost   "Archived" for archived rooms
 *
 * A "stale" room is created via the Matrix API (creator joins on create) and then
 * made stale by having the creator LEAVE — leaving 0 active members. No DB seeding.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { NEBU_USERS } from '../../fixtures/users';
import { getApiSession, createRoom } from '../../fixtures/dex-auth';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const MATRIX_BASE = process.env.NEBU_MATRIX_URL ?? 'http://localhost:8008';

let currentRoomName = '';

async function gotoRooms(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.waitForLoadState('networkidle');
}

// The list row for a room, scoped by its visible name.
function roomRow(page: Page, name: string) {
  return page.locator(`tr:has-text("${name}")`).first();
}

// ─── Precondition: a stale room (active + 0 active members) ─────────────────────

Given(
  'a stale room named {string} exists',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    name: string,
  ) => {
    currentRoomName = name;
    const session = await getApiSession(request, NEBU_USERS.kai, browser);
    const { room_id } = await createRoom(request, session.token, name);

    // Make it stale: the creator leaves, dropping active member_count to 0 while the
    // room stays status='active'.
    const resp = await request.post(
      `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(room_id)}/leave`,
      {
        headers: {
          Authorization: `Bearer ${session.token}`,
          'Content-Type': 'application/json',
        },
        data: {},
      },
    );
    if (!resp.ok()) {
      const body = await resp.json().catch(() => ({}));
      throw new Error(
        `[stale-rooms] failed to leave room "${name}" (${room_id}): ${resp.status()} ${JSON.stringify(body)}`,
      );
    }
  },
);

// ─── Filter selection ───────────────────────────────────────────────────────────

When(
  'the operator selects the {string} status filter',
  async ({ page }: { page: Page }, value: string) => {
    await gotoRooms(page);
    // The filter is a <form phx-change> select with data-field="status-filter".
    await page.locator('[data-field="status-filter"]').selectOption(value);
    // LiveView re-renders the list via a DOM diff — let it settle.
    await page.waitForLoadState('networkidle');
  },
);

// ─── Assertion: room listed with a Stale badge ──────────────────────────────────

Then(
  'the room {string} is listed with a {string} badge',
  async ({ page }: { page: Page }, name: string, badgeText: string) => {
    const row = roomRow(page, name);
    await expect(row).toBeVisible({ timeout: 15_000 });
    await expect(row.getByText(badgeText, { exact: false })).toBeVisible({ timeout: 15_000 });
  },
);
