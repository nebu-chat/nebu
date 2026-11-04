H = "server/lib/nebu/matrix/http_room_keys.ex"
P = "server/lib/nebu/web/router/protected.ex"
J = "server/lib/nebu/web/plugs/json_body.ex"
RL = "server/lib/nebu/web/plugs/request_logger.ex"
RB = "server/lib/nebu/web/plugs/raw_body_reader.ex"
U = "server/lib/nebu/compliance/user_deletion.ex"
MU = "server/priv/migrations/000056_room_key_backup.up.sql"
MD = "server/priv/migrations/000056_room_key_backup.down.sql"
T = "test/nebu/matrix/"
KV = T + "room_keys_keys_http_test.exs " + T + "room_keys_versions_http_test.exs"
K = T + "room_keys_keys_http_test.exs"
V = T + "room_keys_versions_http_test.exs"
L = T + "room_keys_limits_http_test.exs"
C = T + "room_keys_concurrency_test.exs"
G = T + "room_keys_logging_test.exs"
E = "test/nebu/compliance/user_deletion_room_keys_test.exs"
R = T + "room_keys_routes_test.exs"
MIG = "test/nebu/migration/000056_room_key_backup_test.exs"
DOCS = T + "room_keys_docs_test.exs"

MERGE_ALL = """            WHERE (EXCLUDED.is_verified AND NOT s.is_verified)
               OR (EXCLUDED.is_verified = s.is_verified
                   AND (EXCLUDED.first_message_index < s.first_message_index"""

