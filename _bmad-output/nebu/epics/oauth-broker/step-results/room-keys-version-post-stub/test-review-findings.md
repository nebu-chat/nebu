# test-review room-keys-version-post-stub (pre-dev, nebu-test-reviewer, 2026-10-15)
0 MAJOR after fix, 1 MAJOR + 4 MINOR + 4 INFO found, all applied before dev:
- MAJOR-1 (vacuous): the bad-token test accepted M_MISSING_TOKEN -> now exactly M_UNKNOWN_TOKEN, plus a JWT-shaped garbage token case.
- MINOR-2 "nothing stored" only implicit -> `@tag :no_repo` + `Process.whereis(Nebu.Repo) == nil` (DB-free environment as proof).
- MINOR-3 -> fall-through test also anonymous and checks status in [404, 405]; MINOR-4 -> 405 `Allow: GET, POST` rows for PUT / DELETE room_keys/version in the method table.
- MINOR-5 body behaviour -> story D5 (stub ignores the body) + tests with an empty and a malformed body.
