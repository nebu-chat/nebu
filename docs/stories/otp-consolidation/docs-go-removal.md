---
story_id: docs-go-removal
title: "Documentation Alignment — Remove Go from arc42, publiccode.yml, README, Website"
epic: otp-consolidation
status: done
security_review: not-needed
created: 2026-06-17
branch: feature/otp-consolidation
---

## Summary

The full-elixir-stack migration removed all Go **source**, and `umbrella-to-single-app`
consolidated the Elixir core into one OTP application with `Nebu.Matrix/Media/Admin`
domains. The **documentation still describes a Go gateway + Go media gateway** and a
multi-component / umbrella architecture. This story aligns all human-facing docs with the
single-Elixir-OTP-app reality and removes leftover Go build artefacts.

## User Story

As someone evaluating or contributing to Nebu,
I want every document to describe the actual Elixir-only single-OTP-app architecture,
So that no reader is misled by stale references to Go, a gateway/media split, or an umbrella.

## Scope of Changes

1. **`README.md`** — Tech Stack table (drop "API Gateway: Go", "Media Gateway: Go";
   present one Elixir/OTP app), the architecture ASCII diagram (no Go gateway box; single
   BEAM app with Matrix/Media/Admin), the Erlang/OTP + Go badges, "three runtime components"
   wording, and the Matrix API scope intro.
2. **`publiccode.yml`** — `softwareType`, the de/en `longDescription` "Architektur/Architecture"
   and "Technologie-Stack/Tech Stack" paragraphs (remove "stateless Go-Gateway", "Go 1.26+",
   "gRPC (protobuf)" if gRPC is removed), `features`, and any platform/dependency lines that
   imply Go.
3. **arc42 docs** under `docs/architecture/` (and `_bmad-output/.../arc42` if generated) —
   building-block view, runtime view, deployment view, and tech-stack/quality sections that
   describe Go or the gateway↔core gRPC hop. Run `/bmad-maintain-arc42` or edit directly.
4. **Website** under `website/` — any stack/architecture page mentioning Go, the gateway, or
   the three-binary model.
5. **`CLAUDE.md`** (project root) — Tech Stack table, Architecture section, directory
   structure, and the Matrix-scope notes; adopt the consolidated `Nebu.Matrix/Media/Admin`
   structure and the no-umbrella + Public-API conventions. Commit the proposal's
   **`ARCHITECTURE.md`** at the repo root, adapted to the real resulting module names.
6. **ADR housekeeping** — add **ADR-021 (Elixir Consolidation / Go Removal)** formalizing the
   Go→Elixir decision; mark **ADR-005 (gRPC EventBus)** superseded/obsolete if the vestigial
   gRPC layer is removed (see below).
7. **Artefact cleanup** — delete the stale **untracked** `gateway/` and `media/` directories
   (leftover compiled binaries + `node_modules`; no Go source, not git-tracked).
8. **Vestigial gRPC investigation** — the gRPC EventBus + `NodeRegistration` existed for the
   Go gateway ↔ Elixir core hop. With the Matrix HTTP router now calling OTP functions
   directly in-process (no gRPC hop), confirm whether the gRPC server / proto stubs are dead.
   If dead: remove them and update ADR-005. If still referenced: leave in place and document why.

## Acceptance Criteria

1. **Given** `README.md`, **When** searched, **Then** no line presents Go as part of the stack (no "Go 1.26+", no "Go gateway/media" component, no Go badge) and the architecture diagram shows a single Elixir/OTP application.
2. **Given** `publiccode.yml`, **When** searched, **Then** the de + en descriptions and `features` describe an Elixir/OTP single application with no Go and no contradicting "three runtime components" / gateway wording.
3. **Given** the arc42 documentation, **When** reviewed, **Then** the building-block, runtime, and deployment views describe the single OTP app (Matrix/Media/Admin namespaces) with no Go gateway and no gateway↔core gRPC hop (unless gRPC is retained, in which case its real remaining purpose is documented).
4. **Given** the `website/` content, **When** searched, **Then** no page advertises Go or the multi-binary gateway model.
5. **Given** `CLAUDE.md`, **When** read, **Then** the Tech Stack, Architecture, and directory-structure sections match ADR-019/ADR-020 (single OTP app, `lib/nebu/{matrix,media,admin,web,compliance}`, no umbrella, Public-API rule), and a root `ARCHITECTURE.md` exists describing the real module layout.
6. **Given** the repository root, **When** inspected, **Then** the stale `gateway/` and `media/` artefact directories are gone and `.gitignore` still ignores build output.
7. **Given** the gRPC investigation, **When** complete, **Then** either the vestigial gRPC/NodeRegistration code is removed (with ADR-005 updated and `make build-core` + `make test-unit-elixir` still green) or a one-paragraph justification for keeping it is recorded.
8. **Given** the repository, **When** `find . -name "*.go" -not -path "*/vendor/*"` is run, **Then** the output is empty (regression guard — confirms no Go source reintroduced).

## Acceptance Tests

This is a documentation + dead-artefact story with no new runtime behavior, so per the
project gate it does not require ATDD. Verification is by inspection plus:

1. **Doc-grep guard** — shell
   - Given: the repo after edits.
   - When: `grep -rni "\bGo 1\.\|go gateway\|go-based\|gateway (go)\|umbrella" README.md publiccode.yml docs/architecture website/` (allowing legitimate "Horde"/"Golang-migrate-history" mentions to be reviewed by hand).
   - Then: no hit describes Go as a current stack component or an umbrella as the current structure.

2. **Build stays green if gRPC removed** — ExUnit (`make build-core` + `make test-unit-elixir`)
   - Given: the code after any gRPC/NodeRegistration removal.
   - When: compile + unit suite run.
   - Then: both pass (only needed if AC#7 takes the removal path).

3. **No Go source regression** — shell
   - Given: the repo.
   - When: `find . -name "*.go" -not -path "*/vendor/*"`.
   - Then: empty output.

## Implementation Notes

- Depends on `umbrella-to-single-app` being merged/committed first (docs must describe the
  final module names).
- `golang-migrate` history: migrations are now owned by `Nebu.Release.migrate/0` — README's
  "Migrations: golang-migrate" row must change to Ecto migrations. Do not claim Go tooling.
- Keep "no Redis / no NATS / no Kafka" and "no federation / no E2EE by design" messaging —
  those are still true and are differentiators.
- The website may be a static site generator — check `website/` build before/after.
