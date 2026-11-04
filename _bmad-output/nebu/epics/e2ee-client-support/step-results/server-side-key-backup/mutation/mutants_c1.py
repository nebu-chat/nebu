ST = "server/lib/nebu/matrix/room_key_backup_store.ex"
H = "server/lib/nebu/matrix/http_room_keys.ex"
P = "server/lib/nebu/web/router/protected.ex"
J = "server/lib/nebu/web/plugs/json_body.ex"
RN = "server/lib/nebu/web/log_store/route_normalizer.ex"
MU = "server/priv/migrations/000058_room_key_backup.up.sql"
T = "test/nebu/matrix/"
B = T + "room_keys_budget_http_test.exs"
LT = T + "room_keys_lock_timeout_test.exs"
L = T + "room_keys_limits_http_test.exs"
R = T + "room_keys_routes_test.exs"
K = T + "room_keys_keys_http_test.exs"
V = T + "room_keys_versions_http_test.exs"
G = T + "room_keys_logging_test.exs"
DOCS = T + "room_keys_docs_test.exs"
MIG = "test/nebu/migration/000058_room_key_backup_test.exs"
RNT = "test/nebu/web/log_store/route_normalizer_test.exs"
E = "test/nebu/compliance/user_deletion_room_keys_test.exs"
UDOCS = "test/nebu/compliance/user_deletion_docs_test.exs"
LOCK = "{:ok, _} <- query(\"SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))\", [user_id])"

