## Session — matrix-spec-gaps / media-download-content-type-and-filename

**Scope:** staged diff, Content-Type passthrough + spec inline list + filename persistence/Content-Disposition + thumbnail allowlist. Replaces the Epic-12 HIGH-3 octet-stream model.

**Finding summary:** 0 CRITICAL, 0 HIGH, 1 MEDIUM, 2 LOW, 3 INFO. APPROVED/CLEAN.
Report: docs/stories/matrix-spec-gaps/security-reports/media-download-content-type-and-filename-security-review-2026-10-08.md

**New patterns discovered:** passthrough-type model needs category-based neutralization (+xml, JS MIME family); sufficiency rests on Bearer-only media auth (OidcPlug only takes the Authorization header). Admin UI is same-origin with script-src 'self', a latent gadget if media ever becomes unauthenticated or query-token authenticated.

**Accepted risks this session:** none formally; the Epic-12 HIGH-3 model change is documented in the story.

**Follow-up:** F-1 neutralize by category; F-2 strip bidi/Cf in filenames (+admin display); F-3 cap filename length (2b watch-flag: escaping now closed, length not). Watch-flag: any media-auth change re-triggers review.
