# Known failing e2e scenarios (`@known-failure`)

Scenarios tagged `@known-failure` fail for a documented reason that is not (yet) a verified defect of the code under test, or are the red regression test of an open bug. They are
excluded from the default tag expression (`e2e/playwright.config.ts`), so the CI jobs `e2e-element-web`, `e2e-admin-ui` and `e2e-oauth-https` are meaningful: a red scenario is a new finding.
They are never silent: this file lists them, the feature files carry the tag with the reason in a comment, and `NEBU_E2E_TAGS='@known-failure' npx playwright test` runs exactly these.
Remove the tag when the cause is fixed (the scenario then joins the default run).

Status of the last complete run (isolated FRESH stack, plain http, 2026-10-19, Playwright 1.59, Chromium headless shell; log in `_bmad-output/nebu/epics/oauth-broker/step-results/member-event-prev-content/e2e-runA.log`): project `element-web`: 26 passed, 0 failed (13.9 min), including the DM invitee scenario with its `m.direct` assertion (K10 fixed by story member-event-prev-content). Excluded as `@known-failure`: K9 (Element UI start-DM selectors). The `admin-ui` project (without the OAuth groups) was last run in full on 2026-10-15: 133 passed, 4 skipped, 0 failed; the OAuth groups need the https stack (62 passed, 5 skipped, 0 failed on 2026-10-15).

| Id | Scenario | Cause (status) |
|---|---|---|
| K1 | `legacy-sso-redirect-confirmation` "Continue on a touch device", `oauth-consent` "Allow on a touch device" | the tap dispatched through CDP `Input.dispatchTouchEvent` does not submit the form in the Playwright Chromium (headless shell); UNVERIFIED whether the arming script (`Nebu.Web.ArmScript`, touch path) or the test is at fault: needs a real touch device / browser check (07-deployment, manual group D) |
| K2 | `legacy-sso-redirect-confirmation` "A click without moving onto Continue after arming does not submit" | after the blocked stationary click the live region `[data-arm-status]` stays empty (hidden); UNVERIFIED page or test |
| K3 | `admin-media-overview` "A state-filter pill click narrows the visible rows" | one row too many after the filter; identical on the baseline before the oauth-broker stories |
| K4 | `admin-media-overview` "Weitere laden appends more rows" | 50 instead of 55 rows after the click; identical on the baseline |
| K5 | `war-room-dedicated-page` empty-state placeholder | the test expects the text to mention `/admin/logs`; the UI text does not (stale expectation) |
| K6 | `create_room` "An admin-created room shows its name and an Active status" | the rooms list shows the raw room id (known unit family `RoomsFallbackNameTest`, same cause) |
| K7 | `crypto/recovery-setup` "alex sets up recovery to completion" | Element 1.12.15 leaves the "Quick settings" context menu open, it intercepts the click on "All settings" (test step vs Element version) |
| K9 | `dm/create-dm` "Starting a DM in Element Web invites the partner server-side" (@dm-create-ui) | the Element UI selectors of the step (Start chat dialog, `.mx_InviteDialog_tile` for the typed Matrix id) are UNVERIFIED against Element 1.12.15: in the first real run (2026-10-16, story create-room-invites-direct) the invite tile never appeared within 20 s (Nebu has no `/user_directory/search` route; Element 1.12.15 may render the typed-id suggestion with other classes). The API scenario of the same feature passed and is the regression guard; needs a selector pass against a real Element |
| K13 | `room/membership-state` "The People panel and the room settings show the invited and the banned user after a fresh login" (@membership-state-ui) | the UI steps never opened the People panel: in the first real run (2026-10-20, story membership-state-model) Element 1.12.15 showed the room-info panel with the "People" entry but the step expected the member list already open, so the "Invited" section was not found within 30 s; the room, the `/members` answer and the sync were fine (Scenario 1, the API guard of the same feature, passed). The room-info navigation selectors (header button, "People" entry, "Roles & Permissions" tab) are UNVERIFIED against Element 1.12.15; needs a selector pass against a real Element |

## K8 was not a server bug (2026-10-16, follow-up `dx`, story create-room-initial-state-conformance)

`spaces/create-room-in-space` "A room created inside a Space via Element Web is linked to the Space server-side" was tagged `@known-failure` as "createRoom ignores `initial_state`". The server DOES apply
`initial_state` (the API scenario next to it passed in the same run): the UI scenario compared the canonical ALIAS Element shows in its URL (`#/room/#name:localhost`, Nebu derives an alias from the room name)
with the `m.space.parent` state_key and looked the "room id" up in `/sync` (keyed by room id). The step now resolves aliases to room ids (`room_summary`); the scenario is in the default run again.

## K10 was a server gap (2026-10-19, follow-up `ff`, story member-event-prev-content)

`dm/create-dm` "marie sees the DM invitation in Element and accepts it" (@dm-invitee-ui) passed the invitation tile and the join but Element never wrote the invitee's `m.direct`. Element 1.12.15 writes it only
through `RoomMember.getDMInviter()` on the invitee's own JOIN event, which reads `unsigned.prev_content` (`membership: invite`, `is_direct: true`) and `unsigned.prev_sender`; Nebu sent neither. State events now carry
both next to `replaces_state` (one batched predecessor lookup); the scenario is in the default run again and its `m.direct` assertion was never weakened.

## What the 2026-10-15 CI work found and fixed in the e2e setup (not known failures any more)

- **"Unable to set up keys" at the first Element login (34 failures in the first run were attributed to it): a SERVER gap.** `POST /_matrix/client/v3/room_keys/version` (Element creates a key backup right after the
  cross-signing bootstrap of a user's first login) answered 404 on `main` and 405 M_UNRECOGNIZED on this branch; the Go gateway had an acceptance stub that the Elixir migration dropped. Fixed in the server (story
  `room-keys-version-post-stub`).
- **Matrix users alex / marie / kai did not exist: an e2e SETUP gap.** Without the OIDC scope `profile` the IdP token carries no `name`, Nebu derives the Matrix localpart from the opaque `sub`
  (`@ciqw...:localhost`) instead of `@alex:localhost` (OIDC Scopes Law: nothing is requested unless configured). The bootstrap fixture now sets the Matrix client scopes `profile email`,
  `global-setup.ts` sets them on an already bootstrapped stack that has none.
- **Element asks twice before the room list** ("Skip verification for now", then "I'll verify later"): `fixtures/dismiss-prompts.ts`.
- **OAuth scenarios (42 failures):** (a) Playwright calls `page.route` only for the FIRST request of a redirect chain, so the client redirect targets (`https://app.e2e.example/cb`, `http://localhost:53682/cb`)
  were never intercepted: `fixtures/client-stubs.ts` answers them with local stub servers; (b) the consent / account POSTs check their `Origin` against the issuer origin and Chromium ignores an overridden `Origin`:
  the https job uses the real origin as the issuer (`fixtures/oauth-issuer.ts`); (c) `__Host-` cookies need `url` for `addCookies`; (d) the issuer must be preset for the DCR scenarios; (e) one assertion compared the
  whole page URL (whose query legitimately contains the rejected redirect_uri).
