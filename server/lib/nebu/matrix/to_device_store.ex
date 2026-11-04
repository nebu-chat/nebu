defmodule Nebu.Matrix.ToDeviceStore do
  @moduledoc """
  The to-device queue (story to-device-messaging, epic e2ee-client-support, REQ-2026-012): Matrix CS v1.18 "Send-to-Device messaging".

  Transport only. The content of a message is OPAQUE (never parsed beyond JSON well-formedness, never logged: a failing statement
  logs the KIND of its error only, a Postgrex message can quote row data). ADR-011 stays: this enables no E2EE room. No federation.

  State lives only in PostgreSQL (`to_device_messages`, `to_device_txns`, migration 000059): the queue, the idempotency records and the
  acknowledgement position are cluster-safe, a restart or another node sees the same state (ADR-020). SQL is inline (ADR-018).

  ## Delivery and acknowledgement

  A message is delivered by `/sync` and deleted only when a LATER sync presents the token of the response that carried it:

    * the first response that carries a message stamps it with `delivery_seq` (the next value of `to_device_delivery_seq`, one value per
      response); the position of the response token is the highest `delivery_seq` it carries;
    * a sync that presents a token with position `p` deletes the messages with `delivery_seq <= p` (acknowledged) and delivers the messages
      with `delivery_seq IS NULL OR delivery_seq > p`: a retry with an older token delivers a batch again, never loses it;
    * a message that committed late (a lower `stream_pos` than a delivered one) has no `delivery_seq` yet, so no acknowledgement can delete it.

  ## Budgets (every per-item cap has an aggregate cap; all seams are read at request time, defaults in `limits/0`)

  Per request: 64 KiB body, 50 entries, 100 targets and 1 MiB of rows. Per recipient device 500 messages / 8 MiB, per recipient user 2000 messages / 32 MiB,
  per SENDER and recipient device 100 messages / 1 MiB, per sender and recipient user 200 messages / 4 MiB, per SENDER over ALL recipients 4000 messages /
  16 MiB (the sender's own oldest go first), 1000 idempotency records per device, 100 messages / 1 MiB per sync response. A byte-cost rate bucket
  (4 MiB per minute, burst 8 MiB per sender, node-local) is charged with the bytes the request ASKS to fan out (state independent: no oracle), a refusal is a 429.
  A send is TWO transactions: phase 1 queues the rows (it holds `FOR KEY SHARE` on the target `devices` rows only from the target lookup to the commit, never during an eviction),
  phase 2 (a second transaction after the commit, best effort, no lock on `devices`) evicts; a failed eviction never fails the send and leaves the excess until an eviction succeeds (the next send to that queue) or the 7-day purge (phase 2 is all-or-nothing).
  A full queue evicts: the sender's own oldest beyond its shares, and at the DEVICE and USER level FAIRLY (the oldest message of the sender with the LARGEST share
  goes first), the sender is never told, the count is logged without content. The row cost of the byte budgets is the content bytes plus 128.

  ## No waiting locks

  Every transaction of a send (both phases) and of a delivery runs with a short `lock_timeout` and a `statement_timeout` of 2 s: a statement that would wait for a row lock is
  `{:error, :lock_timeout}`, one that runs too long `{:error, :statement_timeout}` (a failure of phase 1 answers the send 429, a failure of phase 2 is only logged by its kind,
  a delivery answers the sync with an EMPTY `to_device` and keeps the position: nothing is acknowledged or lost). The eviction, the acknowledgement, the stamp and the purge take `FOR UPDATE SKIP LOCKED`: a row
  another transaction holds is skipped, never waited for. The erasure fence is its own advisory key (`to_device_erasure|<user>`), the send takes it SHARED as a try-lock.
  """
  require Logger

  @row_overhead 128
  @lock_timeout_ms 100

  @defaults %{
    max_per_device: 500,
    max_bytes_per_device: 8 * 1024 * 1024,
    max_per_user: 2000,
    max_bytes_per_user: 32 * 1024 * 1024,
    max_per_sender_device: 100,
    max_bytes_per_sender_device: 1024 * 1024,
    max_per_sender_total: 4000,
    max_bytes_per_sender_total: 16 * 1024 * 1024,
    rate_bytes_per_min: 4 * 1024 * 1024,
    rate_bytes_burst: 8 * 1024 * 1024,
    statement_timeout_ms: 2000,
    max_per_sender_user: 200,
    max_bytes_per_sender_user: 4 * 1024 * 1024,
    max_targets_per_request: 100,
    max_fanout_bytes_per_request: 1024 * 1024,
    max_txns_per_device: 1000,
    sync_batch_size: 100,
    sync_batch_bytes: 1024 * 1024,
    ttl_seconds: 7 * 24 * 3600,
    txn_ttl_seconds: 24 * 3600
  }

  @doc "The effective limits (defaults merged with the `:nebu, :to_device_<name>` seams)."
  @spec limits() :: map()
  def limits do
    Map.new(@defaults, fn {key, default} ->
      value = Application.get_env(:nebu, String.to_atom("to_device_#{key}"), default)
      {key, if(is_integer(value) and value > 0, do: value, else: default)}
    end)
  end

  @doc "The fixed byte cost of a queued row on top of its content bytes."
  def row_overhead, do: @row_overhead

  # ── send ─────────────────────────────────────────────────────────────────────

  @doc """
  Queues the messages of one `sendToDevice` request: `entries` is `[%{user_id, device, content}]` (`device` an id or `"*"`, `content` the
  canonical JSON text). Idempotent per (sender, sender device, event type, txn id). Recipients are the sender's own devices and the
  devices of users who share a room with the sender where BOTH sides are `join` (evaluated now; an invitation opens no send path); everything else is
  skipped silently. Two transactions (see the moduledoc): the second one, the soft eviction, never changes the result.
  `:ok | {:error, :lock_timeout | :lock_busy | :user_erased | term}` (an error is always one of phase 1: nothing was queued and the transaction id is not burnt).
  """
  @spec send(String.t(), String.t(), String.t(), String.t(), [map()]) :: :ok | {:error, term()}
  def send(sender, sender_device, event_type, txn_id, entries) do
    # PHASE 1 (one short transaction): the locks and the transaction record, the targets (the `FOR KEY SHARE` on their `devices` rows is taken IMMEDIATELY before the
    # INSERT and ends with the commit: no eviction, count or sum scan runs while it is held), the INSERT.
    result =
      transact(fn ->
        with {:ok, _} <- set_timeouts(),
             :ok <- lock_sender(sender),
             {:ok, fresh?} <- record_txn(sender, sender_device, event_type, txn_id) do
          if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: {:ok, {:duplicate, []}}
        end
      end)

    case result do
      {:ok, {:duplicate, _}} ->
        :ok

      {:ok, {targets, us, ds}} ->
        wake(targets)
        # PHASE 2 (a second transaction after the commit, best effort, no lock on `devices`): the soft eviction. It never fails the send.
        settle(sender, us, ds)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The soft eviction in a transaction of its own (see `evict/3`): a failure, a timeout or an exit of the pool is logged by its KIND and leaves the excess until an eviction
  # succeeds (the next send to that queue) or the purge (the caps are soft anyway); the rows are queued and the transaction id is recorded already. It holds no lock on `devices` and sets its own timeouts (`set_config`
  # is local to a transaction). The same statements run whatever the recipients were (an unreachable one only makes the arrays empty: no timing oracle).
  defp settle(sender, us, ds) do
    result =
      try do
        transact(fn ->
          with {:ok, _} <- set_timeouts(), do: evict(sender, us, ds)
        end)
      catch
        :exit, _ -> {:error, :exit}
      end

    case result do
      {:ok, evicted} when evicted > 0 -> Logger.info("to-device: evicted #{evicted} message(s) from full queues")
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("to-device: the eviction failed (#{error_kind(reason)}); the queues catch up with the next send")
    end
  end

  # the KIND of a failure only: a database error message can quote a row (the content of a message)
  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"

  # `lock_timeout` and `statement_timeout` of a transaction, in ONE statement (a delivery on an idle queue stays at its statement count)
  defp set_timeouts do
    query("SELECT set_config('lock_timeout', $1::text, true), set_config('statement_timeout', $2::text, true)", ["#{@lock_timeout_ms}ms", "#{limits().statement_timeout_ms}ms"])
  end

  # The GDPR erasure takes the advisory lock `to_device_erasure|<user>` EXCLUSIVELY (its OWN key: the account data, cross-signing and key backup writers hold
  # `sync_global|<user>` and must not make a message skip); a send takes it SHARED and only as a TRY-lock (no waiter holds a connection): a sender whose own
  # erasure is under way is answered 429 at once, and a send never re-creates rows (as sender or as recipient) after the erasure deleted them: the status is read
  # AFTER the lock
  defp lock_sender(sender) do
    with {:ok, %{rows: [[locked?]]}} <- query("SELECT pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0))", [sender]) do
      if locked?, do: ensure_not_erased(sender), else: {:error, :lock_busy}
    end
  end

  defp ensure_not_erased(user) do
    case query("SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NOT NULL", [user]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, _} -> {:error, :user_erased}
      {:error, _} = err -> err
    end
  end

  defp record_txn(sender, sender_device, event_type, txn_id) do
    limits = limits()

    with {:ok, %{num_rows: n}} <-
           query(
             "INSERT INTO to_device_txns (user_id, device_id, event_type, txn_id) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
             [sender, sender_device, event_type, txn_id]
           ),
         {:ok, _} <-
           (if n == 1 do
              query(
                """
                DELETE FROM to_device_txns WHERE user_id = $1 AND device_id = $2 AND ctid IN
                  (SELECT ctid FROM to_device_txns WHERE user_id = $1 AND device_id = $2 ORDER BY created_at DESC, txn_id OFFSET $3)
                """,
                [sender, sender_device, limits.max_txns_per_device]
              )
            else
              {:ok, nil}
            end) do
      {:ok, n == 1}
    end
  end

  # The SAME statements run whatever the outcome (an unknown, unshared or deactivated recipient only makes the arrays empty): the work of a request does not tell
  # a delivered recipient from a skipped one (no timing oracle; pinned by counting the statements).
  defp enqueue(sender, sender_device, event_type, entries) do
    users = entries |> Enum.map(& &1.user_id) |> Enum.uniq()

    with :ok <- charge_bytes(sender, entries),
         {:ok, allowed} <- allowed_users(sender, users),
         {:ok, targets} <- resolve_targets(sender, sender_device, Enum.filter(entries, &MapSet.member?(allowed, &1.user_id))) do
      {us, ds, cs} = {Enum.map(targets, &elem(&1, 0)), Enum.map(targets, &elem(&1, 1)), Enum.map(targets, &elem(&1, 2))}

      with {:ok, _} <-
             query(
               """
               INSERT INTO to_device_messages (user_id, device_id, sender, event_type, content, bytes)
               SELECT t.u, t.d, $1, $2, t.c, octet_length(t.c) FROM unnest($3::text[], $4::text[], $5::text[]) AS t(u, d, c)
               """,
               [sender, event_type, us, ds, cs]
             ) do
        {:ok, {Enum.map(targets, fn {u, d, _c} -> {u, d} end), us, ds}}
      end
    end
  end

  # The byte-cost rate bucket (per SENDER, node-local like every rate tier: N x the limit in a cluster): charged with the bytes the request ASKS to fan out, not with the
  # bytes that were accepted (an accepted-bytes cost would tell a delivered recipient from a skipped one by the 429): an explicit device costs content + 128, a `*` the
  # most it could reach (`max_targets` rows, never above the fan-out budget). A refusal rolls the transaction back (the txn id is not burnt) and is a 429.
  defp charge_bytes(sender, entries) do
    l = limits()

    cost =
      Enum.reduce(entries, 0, fn %{device: device, content: content}, acc ->
        row = byte_size(content) + @row_overhead
        acc + if(device == "*", do: min(row * l.max_targets_per_request, l.max_fanout_bytes_per_request), else: row)
      end)

    if cost == 0 do
      :ok
    else
      case Nebu.Web.Plugs.RateLimit.take_all([{{"to_device_bytes", sender}, cost, l.rate_bytes_per_min, l.rate_bytes_burst}]) do
        :ok -> :ok
        {:deny, seconds} -> {:error, {:bytes_rate, seconds}}
      end
    end
  end

  # the sender itself, plus every user who shares a room with the sender where BOTH sides are `join` (an invitation opens no send path: no consent, and in-room
  # verification does not use to-device messages); the statement runs even when there is no other user
  defp allowed_users(sender, users) do
    others = users -- [sender]

    with {:ok, %{rows: rows}} <-
           query(
             """
             SELECT DISTINCT o.user_id FROM room_members o JOIN room_members m ON m.room_id = o.room_id
             WHERE o.user_id = ANY($2::text[]) AND o.left_at IS NULL AND m.user_id = $1 AND m.left_at IS NULL
             """,
             [sender, others]
           ),
         {:ok, active} <- active_users(List.flatten(rows)) do
      {:ok, MapSet.new(if(sender in users, do: [sender | active], else: active))}
    end
  end

  # a deactivated (or erased) user receives nothing new: its queue is kept (a deactivation is reversible) but not extended
  # (a recipient whose erasure holds its fence is skipped like an unknown one: no oracle, and no row is created behind the erasure). Only the ids that PASSED the
  # shared-room join are locked (`cand` is materialised, the volatile lock function runs once per candidate row, never inside the scan of `users`).
  defp active_users(users) do
    with {:ok, %{rows: rows}} <-
           query(
             """
             WITH cand AS MATERIALIZED (SELECT DISTINCT unnest($1::text[]) AS user_id),
                  locked AS MATERIALIZED (SELECT user_id FROM cand WHERE pg_try_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || user_id, 0)))
             SELECT u.user_id FROM users u JOIN locked l ON l.user_id = u.user_id WHERE u.is_active AND u.deletion_status IS NULL
             """,
             [users]
           ) do
      {:ok, List.flatten(rows)}
    end
  end

  # `[{user, device, content}]`: an explicit device entry wins over `*`, `*` of the sender excludes the sending device, only existing devices
  # (a `devices` row), at most `max_targets_per_request` in total
  defp resolve_targets(sender, sender_device, entries) do
    cap = limits().max_targets_per_request
    explicit = for %{device: d} = e <- entries, d != "*", do: e
    stars = for %{device: "*"} = e <- entries, do: e

    with {:ok, existing} <- existing_devices(explicit),
         {:ok, expanded} <- star_devices(stars, cap) do
      star_targets =
        for {user, device} <- expanded,
            not (user == sender and device == sender_device),
            do: {user, device, star_content(stars, user)}

      explicit_targets = for %{user_id: u, device: d, content: c} <- explicit, MapSet.member?(existing, {u, d}), do: {u, d, c}
      explicit_keys = MapSet.new(explicit_targets, fn {u, d, _} -> {u, d} end)

      merged = explicit_targets ++ Enum.reject(star_targets, fn {u, d, _} -> MapSet.member?(explicit_keys, {u, d}) end)
      {:ok, merged |> Enum.uniq_by(fn {u, d, _} -> {u, d} end) |> Enum.take(cap) |> fit_fanout_bytes(limits().max_fanout_bytes_per_request)}
    end
  end

  # the rows of ONE request cost at most `max_fanout_bytes_per_request` (content + 128 per row, deterministic order, the first target is always kept): a 64 KiB content
  # cannot fan out to 100 devices (6.4 MB of parameters and rows per request); beyond the budget the targets are dropped silently like an unreachable one
  defp fit_fanout_bytes(targets, budget) do
    {kept, _} =
      Enum.reduce_while(targets, {[], 0}, fn {_u, _d, content} = target, {acc, total} ->
        cost = byte_size(content) + @row_overhead
        if acc != [] and total + cost > budget, do: {:halt, {acc, total}}, else: {:cont, {[target | acc], total + cost}}
      end)

    Enum.reverse(kept)
  end

  defp star_content(stars, user), do: stars |> Enum.find(&(&1.user_id == user)) |> Map.fetch!(:content)

  defp existing_devices(explicit) do
    with {:ok, %{rows: rows}} <-
           query(
             "SELECT user_id, device_id FROM devices WHERE (user_id, device_id) IN (SELECT * FROM unnest($1::text[], $2::text[])) FOR KEY SHARE",
             [Enum.map(explicit, & &1.user_id), Enum.map(explicit, & &1.device)]
           ) do
      {:ok, MapSet.new(rows, fn [u, d] -> {u, d} end)}
    end
  end

  defp star_devices(stars, cap) do
    with {:ok, %{rows: rows}} <-
           query(
             """
             SELECT u.user_id, d.device_id FROM unnest($1::text[]) AS u(user_id)
             CROSS JOIN LATERAL (SELECT device_id FROM devices WHERE user_id = u.user_id ORDER BY COALESCE(last_seen_ts, 0) DESC, device_id LIMIT $2 FOR KEY SHARE) d
             """,
             [stars |> Enum.map(& &1.user_id) |> Enum.uniq(), cap]
           ) do
      {:ok, Enum.map(rows, fn [u, d] -> {u, d} end)}
    end
  end

  # The budgets of the touched queues, set based (a constant number of statements however many recipients):
  #   (1) the sender's share of a device queue (100 messages / 1 MiB): its own oldest go first,
  #   (2) the sender's share of a recipient USER's queues (200 messages / 4 MiB): its own oldest,
  #   (3) the sender's TOTAL over all recipients (4000 messages / 16 MiB): its own oldest, any recipient,
  #   (4) the device queue (500 / 8 MiB) and (5) the user (2000 / 32 MiB), count and bytes, evicted FAIRLY: the oldest message of the sender with the LARGEST share
  #       goes first (a row's rank is its position counted from the newest message of its sender; the highest ranks go first, older first on a tie), so a flooding
  #       co-member never evicts the older messages of a sender below its share.
  # Every DELETE takes `FOR UPDATE SKIP LOCKED` on the rows it removes: a row another transaction holds is skipped (the cap catches up with the next send), a victim's
  # sync never makes a send wait and a send never makes a sync wait. Returns the number of evicted rows.
  defp evict(sender, us, ds) do
    l = limits()
    users = Enum.uniq(us)
    pairs = "(user_id, device_id) IN (SELECT * FROM unnest($1::text[], $2::text[]))"

    statements = [
      {skip_locked("""
       SELECT stream_pos FROM (
         SELECT stream_pos, row_number() OVER w AS rn, sum(bytes + $5) OVER w AS total
         FROM to_device_messages WHERE sender = $1 AND (user_id, device_id) IN (SELECT * FROM unnest($2::text[], $3::text[]))
         WINDOW w AS (PARTITION BY user_id, device_id ORDER BY stream_pos DESC)) s WHERE rn > $4 OR total > $6
       """), [sender, us, ds, l.max_per_sender_device, @row_overhead, l.max_bytes_per_sender_device]},
      {skip_locked("""
       SELECT stream_pos FROM (
         SELECT stream_pos, row_number() OVER w AS rn, sum(bytes + $4) OVER w AS total
         FROM to_device_messages WHERE sender = $1 AND user_id = ANY($2::text[])
         WINDOW w AS (PARTITION BY user_id ORDER BY stream_pos DESC)) s WHERE rn > $3 OR total > $5
       """), [sender, users, l.max_per_sender_user, @row_overhead, l.max_bytes_per_sender_user]},
      {skip_locked("""
       SELECT stream_pos FROM (
         SELECT stream_pos, row_number() OVER w AS rn, sum(bytes + $3) OVER w AS total
         FROM to_device_messages WHERE sender = $1
         WINDOW w AS (ORDER BY stream_pos DESC)) s WHERE rn > $2 OR total > $4
       """), [sender, l.max_per_sender_total, @row_overhead, l.max_bytes_per_sender_total]},
      {skip_locked(fair_count_sql("user_id, device_id", pairs, "$3")), [us, ds, l.max_per_device]},
      {skip_locked(fair_bytes_sql("user_id, device_id", pairs, "$3", "$4")), [us, ds, l.max_bytes_per_device, @row_overhead]},
      {skip_locked(fair_count_sql("user_id", "user_id = ANY($1::text[])", "$2")), [users, l.max_per_user]},
      {skip_locked(fair_bytes_sql("user_id", "user_id = ANY($1::text[])", "$2", "$3")), [users, l.max_bytes_per_user, @row_overhead]}
    ]

    Enum.reduce_while(statements, {:ok, 0}, fn {sql, params}, {:ok, acc} ->
      case query(sql, params) do
        {:ok, %{num_rows: n}} -> {:cont, {:ok, acc + n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # deletes the rows `doomed_select` names, but only those no other transaction holds (`FOR UPDATE SKIP LOCKED`; a window function and a row lock cannot share a select)
  defp skip_locked(doomed_select) do
    """
    WITH doomed AS (#{doomed_select}),
         locked AS (SELECT stream_pos FROM to_device_messages WHERE stream_pos IN (SELECT stream_pos FROM doomed) FOR UPDATE SKIP LOCKED)
    DELETE FROM to_device_messages WHERE stream_pos IN (SELECT stream_pos FROM locked)
    """
  end

  # the rows of a queue (`cols`: the user or the device) beyond the message cap in the FAIR order: the highest rank (largest share) first, older first on a tie; the first
  # `total - cap` rows of that order go. Only the over-full queues are read in full (the HAVING prefilter).
  defp fair_count_sql(cols, filter, cap) do
    """
    WITH overfull AS (SELECT #{cols} FROM to_device_messages WHERE #{filter} GROUP BY #{cols} HAVING count(*) > #{cap})
    SELECT stream_pos FROM (
      SELECT stream_pos, row_number() OVER (PARTITION BY #{cols} ORDER BY rank DESC, stream_pos ASC) AS ord, count(*) OVER (PARTITION BY #{cols}) AS n
      FROM (SELECT stream_pos, #{cols}, row_number() OVER (PARTITION BY #{cols}, sender ORDER BY stream_pos DESC) AS rank
            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE ord <= n - #{cap}
    """
  end

  # the same for the byte budget (a row costs `bytes + overhead`): the rows are taken in the fair order while the bytes still above the budget are not freed
  defp fair_bytes_sql(cols, filter, cap, overhead) do
    """
    WITH overfull AS (SELECT #{cols} FROM to_device_messages WHERE #{filter} GROUP BY #{cols} HAVING sum(bytes + #{overhead}) > #{cap}::bigint)
    SELECT stream_pos FROM (
      SELECT stream_pos, sum(cost) OVER (PARTITION BY #{cols} ORDER BY rank DESC, stream_pos ASC) - cost AS before, sum(cost) OVER (PARTITION BY #{cols}) - #{cap}::bigint AS excess
      FROM (SELECT stream_pos, #{cols}, bytes + #{overhead} AS cost, row_number() OVER (PARTITION BY #{cols}, sender ORDER BY stream_pos DESC) AS rank
            FROM to_device_messages WHERE (#{cols}) IN (SELECT #{cols} FROM overfull)) r) s WHERE excess > 0 AND before < excess
    """
  end

  # after the commit: wake the long-polling /sync of exactly the target devices (cluster wide, `:pg`)
  defp wake(targets) do
    targets
    |> Enum.uniq()
    |> Enum.each(fn {user, device} -> for pid <- :pg.get_members("user:#{user}"), do: Kernel.send(pid, {:to_device, device}) end)
  end

  # ── delivery ─────────────────────────────────────────────────────────────────

  @doc """
  Acknowledges and delivers for one /sync: `ack` is the to-device position of the token the client presented (`nil`: an initial or fallback
  sync, nothing is acknowledged and every pending message is delivered). Returns `{:ok, %{events, position}}` or `{:error, reason}`.
  """
  @spec deliver(String.t(), String.t(), non_neg_integer() | nil) :: {:ok, %{events: [map()], position: non_neg_integer()}} | {:error, term()}
  def deliver(_user, "", _ack), do: {:ok, %{events: [], position: 0}}

  def deliver(user, device, ack) do
    l = limits()
    since = ack || 0

    result =
      transact(fn ->
        with {:ok, _} <- set_timeouts(),
             {:ok, _} <- acknowledge(user, device, ack),
             {:ok, %{rows: rows}} <-
               query(
                 # the batch is cut in SQL (at most `sync_batch_size` rows, the first one always, then while the running cost stays within
                 # `sync_batch_bytes`) and only THEN are the contents read: a device that holds 8 MiB of queued content does not read them all for a 1 MiB response
                 """
                 SELECT m.stream_pos, m.sender, m.event_type, m.content, m.bytes, m.delivery_seq
                 FROM (
                   SELECT stream_pos, row_number() OVER w AS rn, sum(bytes + $6) OVER w AS total
                   FROM (SELECT stream_pos, bytes FROM to_device_messages
                         WHERE user_id = $1 AND device_id = $2 AND created_at > now() - make_interval(secs => $3) AND (delivery_seq IS NULL OR delivery_seq > $4)
                         ORDER BY stream_pos LIMIT $5) w0
                   WINDOW w AS (ORDER BY stream_pos)) c
                 JOIN to_device_messages m ON m.stream_pos = c.stream_pos
                 WHERE c.rn = 1 OR c.total <= $7
                 ORDER BY m.stream_pos
                 """,
                 [user, device, l.ttl_seconds * 1.0, since, l.sync_batch_size, @row_overhead, l.sync_batch_bytes]
               ) do
          batch = rows

          # test seam (ATDD, the lost-race trace): runs between the read and the stamp
          case Application.get_env(:nebu, :atdd_to_device_before_stamp) do
            hook when is_function(hook, 0) -> hook.()
            _ -> :ok
          end

          stamp(batch, since)
        end
      end)

    case result do
      {:ok, {events, position}} -> {:ok, %{events: events, position: position}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acknowledge(_user, _device, ack) when ack in [nil, 0], do: {:ok, nil}

  defp acknowledge(user, device, ack),
    do:
      query(
        """
        DELETE FROM to_device_messages WHERE stream_pos IN
          (SELECT stream_pos FROM to_device_messages WHERE user_id = $1 AND device_id = $2 AND delivery_seq IS NOT NULL AND delivery_seq <= $3 FOR UPDATE SKIP LOCKED)
        """,
        [user, device, ack]
      )

  # The response carries the messages that are stamped (by an earlier response, or by THIS one just now). A row this response could not stamp (another response of the
  # same device stamped it first, or its row is locked) is NOT carried: its stamp belongs to the other response, so the position of this token must not cover it.
  # The position is the highest stamp of the carried rows, or the presented position (`since`) when there is none.
  defp stamp([], since), do: {:ok, {[], since}}

  defp stamp(batch, since) do
    unstamped = for [pos, _, _, _, _, nil] <- batch, do: pos

    with {:ok, seq, stamped_now} <- stamp_new(unstamped) do
      carried = Enum.filter(batch, fn [pos, _, _, _, _, s] -> is_integer(s) or MapSet.member?(stamped_now, pos) end)
      earlier = for [_, _, _, _, _, s] <- carried, is_integer(s), do: s
      position = Enum.max([since | if(MapSet.size(stamped_now) > 0, do: [seq | earlier], else: earlier)])

      events = for [_pos, sender, type, content, _bytes, _seq] <- carried, do: %{"sender" => sender, "type" => type, "content" => Jason.decode!(content)}
      {:ok, {events, position}}
    end
  end

  defp stamp_new([]), do: {:ok, 0, MapSet.new()}

  defp stamp_new(positions) do
    with {:ok, %{rows: [[seq]]}} <- query("SELECT nextval('to_device_delivery_seq')", []),
         {:ok, %{rows: rows}} <-
           query(
             """
             UPDATE to_device_messages SET delivery_seq = $1 WHERE stream_pos IN
               (SELECT stream_pos FROM to_device_messages WHERE stream_pos = ANY($2::bigint[]) AND delivery_seq IS NULL FOR UPDATE SKIP LOCKED)
             RETURNING stream_pos
             """,
             [seq, positions]
           ) do
      {:ok, seq, MapSet.new(List.flatten(rows))}
    end
  end

  @doc "True when a message is queued that no response has carried yet (the long poll must not wait for it)."
  @spec undelivered?(String.t(), String.t()) :: boolean()
  def undelivered?("", _), do: false

  def undelivered?(user, device) do
    pending_query("delivery_seq IS NULL", [user, device])
  end

  @doc "True when a message is waiting for a sync that presents the to-device position `since`: not yet delivered, or delivered after `since`."
  @spec pending?(String.t(), String.t(), non_neg_integer()) :: boolean()
  def pending?("", _, _), do: false
  def pending?(user, device, since), do: pending_query("(delivery_seq IS NULL OR delivery_seq > $3)", [user, device, since])

  defp pending_query(condition, params) do
    sql = "SELECT EXISTS (SELECT 1 FROM to_device_messages WHERE user_id = $1 AND device_id = $2 AND #{condition} AND created_at > now() - make_interval(secs => #{ttl_param(length(params))}))"
    params = params ++ [limits().ttl_seconds * 1.0]

    case query(sql, params) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  rescue
    # a read of the wake-up check: never raises (a pure-unit run of the dispatcher has no `Nebu.Repo`), a failure means "nothing known to be pending"
    _ -> false
  catch
    :exit, _ -> false
  end

  defp ttl_param(n), do: "$#{n + 1}"

  # ── housekeeping ─────────────────────────────────────────────────────────────

  @doc """
  Deletes the messages older than the TTL and the idempotency records older than their TTL, in batches (`FOR UPDATE SKIP LOCKED`, atomic, concurrent
  runs split the work). Housekeeping only: delivery never returns an expired message. `{:ok, %{messages: n, txns: n}}`.
  """
  @spec purge_expired() :: {:ok, %{messages: non_neg_integer(), txns: non_neg_integer()}} | {:error, term()}
  def purge_expired do
    l = limits()

    with {:ok, messages} <- purge_batches("to_device_messages", "stream_pos", l.ttl_seconds),
         {:ok, txns} <- purge_batches("to_device_txns", "ctid", l.txn_ttl_seconds) do
      {:ok, %{messages: messages, txns: txns}}
    end
  end

  defp purge_batches(table, key, ttl, total \\ 0, rounds \\ 0) do
    sql =
      "DELETE FROM #{table} WHERE #{key} IN (SELECT #{key} FROM #{table} WHERE created_at < now() - make_interval(secs => $1) LIMIT 5000 FOR UPDATE SKIP LOCKED)"

    case query(sql, [ttl * 1.0]) do
      {:ok, %{num_rows: 0}} -> {:ok, total}
      {:ok, %{num_rows: n}} when rounds < 1000 -> purge_batches(table, key, ttl, total + n, rounds + 1)
      {:ok, %{num_rows: n}} -> {:ok, total + n}
      {:error, _} = err -> err
    end
  end

  # ── plumbing ─────────────────────────────────────────────────────────────────

  defp transact(fun) do
    Nebu.Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Nebu.Repo.rollback(reason)
      end
    end)
  rescue
    e -> {:error, e}
  end

  defp query(sql, params) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, params) do
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> {:error, :lock_timeout}
      {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} -> {:error, :statement_timeout}
      other -> other
    end
  end
end
