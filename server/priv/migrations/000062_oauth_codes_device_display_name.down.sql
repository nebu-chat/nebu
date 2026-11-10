-- 000062_oauth_codes_device_display_name.down.sql
ALTER TABLE oauth_codes
    DROP COLUMN IF EXISTS device_display_name;
