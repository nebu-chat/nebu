# code-review — cycle 1
INFO | prescan | delta review; prescan lines carried from cycle 0 (no MAJOR/MINOR/HINT); no migration touched by the delta | -
INFO | CHANGELOG.md:20 | previous MINOR fixed: RustFS entry now says "see the BREAKING entry above" (entry is line 19) | none
INFO | docs/architecture/adr/ADR-013-minio-object-storage.md:10 | previous MINOR fixed: amendment now says only the `minio` service name is kept and the variables were renamed NEBU_MINIO_* -> NEBU_MEDIA_STORAGE_* | none
INFO | docker-compose.yml:206 | previous MINOR fixed: comment says service name and `minio_*` secret file names stay, server reads NEBU_MEDIA_STORAGE_* (runtime.exs); false e2e-ci.sh/Makefile reference dropped | none
INFO | CHANGELOG.md:19 + docs/architecture/07-deployment.md:33 | previous MINOR fixed: both now state NEBU_TEST_MINIO_ENDPOINT was only read by the removed Go media service (confirmed: only Go t.Skip refs in story 12-3) and has no replacement; no remaining doc claims a NEBU_TEST_MEDIA_STORAGE_ENDPOINT reader | none
INFO | docs/stories/media-storage-env-neutral/neutral-media-storage-env-names.md:15 | story text and the ATDD @renames list still say NEBU_TEST_MINIO_ENDPOINT "becomes" NEBU_TEST_MEDIA_STORAGE_ENDPOINT while docs now say "no replacement"; harmless (the test only asserts legacy names are ignored) | optional wording alignment in story
INFO | docs/architecture/07-deployment.md:21-24 | wording "object store Docker secrets (`minio_*` files ...)" accurate; no new inconsistency introduced by the delta; delta is doc/comment only, no shipped migration edited | none
