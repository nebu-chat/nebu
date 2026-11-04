ST = "server/lib/nebu/matrix/room_key_backup_store.ex"
H = "server/lib/nebu/matrix/http_room_keys.ex"
P = "server/lib/nebu/web/router/protected.ex"
J = "server/lib/nebu/web/plugs/json_body.ex"
RN = "server/lib/nebu/web/log_store/route_normalizer.ex"
GATE = "server/lib/nebu/matrix/room_keys_read_gate.ex"
T = "test/nebu/matrix/"
B = T + "room_keys_budget_http_test.exs"
LT = T + "room_keys_lock_timeout_test.exs"
L = T + "room_keys_limits_http_test.exs"
R = T + "room_keys_routes_test.exs"
F = T + "room_keys_bulk_flight_test.exs"
PR = T + "room_keys_prune_runbook_test.exs"
DOCS = T + "room_keys_docs_test.exs"
RNT = "test/nebu/web/log_store/route_normalizer_test.exs"
E = "test/nebu/compliance/user_deletion_room_keys_test.exs"
C = T + "room_keys_concurrency_test.exs"
CON = "docs/architecture/08-concepts.md"
RISK = "docs/architecture/11-risks.md"
RUN = "docs/compliance/gdpr-deletion-runbook.md"
CL = "CHANGELOG.md"
SEC = "docs/stories/e2ee-client-support/security-reports/server-side-key-backup-security-review-2026-10-30.md"

SUM = "octet_length(room_id) + octet_length(session_id) + #{@row_overhead_bytes} + octet_length(session_data)"
BUMP = "query(\"SELECT pg_try_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))\", [user_id])"