MUTANTS = [
    # ── merge rule ──
    dict(id="M01", label="merge: drop 'verified wins'", file=H, old="WHERE (EXCLUDED.is_verified AND NOT s.is_verified)", new="WHERE (false)", tests=K),
    dict(id="M02", label="merge: ignore is_verified entirely (index / forwarded_count only)", file=H, old=MERGE_ALL,
         new="""            WHERE (true)
               AND ((EXCLUDED.first_message_index < s.first_message_index""", tests=K),
    dict(id="M03", label="merge: a full tie replaces (<= on forwarded_count)", file=H, old="EXCLUDED.forwarded_count < s.forwarded_count)))", new="EXCLUDED.forwarded_count <= s.forwarded_count)))", tests=K),
    dict(id="M04", label="merge: forwarded_count decides independently of the index (OR instead of nested)", file=H,
         old="OR (EXCLUDED.first_message_index = s.first_message_index AND EXCLUDED.forwarded_count < s.forwarded_count)))",
         new="OR EXCLUDED.forwarded_count < s.forwarded_count))", tests=K),
    dict(id="M05", label="merge: HIGHER first_message_index wins", file=H, old="AND (EXCLUDED.first_message_index < s.first_message_index", new="AND (EXCLUDED.first_message_index > s.first_message_index", tests=K),
    dict(id="M06", label="merge: any verified difference replaces (an unverified one downgrades a verified one)", file=H, old="WHERE (EXCLUDED.is_verified AND NOT s.is_verified)", new="WHERE (EXCLUDED.is_verified <> s.is_verified)", tests=K),
    # ── etag / count ──
    dict(id="M07", label="etag bumped only for NEW sessions (not on replace)", file=H, old="if changed > 0, do: bump_etag!(uid, v)", new="if fresh > 0, do: bump_etag!(uid, v)", tests=K),
    dict(id="M08", label="etag never bumped by DELETE keys", file=H, old="if deleted > 0, do: bump_etag!(uid, v)", new="if false, do: bump_etag!(uid, v)", tests=K),
    dict(id="M09", label="GET /version count is always 0", file=H, old='          "count" => count,', new='          "count" => 0,', tests=KV),
    dict(id="M50", label="PUT keys answers the batch size as count (not the stored total)", file=H, old="store!(uid, v, entries)\n        {200, count_etag(uid, v)}", new='store!(uid, v, entries)\n        {200, %{"count" => length(entries), "etag" => "0"}}', tests=K),
    dict(id="M51", label="write answers carry a constant etag", file=H, old='%{"count" => count, "etag" => Integer.to_string(etag)}', new='%{"count" => count, "etag" => "1"}', tests=K),
    dict(id="M52", label="GET /version carries a constant etag", file=H, old='"etag" => Integer.to_string(etag),', new='"etag" => "1",', tests=K),
    # ── quota of versions / numbering ──
    dict(id="M10", label="quota off by one (11 versions allowed)", file=H, old="if live >= @max_versions", new="if live > @max_versions", tests=V),
    dict(id="M11", label="deleted versions count toward the quota", file=H, old='SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL"', new='SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1"', tests=V),
    dict(id="M12", label="version numbers computed over live versions only (reuse)", file=H, old='SELECT COALESCE(max(version), 0) + 1 FROM room_key_backup_versions WHERE user_id = $1"', new='SELECT COALESCE(max(version), 0) + 1 FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL"', tests=V),
    dict(id="M31", label="version parser accepts leading zeros / zero", file=H, old=r"~r/\A[1-9][0-9]{0,17}\z/", new=r"~r/\A[0-9]{1,18}\z/", tests=KV),
    dict(id="M57", label="version parser accepts 31 digits (int64 overflow)", file=H, old="{0,17}", new="{0,30}", tests=KV),
    dict(id="M39", label="current version falls back to the OLDEST (min) instead of the newest", file=H, old="SELECT max(version) FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL", new="SELECT min(version) FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL", tests=KV),
    # ── isolation ──
    dict(id="M13", label="live_version ignores the user (another user's version resolves)", file=H, old='"SELECT 1 FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND deleted_at IS NULL"', new='"SELECT 1 FROM room_key_backup_versions WHERE $1::text IS NOT NULL AND version = $2 AND deleted_at IS NULL LIMIT 1"', tests=K),
    dict(id="M14", label="GET /version/{v} ignores the user", file=H, old='"SELECT algorithm, auth_data, etag FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND deleted_at IS NULL"', new='"SELECT algorithm, auth_data, etag FROM room_key_backup_versions WHERE $1::text IS NOT NULL AND version = $2 AND deleted_at IS NULL LIMIT 1"', tests=V),
    dict(id="M15", label="DELETE /version/{v} ignores the user in its lookup", file=H, old='"SELECT deleted_at FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 FOR UPDATE"', new='"SELECT deleted_at FROM room_key_backup_versions WHERE $1::text IS NOT NULL AND version = $2 LIMIT 1 FOR UPDATE"', tests=V),
    dict(id="M16", label="PUT /version/{v} ignores the user in its lookup", file=H, old='"SELECT algorithm FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND deleted_at IS NULL FOR UPDATE"', new='"SELECT algorithm FROM room_key_backup_versions WHERE $1::text IS NOT NULL AND version = $2 AND deleted_at IS NULL LIMIT 1 FOR UPDATE"', tests=V),
    dict(id="M53", label="PUT /version/{v} does not store the new auth_data", file=H, old='q!("UPDATE room_key_backup_versions SET auth_data = $3, updated_at = $4 WHERE user_id = $1 AND version = $2", [uid, v, Jason.encode!(auth_data), now_ms()])', new=":ok", tests=V),
    dict(id="M40", label="a deleted version resolves as a live one", file=H, old='"SELECT 1 FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND deleted_at IS NULL"', new='"SELECT 1 FROM room_key_backup_versions WHERE user_id = $1 AND version = $2"', tests=KV),
    # ── delete semantics ──
    dict(id="M17", label="DELETE /version leaves the session rows", file=H,
         old='        %{rows: [[nil]]} ->\n          q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])\n          now = now_ms()', new="        %{rows: [[nil]]} ->\n          now = now_ms()", tests=V),
    dict(id="M33", label="DELETE of an already deleted version is 404 (not idempotent)", file=H, old="%{rows: [[_deleted_at]]} ->\n          {200, %{}}", new='%{rows: [[_deleted_at]]} ->\n          fail(404, "M_NOT_FOUND", "Unknown backup version")', tests=V),
    dict(id="M48", label="DELETE /keys/{room} deletes every room", file=H, old='{:room, room} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3", [uid, v, room])', new='{:room, _room} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])', tests=K),
    dict(id="M49", label="DELETE /keys/{room}/{session} deletes the whole room", file=H, old='{:session, room, session} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3 AND session_id = $4", [uid, v, room, session])', new='{:session, room, _s} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3", [uid, v, room])', tests=K),
    # ── wrong version ──
    dict(id="M18", label="wrong version answers 404 (status)", file=H, old='fail(403, "M_WRONG_ROOM_KEYS_VERSION"', new='fail(404, "M_WRONG_ROOM_KEYS_VERSION"', tests=K),
    dict(id="M19", label="wrong version answers M_NOT_FOUND (errcode)", file=H, old='"M_WRONG_ROOM_KEYS_VERSION", "The version', new='"M_NOT_FOUND", "The version', tests=K),
    dict(id="M20", label="403 carries no current_version", file=H, old='%{"current_version" => Integer.to_string(current)}', new="%{}", tests=K),
    dict(id="M21", label="writes accepted for any live version (no current check)", file=H, old="if parse_version(version) != {:ok, current},", new="if false,", tests=K),
    dict(id="M32", label="empty `version` query is not 'missing'", file=H, old='v when is_binary(v) and v != "" ->', new="v when is_binary(v) ->", tests=K),
    # ── caps / validation ──
    dict(id="M24", label="session cap off by one (>=)", file=H, old="if existing + fresh > max_sessions()", new="if existing + fresh >= max_sessions()", tests=L),
    dict(id="M55", label="session cap counts the whole batch as new (replace at the cap refused)", file=H, old="if existing + fresh > max_sessions()", new="if existing + length(entries) > max_sessions()", tests=L),
    dict(id="M25", label="default session cap 100 001", file=H, old="@default_max_sessions 100_000", new="@default_max_sessions 100_001", tests=L),
    dict(id="M26", label="session_data cap 8 KiB + 1", file=H, old="@max_session_data_bytes 8 * 1024", new="@max_session_data_bytes 8 * 1024 + 1", tests=L),
    dict(id="M27", label="size limits count characters, not bytes", file=H, old="if byte_size(Jason.encode!(value)) > max,", new="if String.length(Jason.encode!(value)) > max,", tests=L + " " + V),
    dict(id="M28", label="auth_data cap 16 KiB + 1", file=H, old="@max_auth_data_bytes 16 * 1024", new="@max_auth_data_bytes 16 * 1024 + 1", tests=V),
    dict(id="M29", label="id length cap 256", file=H, old="@max_id_bytes 255", new="@max_id_bytes 256", tests=K),
    dict(id="M30", label="megolm index bound 2^32", file=H, old="@max_index 4_294_967_295", new="@max_index 4_294_967_296", tests=K),
    dict(id="M30b", label="megolm index bound 2^31 - 1", file=H, old="@max_index 4_294_967_295", new="@max_index 2_147_483_647", tests=K),
    dict(id="M59", label="ids: invalid UTF-8 / NUL accepted", file=H, old="and String.valid?(id) and not String.contains?(id, <<0>>)", new="and true", tests=K),
    dict(id="M34", label="an invalid session is skipped instead of refusing the batch", file=H, old="{:error, _} = err -> {:halt, err}", new="{:error, _} -> {:cont, {:ok, acc}}", tests=K),
    dict(id="M35", label="an empty room reads as 404", file=H, old='send_json(conn, 200, %{"sessions" => Map.new(rows, fn [sid | rest] -> {sid, kbd(rest)} end)})', new='if rows == [], do: error(conn, 404, "M_NOT_FOUND", "x"), else: send_json(conn, 200, %{"sessions" => Map.new(rows, fn [sid | rest] -> {sid, kbd(rest)} end)})', tests=K),
    dict(id="M36", label="KeyBackupData leaks an extra member", file=H, old='defp kbd([fmi, fwd, verified, data]), do: %{"first_message_index" => fmi,', new='defp kbd([fmi, fwd, verified, data]), do: %{"user_id" => "leak", "first_message_index" => fmi,', tests=K),
    dict(id="M37", label="PUT /version does not compare the algorithm", file=H, old="if algorithm != stored, do:", new="if false, do:", tests=V),
    dict(id="M38", label="PUT /version ignores a mismatching body `version`", file=H, old='{:ok, _} -> fail(400, "M_INVALID_PARAM", "The version in the body does not match the version in the path")', new="{:ok, _} -> :ok", tests=V),
    dict(id="M44", label="a non-object JSON body is accepted as {}", file=H, old='is_map(conn.body_params) and map_size(conn.body_params) == 1 and Map.has_key?(conn.body_params, "_json") -> {:error, {400, "M_BAD_JSON", "Request body must be a JSON object", %{}}}', new="is_map(conn.body_params) and false -> {:ok, %{}}", tests=KV),
    dict(id="M45", label="malformed JSON accepted as {}", file=H, old='conn.assigns[:json_parse_error] == true -> {:error, {400, "M_NOT_JSON", "Request body is not valid JSON", %{}}}', new="conn.assigns[:json_parse_error] == true -> {:ok, %{}}", tests=KV),
    dict(id="M46", label="a missing member is M_INVALID_PARAM", file=H, old='{:error, {400, "M_MISSING_PARAM", "Missing #{key}", %{}}}', new='{:error, {400, "M_INVALID_PARAM", "Missing #{key}", %{}}}', tests=KV),
    dict(id="M47", label="any algorithm accepted on POST", file=H, old=':ok <- if(algorithm == @algorithm, do: :ok,', new=':ok <- if(true, do: :ok,', tests=V),
    # ── erasure / lock / races ──
    dict(id="M22", label="erased-user check never fires", file=H, old='SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NOT NULL"', new='SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NOT NULL AND false"', tests=E),
    dict(id="M41", label="PUT /keys does not check the erased user", file=H, old="        lock_and_check_erased!(uid)\n\n        v =\n          case current_version(uid) do", new="        lock!(uid)\n\n        v =\n          case current_version(uid) do", tests=E),
    dict(id="M42", label="POST /version does not check the erased user", file=H, old="        lock_and_check_erased!(uid)\n        %{rows: [[live]]}", new="        lock!(uid)\n        %{rows: [[live]]}", tests=E),
    dict(id="M23", label="no advisory lock at all", file=H, old="defp lock!(uid), do: q!(@lock_sql, [uid])", new="defp lock!(_uid), do: :ok", tests=E + " " + C),
    dict(id="M43", label="a different advisory lock key (not the sync_global one)", file=H, old="'sync_global|'", new="'room_keys|'", tests=E),
    # ── static source scans ──
    dict(id="S01", label="ETS state in the key backup code", file=H, old="  require Logger\n", new="  require Logger\n  def __probe__, do: :ets.new(:rk_probe, [])\n", tests=DOCS),
    dict(id="S02", label="a Logger call names auth_data", file=H, old="  require Logger\n", new='  require Logger\n  def __probe__, do: Logger.debug("auth_data")\n', tests=DOCS),
    dict(id="S03", label="an Ecto schema for the key backup", file=H, old="  require Logger\n", new="  require Logger\n  use Ecto.Schema\n", tests=DOCS),
    # ── router / limiter / body cap / logging / erasure list ──
    dict(id="P01", label="GET /version is rate limited", file=P, old="  get \"/client/v3/room_keys/version\" do\n    Nebu.Matrix.HttpRoomKeys.get_version(conn)", new="  get \"/client/v3/room_keys/version\" do\n    room_keys_write(conn, fn -> Nebu.Matrix.HttpRoomKeys.get_version(conn) end)", tests=L),
    dict(id="P02", label="burst 31", file=P, old='rate_per_min: 60, burst: 30, tier: "room_keys", key: :user)', new='rate_per_min: 60, burst: 31, tier: "room_keys", key: :user)', tests=L),
    dict(id="P03", label="tier shared with account_data", file=P, old='tier: "room_keys", key: :user)', new='tier: "account_data", key: :user)', tests=L),
    dict(id="P04", label="bucket keyed by IP", file=P, old='tier: "room_keys", key: :user)', new='tier: "room_keys", key: :ip)', tests=L),
    dict(id="P05", label="DELETE /keys/{room}/{session} route renamed (unrouted)", file=P, old='delete "/client/v3/room_keys/keys/:room_id/:session_id" do', new='delete "/client/v3/room_keys/keysX/:room_id/:session_id" do', tests=K + " " + R),
    dict(id="P06", label="PUT /keys/{room}/{session} not rate limited", file=P, old="    room_keys_write(conn, fn -> Nebu.Matrix.HttpRoomKeys.put_keys(conn, {:session, room_id, session_id}) end)", new="    Nebu.Matrix.HttpRoomKeys.put_keys(conn, {:session, room_id, session_id})", tests=L),
    dict(id="P07", label="DELETE /version/{v} not rate limited", file=P, old="    room_keys_write(conn, fn -> Nebu.Matrix.HttpRoomKeys.delete_version(conn, version) end)", new="    Nebu.Matrix.HttpRoomKeys.delete_version(conn, version)", tests=L),
    dict(id="P08", label="POST /version not rate limited", file=P, old="    room_keys_write(conn, fn -> Nebu.Matrix.HttpRoomKeys.create_version(conn) end)", new="    Nebu.Matrix.HttpRoomKeys.create_version(conn)", tests=L),
    dict(id="P09", label="DELETE /keys not rate limited", file=P, old="    room_keys_write(conn, fn -> Nebu.Matrix.HttpRoomKeys.delete_keys(conn, :all) end)", new="    Nebu.Matrix.HttpRoomKeys.delete_keys(conn, :all)", tests=L),
    dict(id="P10", label="PUT /version/{v} not rate limited", file=P, old="    room_keys_write(conn, fn -> Nebu.Matrix.HttpRoomKeys.update_version(conn, version) end)", new="    Nebu.Matrix.HttpRoomKeys.update_version(conn, version)", tests=L),
    dict(id="J01", label="body cap 5 MiB + 1", file=J, old="length: 5_242_880,", new="length: 5_242_881,", tests=L),
    dict(id="J02", label="body cap 4 MiB", file=J, old="length: 5_242_880,", new="length: 4_194_304,", tests=L),
    dict(id="J03", label="body cap stays 1 MB on room_keys", file=J, old="length: 5_242_880,", new="length: 1_000_000,", tests=L),
    dict(id="J04", label="the room_keys cap clause never matches", file=J, old='"v3", "room_keys" | _]', new='"v3", "room_keysX" | _]', tests=L),
    dict(id="L01", label="RequestLogger captures room_keys bodies", file=RL, old=" or Nebu.Web.Plugs.RawBodyReader.room_keys_shape?(conn.request_path)", new="", tests=G),
    dict(id="L02", label="room_keys_shape? is false", file=RB, old='["_matrix", "client", _version, "room_keys" | _] -> true', new='["_matrix", "client", _version, "room_keys" | _] -> false', tests=G),
    dict(id="U01", label="erasure misses the versions table", file=U, old="room_key_backup_sessions room_key_backup_versions", new="room_key_backup_sessions", tests=E),
    dict(id="U02", label="erasure deletes versions before sessions (FK order)", file=U, old="room_key_backup_sessions room_key_backup_versions", new="room_key_backup_versions room_key_backup_sessions", tests=E),
    dict(id="U03", label="erasure misses the sessions table", file=U, old="room_key_backup_sessions room_key_backup_versions", new="room_key_backup_versions", tests=E),
    # ── migration (static + catalog part) ──
    dict(id="N01", label="migration: sessions RLS not forced", file=MU, old="ALTER TABLE room_key_backup_sessions FORCE ROW LEVEL SECURITY;\n", new="", tests=MIG),
    dict(id="N02", label="migration: no grant on versions", file=MU, old="GRANT SELECT, INSERT, UPDATE, DELETE ON room_key_backup_versions TO nebu_app;\n", new="", tests=MIG),
    dict(id="N03", label="migration: no DELETE policy on sessions", file=MU, old="DROP POLICY IF EXISTS room_key_backup_sessions_delete ON room_key_backup_sessions;\nCREATE POLICY room_key_backup_sessions_delete ON room_key_backup_sessions FOR DELETE USING (true);\n", new="", tests=MIG),
    dict(id="N04", label="migration down: versions dropped before sessions", file=MD, old="DROP TABLE IF EXISTS room_key_backup_sessions;\nDROP TABLE IF EXISTS room_key_backup_versions;", new="DROP TABLE IF EXISTS room_key_backup_versions;\nDROP TABLE IF EXISTS room_key_backup_sessions;", tests=MIG),
    dict(id="N05", label="migration: grant to PUBLIC", file=MU, old="ALTER TABLE room_key_backup_versions ENABLE ROW LEVEL SECURITY;", new="GRANT SELECT ON room_key_backup_versions TO PUBLIC;\nALTER TABLE room_key_backup_versions ENABLE ROW LEVEL SECURITY;", tests=MIG),
    dict(id="N06", label="migration: sessions.user_id nullable", file=MU, old="    user_id             TEXT    NOT NULL,", new="    user_id             TEXT,", tests=MIG),
    dict(id="N07", label="migration: TRUNCATE granted", file=MU, old="GRANT SELECT, INSERT, UPDATE, DELETE ON room_key_backup_sessions TO nebu_app;", new="GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON room_key_backup_sessions TO nebu_app;", tests=MIG),
    dict(id="N08", label="migration: touches an existing table", file=MU, old="ALTER TABLE room_key_backup_versions ENABLE ROW LEVEL SECURITY;", new="ALTER TABLE users ADD COLUMN IF NOT EXISTS rk_probe INT;\nALTER TABLE room_key_backup_versions ENABLE ROW LEVEL SECURITY;", tests=MIG),
    dict(id="N09", label="migration: versions RLS not even enabled", file=MU, old="ALTER TABLE room_key_backup_versions ENABLE ROW LEVEL SECURITY;\nALTER TABLE room_key_backup_versions FORCE ROW LEVEL SECURITY;\n", new="", tests=MIG),
    dict(id="N10", label="migration: no UPDATE policy on versions", file=MU, old="DROP POLICY IF EXISTS room_key_backup_versions_update ON room_key_backup_versions;\nCREATE POLICY room_key_backup_versions_update ON room_key_backup_versions FOR UPDATE USING (true) WITH CHECK (true);\n", new="", tests=MIG),
    # ── docs ──
    dict(id="D01", label="ADR-011 clarification does not name the story", file="docs/architecture/adr/ADR-011-managed-e2ee-key-escrow.md", old="story `server-side-key-backup`, epic e2ee-client-support):", new="story `x`, epic e2ee-client-support):", tests=DOCS),
    dict(id="D02", label="08-concepts drops the 5 MiB cap", file="docs/architecture/08-concepts.md", old="5 MiB per request body on these routes", new="a request body cap on these routes", tests=DOCS),
    dict(id="D03", label="08-concepts drops the rate limit divergence", file="docs/architecture/08-concepts.md", old="reads are not limited (a divergence", new="reads are free (a divergence", tests=DOCS),
    dict(id="D04", label="05-building-blocks drops the sessions table", file="docs/architecture/05-building-blocks.md", old="tables `room_key_backup_versions` and `room_key_backup_sessions`\n> (migration 000056", new="tables `room_key_backup_versions`\n> (migration 000056", tests=DOCS),
    dict(id="D05", label="the old stub comment returns in protected.ex", file=P, old="  # Server-side key backups (Matrix CS v1.18, story server-side-key-backup)", new="  # POST /room_keys/version — key backup creation ACCEPTANCE STUB\n  # Server-side key backups (Matrix CS v1.18, story server-side-key-backup)", tests=DOCS),
    dict(id="D06", label="runbook verification query for the sessions table removed", file="docs/compliance/gdpr-deletion-runbook.md", old="SELECT COUNT(*) FROM room_key_backup_sessions WHERE user_id = '@alice:example.com';\n", new="", tests="test/nebu/compliance/user_deletion_docs_test.exs"),
    dict(id="D07", label="sweep in 07-deployment misses the versions table", file="docs/architecture/07-deployment.md", old="DELETE FROM room_key_backup_versions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');\n", new="", tests="test/nebu/compliance/user_deletion_sweep_test.exs"),
    dict(id="D08", label="08-concepts erasure inventory misses the key backup tables", file="docs/architecture/08-concepts.md", old=", `room_key_backup_sessions`, `room_key_backup_versions` (the server-side key backup of story server-side-key-backup, migration 000056: every version row, the soft-delete markers included, and every session row)", new="", tests="test/nebu/compliance/user_deletion_docs_test.exs"),
]

