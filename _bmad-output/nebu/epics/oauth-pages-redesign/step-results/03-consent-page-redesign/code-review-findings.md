# code-review — cycle 1
INFO | review-prescan.md | prescan reported no MAJOR/MINOR/HINT lines | none
INFO | server/lib/nebu/oauth/consent_page.ex:269 | previous MINOR (device-name-label id hook) fixed | none
INFO | server/lib/nebu/web/page_text.ex:155 | previous MINOR (EN consent.noscript phrase) fixed, DE aligned; test oauth_consent_page_test.exs:508 updated consistently | none
INFO | e2e/step-definitions/oauth/consent-page-redesign.steps.ts:414 | previous MINOR (hard wait) addressed via waitForRequest(...).catch; still a bounded 1s window since no POST is expected, and the real assertion is the noJsDecisionPosts counter registered at :409 (listener predates click, no race) | none
MINOR | e2e/step-definitions/oauth/consent-page-redesign.steps.ts:212 | previous MINOR still open: requireFreshness skips scenarios 1/2/3 via $testInfo.skip when Dex yields no matching data-fresh variant, so the fresh-login AC could be silently unexercised | settle which variant Dex yields and fail instead of skip (or defer to follow-ups)
INFO | delta | no new problems introduced by the fixes (one-line id attr, copy text, test expectation, e2e wait); no ADR-018/020 or cluster-safety concerns | none
