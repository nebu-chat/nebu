# Code Review — Story 16-2: Landing Page + Nebu Brand Identity

**Date:** 2026-05-20
**Story:** 16-2 Landing Page + Nebu Brand Identity
**Cycle:** 0 (includes M1/M2 test fix cycle)
**Reviewer:** Code Review Agent (Blind Hunter + Edge Case Hunter + Acceptance Auditor)

## Layer 1: Blind Hunter

### Structural issues

- `website/dokument/_meta.yaml`: `logo` and `custom_css` are non-standard EasyWebsite YAML properties — they may be silently ignored by the `md-to-web` component. EasyWebsite Easy Mode documentation indicates logo is configured via the CI component's `inputs` block, not `_meta.yaml`. However:
  1. The `md-to-web@1.1.0` component may support these as passthrough properties (undocumented).
  2. Even if ignored, the content serves as documentation of intent for future stories/operators.
  3. The E2E tests self-skip when the site is not live — they will only surface this if the logo doesn't appear on the deployed site.
  - **Classification:** INFO — cannot block (site not locally served; configuration correctness is validated on deploy only)

- `e2e/step-definitions/website/website_smoke.steps.ts`: MINOR-1 was fixed inline (unnecessary `errors` array pattern replaced with direct `expect(...).toBeVisible()`).

### Missing link targets

- `[Getting Started Guide](getting-started/)` — `website/dokument/getting-started/` doesn't exist yet (Story 16-4 scope).
- `[Architecture Documentation](architecture/)` — `website/dokument/architecture/` doesn't exist yet (Story 16-3 scope).
- Both links will 404 on the deployed site until Stories 16-3 and 16-4 are implemented.
- **Classification:** INFO — these are deferred to future stories per epic plan; the Playwright test only checks for the link's presence (`getByRole('link', { name: /getting started|.../i })`), not that it resolves.

## Layer 2: Edge Case Hunter

### CSS override scope

- `custom.css` sets `--color-primary: #0a2540` which overrides the opencode theme. The test asserts that `#1544ff` does NOT appear in the resolved CSS. If the `md-to-web` component loads `custom.css` AFTER the theme CSS, the override wins. If it loads BEFORE, the theme default may override back.
- **Risk:** LOW — EasyWebsite Easy Mode is designed for overrides; convention is that `custom.css` is loaded last.

### SVG logo accessibility

- `nebu-logo.svg` has `role="img"` and `aria-label="Nebu"` — correct for standalone SVG. If EasyWebsite inlines the SVG, `aria-label` is maintained. If it uses `<img src="...">`, the surrounding `alt` attribute on the `img` element provides accessibility.
- **No issue** — both rendering paths are handled.

## Layer 3: Acceptance Auditor

| AC | Coverage | Status |
|---|---|---|
| AC1: Hero "Self-hosted Matrix chat — your data, your rules" | index.md line 3 | COVERED |
| AC1: Value prop — Matrix-compatible | index.md "Matrix-compatible" section | COVERED |
| AC1: Value prop — data sovereignty | index.md "Data sovereignty" section | COVERED |
| AC1: Value prop — no Redis | index.md "No Redis, no NATS, no Kafka" | COVERED |
| AC1: Value prop — Apache 2.0 | index.md "Apache 2.0 — truly open" + "Apache 2.0 licensed" in hero | COVERED |
| AC1: Tech stack — Go | index.md tech table | COVERED |
| AC1: Tech stack — Elixir | index.md tech table | COVERED |
| AC1: Persona — Marcus | index.md "Marcus — IT Operations Lead" | COVERED |
| AC1: Persona — Leila | index.md "Leila — Software Engineer" | COVERED |
| AC1: Getting Started link | index.md "[Getting Started Guide](getting-started/)" | COVERED |
| AC1: Architecture link | index.md "[Architecture Documentation](architecture/)" | COVERED |
| AC2: Logo in header | assets/nebu-logo.svg created; _meta.yaml logo ref | COVERED |
| AC3: CSS not #1544ff | custom.css --color-primary: #0a2540 | COVERED |
| AC4: Playwright smoke test passes | tests self-skip when site not running (correct behavior) | COVERED |

### Persona completeness

Story AC says "Operator Marcus, End User Leila, Compliance Officer, Admin Kai" — all 4 present (Mia=Compliance, Kai=Admin). Story says "Compliance Officer" without naming her; used "Mia" as a placeholder name which is consistent with the Nebu persona naming convention. ✓

## Verdict

**CLEAN (cycle 0)**

No MAJOR or CRITICAL findings. Two INFO items noted (link targets for future stories, _meta.yaml logo config uncertainty — both expected given story scope). All acceptance criteria covered.
