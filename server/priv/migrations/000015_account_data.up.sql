-- 000011_account_data.up.sql
-- Story account-data-durability (epic client-crypto-setup).
--
-- DURABLE per-user GLOBAL account data. Backs:
--   PUT /_matrix/client/v3/user/{userId}/account_data/{type}
--   GET /_matrix/client/v3/user/{userId}/account_data/{type}
-- and the top-level `account_data.events` of GET /_matrix/client/v3/sync.
--
-- Why PostgreSQL (not the previous volatile ETS): Element stores its secret-storage
-- / recovery material in GLOBAL account data — m.secret_storage.default_key,
-- m.secret_storage.key.<id>, and the client-encrypted private cross-signing keys
-- (m.cross_signing.master / .self_signing / .user_signing). If that is lost on a
-- server restart or never delivered via /sync, Element treats recovery as not
-- configured and re-prompts setup. Durability + /sync delivery closes that gap and
-- completes the cross-signing / recovery work (cross-signing-readback left this OUT).
-- PostgreSQL also makes it cluster-correct (ADR-020: a PUT and a later /sync may land
-- on different nodes). ADR-002 (ETS for volatile) does NOT apply — this data is durable.
--
-- content_json holds the account-data value VERBATIM (opaque, ADR-011): for the
-- secret-storage / cross-signing types it is client-encrypted; the server never parses
-- or decrypts it. Stored as TEXT (the exact bytes the client PUT), not jsonb, to
-- guarantee byte-for-byte round-trip.
--
-- `changed` is a consume-once flag (mirrors cross_signing_keys.cross_signing_changed):
-- set TRUE on every PUT; the next INCREMENTAL /sync reads-and-clears the changed rows
-- (UPDATE ... RETURNING) so it delivers only entries changed since the client's `since`
-- token. INITIAL /sync (no since) returns ALL rows and clears their flags.
--
-- All timestamps are BIGINT epoch-millis (schema-wide convention). Idempotent
-- (IF NOT EXISTS) so applying on a fresh or already-migrated instance is harmless.
-- One row per (user_id, type).

CREATE TABLE IF NOT EXISTS account_data (
    user_id      TEXT    NOT NULL,
    type         TEXT    NOT NULL,
    content_json TEXT    NOT NULL,
    changed      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   BIGINT  NOT NULL,
    updated_at   BIGINT  NOT NULL,
    PRIMARY KEY (user_id, type)
);