MUTANTS = [
  # ── byte budget: default and the accounting parts ──
  dict(id="Q01", label="default budget 128 MiB instead of 64", file=ST, old="@default_max_bytes 64 * 1024 * 1024", new="@default_max_bytes 128 * 1024 * 1024", tests=B, slow=True),
  dict(id="Q02", label="default budget 32 MiB instead of 64", file=ST, old="@default_max_bytes 64 * 1024 * 1024", new="@default_max_bytes 32 * 1024 * 1024", tests=B, slow=True),
  dict(id="Q03", label="room_id bytes not counted", file=ST, old=SUM, new="#{@row_overhead_bytes} + octet_length(session_id) + octet_length(session_data)", tests=B),
  dict(id="Q04", label="session_id bytes not counted", file=ST, old=SUM, new="octet_length(room_id) + #{@row_overhead_bytes} + octet_length(session_data)", tests=B),
  dict(id="Q05", label="fixed row cost 127 instead of 128", file=ST, old="@row_overhead_bytes 128", new="@row_overhead_bytes 127", tests=B),
  dict(id="Q06", label="fixed row cost 129 instead of 128", file=ST, old="@row_overhead_bytes 128", new="@row_overhead_bytes 129", tests=B),
  dict(id="Q07", label="fixed row cost not counted at all", file=ST, old=SUM, new="octet_length(room_id) + octet_length(session_id) + octet_length(session_data)", tests=B),
  dict(id="Q08", label="ids counted in CHARACTERS (char_length) not bytes", file=ST, old=SUM, new="char_length(room_id) + char_length(session_id) + #{@row_overhead_bytes} + octet_length(session_data)", tests=B),
  dict(id="Q09", label="the fixed cost is added ONCE per user, not per row", file=ST, old="+ #{@row_overhead_bytes} + octet_length(session_data)), 0)::bigint", new="+ octet_length(session_data)), 0)::bigint + #{@row_overhead_bytes}", tests=B),
  dict(id="Q10", label="budget off by one (>= instead of >)", file=ST, old="if sessions + auth > max_bytes(), do:", new="if sessions + auth >= max_bytes(), do:", tests=B),
  dict(id="Q11", label="auth_data bytes not counted", file=ST, old="sum(octet_length(auth_data))", new="0 * sum(octet_length(auth_data))", tests=B),
  dict(id="Q12", label="session_data bytes not counted", file=ST, old="octet_length(session_id) + #{@row_overhead_bytes} + octet_length(session_data)", new="octet_length(session_id) + #{@row_overhead_bytes}", tests=B),

  # ── try-lock ──
  dict(id="K01", label="the lock WAITS again (pg_advisory_xact_lock, no try)", file=ST, old=BUMP, new="query(\"SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))\", [user_id])", tests=LT + " " + E),
  dict(id="K02", label="a busy lock is ignored (the writer runs without the lock)", file=ST, old="if locked?, do: {:ok, :locked}, else: {:error, :lock_busy}", new="_ = locked?\n      {:ok, :locked}", tests=LT + " " + E),
  dict(id="K03", label="a busy lock is answered 409 M_UNKNOWN instead of 429", file=H, old="defp reply_error(conn, :lock_busy), do: Nebu.Web.Plugs.RateLimit.respond_limited(conn, 1)", new="defp reply_error(conn, :lock_busy), do: error(conn, 409, \"M_UNKNOWN\", \"busy\")", tests=LT),
  dict(id="K04", label="a busy lock is a 429 WITHOUT retry_after_ms", file=H, old="defp reply_error(conn, :lock_busy), do: Nebu.Web.Plugs.RateLimit.respond_limited(conn, 1)", new="defp reply_error(conn, :lock_busy), do: error(conn, 429, \"M_LIMIT_EXCEEDED\", \"busy\")", tests=LT),
  dict(id="K05", label="a busy lock is a 500 (the :lock_busy error is not mapped)", file=H, old="defp reply_error(conn, :lock_busy), do: Nebu.Web.Plugs.RateLimit.respond_limited(conn, 1)", new="defp reply_error(conn, :lock_busy), do: error(conn, 500, \"M_UNKNOWN\", \"busy\")", tests=LT),
  dict(id="K06", label="lock_timeout safety net removed (a row lock waits for ever)", file=ST, old="query(\"SELECT set_config('lock_timeout', $1::text, true)\", [\"#{lock_timeout_ms()}ms\"])", new="query(\"SELECT $1::text\", [\"x\"])", tests=LT),
  dict(id="K07", label="SQLSTATE 55P03 is no longer a 429 (a row-lock timeout is a 500)", file=ST, old="{:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> {:error, :lock_timeout}", new="{:error, %Postgrex.Error{postgres: %{code: :never_matches}}} -> {:error, :lock_timeout}", tests=LT),
  dict(id="K08", label="the row-lock timeout seam default is 20 ms", file=ST, old="@default_lock_timeout_ms 2000", new="@default_lock_timeout_ms 20", tests=LT),
  dict(id="K09", label="reads take the per-user lock too", file=ST, old="def get_sessions(user_id, version, scope) when is_binary(user_id) and is_binary(version) do\n    with {:ok, v} <- version_or_not_found(version),", new="def get_sessions(user_id, version, scope) when is_binary(user_id) and is_binary(version) do\n    with {:ok, :locked} <- lock_user(user_id),\n         {:ok, v} <- version_or_not_found(version),", tests=LT),

  # ── bulk-read slots ──
  dict(id="G01", label="no per-user limit (any number of bulk reads of one user)", file=GATE, old="busy_user? = Enum.any?(state.holders, fn {_slot, {user, _pid}} -> user == user_id end)", new="busy_user? = false", tests=F),
  dict(id="G02", label="no node cap", file=GATE, old="map_size(state.holders) >= max_per_node()", new="false", tests=F),
  dict(id="G03", label="node cap default 3", file=GATE, old="@default_per_node 2", new="@default_per_node 3", tests=F),
  dict(id="G04", label="node cap default 1", file=GATE, old="@default_per_node 2", new="@default_per_node 1", tests=F),
  dict(id="G05", label="the slot of a KILLED request is never freed (DOWN ignored)", file=GATE, old="def handle_info({:DOWN, slot, :process, _pid, _reason}, state), do: {:noreply, %{state | holders: Map.delete(state.holders, slot)}}", new="def handle_info({:DOWN, _slot, :process, _pid, _reason}, state), do: {:noreply, state}", tests=F),
  dict(id="G06", label="the slot of a FINISHED request is never freed (only DOWN frees)", file=GATE, old="GenServer.cast(__MODULE__, {:release, slot})", new=":ok", tests=F),
  dict(id="G07", label="the 429 is decided AFTER the database work (fun runs before the slot is asked)", file=GATE, old="    case acquire(user_id) do\n      {:ok, slot} ->", new="    _early = fun.()\n\n    case acquire(user_id) do\n      {:ok, slot} ->", tests=F),
  dict(id="G08", label="bulk reads do not take a slot at all", file=P, old="case Nebu.Matrix.RoomKeysReadGate.run(conn.assigns[:current_user], fn -> fun.(conn) end) do", new="case {:ok, fun.(conn)} do", tests=F),
  dict(id="G09", label="GET /keys/{room} takes no slot (only GET /keys does)", file=P, old="room_keys_bulk_read(conn, fn conn -> HttpRoomKeys.get_keys(conn, {:room, room_id}) end)", new="(fn c -> c = Nebu.Web.Plugs.RateLimit.call(c, @room_keys_bulk_read_rate_limit); if c.halted, do: c, else: HttpRoomKeys.get_keys(c, {:room, room_id}) end).(conn)", tests=F),
  dict(id="G10", label="the user key is ignored: ANY holder blocks every user (one per node)", file=GATE, old="fn {_slot, {user, _pid}} -> user == user_id end", new="fn {_slot, {_user, _pid}} -> true end", tests=F),
  dict(id="G11", label="the single-session GET takes a slot too", file=P, old="    HttpRoomKeys.get_keys(conn, {:session, room_id, session_id})\n  end\n\n  put \"/client/v3/room_keys/keys/:room_id/:session_id\" do", new="    room_keys_bulk_read(conn, fn conn -> HttpRoomKeys.get_keys(conn, {:session, room_id, session_id}) end)\n  end\n\n  put \"/client/v3/room_keys/keys/:room_id/:session_id\" do", tests=F + " " + L),
  dict(id="G12", label="the version GETs take a slot", file=P, old="room_keys_version_read(conn, fn conn -> HttpRoomKeys.get_version(conn) end)", new="room_keys_bulk_read(conn, fn conn -> HttpRoomKeys.get_version(conn) end)", tests=F + " " + L),
  dict(id="G13", label="the gate monitors nobody (a killed request is never noticed)", file=GATE, old="slot = Process.monitor(pid)", new="slot = make_ref()", tests=F),

  # ── rate limits ──
  dict(id="R01", label="write burst 6", file=P, old="rate_per_min: 60, burst: 5, tier: \"room_keys\"", new="rate_per_min: 60, burst: 6, tier: \"room_keys\"", tests=L),
  dict(id="R02", label="write burst 4", file=P, old="rate_per_min: 60, burst: 5, tier: \"room_keys\"", new="rate_per_min: 60, burst: 4, tier: \"room_keys\"", tests=L),
  dict(id="R03", label="write rate 120 per minute", file=P, old="rate_per_min: 60, burst: 5, tier: \"room_keys\"", new="rate_per_min: 120, burst: 5, tier: \"room_keys\"", tests=L),
  dict(id="R04", label="write rate 30 per minute", file=P, old="rate_per_min: 60, burst: 5, tier: \"room_keys\"", new="rate_per_min: 30, burst: 5, tier: \"room_keys\"", tests=L),
  dict(id="R05", label="bulk burst 4", file=P, old="rate_per_min: 30, burst: 3, tier: \"room_keys_bulk_read\"", new="rate_per_min: 30, burst: 4, tier: \"room_keys_bulk_read\"", tests=L),
  dict(id="R06", label="bulk burst 2", file=P, old="rate_per_min: 30, burst: 3, tier: \"room_keys_bulk_read\"", new="rate_per_min: 30, burst: 2, tier: \"room_keys_bulk_read\"", tests=L),
  dict(id="R07", label="bulk rate 60 per minute", file=P, old="rate_per_min: 30, burst: 3, tier: \"room_keys_bulk_read\"", new="rate_per_min: 60, burst: 3, tier: \"room_keys_bulk_read\"", tests=L),
  dict(id="R08", label="version bucket burst 31", file=P, old="rate_per_min: 120, burst: 30, tier: \"room_keys_version_read\"", new="rate_per_min: 120, burst: 31, tier: \"room_keys_version_read\"", tests=L),
  dict(id="R09", label="version bucket burst 29", file=P, old="rate_per_min: 120, burst: 30, tier: \"room_keys_version_read\"", new="rate_per_min: 120, burst: 29, tier: \"room_keys_version_read\"", tests=L),
  dict(id="R10", label="version bucket rate 60 per minute", file=P, old="rate_per_min: 120, burst: 30, tier: \"room_keys_version_read\"", new="rate_per_min: 60, burst: 30, tier: \"room_keys_version_read\"", tests=L),
  dict(id="R11", label="GET /version is not limited", file=P, old="room_keys_version_read(conn, fn conn -> HttpRoomKeys.get_version(conn) end)", new="HttpRoomKeys.get_version(conn)", tests=L),
  dict(id="R12", label="GET /version/{v} is not limited", file=P, old="room_keys_version_read(conn, fn conn -> HttpRoomKeys.get_version(conn, version) end)", new="HttpRoomKeys.get_version(conn, version)", tests=L),
  dict(id="R13", label="the version bucket IS the bulk bucket (same tier)", file=P, old="tier: \"room_keys_version_read\"", new="tier: \"room_keys_bulk_read\"", tests=L),
  dict(id="R14", label="the version bucket IS the write bucket (same tier)", file=P, old="tier: \"room_keys_version_read\"", new="tier: \"room_keys\"", tests=L),
  dict(id="R15", label="GET /version and GET /version/{v} have buckets of their own each (tier by route)", file=P, old="room_keys_version_read(conn, fn conn -> HttpRoomKeys.get_version(conn, version) end)", new="(fn c -> c = Nebu.Web.Plugs.RateLimit.call(c, Nebu.Web.Plugs.RateLimit.init(rate_per_min: 120, burst: 30, tier: \"room_keys_version_n\", key: :user)); if c.halted, do: c, else: HttpRoomKeys.get_version(c, version) end).(conn)", tests=L),
  dict(id="R16", label="the single-session GET is limited with the version bucket", file=P, old="    HttpRoomKeys.get_keys(conn, {:session, room_id, session_id})\n  end\n\n  put \"/client/v3/room_keys/keys/:room_id/:session_id\" do", new="    room_keys_version_read(conn, fn conn -> HttpRoomKeys.get_keys(conn, {:session, room_id, session_id}) end)\n  end\n\n  put \"/client/v3/room_keys/keys/:room_id/:session_id\" do", tests=L),

  # ── JsonBody decoded segments / normalizer ──
  dict(id="J01", label="JsonBody skip clause matches the RAW segments again", file=J, old="case Enum.map(Enum.take(path_info, 4), &decode_segment/1) do", new="case Enum.take(path_info, 4) do", tests=R),
  dict(id="J02", label="JsonBody decodes only the room_keys segment (v%33 / %5Fmatrix / %63lient stay raw)", file=J, old="case Enum.map(Enum.take(path_info, 4), &decode_segment/1) do", new="case Enum.take(path_info, 3) ++ Enum.map(Enum.drop(Enum.take(path_info, 4), 3), &decode_segment/1) do", tests=R),
  dict(id="J03", label="JsonBody decodes only the first three segments (room%5Fkeys stays raw)", file=J, old="case Enum.map(Enum.take(path_info, 4), &decode_segment/1) do", new="case Enum.map(Enum.take(path_info, 3), &decode_segment/1) ++ Enum.drop(Enum.take(path_info, 4), 3) do", tests=R),
  dict(id="J04", label="JsonBody skip clause is gone (pre-auth parse back)", file=J, old="[\"_matrix\", \"client\", \"v3\", \"room_keys\"] -> conn", new="[\"_matrix\", \"client\", \"v3\", \"room_keys_x\"] -> conn", tests=R),
  dict(id="N01", label="normalizer: the version number is :room_id again", file=RN, old="{\"room_keys\", {_idx, \"version\"}} -> %{2 => \":version\"}", new="{\"room_keys\", {_idx, \"version\"}} -> %{2 => \":room_id\"}", tests=RNT),
  dict(id="N02", label="normalizer: placeholder is :versions", file=RN, old="{\"room_keys\", {_idx, \"version\"}} -> %{2 => \":version\"}", new="{\"room_keys\", {_idx, \"version\"}} -> %{2 => \":versions\"}", tests=RNT),
  dict(id="N03", label="normalizer: every room_keys path gets the version rule (keys/{room} loses :room_id)", file=RN, old="{\"room_keys\", {_idx, \"version\"}} -> %{2 => \":version\"}", new="{\"room_keys\", {_idx, _}} -> %{2 => \":version\"}", tests=RNT),
  dict(id="N04", label="normalizer: the version number is left in the template", file=RN, old="{\"room_keys\", {_idx, \"version\"}} -> %{2 => \":version\"}", new="{\"room_keys\", {_idx, \"version\"}} -> %{}", tests=RNT),

  # ── docs pins ──
  dict(id="D01", label="08-concepts: write burst 30 again", file=CON, old="(tier `room_keys`: 60 per minute, burst 5)", new="(tier `room_keys`: 60 per minute, burst 30)", tests=DOCS),
  dict(id="D02", label="08-concepts: bulk burst 10 again", file=CON, old="(30 per minute, burst 3 per user, 429", new="(30 per minute, burst 10 per user, 429", tests=DOCS),
  dict(id="D03", label="08-concepts: budget 256 MiB again", file=CON, old="default 64 MiB, seam `:nebu, :room_keys_max_bytes_per_user`", new="default 256 MiB, seam `:nebu, :room_keys_max_bytes_per_user`", tests=DOCS),
  dict(id="D04", label="08-concepts: the fixed 128 bytes per row dropped", file=CON, old="plus a fixed 128 bytes per row plus the canonical bytes", new="plus the canonical bytes", tests=DOCS),
  dict(id="D05", label="08-concepts: the try-lock is a waiting lock again", file=CON, old="*Per-user lock (try-lock):* every writer takes the `sync_global` lock with `pg_try_advisory_xact_lock`: a busy lock is `429 M_LIMIT_EXCEEDED` with `retry_after_ms` at once", new="*Per-user lock:* every writer waits for the `sync_global` lock up to 2 s and then answers `429 M_LIMIT_EXCEEDED` with `retry_after_ms`", tests=DOCS),
  dict(id="D06", label="08-concepts: no node cap for bulk reads", file=CON, old="at most TWO per node (seam `:nebu, :room_keys_max_concurrent_bulk_reads_per_node`, default 2)", new="no cap per node (seam `:nebu, :room_keys_max_concurrent_bulk_reads_per_node`)", tests=DOCS),
  dict(id="D07", label="08-concepts: the light version bucket dropped", file=CON, old="`GET /version` and `GET /version/{version}` (a `count(*)` over up to 100 000 rows) have a light bucket of their own (120 per minute, burst 30 per user, shared by the two routes, separate from the bulk and the write buckets); ", new="", tests=DOCS),
  dict(id="D08", label="08-concepts: node-local statement dropped", file=CON, old=" All buckets and slots are node-local: in a cluster of N nodes the effective limit is N x the documented limit.", new="", tests=DOCS),
  dict(id="D09", label="11-risks: the peak memory numbers dropped", file=RISK, old="one bulk read peaked at about 300-350 MiB for a version at the former 256 MiB budget (the spliced iodata copy, the rows, and +0.75x with gzip); at the 64 MiB budget it is about 64 MiB x 2.5, and at most two run per node; streaming the response is the recorded follow-up.", new="memory use is bounded.", tests=DOCS),
  dict(id="D10", label="11-risks: no 64 MiB x 2.5 after number", file=RISK, old="at the 64 MiB budget it is about 64 MiB x 2.5", new="at the 64 MiB budget it is small", tests=DOCS),
  dict(id="D11", label="11-risks: the RLS USING (true) residual dropped", file=RISK, old="the RLS policies are `USING (true)` like the sibling tables (accepted: isolation rests on the `user_id` predicate of every statement); ", new="", tests=DOCS),
  dict(id="D12", label="11-risks: the O(scan) per write follow-up dropped", file=RISK, old="the byte check is O(scan) of the user's rows on every write (follow-up: an O(1) counter column)", new="the byte check is cheap", tests=DOCS),
  dict(id="D13", label="11-risks: the single-flight / node cap sentence dropped", file=RISK, old="at most ONE in flight per user and TWO per node (`:room_keys_max_concurrent_bulk_reads_per_node`, a monitor based slot, 429 before any database work), ", new="", tests=DOCS),
  dict(id="D14", label="11-risks: the node-local statement dropped", file=RISK, old="the rate-limit buckets and the slots are node-local (a cluster of N nodes allows N x the limit); ", new="", tests=DOCS),
  dict(id="D15", label="CHANGELOG: 256 MiB again", file=CL, old="a per-user storage budget of 64 MiB over all live versions", new="a per-user storage budget of 256 MiB over all live versions", tests=DOCS),
  dict(id="D16", label="security report: 000056_room_key_backup again", file=SEC, old="migration `000058_room_key_backup.up.sql`", new="migration `000056_room_key_backup.up.sql`", tests=DOCS),
  dict(id="D17", label="runbook: prune SQL deletes the highest marker too (no keep rule)", file=RUN, old="\n  AND version < (SELECT max(version) FROM room_key_backup_versions WHERE user_id = '<user_id>' AND deleted_at IS NOT NULL);", new=";", tests=PR),
  dict(id="D18", label="runbook: prune SQL also deletes LIVE versions (marker condition dropped from the outer WHERE)", file=RUN, old="WHERE user_id = '<user_id>'\n  AND deleted_at IS NOT NULL\n  AND version <", new="WHERE user_id = '<user_id>'\n  AND version <", tests=PR),
  dict(id="D19", label="runbook: prune SQL is not scoped to the user (other users' markers go too)", file=RUN, old="WHERE user_id = '<user_id>'\n  AND deleted_at IS NOT NULL\n  AND version <", new="WHERE user_id IS NOT NULL\n  AND deleted_at IS NOT NULL\n  AND version <", tests=PR),
  dict(id="D20", label="runbook: the prune SQL block is no sql block any more", file=RUN, old="```sql\nDELETE FROM room_key_backup_versions\nWHERE user_id = '<user_id>'", new="```text\nDELETE FROM room_key_backup_versions\nWHERE user_id = '<user_id>'", tests=PR + " " + DOCS),
  dict(id="D21", label="runbook: the prune SQL keeps the LOWEST marker instead of the highest", file=RUN, old="AND version < (SELECT max(version) FROM room_key_backup_versions WHERE user_id = '<user_id>' AND deleted_at IS NOT NULL);", new="AND version > (SELECT min(version) FROM room_key_backup_versions WHERE user_id = '<user_id>' AND deleted_at IS NOT NULL);", tests=PR),
  dict(id="D22", label="the version-rows 403 no longer points at the operator", file=H, old="(deleted ones count): contact the server administrator", new="(deleted ones count)", tests=PR),
]