MUTANTS = [
  # ── byte budget ──
  dict(id="B01", label="budget off by one (>= instead of >)", file=ST, old="if sessions + auth > max_bytes(), do:", new="if sessions + auth >= max_bytes(), do:", tests=B),
  dict(id="B02", label="budget counted GROSS (stored + incoming, replacements not netted) before the write", file=ST, old="", new="", tests=B, edits=[
      (ST, ":ok <- store_entries(user_id, current, entries),\n           :ok <- ensure_byte_budget(user_id) do", ":ok <- ensure_gross_budget(user_id, entries),\n           :ok <- store_entries(user_id, current, entries) do"),
      (ST, "  defp ensure_byte_budget(user_id) do", "  defp ensure_gross_budget(user_id, entries) do\n    {:ok, %{rows: [[sessions]]}} = query(\"SELECT COALESCE(sum(octet_length(session_data)), 0)::bigint FROM room_key_backup_sessions WHERE user_id = $1\", [user_id])\n    {:ok, %{rows: [[auth]]}} = query(\"SELECT COALESCE(sum(octet_length(auth_data)), 0)::bigint FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL\", [user_id])\n    incoming = entries |> Enum.map(&byte_size(Jason.encode!(&1.session_data))) |> Enum.sum()\n    if sessions + auth + incoming > max_bytes(), do: {:error, :bytes_quota}, else: :ok\n  end\n\n  defp ensure_byte_budget(user_id) do")]),
  dict(id="B03", label="advisory lock not taken (budget / quota decided on an unlocked state)", file=ST, old="case query(\"SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))\", [user_id]) do", new="case query(\"SELECT $1::text\", [user_id]) do", tests=B + " " + LT),
  dict(id="B04", label="auth_data bytes not counted", file=ST, old="sum(octet_length(auth_data))", new="0 * sum(octet_length(auth_data))", tests=B),
  dict(id="B05", label="session_data bytes not counted", file=ST, old="sum(octet_length(session_data))", new="0 * sum(octet_length(session_data))", tests=B),
  dict(id="B06", label="budget counts only the current version's sessions", file=ST, old="FROM room_key_backup_sessions WHERE user_id = $1\", [user_id]),\n         {:ok, %{rows: [[auth]]}}", new="FROM room_key_backup_sessions WHERE user_id = $1 AND version = (SELECT max(version) FROM room_key_backup_versions v2 WHERE v2.user_id = $1 AND v2.deleted_at IS NULL)\", [user_id]),\n         {:ok, %{rows: [[auth]]}}", tests=B),
  dict(id="B07", label="the budget of one user counts every user's sessions", file=ST, old="FROM room_key_backup_sessions WHERE user_id = $1\", [user_id]),\n         {:ok, %{rows: [[auth]]}}", new="FROM room_key_backup_sessions WHERE $1::text IS NOT NULL\", [user_id]),\n         {:ok, %{rows: [[auth]]}}", tests=B),
  dict(id="B08", label="default budget 128 MiB", file=ST, old="@default_max_bytes 256 * 1024 * 1024", new="@default_max_bytes 128 * 1024 * 1024", tests=B),
  dict(id="B09", label="default budget 512 MiB", file=ST, old="@default_max_bytes 256 * 1024 * 1024", new="@default_max_bytes 512 * 1024 * 1024", tests=B),
  dict(id="B10", label="over-budget answer is 429 M_LIMIT_EXCEEDED", file=H, old='defp reply_error(conn, :bytes_quota), do: error(conn, 403, "M_FORBIDDEN",', new='defp reply_error(conn, :bytes_quota), do: error(conn, 429, "M_LIMIT_EXCEEDED",', tests=B),
  dict(id="B11", label="PUT /version is not budget-checked", file=ST, old="                        :ok <- ensure_byte_budget(user_id),\n                        do: {:ok, :ok}", new="                        do: {:ok, :ok}", tests=B),
  dict(id="B12", label="POST /version is not budget-checked", file=ST, old="             ),\n           :ok <- ensure_byte_budget(user_id) do\n        {:ok, Integer.to_string(version)}", new="             ) do\n        {:ok, Integer.to_string(version)}", tests=B),
  dict(id="B13", label="PUT /keys is not budget-checked", file=ST, old="           :ok <- store_entries(user_id, current, entries),\n           :ok <- ensure_byte_budget(user_id) do", new="           :ok <- store_entries(user_id, current, entries) do", tests=B),
  dict(id="B14", label="a deleted version does not free its session bytes (sessions kept)", file=ST, old="                   with {:ok, _} <- query(\"DELETE FROM room_key_backup_sessions WHERE user_id = $1 AND version = $2\", [user_id, v]),", new="                   with {:ok, _} <- query(\"SELECT 1 WHERE $1::text IS NOT NULL AND $2::bigint IS NOT NULL\", [user_id, v]),", tests=B + " " + V),
  # ── version rows cap ──
  dict(id="R01", label="markers not counted in the row cap", file=ST, old="query(\"SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1\", [user_id]),\n           :ok <- if(rows >= max_version_rows()", new="query(\"SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1 AND deleted_at IS NULL\", [user_id]),\n           :ok <- if(rows >= max_version_rows()", tests=B),
  dict(id="R02", label="row cap off by one (>)", file=ST, old="if(rows >= max_version_rows()", new="if(rows > max_version_rows()", tests=B),
  dict(id="R03", label="default row cap 2000", file=ST, old="@default_max_version_rows 1000", new="@default_max_version_rows 2000", tests=B),
  dict(id="R04", label="row cap counts every user's rows", file=ST, old="query(\"SELECT count(*) FROM room_key_backup_versions WHERE user_id = $1\", [user_id]),\n           :ok <- if(rows >= max_version_rows()", new="query(\"SELECT count(*) FROM room_key_backup_versions WHERE $1::text IS NOT NULL\", [user_id]),\n           :ok <- if(rows >= max_version_rows()", tests=B),
  dict(id="R05", label="row cap refusal is 429", file=H, old='defp reply_error(conn, :version_rows_quota), do: error(conn, 403, "M_FORBIDDEN",', new='defp reply_error(conn, :version_rows_quota), do: error(conn, 429, "M_LIMIT_EXCEEDED",', tests=B),
  # ── lock timeout ──
  dict(id="L01", label="no lock_timeout set", file=ST, old="query(\"SELECT set_config('lock_timeout', $1::text, true)\", [\"#{lock_timeout_ms()}ms\"])", new="query(\"SELECT $1::text\", [\"x\"])", tests=LT),
  dict(id="L02", label="default lock timeout 5 s", file=ST, old="@default_lock_timeout_ms 2000", new="@default_lock_timeout_ms 5000", tests=LT),
  dict(id="L03", label="lock timeout 55P03 not mapped (a 500)", file=ST, old="lock_not_available}}} -> {:error, :lock_timeout}", new="lock_not_available}}} -> {:error, :boom}", tests=LT),
  dict(id="L04", label="429 without retry_after_ms", file=H, old=', "retry_after_ms" => 1000})', new='})', tests=LT),
  dict(id="L05", label="a try-lock (timeout 1 ms) instead of a wait up to the timeout", file=ST, old='["#{lock_timeout_ms()}ms"]', new='["1ms"]', tests=LT),
  dict(id="L06", label="DELETE /keys takes the lock WITHOUT a timeout", file=ST, old="        with {:ok, _} <- lock_user(user_id),\n             :ok <- ensure_live(user_id, v),", new="        with " + LOCK + ",\n             :ok <- ensure_live(user_id, v),", tests=LT),
  dict(id="L07", label="a read waits for the lock", file=ST, old="    with {:ok, v} <- version_or_not_found(version),\n         {:ok, %{rows: rows}} <- read_sessions(user_id, v, scope) do", new="    with {:ok, v} <- version_or_not_found(version),\n         {:ok, _} <- query(\"SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))\", [user_id]),\n         {:ok, %{rows: rows}} <- read_sessions(user_id, v, scope) do", tests=LT),
  dict(id="L08", label="lock timeout answers 503", file=H, old="|> send_json(429, %{\"errcode\" => \"M_LIMIT_EXCEEDED\", \"error\" => \"Too many concurrent", new="|> send_json(503, %{\"errcode\" => \"M_LIMIT_EXCEEDED\", \"error\" => \"Too many concurrent", tests=LT),
  # ── bulk read bucket ──
  dict(id="K01", label="GET /keys has no bulk bucket", file=P, old="room_keys_bulk_read(conn, fn -> HttpRoomKeys.get_keys(conn, :all) end)", new="HttpRoomKeys.get_keys(conn, :all)", tests=L),
  dict(id="K02", label="GET /keys/{room} has no bulk bucket", file=P, old="room_keys_bulk_read(conn, fn -> HttpRoomKeys.get_keys(conn, {:room, room_id}) end)", new="HttpRoomKeys.get_keys(conn, {:room, room_id})", tests=L),
  dict(id="K03", label="the bulk bucket is the write bucket (same tier)", file=P, old='tier: "room_keys_bulk_read"', new='tier: "room_keys"', tests=L),
  dict(id="K04", label="the single-session GET is bulk limited", file=P, old="    HttpRoomKeys.get_keys(conn, {:session, room_id, session_id})\n", new="    room_keys_bulk_read(conn, fn -> HttpRoomKeys.get_keys(conn, {:session, room_id, session_id}) end)\n", tests=L),
  dict(id="K05", label="GET /version is bulk limited", file=P, old="  get \"/client/v3/room_keys/version\" do\n    HttpRoomKeys.get_version(conn)", new="  get \"/client/v3/room_keys/version\" do\n    room_keys_bulk_read(conn, fn -> HttpRoomKeys.get_version(conn) end)", tests=L),
  dict(id="K06", label="bulk burst 11", file=P, old="rate_per_min: 30, burst: 10, tier: \"room_keys_bulk_read\"", new="rate_per_min: 30, burst: 11, tier: \"room_keys_bulk_read\"", tests=L),
  dict(id="K07", label="bulk burst 9", file=P, old="rate_per_min: 30, burst: 10, tier: \"room_keys_bulk_read\"", new="rate_per_min: 30, burst: 9, tier: \"room_keys_bulk_read\"", tests=L),
  dict(id="K08", label="bulk bucket keyed by IP", file=P, old='tier: "room_keys_bulk_read", key: :user', new='tier: "room_keys_bulk_read", key: :ip', tests=L),
  dict(id="K09", label="bulk reads charge the write bucket too", file=P, old="    conn = Nebu.Web.Plugs.RateLimit.call(conn, @room_keys_bulk_read_rate_limit)\n    if conn.halted, do: conn, else: fun.()", new="    conn = Nebu.Web.Plugs.RateLimit.call(conn, @room_keys_bulk_read_rate_limit)\n    conn = if conn.halted, do: conn, else: Nebu.Web.Plugs.RateLimit.call(conn, @room_keys_write_rate_limit)\n    if conn.halted, do: conn, else: fun.()", tests=L),
  # ── no pre-auth parse ──
  dict(id="A01", label="JsonBody parses room_keys bodies before the authentication (5 MiB)", file=J, old='"v3", "room_keys" | _]} = conn, _opts), do: conn', new='"v3", "room_keys" | _]} = conn, _opts), do: parse(conn, @room_keys_parser_opts)', tests=R),
  dict(id="A02", label="any bearer (junk too) lifts the cap pre-auth (cycle-0 behaviour)", file=J, old='"v3", "room_keys" | _]} = conn, _opts), do: conn', new='"v3", "room_keys" | _]} = conn, _opts) do\n    case Plug.Conn.get_req_header(conn, "authorization") do\n      ["Bearer " <> token | _] when token != "" -> parse(conn, @room_keys_parser_opts)\n      _ -> parse(conn, @parser_opts)\n    end\n  end\n\n  def call(%Plug.Conn{path_info: ["_matrix", "client", "v3", "never_room_keys" | _]} = conn, _opts), do: conn', tests=R),
  dict(id="A03", label="the write rate limit runs AFTER the body parse", file=P, old="    conn = Nebu.Web.Plugs.RateLimit.call(conn, @room_keys_write_rate_limit)\n\n    if conn.halted do\n      conn\n    else\n      conn = Nebu.Web.Plugs.JsonBody.parse_room_keys(conn)\n      if conn.halted, do: conn, else: fun.(conn)\n    end", new="    conn = Nebu.Web.Plugs.JsonBody.parse_room_keys(conn)\n\n    if conn.halted do\n      conn\n    else\n      conn = Nebu.Web.Plugs.RateLimit.call(conn, @room_keys_write_rate_limit)\n      if conn.halted, do: conn, else: fun.(conn)\n    end", tests=L),
  dict(id="A04", label="room_keys body cap 1 MB", file=J, old="length: 5_242_880,", new="length: 1_000_000,", tests=L),
  dict(id="A05", label="room_keys body cap 5 MiB + 1", file=J, old="length: 5_242_880,", new="length: 5_242_881,", tests=L),
  dict(id="A06", label="malformed JSON of an authenticated request is not flagged", file=J, old="    Plug.Parsers.ParseError ->\n      %{conn | body_params: %{}} |> Plug.Conn.assign(:json_parse_error, true)\n  end\n\n  defp parse(", new="    Plug.Parsers.ParseError ->\n      %{conn | body_params: %{}}\n  end\n\n  defp parse(", tests=L),
  dict(id="A07", label="an oversize authenticated body is not answered 413 (re-raised)", file=J, old="    _ in Plug.Parsers.RequestTooLargeError ->\n      conn\n", new="    e in Plug.Parsers.RequestTooLargeError ->\n      reraise e, __STACKTRACE__\n      conn\n", tests=L),
  dict(id="A08", label="the write routes do not parse the body at all", file=P, old="      conn = Nebu.Web.Plugs.JsonBody.parse_room_keys(conn)\n      if conn.halted, do: conn, else: fun.(conn)", new="      if conn.halted, do: conn, else: fun.(conn)", tests=K),
  # ── route normalizer ──
  dict(id="N01", label="no room_keys anchor in the normalizer", file=RN, old='"room_keys" => %{2 => @room_id_placeholder, 3 => ":session_id"}', new='"room_keys_unused" => %{2 => @room_id_placeholder, 3 => ":session_id"}', tests=RNT + " " + G),
  dict(id="N02", label="the room id segment is not replaced", file=RN, old='"room_keys" => %{2 => @room_id_placeholder, 3 => ":session_id"}', new='"room_keys" => %{3 => ":session_id"}', tests=RNT),
  dict(id="N03", label="the session id segment is not replaced", file=RN, old='"room_keys" => %{2 => @room_id_placeholder, 3 => ":session_id"}', new='"room_keys" => %{2 => @room_id_placeholder}', tests=RNT + " " + G),
  # ── migration ──
  dict(id="X01", label="migration: no live-version index", file=MU, old="CREATE INDEX IF NOT EXISTS room_key_backup_versions_live_idx ON room_key_backup_versions (user_id, version) WHERE deleted_at IS NULL;", new="", tests=MIG),
  dict(id="X02", label="migration: the index is not partial", file=MU, old="(user_id, version) WHERE deleted_at IS NULL;", new="(user_id, version);", tests=MIG),
  dict(id="X03", label="migration: stale 000056 in the header", file=MU, old="-- 000058_room_key_backup.up.sql", new="-- 000056_room_key_backup.up.sql", tests=MIG),
  dict(id="X04", label="migration: the index on the wrong columns", file=MU, old="(user_id, version) WHERE deleted_at IS NULL;", new="(version, user_id) WHERE deleted_at IS NULL;", tests=MIG),
  # ── docs ──
  dict(id="D01", label="07-deployment: the old 'no server-side key backup' sentence is back", file="docs/architecture/07-deployment.md", old="HISTORICAL note (releases before story `server-side-key-backup`): Nebu had no server-side key backup then", new="Nebu has no server-side key backup", tests=DOCS),
  dict(id="D02", label="11-risks: the lock timeout is not mentioned", file="docs/architecture/11-risks.md", old="every writer has a lock timeout (2 s, 429)", new="every writer is bounded (2 s, 429)", tests=DOCS),
  dict(id="D03", label="08-concepts: the erasure paragraph does not name RoomKeyBackupStore", file="docs/architecture/08-concepts.md", old="The key backup writers `RoomKeyBackupStore.create_version/3` and `RoomKeyBackupStore.put_sessions/3` take the same per-user `sync_global` lock and refuse an erased user the same way", new="The key backup writers take the same per-user lock and refuse an erased user the same way", tests=DOCS),
  dict(id="D04", label="08-concepts: 'stored verbatim' is back", file="docs/architecture/08-concepts.md", old="are kept as opaque JSON text (the server re-encodes them canonically; it never interprets them)", new="are kept verbatim as opaque JSON text", tests=DOCS),
  dict(id="D05", label="story: the superseded marker is gone", file="docs/stories/e2ee-client-support/server-side-key-backup.md", old="- SUPERSEDED (cycle 1, Kassandra MEDIUM 3): the cycle-0 rule", new="- (cycle 1, Kassandra MEDIUM 3): the cycle-0 rule", tests=DOCS),
  dict(id="D06", label="CHANGELOG: the budget is not named", file="CHANGELOG.md", old="a per-user storage budget of 256 MiB over all live versions (`403 M_FORBIDDEN`); ", new="", tests=DOCS),
  dict(id="D07", label="08-concepts: the bulk bucket is not documented", file="docs/architecture/08-concepts.md", old="The two bulk reads (`GET /keys`, `GET /keys/{room}`) have a bucket of their own (30 per minute, burst 10 per user, 429 `M_LIMIT_EXCEEDED` with `retry_after_ms`)", new="The two bulk reads have a limit", tests=DOCS),
  dict(id="D08", label="08-concepts: the migration says 000056 again", file="docs/architecture/08-concepts.md", old="(migration 000058, runtime-role grants", new="(migration 000056, runtime-role grants", tests=DOCS),
  dict(id="D09", label="KNOWN-FAILURES: 000056 again", file="e2e/KNOWN-FAILURES.md", old="000058", new="000056", tests=DOCS),
  # ── splice (expected equivalent: not observable) ──
  dict(id="S01", label="the session_data of a bulk read is decoded and re-encoded again (no splice)", file=ST, old="      ~s(,\"session_data\":),\n      session_data,", new="      ~s(,\"session_data\":),\n      Jason.encode!(Jason.decode!(session_data)),", tests=K),
]
