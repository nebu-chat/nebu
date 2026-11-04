"""Mutants of cycle 1 (to-device-messaging): the new rules (sender total, byte bucket, device-level fairness, own fence key, delivery faults, timeouts, device row lock,
ack position, facade, docs pins) plus the RE-TARGETED versions (suffix `c`) of the cycle 0 mutants whose text moved with the cycle 1 reference (`reference-impl-cycle1.diff`;
mutants.py stays the record of cycle 0 for everything that still applies).

Run from the repo root with reference-impl-cycle1.diff applied on top of the staged tree:
  python3 .../mutation/check.py .../mutation/mutants_c1.py      # dry run: every `old` occurs exactly once
  python3 .../mutation/mutate.py .../mutation/mutants_c1.py <log> [ids]
"""
ST = "server/lib/nebu/matrix/to_device_store.ex"
H = "server/lib/nebu/matrix/http_to_device.ex"
GATE = "server/lib/nebu/matrix/to_device_send_gate.ex"
P = "server/lib/nebu/web/router/protected.ex"
DKS = "server/lib/nebu/matrix/device_key_store.ex"
UD = "server/lib/nebu/compliance/user_deletion.ex"
WK = "server/lib/nebu/workers/to_device_purge_worker.ex"
FAC = "server/lib/nebu/matrix.ex"
CL = "CHANGELOG.md"
CON = "docs/architecture/08-concepts.md"
DEP = "docs/architecture/07-deployment.md"
RISK = "docs/architecture/11-risks.md"
T = "test/nebu/matrix/"
SB = T + "to_device_sender_budget_test.exs"
DF = T + "to_device_delivery_faults_test.exs"
LIM = T + "to_device_limits_http_test.exs"
SYNC = T + "to_device_sync_http_test.exs"
SEND = T + "to_device_send_http_test.exs"
CONC = T + "to_device_concurrency_test.exs"
LOG = T + "to_device_logging_test.exs"
ROUTES = T + "to_device_routes_test.exs"
GT = T + "to_device_send_gate_test.exs"
DOCS = T + "to_device_docs_test.exs"
PUR = T + "to_device_purge_test.exs"
IDD = T + "to_device_identical_device_test.exs"
ERA = "test/nebu/compliance/user_deletion_to_device_test.exs"

# the exact texts of the reference (to_device_store.ex)
DEV_SHARE = "WINDOW w AS (PARTITION BY user_id, device_id ORDER BY stream_pos DESC)) s WHERE rn > $4 OR total > $6"
USR_SHARE = "WINDOW w AS (PARTITION BY user_id ORDER BY stream_pos DESC)) s WHERE rn > $3 OR total > $5"
TOTAL = "WINDOW w AS (ORDER BY stream_pos DESC)) s WHERE rn > $2 OR total > $4"
DEV_CNT = 'fair_count_sql("user_id, device_id", pairs, "$3")), [us, ds, l.max_per_device]}'
DEV_BYT = 'fair_bytes_sql("user_id, device_id", pairs, "$3", "$4")), [us, ds, l.max_bytes_per_device, @row_overhead]}'
USR_CNT = 'fair_count_sql("user_id", "user_id = ANY($1::text[])", "$2")), [users, l.max_per_user]}'
USR_BYT = 'fair_bytes_sql("user_id", "user_id = ANY($1::text[])", "$2", "$3")), [users, l.max_bytes_per_user, @row_overhead]}'
ACK_SQL = "(SELECT stream_pos FROM to_device_messages WHERE user_id = $1 AND device_id = $2 AND delivery_seq IS NOT NULL AND delivery_seq <= $3 FOR UPDATE SKIP LOCKED)"
STAMP_SEL = "(SELECT stream_pos FROM to_device_messages WHERE stream_pos = ANY($2::bigint[]) AND delivery_seq IS NULL FOR UPDATE SKIP LOCKED)"


def plain_count(cols_expr, filt, cap):
    return 'skip_locked("SELECT stream_pos FROM (SELECT stream_pos, row_number() OVER (PARTITION BY %s ORDER BY stream_pos DESC) AS rn FROM to_device_messages WHERE %s) s WHERE rn > %s")' % (cols_expr, filt, cap)


