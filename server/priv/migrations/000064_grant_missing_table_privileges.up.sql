-- Fix: the runtime role nebu_app has no DML privileges on five tables.
--
-- Migration 000001 ends with a blanket GRANT on ALL TABLES, but that only covers
-- tables existing at that moment. 000014 (cross_signing_keys), 000015 (account_data),
-- 000017 (operational_logs), 000019 (war_room_sessions) and 000020
-- (admin_temporary_captures) created tables without granting nebu_app. On managed
-- PostgreSQL with dual roles (nebu_migrate migrates, nebu_app runs the server) no
-- default privileges compensate, so every access fails with SQLSTATE 42501
-- (permission denied). Only the dev database masks it.
--
-- Forward-only and GRANT-only: no schema change, shipped migrations stay untouched.
-- Exactly SELECT/INSERT/UPDATE/DELETE on the tables, USAGE/SELECT on the one sequence.

GRANT SELECT, INSERT, UPDATE, DELETE ON cross_signing_keys TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON account_data TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON operational_logs TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE operational_logs_id_seq TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON war_room_sessions TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON admin_temporary_captures TO nebu_app;
