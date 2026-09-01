# ATDD Summary — 11c-s3-key-prefix-template

Test count added: 13
- server/test/nebu/media/key_prefix_template_test.exs (new, 12 tests): AT1-AT6, AT10, AT11 + adapted AT8/AT9
- server/test/nebu/media/storage_config_test.exs (extended, +1 test 11c-AT7)

RED confirmed: make test-unit-elixir compile aborted (--warnings-as-errors) naming
Nebu.Media.StorageConfig.compute_key/2 and validate_template/1 as undefined across
all 12 call sites in the new file — compile-time abort, strongest possible RED signal,
not an assertion-logic failure.

Caveat: 11c-AT7 in storage_config_test.exs would fail with MatchError in isolation
(upsert/1 exists, only validate_template/1 inside it is missing) — documented inline.

Scope adaptation (mirrors 9c-mime-denylist-enforcement pattern, since Story 2b's
async PUT/store_and_quarantine seam has not landed — server/lib/nebu/media.ex still
only has the deprecated flat-media_id v3 upload/1 handler):
- AT8 adapted to prove compute_key/2 produces the exact interpolated key Story 2b's
  seam would pass to Storage.put/2.
- AT9 adapted to prove compute_key/2's purity/determinism: template A -> key1,
  template B -> key2 (different), re-derive template A -> key1 again (byte-identical).
  This is the property Story 2b's real integration test will rely on once it lands.

No implementation code written in server/lib/.