def plain_bytes(cols_expr, filt, cap, oh):
    return 'skip_locked("SELECT stream_pos FROM (SELECT stream_pos, sum(bytes + %s) OVER (PARTITION BY %s ORDER BY stream_pos DESC) AS total FROM to_device_messages WHERE %s) s WHERE total > %s")' % (oh, cols_expr, filt, cap)


I06_OLD = """    result =
      transact(fn ->
        with {:ok, _} <- set_timeouts(),
             :ok <- lock_sender(sender),
             {:ok, fresh?} <- record_txn(sender, sender_device, event_type, txn_id) do
          if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: {:ok, []}
        end
      end)
"""
I06_NEW = """    {:ok, fresh?} = record_txn(sender, sender_device, event_type, txn_id)

    result =
      transact(fn ->
        with {:ok, _} <- set_timeouts(),
             :ok <- lock_sender(sender) do
          if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: {:ok, []}
        end
      end)
"""

MUTANTS = [
  # ═══ HIGH #1: per-SENDER total over all recipients ═══
  dict(id="K01", label="sender total: message cap removed", file=ST, old=TOTAL, new=TOTAL.replace("rn > $2", "rn > $2 + 1000000"), tests=SB),
  dict(id="K02", label="sender total: message cap off by one", file=ST, old=TOTAL, new=TOTAL.replace("rn > $2", "rn > $2 + 1"), tests=SB),
  dict(id="K03", label="sender total: byte budget removed", file=ST, old=TOTAL, new=TOTAL.replace("total > $4", "total > $4 + 1000000000"), tests=SB),
  dict(id="K04", label="sender total: byte budget off by one (>=)", file=ST, old=TOTAL, new=TOTAL.replace("total > $4", "total >= $4"), tests=SB),
  dict(id="K05", label="sender total: evicts the NEWEST rows", file=ST, old=TOTAL, new=TOTAL.replace("ORDER BY stream_pos DESC", "ORDER BY stream_pos ASC"), tests=SB),
  dict(id="K06", label="sender total: counted per recipient USER (no total over recipients)", file=ST, old=TOTAL, new=TOTAL.replace("WINDOW w AS (ORDER BY", "WINDOW w AS (PARTITION BY user_id ORDER BY"), tests=SB),
  dict(id="K07", label="sender total: not scoped to the sender (another sender's rows count and go)", file=ST,
       old="FROM to_device_messages WHERE sender = $1\n         WINDOW w AS (ORDER BY stream_pos DESC)", new="FROM to_device_messages WHERE $1::text IS NOT NULL\n         WINDOW w AS (ORDER BY stream_pos DESC)", tests=SB),
  dict(id="K08", label="sender total: row overhead not counted", file=ST, old="sum(bytes + $3) OVER w AS total\n         FROM to_device_messages WHERE sender = $1\n         WINDOW w AS (ORDER BY",
       new="sum(bytes + 0 * $3) OVER w AS total\n         FROM to_device_messages WHERE sender = $1\n         WINDOW w AS (ORDER BY", tests=SB),
  dict(id="K09", label="default per sender total 4001 messages", file=ST, old="max_per_sender_total: 4000", new="max_per_sender_total: 4001", tests=ROUTES),
  dict(id="K10", label="default per sender total 17 MiB", file=ST, old="max_bytes_per_sender_total: 16 * 1024 * 1024", new="max_bytes_per_sender_total: 17 * 1024 * 1024", tests=ROUTES),
  dict(id="K11", label="default byte bucket 5 MiB per minute", file=ST, old="rate_bytes_per_min: 4 * 1024 * 1024", new="rate_bytes_per_min: 5 * 1024 * 1024", tests=ROUTES),
  dict(id="K12", label="default byte bucket burst 9 MiB", file=ST, old="rate_bytes_burst: 8 * 1024 * 1024", new="rate_bytes_burst: 9 * 1024 * 1024", tests=ROUTES),
  dict(id="K13", label="default sender-device byte share 2 MiB", file=ST, old="max_bytes_per_sender_device: 1024 * 1024", new="max_bytes_per_sender_device: 2 * 1024 * 1024", tests=ROUTES),
  dict(id="K14", label="default statement timeout 3000 ms", file=ST, old="statement_timeout_ms: 2000", new="statement_timeout_ms: 3000", tests=ROUTES),

  # ═══ byte-cost rate bucket ═══
  dict(id="K20", label="bucket: not charged at all", file=ST, old=":ok <- charge_bytes(sender, entries),", new=":ok <- :ok,", tests=SB),
  dict(id="K21", label="bucket: ONE bucket for all senders", file=ST, old='{{"to_device_bytes", sender}, cost,', new='{{"to_device_bytes", "all"}, cost,', tests=SB),
  dict(id="K22", label="bucket: row overhead not charged", file=ST, old="        row = byte_size(content) + @row_overhead\n        acc + if(", new="        row = byte_size(content)\n        acc + if(", tests=SB),
  dict(id="K23", label="bucket: a `*` is charged as ONE row", file=ST, old='acc + if(device == "*", do: min(row * l.max_targets_per_request, l.max_fanout_bytes_per_request), else: row)', new="acc + row", tests=SB),
  dict(id="K24", label="bucket: a `*` is charged above the fan-out budget (uncapped)", file=ST, old='do: min(row * l.max_targets_per_request, l.max_fanout_bytes_per_request)', new="do: row * l.max_targets_per_request", tests=SB),
  dict(id="K25", label="bucket: a retried (duplicate) transaction is charged again", file=ST, old="if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: {:ok, []}",
       new="if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: (case charge_bytes(sender, entries) do\n            :ok -> {:ok, []}\n            err -> err\n          end)", tests=SB),
  dict(id="K26", label="bucket: charged with the ACCEPTED bytes (existence oracle)", file=ST,
       edits=[(ST, ":ok <- charge_bytes(sender, entries),\n         {:ok, allowed}", "{:ok, allowed}"),
              (ST, "         {:ok, targets} <- resolve_targets(sender, sender_device, Enum.filter(entries, &MapSet.member?(allowed, &1.user_id))) do",
               "         {:ok, targets} <- resolve_targets(sender, sender_device, Enum.filter(entries, &MapSet.member?(allowed, &1.user_id))),\n         :ok <- charge_bytes(sender, Enum.filter(entries, &MapSet.member?(allowed, &1.user_id))) do")], tests=SB),
  dict(id="K27", label="bucket: the 429 carries a fixed retry of 1 s", file=H, old="{:error, {:bytes_rate, seconds}} -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, seconds)", new="{:error, {:bytes_rate, _seconds}} -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, 1)", tests=SB),
  dict(id="K28", label="bucket: a refusal is a 500 (clause removed)", file=H, old="        {:error, {:bytes_rate, seconds}} -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, seconds)\n", new="", tests=SB),

  # ═══ MEDIUM #2: fair eviction at the DEVICE level, sender byte share per device ═══
  dict(id="K40", label="device count cap NOT fair (plain oldest first)", file=ST, old='skip_locked(fair_count_sql("user_id, device_id", pairs, "$3"))', new=plain_count("user_id, device_id", "#{pairs}", "$3"), tests=SB),
  dict(id="K41", label="device byte budget NOT fair (plain oldest first)", file=ST, old='skip_locked(fair_bytes_sql("user_id, device_id", pairs, "$3", "$4"))', new=plain_bytes("user_id, device_id", "#{pairs}", "$3", "$4"), tests=SB),
  dict(id="K42", label="sender-device byte share removed", file=ST, old=DEV_SHARE, new=DEV_SHARE.replace("total > $6", "total > $6 + 1000000000"), tests=SB),
  dict(id="K43", label="sender-device byte share off by one (>=)", file=ST, old=DEV_SHARE, new=DEV_SHARE.replace("total > $6", "total >= $6"), tests=SB),
  dict(id="K44", label="sender-device byte share without the row overhead", file=ST, old="sum(bytes + $5) OVER w AS total\n         FROM to_device_messages WHERE sender = $1 AND (user_id, device_id)", new="sum(bytes + 0 * $5) OVER w AS total\n         FROM to_device_messages WHERE sender = $1 AND (user_id, device_id)", tests=SB),

  # ═══ MEDIUM #3: own erasure fence ═══
  dict(id="K50", label="the SEND takes sync_global as the sender fence again", file=ST, old="SELECT pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0))", new="SELECT pg_try_advisory_xact_lock_shared(hashtextextended('sync_global|' || $1::text, 0))", tests=ERA),
  dict(id="K51", label="the RECIPIENT fence is sync_global again", file=ST, old="WHERE pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || user_id, 0))", new="WHERE pg_try_advisory_xact_lock_shared(hashtextextended('sync_global|' || user_id, 0))", tests=ERA),
  dict(id="K52", label="the erasure does not take the to_device_erasure fence", file=UD, old="\"SELECT pg_advisory_xact_lock(hashtextextended('to_device_erasure|' || $1::text, 0))\"", new="\"SELECT pg_advisory_xact_lock(hashtextextended('to_device_erasureX|' || $1::text, 0))\"", tests=ERA),
  dict(id="K53", label="the erasure takes the fence SHARED (a send in flight does not block it)", file=UD, old="\"SELECT pg_advisory_xact_lock(hashtextextended('to_device_erasure|' || $1::text, 0))\"", new="\"SELECT pg_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0))\"", tests=ERA),
  dict(id="K54", label="the recipient fence is not taken", file=ST, old="locked AS MATERIALIZED (SELECT user_id FROM cand WHERE pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || user_id, 0)))", new="locked AS MATERIALIZED (SELECT user_id FROM cand)", tests=ERA),
  dict(id="K55", label="the recipient fence WAITS (blocking lock)", file=ST, old="WHERE pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || user_id, 0))", new="WHERE pg_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || user_id, 0)) IS NOT NULL", tests=ERA + " " + DOCS),
  dict(id="K56", label="the sender fence is not taken", file=ST,
       old="    with {:ok, %{rows: [[locked?]]}} <- query(\"SELECT pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0))\", [sender]) do\n      if locked?, do: ensure_not_erased(sender), else: {:error, :lock_busy}\n    end",
       new="    ensure_not_erased(sender)", tests=ERA),
  dict(id="K57", label="the sender fence WAITS (blocking lock)", file=ST, old="SELECT pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0))", new="SELECT pg_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0)) IS NOT NULL", tests=DOCS),
  dict(id="K58", label="a busy sender fence is not a 429", file=H, old="busy in [:lock_timeout, :lock_busy, :statement_timeout]", new="busy in [:lock_timeout, :statement_timeout]", tests=ERA),

  # ═══ MEDIUM #4: a delivery fault never fails /sync, SKIP LOCKED ═══
  dict(id="K60", label="a failed delivery loses the position (answer carries 0)", file=P, old="{[], if(ack, do: ack, else: 0)}", new="{[], 0}", tests=DF),
  dict(id="K61", label="a failed delivery fails the sync again (503)", file=P,
       old="          {[], if(ack, do: ack, else: 0)}\n", new="          throw({:td_failed, reason})\n", tests=DF + " " + LOG),
  dict(id="K62", label="the ack DELETE waits for locked rows (no SKIP LOCKED)", file=ST, old=ACK_SQL, new=ACK_SQL.replace(" SKIP LOCKED", ""), tests=DF),
  dict(id="K63", label="the stamp UPDATE waits for locked rows (no SKIP LOCKED)", file=ST, old=STAMP_SEL, new=STAMP_SEL.replace(" SKIP LOCKED", ""), tests=DF),
  dict(id="K64", label="the eviction waits for locked rows (no SKIP LOCKED)", file=ST, old="locked AS (SELECT stream_pos FROM to_device_messages WHERE stream_pos IN (SELECT stream_pos FROM doomed) FOR UPDATE SKIP LOCKED)",
       new="locked AS (SELECT stream_pos FROM to_device_messages WHERE stream_pos IN (SELECT stream_pos FROM doomed) FOR UPDATE)", tests=DF),
  dict(id="K65", label="the delivery failure log names the database error (not the kind)", file=P, old='Logger.error("sync: the to-device messages could not be read (#{to_device_error_kind(reason)})")', new='Logger.error("sync: the to-device messages could not be read (#{inspect(reason)})")', tests=LOG),

  # ═══ MEDIUM #5: slots and statement timeout ═══
  dict(id="K70", label="gate default per node 7", file=GATE, old="@default_per_node 6", new="@default_per_node 7", tests=GT + " " + ROUTES),
  dict(id="K71", label="gate default per node 32 again", file=GATE, old="@default_per_node 6", new="@default_per_node 32", tests=GT),
  dict(id="K72", label="no statement timeout (set to 0)", file=ST, old='"#{limits().statement_timeout_ms}ms"]', new='"0ms"]', tests=DF),
  dict(id="K73", label="a send over the statement timeout is a 500 (not mapped to 429)", file=H, old="busy in [:lock_timeout, :lock_busy, :statement_timeout]", new="busy in [:lock_timeout, :lock_busy]", tests=DF),
  dict(id="K74", label="the cancelled statement is not recognised (raw database error)", file=ST, old="      {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} -> {:error, :statement_timeout}\n", new="", tests=DF),
  dict(id="K75", label="lock_timeout not set (waits for ever behind a held record)", file=ST, old="set_config('lock_timeout', $1::text, true)", new="set_config('lock_timeout', CASE WHEN $1::text = 'zzz' THEN $1::text ELSE '0' END, true)", tests=CONC),

  # ═══ LOW #6: device row locks ═══
  dict(id="K80", label="send: explicit devices read without FOR KEY SHARE", file=ST, old="IN (SELECT * FROM unnest($1::text[], $2::text[])) FOR KEY SHARE\"", new="IN (SELECT * FROM unnest($1::text[], $2::text[]))\"", tests=DF),
  dict(id="K81", label="send: `*` devices read without FOR KEY SHARE", file=ST, old="LIMIT $2 FOR KEY SHARE) d", new="LIMIT $2) d", tests=DF),
  dict(id="K82", label="delete_device does not lock the device row first", file=DKS, old="          lock_device_row!(Nebu.Repo, user_id, device_id)\n", new="", tests=DF),
  dict(id="K83", label="delete_device! does not lock the device row first", file=DKS, old="    :ok = lock_device_row!(repo, user_id, device_id)\n", new="", tests=DF),
  dict(id="K84", label="the device lock is FOR NO KEY UPDATE (does not conflict with KEY SHARE)", file=DKS, old="SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", new="SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR NO KEY UPDATE", tests=DF),

  # ═══ code review MINOR 1-3 ═══
  dict(id="K90", label="position takes the fresh stamp number although nothing was stamped (lost race)", file=ST, old="if(MapSet.size(stamped_now) > 0, do: [seq | earlier], else: earlier)", new="[seq | earlier]", tests=DF + " " + CONC),
  dict(id="K91", label="the response carries rows it did not stamp", file=ST, old="is_integer(s) or MapSet.member?(stamped_now, pos)", new="true or is_integer(s) or MapSet.member?(stamped_now, pos)", tests=DF + " " + CONC),
  dict(id="K97", label="a pure redelivery claims no position (the retry token acknowledges nothing)", file=ST, old="[seq | earlier], else: earlier)", new="[seq | earlier], else: [])", tests=DF + " " + SYNC),
  dict(id="K98", label="the sync response byte cap is cut nowhere (SQL cut and the redundant Elixir cut removed)", file=ST,
       edits=[(ST, "WHERE c.rn = 1 OR c.total <= $7", "WHERE c.rn = 1 OR c.total <= $7 + 1000000000"), (ST, "batch = take_within_bytes(rows, l.sync_batch_bytes)", "batch = rows")], tests=SYNC),
  dict(id="K92", label="position of a MIXED batch ignores the earlier stamps (equivalent: nextval is above every earlier stamp)", file=ST, old="[seq | earlier], else: earlier)", new="[seq], else: earlier)", tests=SYNC),
  dict(id="K93", label="the advisory lock runs for every REQUESTED id (not only the matched)", file=ST,
       old="{:ok, active} <- active_users(List.flatten(rows)) do", new="{:ok, active0} <- active_users(users),\n         active = Enum.filter(active0, &(&1 in List.flatten(rows))) do", tests=DF),
  dict(id="K94", label="the worker calls ToDeviceStore directly (no facade)", file=WK, old="case Nebu.Matrix.purge_expired_to_device() do", new="case Nebu.Matrix.ToDeviceStore.purge_expired() do", tests=DOCS),
  dict(id="K95", label="the facade purges nothing", file=FAC, old="def purge_expired_to_device, do: Nebu.Matrix.ToDeviceStore.purge_expired()", new="def purge_expired_to_device, do: {:ok, %{messages: 0, txns: 0}}", tests=DF + " " + PUR),
  dict(id="K96", label="the worker fails on every run", file=WK, old="case Nebu.Matrix.purge_expired_to_device() do", new="case {:error, :boom} do", tests=PUR),

  # ═══ docs pins (07 / 08 / 11-risks / CHANGELOG / moduledoc) ═══
  dict(id="K100", label="08-concepts: the superseded 'covers exactly the batch' sentence is back", file=CON, old="covers exactly the messages the responses stamped", new="covers exactly the batch a response carried", tests=DOCS),
  dict(id="K101", label="08-concepts: 'at most 16 devices' is back", file=CON, old="about 16 devices (15 when the content fills the whole body)", new="at most 16 devices", tests=DOCS),
  dict(id="K102", label="08-concepts: lost-race sentence removed", file=CON, old="never exceeds its own stamps", new="never exceeds", tests=DOCS),
  dict(id="K103", label="08-concepts: the byte bucket is not node-local (N x removed)", file=CON, old="the same node-local N x rule", new="the same node-local rule", tests=DOCS),
  dict(id="K104", label="07-deployment: the worst-case footprint paragraph removed", file=DEP, old="Worst-case database footprint", new="Footprint", tests=DOCS),
  dict(id="K105", label="07-deployment: the sequence reset operator note removed", file=DEP, old="set `to_device_delivery_seq`", new="set the sequence", tests=DOCS),
  dict(id="K106", label="11-risks: the 'two are enough' residual wording is back", file=RISK, old="only MANY senders", new="two colluding co-members are enough: many colluding", tests=DOCS),
  dict(id="K107", label="11-risks: Jason.Fragment follow-up removed", file=RISK, old="`Jason.Fragment`", new="`Jason`", tests=DOCS),
  dict(id="K108", label="CHANGELOG: the old 32 node slots are back", file=CL, old="6 per node", new="32 per node", tests=DOCS),
  dict(id="K109", label="moduledoc: the sender total budget is not stated", file=ST, old="per SENDER over ALL recipients 4000 messages /", new="per SENDER over ALL recipients 4001 messages /", tests=DOCS),

  # ═══ RE-TARGETED cycle 0 mutants (suffix c) ═══
  dict(id="B01c", label="per-device count cap off by one", file=ST, old=DEV_CNT, new=DEV_CNT.replace("l.max_per_device]", "l.max_per_device + 1]"), tests=LIM),
  dict(id="B02c", label="per-device count cap removed", file=ST, old=DEV_CNT, new=DEV_CNT.replace("l.max_per_device]", "l.max_per_device + 1000000]"), tests=LIM),
  dict(id="B03c", label="per-device BYTE budget removed", file=ST, old=DEV_BYT, new=DEV_BYT.replace("l.max_bytes_per_device,", "l.max_bytes_per_device * 1000000,"), tests=LIM),
  dict(id="B06c", label="device byte budget one byte too big", file=ST, old=DEV_BYT, new=DEV_BYT.replace("l.max_bytes_per_device,", "l.max_bytes_per_device + 1,"), tests=LIM),
  dict(id="B07c", label="user MESSAGE cap removed", file=ST, old=USR_CNT, new=USR_CNT.replace("l.max_per_user]", "l.max_per_user + 1000000]"), tests=LIM),
  dict(id="B08c", label="user BYTE budget removed", file=ST, old=USR_BYT, new=USR_BYT.replace("l.max_bytes_per_user,", "l.max_bytes_per_user * 1000000,"), tests=LIM),
  dict(id="B09c", label="per-sender-device share removed (count)", file=ST, old=DEV_SHARE, new=DEV_SHARE.replace("rn > $4", "rn > $4 + 1000000"), tests=LIM),
  dict(id="B10c", label="per-sender-device share off by one (count)", file=ST, old=DEV_SHARE, new=DEV_SHARE.replace("rn > $4", "rn > $4 + 1"), tests=LIM),
  dict(id="B11c", label="per-sender-device share counted per USER", file=ST, old=DEV_SHARE, new=DEV_SHARE.replace("PARTITION BY user_id, device_id", "PARTITION BY user_id"), tests=LIM + " " + SB),
  dict(id="B14c", label="sender-device share evicts the NEWEST of that sender", file=ST, old=DEV_SHARE, new=DEV_SHARE.replace("stream_pos DESC", "stream_pos ASC"), tests=LIM),
  dict(id="B13c", label="user message cap NOT fair (plain oldest first)", file=ST, old='skip_locked(fair_count_sql("user_id", "user_id = ANY($1::text[])", "$2"))', new=plain_count("user_id", "user_id = ANY($1::text[])", "$2"), tests=LIM),
  dict(id="F01c", label="user BYTE budget NOT fair (plain oldest first)", file=ST, old='skip_locked(fair_bytes_sql("user_id", "user_id = ANY($1::text[])", "$2", "$3"))', new=plain_bytes("user_id", "user_id = ANY($1::text[])", "$2", "$3"), tests=LIM),
  dict(id="F02c", label="fair count: the SMALLEST share first", file=ST, old="ORDER BY rank DESC, stream_pos ASC) AS ord", new="ORDER BY rank ASC, stream_pos ASC) AS ord", tests=LIM + " " + SB),
  dict(id="F03c", label="fair count: on a tie the NEWER row goes first", file=ST, old="ORDER BY rank DESC, stream_pos ASC) AS ord", new="ORDER BY rank DESC, stream_pos DESC) AS ord", tests=LIM + " " + SB),
  dict(id="F04c", label="fair count: rank counted from the OLDEST message of the sender", file=ST,
       old="row_number() OVER (PARTITION BY #{cols}, sender ORDER BY stream_pos DESC) AS rank\n            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE ord",
       new="row_number() OVER (PARTITION BY #{cols}, sender ORDER BY stream_pos ASC) AS rank\n            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE ord", tests=LIM + " " + SB),
  dict(id="F05c", label="fair count: rank over ALL senders (no per-sender partition)", file=ST,
       old="row_number() OVER (PARTITION BY #{cols}, sender ORDER BY stream_pos DESC) AS rank\n            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE ord",
       new="row_number() OVER (PARTITION BY #{cols} ORDER BY stream_pos DESC) AS rank\n            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE ord", tests=LIM + " " + SB),
  dict(id="F06c", label="fair byte budget off by one (<= instead of <)", file=ST, old="s WHERE excess > 0 AND before < excess", new="s WHERE excess > 0 AND before <= excess", tests=LIM + " " + SB),
  dict(id="F07c", label="fair bytes: the SMALLEST share first", file=ST, old="ORDER BY rank DESC, stream_pos ASC) - cost AS before", new="ORDER BY rank ASC, stream_pos ASC) - cost AS before", tests=LIM + " " + SB),
  dict(id="F08c", label="fair bytes: rank over ALL senders", file=ST,
       old="row_number() OVER (PARTITION BY #{cols}, sender ORDER BY stream_pos DESC) AS rank\n            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE excess",
       new="row_number() OVER (PARTITION BY #{cols} ORDER BY stream_pos DESC) AS rank\n            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE excess", tests=LIM + " " + SB),
  dict(id="S01c", label="per-sender-USER message cap removed", file=ST, old=USR_SHARE, new=USR_SHARE.replace("rn > $3", "rn > $3 + 1000000"), tests=LIM),
  dict(id="S02c", label="per-sender-USER byte budget removed", file=ST, old=USR_SHARE, new=USR_SHARE.replace("total > $5", "total > $5 + 1000000000"), tests=LIM),
  dict(id="S03c", label="per-sender-USER message cap off by one", file=ST, old=USR_SHARE, new=USR_SHARE.replace("rn > $3", "rn > $3 + 1"), tests=LIM),
  dict(id="S04c", label="per-sender-USER byte budget off by one (>=)", file=ST, old=USR_SHARE, new=USR_SHARE.replace("total > $5", "total >= $5"), tests=LIM),
  dict(id="S05c", label="per-sender-USER share counted per DEVICE", file=ST, old=USR_SHARE, new=USR_SHARE.replace("PARTITION BY user_id", "PARTITION BY user_id, device_id"), tests=LIM),
  dict(id="A01c", label="ACK ON DELIVERY (the delivered rows are deleted instead of stamped)", file=ST,
       old="UPDATE to_device_messages SET delivery_seq = $1 WHERE stream_pos IN\n               " + STAMP_SEL,
       new="DELETE FROM to_device_messages WHERE $1::bigint > 0 AND stream_pos IN\n               " + STAMP_SEL, tests=SYNC),
  dict(id="A02c", label="ack by QUEUE POSITION (delete up to the position)", file=ST, old=ACK_SQL, new=ACK_SQL.replace("delivery_seq IS NOT NULL AND delivery_seq <= $3", "stream_pos <= $3"), tests=SYNC),
  dict(id="A03c", label="the acknowledgement deletes nothing", file=ST, old=ACK_SQL, new=ACK_SQL.replace("delivery_seq <= $3", "delivery_seq <= $3 AND $3 < 0"), tests=SYNC),
  dict(id="A04c", label="ack boundary off by one (< instead of <=)", file=ST, old=ACK_SQL, new=ACK_SQL.replace("delivery_seq <= $3", "delivery_seq < $3"), tests=SYNC),
  dict(id="A05c", label="the acknowledgement ignores the DEVICE", file=ST, old=ACK_SQL, new=ACK_SQL.replace("device_id = $2", "$2::text IS NOT NULL"), tests=SYNC),
  dict(id="A08c", label="no redelivery: delivered rows are never delivered again", file=ST,
       old="AND (delivery_seq IS NULL OR delivery_seq > $4)\n                         ORDER BY stream_pos LIMIT $5)", new="AND delivery_seq IS NULL AND $4::bigint >= 0\n                         ORDER BY stream_pos LIMIT $5)", tests=SYNC),
  dict(id="D02c", label="IDENTICAL device id: the acknowledgement is not scoped by user", file=ST, old=ACK_SQL, new=ACK_SQL.replace("user_id = $1", "$1::text IS NOT NULL"), tests=IDD),
  dict(id="I06c", label="the txn record is written outside the transaction (a failed enqueue keeps it)", file=ST, edits=[(ST, I06_OLD, I06_NEW)], tests=LOG),
  dict(id="R11c", label="a deactivated recipient still gets messages", file=ST, old="WHERE u.is_active AND u.deletion_status IS NULL", new="WHERE u.deletion_status IS NULL", tests=PUR),
  dict(id="C01c", label="no lock_timeout in the send transaction", file=ST, old="set_config('lock_timeout', $1::text, true)", new="set_config('lock_timeout', CASE WHEN $1::text = 'zzz' THEN $1::text ELSE '0' END, true)", tests=CONC),
  dict(id="C03c", label="a lock timeout is a 500 (not mapped to 429)", file=H, old="busy in [:lock_timeout, :lock_busy, :statement_timeout]", new="busy in [:lock_busy, :statement_timeout]", tests=CONC),
  dict(id="C04c", label="the existing-device lookup runs one statement PER explicit entry", file=ST,
       old='    with {:ok, %{rows: rows}} <-\n           query(\n             "SELECT user_id, device_id FROM devices WHERE (user_id, device_id) IN (SELECT * FROM unnest($1::text[], $2::text[])) FOR KEY SHARE",\n             [Enum.map(explicit, & &1.user_id), Enum.map(explicit, & &1.device)]\n           ) do\n      {:ok, MapSet.new(rows, fn [u, d] -> {u, d} end)}\n    end',
       new='    rows =\n      Enum.flat_map(explicit, fn e ->\n        {:ok, %{rows: r}} = query("SELECT user_id, device_id FROM devices WHERE user_id = $1 AND device_id = $2 FOR KEY SHARE", [e.user_id, e.device])\n        r\n      end)\n\n    {:ok, MapSet.new(rows, fn [u, d] -> {u, d} end)}', tests=CONC),
  dict(id="C05c", label="the delivery stamp runs one UPDATE per message", file=ST,
       old='  defp stamp_new(positions) do\n    with {:ok, %{rows: [[seq]]}} <- query("SELECT nextval(\'to_device_delivery_seq\')", []),\n         {:ok, %{rows: rows}} <-\n           query(\n             """\n             UPDATE to_device_messages SET delivery_seq = $1 WHERE stream_pos IN\n               ' + STAMP_SEL + '\n             RETURNING stream_pos\n             """,\n             [seq, positions]\n           ) do\n      {:ok, seq, MapSet.new(List.flatten(rows))}\n    end\n  end',
       new='  defp stamp_new(positions) do\n    with {:ok, %{rows: [[seq]]}} <- query("SELECT nextval(\'to_device_delivery_seq\')", []) do\n      done =\n        Enum.flat_map(positions, fn p ->\n          {:ok, %{rows: r}} = query("UPDATE to_device_messages SET delivery_seq = $1 WHERE stream_pos = $2 AND delivery_seq IS NULL RETURNING stream_pos", [seq, p])\n          List.flatten(r)\n        end)\n\n      {:ok, seq, MapSet.new(done)}\n    end\n  end', tests=CONC),
]
