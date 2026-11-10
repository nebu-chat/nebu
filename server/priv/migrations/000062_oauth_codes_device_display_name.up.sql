-- 000062_oauth_codes_device_display_name.up.sql
-- Story oauth-pages-redesign / 01-device-naming-chain (REQ-2026-016): the device name the user TYPED on the Allow page (asked only when Nebu cannot derive
-- one from the registered client) travels with the authorization code to the token endpoint, which gives it to the device. NULL = nothing typed (the name is
-- derived from the client record as before). Sanitised and bounded to 64 characters by the application before the INSERT; plain text; short-lived (a code lives
-- 60 seconds, kept 24 hours for reuse detection). No new table, no grant or policy change (table-level grants and the row policies of 000041 / 000055 cover it).
ALTER TABLE oauth_codes
    ADD COLUMN IF NOT EXISTS device_display_name TEXT;