# ═══ fix pass (test review: coinciding versions, credentialed cap, empty batches, DB faults, ...) ═══
for _m in MUTANTS:
    if _m["id"] == "D02":
        _m["old"] = "5 MiB per request body on these routes for requests"
        _m["new"] = "a request body cap on these routes for requests"

FIX_MUTANTS = [
    # per-user scoping of the room / session level SQL (coinciding version numbers)
    dict(id="M61", label="GET /keys (all) ignores the user", file=H, old="SELECT room_id, session_id, first_message_index, forwarded_count, is_verified, session_data FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", new="SELECT room_id, session_id, first_message_index, forwarded_count, is_verified, session_data FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2", tests=K),
    dict(id="M62", label="GET /keys/{room} ignores the user", file=H, old="SELECT session_id, first_message_index, forwarded_count, is_verified, session_data FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3", new="SELECT session_id, first_message_index, forwarded_count, is_verified, session_data FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2 AND room_id = $3", tests=K),
    dict(id="M63", label="GET /keys/{room}/{session} ignores the user", file=H, old="SELECT first_message_index, forwarded_count, is_verified, session_data FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3 AND session_id = $4", new="SELECT first_message_index, forwarded_count, is_verified, session_data FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2 AND room_id = $3 AND session_id = $4", tests=K),
    dict(id="M64", label="DELETE /keys (all) ignores the user", file=H, old=':all -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])', new=':all -> q!("DELETE FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2", [uid, v])', tests=K),
    dict(id="M65", label="DELETE /keys/{room} ignores the user", file=H, old='{:room, room} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3", [uid, v, room])', new='{:room, room} -> q!("DELETE FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2 AND room_id = $3", [uid, v, room])', tests=K),
    dict(id="M66", label="DELETE /keys/{room}/{session} ignores the user", file=H, old='{:session, room, session} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3 AND session_id = $4", [uid, v, room, session])', new='{:session, room, session} -> q!("DELETE FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2 AND room_id = $3 AND session_id = $4", [uid, v, room, session])', tests=K),
    dict(id="M67", label="count of a write answer ignores the user", file=H, old='%{rows: [[count]]} = q!("SELECT count(*) FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])\n    %{rows: [[etag]]}', new='%{rows: [[count]]} = q!("SELECT count(*) FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2", [uid, v])\n    %{rows: [[etag]]}', tests=K),
    dict(id="M68", label="count of GET /version ignores the user", file=H, old='%{rows: [[count]]} = q!("SELECT count(*) FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])\n\n        send_json(conn, 200, %{', new='%{rows: [[count]]} = q!("SELECT count(*) FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2", [uid, v])\n\n        send_json(conn, 200, %{', tests=K),
    dict(id="M69", label="the cap count of a write ignores the user", file=H, old='%{rows: [[existing]]} = q!("SELECT count(*) FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])', new='%{rows: [[existing]]} = q!("SELECT count(*) FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2", [uid, v])', tests=L),
    dict(id="M70", label="the 'new session' count of a write ignores the user", file=H, old="(SELECT 1 FROM room_key_backup_sessions s WHERE s.user_id = $1 AND s.version = $2 AND", new="(SELECT 1 FROM room_key_backup_sessions s WHERE $1::text IS NOT NULL AND s.version = $2 AND", tests=L),
    dict(id="M71", label="the etag bump ignores the user", file=H, old='"UPDATE room_key_backup_versions SET etag = etag + 1, updated_at = $3 WHERE user_id = $1 AND version = $2"', new='"UPDATE room_key_backup_versions SET etag = etag + 1, updated_at = $3 WHERE $1::text IS NOT NULL AND version = $2"', tests=K),
    dict(id="M72", label="the tombstone UPDATE of DELETE /version ignores the user", file=H, old="deleted_at = $3, updated_at = $3 WHERE user_id = $1 AND version = $2", new="deleted_at = $3, updated_at = $3 WHERE $1::text IS NOT NULL AND version = $2", tests=V),
    dict(id="M73", label="the auth_data UPDATE of PUT /version ignores the user", file=H, old="SET auth_data = $3, updated_at = $4 WHERE user_id = $1 AND version = $2", new="SET auth_data = $3, updated_at = $4 WHERE $1::text IS NOT NULL AND version = $2", tests=V),
    dict(id="M87", label="the session rows of DELETE /version are deleted for every user", file=H, old='        %{rows: [[nil]]} ->\n          q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2", [uid, v])', new='        %{rows: [[nil]]} ->\n          q!("DELETE FROM room_key_backup_sessions WHERE $1::text IS NOT NULL AND version = $2", [uid, v])', tests=K),
    # credentialed-only cap
    dict(id="M74", label="the 5 MiB cap applies to anonymous requests too", file=J, old="      _ -> parse(conn, @parser_opts)\n    end\n  end", new="      _ -> parse(conn, @room_keys_parser_opts)\n    end\n  end", tests=R),
    dict(id="M75", label="any Authorization header counts as a credential", file=J, old='["Bearer " <> token | _] when token != "" -> parse(conn, @room_keys_parser_opts)', new="[_ | _] -> parse(conn, @room_keys_parser_opts)", tests=R),
    dict(id="M76", label="an access_token query parameter counts as a credential", file=J, old="      _ -> parse(conn, @parser_opts)\n    end\n  end", new='      _ -> if String.contains?(conn.query_string, "access_token="), do: parse(conn, @room_keys_parser_opts), else: parse(conn, @parser_opts)\n    end\n  end', tests=R),
    dict(id="M88", label="an empty Bearer counts as a credential", file=J, old='["Bearer " <> token | _] when token != "" -> parse(conn, @room_keys_parser_opts)', new='["Bearer " <> _token | _] -> parse(conn, @room_keys_parser_opts)', tests=R),
    dict(id="M89", label="the credentialed cap is lowered back to 1 MB (credentialed clause = default opts)", file=J, old='["Bearer " <> token | _] when token != "" -> parse(conn, @room_keys_parser_opts)', new='["Bearer " <> token | _] when token != "" -> parse(conn, @parser_opts)', tests=R),
    # empty batches, ids in the body, SQL metacharacters, floats, array version
    dict(id="M77", label="a NUL in an id is accepted (body and path)", file=H, old=" and not String.contains?(id, <<0>>)", new="", tests=K),
    dict(id="M78", label="an empty batch is refused", file=H, old="defp store!(_uid, _v, []), do: :ok", new='defp store!(_uid, _v, []), do: fail(400, "M_INVALID_PARAM", "empty")', tests=K),
    dict(id="M79", label="an empty batch bumps the etag", file=H, old="defp store!(_uid, _v, []), do: :ok", new="defp store!(uid, v, []), do: bump_etag!(uid, v)", tests=K),
    dict(id="M80", label="SQL built by string interpolation in DELETE /keys/{room}", file=H, old='{:room, room} -> q!("DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = $3", [uid, v, room])', new="{:room, room} -> q!(\"DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2 AND room_id = '#{room}'\", [uid, v])", tests=K),
    dict(id="M81", label="a float index is accepted", file=H, old="defp index?(n), do: is_integer(n) and n >= 0 and n <= @max_index", new="defp index?(n), do: is_number(n) and n >= 0 and n <= @max_index", tests=K),
    dict(id="M82", label="an array `version` query is taken as the first element", file=H, old="      _ -> {:error, {400, \"M_MISSING_PARAM\", \"Missing the `version` query parameter\", %{}}}", new="      [v | _] when is_binary(v) -> {:ok, v}\n      _ -> {:error, {400, \"M_MISSING_PARAM\", \"Missing the `version` query parameter\", %{}}}", tests=K),
    # DB faults and leaks
    dict(id="M83", label="the database error MESSAGE is the logged 'kind'", file=H, old="defp error_kind(%{__struct__: module}), do: inspect(module)", new="defp error_kind(%{__struct__: _} = e), do: Exception.message(e)", tests=G),
    dict(id="M85", label="soft-deleted version row is removed instead of marked (no marker)", file=H, old='"UPDATE room_key_backup_versions SET algorithm = NULL, auth_data = NULL, etag = etag + 1, deleted_at = $3, updated_at = $3 WHERE user_id = $1 AND version = $2"', new='"DELETE FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 AND $3::bigint IS NOT NULL"', tests=V + " " + E),
    dict(id="M86", label="count cached in the VM (persistent_term), not read from the database", file=H, edits=[
        (H, "    if changed > 0, do: bump_etag!(uid, v)\n    :ok", "    if changed > 0, do: bump_etag!(uid, v)\n    :persistent_term.put({:rk_count, uid, v}, existing + fresh)\n    :ok"),
        (H, '          "count" => count,', '          "count" => :persistent_term.get({:rk_count, uid, v}, count),')], old="", new="", tests=K),
    # FK decision
    dict(id="N11", label="migration: FK with ON DELETE CASCADE", file=MU, old="FOREIGN KEY (user_id, version) REFERENCES room_key_backup_versions (user_id, version),", new="FOREIGN KEY (user_id, version) REFERENCES room_key_backup_versions (user_id, version) ON DELETE CASCADE,", tests=MIG),
    dict(id="N12", label="migration: no foreign key", file=MU, old="    FOREIGN KEY (user_id, version) REFERENCES room_key_backup_versions (user_id, version),\n", new="", tests=MIG),
    # hygiene
    dict(id="S04", label="Cachex in the key backup code", file=H, old="  require Logger\n", new="  require Logger\n  def __probe__, do: Cachex.get(:x, :y)\n", tests=DOCS),
    dict(id="S05", label="the version doc drops the per-user counter", file="docs/architecture/08-concepts.md", old="a per-user counter (the first version of every user is `1`", new="a number (the first version is `1`", tests=DOCS),
    dict(id="S06", label="the doc drops the credentialed cap", file="docs/architecture/08-concepts.md", old="for requests that carry an `Authorization: Bearer` credential", new="for every request", tests=DOCS),
]
# the old mutants that guard what the fix pass changed or loosened (isolation, concurrency, docs wording, erasure)
RERUN = {"M13", "M14", "M15", "M16", "M53", "M23", "M43", "M09", "M48", "M49", "M22", "M41", "M42", "U01", "U02", "U03", "D01", "D02", "D03", "D04", "D05", "J01", "J02", "J03", "J04", "P01", "P05"}
MUTANTS = [m for m in MUTANTS if m["id"] in RERUN] + FIX_MUTANTS
