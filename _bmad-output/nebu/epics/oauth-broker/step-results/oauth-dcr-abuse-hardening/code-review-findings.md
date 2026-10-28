# Code review oauth-dcr-abuse-hardening cycle 0: 0 MAJOR, 5 MINOR, 7 INFO
M1 000044 up.sql:36-37 + ADR AH17 (~l.927): "rolling deploy safe" is wrong for oauth_clients_source_key_pending_check: an OLD node's approve/reject SQL does not set source_key NULL -> check violation (fails closed, retry on a new node works): correct AH17 + migration header (or defer the CHECK).
M2 oauth_registrations_controller.ex:48,:164 as_of snapshot uses app clock but created_at is DB now(): take as_of from the DB clock (SELECT now()) in preview, validate the 1 h/future window against the DB clock too.
M3 controller write_bulk_audit :278-283 with match=domain records the host as typed, not the effective registrable domain swept: record the effective domain (normalize_criteria output) in audit metadata.
M4 migration test 000044_..._test.exs:14 stale "Red today" moduledoc.
M5 client_store.ex:933-936 `IS NOT DISTINCT FROM` defeats btree: split into ((p IS NULL AND col IS NULL) OR col = p) so oauth_clients_pending_domain_source_idx is usable.
INFO: I4 suffix coverage gaps (regional s3, cloudapp.azure.com, github.dev) -> follow-up ar; I5 NAT64/IPv4-compat aggregate into one /64 source: note with ao.
