# Test Review — server/test/nebu/media/media_compression_test.exs (Story 12, media-security-admin-control)

Verified independently: `server/lib/nebu/media/storage.ex` exists but has no `compress` function (correct RED precondition), `:oban` is absent from `server/mix.exs`/`mix.lock`, `server/lib/nebu/workers/` and `Nebu.Media.ClamAV` do not exist — the moduledoc's grounding claims about Story 4b/Oban all check out against the actual tree. Also confirmed empirically that the tie-case fixture search is not vacuous: `byte_size(:zlib.gzip(String.duplicate("a", 23))) == 23` — a genuine, deterministic tie exists in the 1..2000 search space.

## AC coverage (AC1/AC2/AC3/AC6/AC7 required, AC4/AC5 correctly out of scope per story's own Technical Requirements)

| AC | Coverage | Notes |
|---|---|---|
| AC1 | OK | Every test pattern-matches `{bytes, compressed?}` from `Storage.compress/1` |
| AC2 | OK | Test 1 asserts `bytes == :zlib.gzip(@json_fixture)` directly — proves no custom level/dictionary tuning |
| AC3 | OK | Tests 2 (random/incompressible), 3 (2MB high-entropy), 4 (tie), 5 (empty) — all four branches of the strict `<` comparison |
| AC6 | OK | Test 6 round-trips via `:zlib.gunzip/1` directly (the same primitive `maybe_gunzip/2` calls) — proves standard gzip-format compatibility |
| AC7 | OK | Tests 6 (3 fixture shapes: repeated text, JSON, synthetic log) + 7 (random/incompressible) cover both branches across multiple file-type shapes |

## Quality checks

- No hard waits, no `Process.sleep`, `async: true` correctly used (pure functions, no shared state).
- Tie-case test (AC3) is well-constructed, not vacuous or flaky: searches `1..2000` for an actual tie, uses `refute is_nil(...)` with a descriptive failure message. Independently verified a genuine tie exists at n=23.
- Empty-input case (AC3) genuinely tested, including sanity pre-check that `:zlib.gzip("")` really produces >0 bytes.
- Random-byte tests (2, 3) non-deterministic in principle but test 2 includes an explicit fixture-sanity assertion; test 3 (2MB) omits it — MINOR, negligible risk.
- Round-trip coverage for AC7 adequate: distinct fixture shapes, both branches, exact byte-identity assertions.

## Tests 8/9 deviation (skip + flunk, documented in moduledoc)

Judged reasonable, **not a MAJOR gap**:
1. Absence of `Nebu.Workers.MediaScanWorker`, `Nebu.Media.ClamAV`, and `:oban` independently verified — story's own claim that 4b is "a landed dependency" is factually wrong for this repo state.
2. Writing tests 8/9 literally would raise a CompileError killing the entire file (losing AC1/2/3/6/7 coverage) — strictly worse than a scoped skip.
3. AC6's core byte-compatibility claim is already substantively proven at unit level (test 6 calls `:zlib.gunzip/1` directly — the exact primitive `maybe_gunzip/2` invokes).
4. Skips are named, tagged, and each `flunk/1` documents the exact fixture/assertion for Story 4b's dev-story to implement.

**INFO (non-blocking):** Recommend Story 4b's dev-story checklist explicitly include "un-skip and implement tests 8/9 in media_compression_test.exs".

## Verdict: CLEAN (0 MAJOR)

Tests 8/9 skip+flunk deviation does not count as MAJOR — justified, well-documented engineering call given verified absence of the Story 4b/Oban dependency; does not weaken coverage of any in-scope AC. Story 12's test file is ready to proceed to dev-story.
