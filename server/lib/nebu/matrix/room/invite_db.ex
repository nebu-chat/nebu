defmodule Nebu.Matrix.Room.InviteDB do
  @moduledoc """
  PostgreSQL persistence layer for room invitations.

  Inserts invitation records into the `room_invitations` table.
  All timestamps stored as BIGINT milliseconds.
  """

  @sql_insert_invitation """
  INSERT INTO room_invitations (room_id, inviter_id, invitee_id, invited_at)
  VALUES ($1, $2, $3, $4)
  ON CONFLICT (room_id, invitee_id) DO UPDATE SET
    inviter_id = EXCLUDED.inviter_id,
    invited_at = EXCLUDED.invited_at,
    accepted_at = NULL,
    rejected_at = NULL
  """

  @doc """
  Inserts an invitation record into the `room_invitations` table.

  There is ONE row per (room_id, invitee_id). If it already exists the invitation is RE-ARMED
  (story create-room-presets-power-levels-topic, D1): `inviter_id` / `invited_at` are refreshed and
  `accepted_at` / `rejected_at` are cleared, so a user who joined (accepted), declined (rejected), left,
  was kicked or was unbanned holds a PENDING invitation again after a NEW invite. With the old
  `ON CONFLICT DO NOTHING` a former member could never be re-invited into an invite-only room (the
  join decision needs a pending invite), the re-invite never showed in `/sync` `rooms.invite`, and an
  Admin force-add of a former member failed. A still pending row is just refreshed.

  Returns `:ok` on success, `{:error, reason}` on DB error.
  """
  @spec insert_invitation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def insert_invitation(room_id, inviter_id, invitee_id) do
    now_ms = System.system_time(:millisecond)

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert_invitation, [
           room_id,
           inviter_id,
           invitee_id,
           now_ms
         ]) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sql_pending_invite """
  SELECT 1 FROM room_invitations
  WHERE room_id = $1 AND invitee_id = $2
    AND accepted_at IS NULL AND rejected_at IS NULL
  LIMIT 1
  """

  @doc """
  True when `invitee_id` has a PENDING invitation (neither accepted nor rejected) to `room_id`
  (story oauth-room-summary-unrecognized, room_summary visibility). Read-only.
  Returns `{:ok, boolean}` or `{:error, reason}` on a DB failure.
  """
  @spec pending_invite?(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def pending_invite?(room_id, invitee_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_pending_invite, [room_id, invitee_id]) do
      {:ok, %{rows: [_ | _]}} -> {:ok, true}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  # ONE statement for the whole call (story rate-limits-join-invite-create-room, D8; ADR-018: inline, parameter-bound).
  # $1 inviter, $2 invitees (text[]), $3 the bound. The first row (invitee NULL) is the inviter's pending rows over ALL rooms
  # (room_invitations_pending_inviter_idx); every further row is one invitee: the invitee's pending rows (room_invitations_invitee_idx)
  # and the inviter's pending rows to that invitee (the partial index again). Each count runs over a LIMIT $3 subquery, so a user
  # with 100 000 pending rows costs at most $3 index entries per count, not a scan of all of them.
  #
  # Review cycle 1 (Kassandra M-1): the invitee's TOTAL does not count rows the victim already neutralised or that nobody can act on:
  # rows of a DEACTIVATED inviter (users.is_active, they come back when the account is reactivated) and rows of an inviter on the
  # invitee's `m.ignored_user_list` (the sync hides them; the list is read here like the sync reads it: an absent, malformed or
  # non-object list ignores nobody, `pg_input_is_valid` keeps a malformed stored body from failing the whole count; PostgreSQL 16+).
  # The PAIR count and the inviter count stay raw: they bound what ONE attacker writes.
  #
  # Delta gate (Kassandra H-1, HIGH): the list is attacker-sized global account data (up to 1 MB) and parsing it costs time AND memory
  # that PostgreSQL does not give back inside one statement. It is therefore parsed ONCE PER INVITEE, in the LATERAL join on the unnest
  # (`ig.ignored`, the parsed `ignored_users` value, or NULL), never inside the per-row counted subquery: the per-row work is a
  # `jsonb_exists` on an already parsed value. Rows the exclusion removes do not count towards LIMIT, so the scan of an invitee's pending
  # rows is bounded by the rows themselves, not by 101; that is why nothing per row may depend on the size of the list.
  @sql_pending_invite_counts """
  SELECT NULL::text AS invitee,
         (SELECT count(*) FROM (SELECT 1 FROM room_invitations
                                 WHERE inviter_id = $1 AND accepted_at IS NULL AND rejected_at IS NULL
                                 LIMIT $3) pending) AS total,
         0::bigint AS from_inviter
  UNION ALL
  SELECT i.invitee,
         (SELECT count(*) FROM (SELECT 1 FROM room_invitations r
                                 JOIN users u ON u.user_id = r.inviter_id AND u.is_active
                                 WHERE r.invitee_id = i.invitee AND r.accepted_at IS NULL AND r.rejected_at IS NULL
                                   AND NOT (ig.ignored IS NOT NULL AND jsonb_typeof(ig.ignored) = 'object'
                                            AND jsonb_exists(ig.ignored, r.inviter_id))
                                 LIMIT $3) t),
         (SELECT count(*) FROM (SELECT 1 FROM room_invitations r
                                 WHERE r.inviter_id = $1 AND r.invitee_id = i.invitee AND r.accepted_at IS NULL AND r.rejected_at IS NULL
                                 LIMIT $3) pending)
  FROM unnest($2::text[]) AS i(invitee)
  LEFT JOIN LATERAL (SELECT CASE WHEN pg_input_is_valid(a.content_json, 'jsonb') THEN a.content_json::jsonb -> 'ignored_users' END AS ignored
                       FROM account_data a
                      WHERE a.user_id = i.invitee AND a.type = 'm.ignored_user_list') ig ON true
  """

  @doc """
  The bounded counts of PENDING invitations (neither accepted nor rejected) the invitation caps are decided on
  (story rate-limits-join-invite-create-room, D6, D8): ONE statement, however many invitees.

      {:ok, %{inviter: n, invitees: %{invitee_id => %{total: t, from_inviter: p}}}}

    * `inviter`: the pending rows of `inviter_id` over all rooms;
    * `total`: the pending rows of every ACTIVE inviter to that invitee, except those of inviters on the invitee's
      `m.ignored_user_list` (review cycle 1, Kassandra M-1); `from_inviter`: the pending rows of `inviter_id` to that invitee;
    * an invitee without rows is present with zeros; duplicates in `invitee_ids` are answered once; `[]` answers the inviter count
      only;
    * every count is at most `limit` (the caller passes the largest cap + 1: whether a cap is exceeded is decidable without the
      exact number, and a user with 100 000 rows costs at most `limit` index entries).

  A row is the CURRENT state of ONE (room, invitee) pair: a re-armed (re-invited) row is counted once, under its current inviter.
  Read-only. `{:error, reason}` on a DB failure (the caller fails closed).
  """
  @spec pending_invite_counts(String.t(), [String.t()], pos_integer()) ::
          {:ok, %{inviter: non_neg_integer(), invitees: %{String.t() => %{total: non_neg_integer(), from_inviter: non_neg_integer()}}}}
          | {:error, term()}
  def pending_invite_counts(inviter_id, invitee_ids, limit) when is_binary(inviter_id) and is_list(invitee_ids) and is_integer(limit) and limit > 0 do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_pending_invite_counts, [inviter_id, Enum.uniq(invitee_ids), limit]) do
      {:ok, %{rows: rows}} ->
        {[[nil, inviter_count, _]], invitee_rows} = Enum.split_with(rows, fn [invitee, _total, _from] -> is_nil(invitee) end)

        {:ok,
         %{
           inviter: inviter_count,
           invitees: Map.new(invitee_rows, fn [invitee, total, from_inviter] -> {invitee, %{total: total, from_inviter: from_inviter}} end)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The count bound a caller passes to `pending_invite_counts/3` for `caps`: the largest cap + 1 (whether a cap is exceeded is
  decidable without the exact number), clamped to the largest bigint (the caps are operator input up to int64).
  """
  @spec count_bound(%{per_inviter: pos_integer(), per_invitee: pos_integer(), per_pair: pos_integer()}) :: pos_integer()
  def count_bound(caps), do: min(caps |> Map.values() |> Enum.max() |> Kernel.+(1), 9_223_372_036_854_775_807)

  @doc """
  The FIRST cap a request that adds one pending row per invitee of `invitees` would break, `nil` when none (story
  rate-limits-join-invite-create-room, D6): `:inviter` when `counts.inviter + length(invitees) > per_inviter`, then the invitees in
  list order, the pair (`:pair`) before the invitee total (`:invitee`). Pure; the ONE decision both the core's pre-check (exact
  texts, all-or-nothing createRoom) and `insert_invitation_capped/4` (inside the lock) use.
  """
  @spec first_cap_violation(map(), [String.t()], map()) :: nil | :inviter | :pair | :invitee
  def first_cap_violation(%{inviter: inviter_pending, invitees: per_invitee}, invitees, caps) do
    if inviter_pending + length(invitees) > caps.per_inviter do
      :inviter
    else
      Enum.find_value(invitees, fn invitee ->
        %{total: total, from_inviter: pair} = Map.get(per_invitee, invitee, %{total: 0, from_inviter: 0})

        cond do
          pair + 1 > caps.per_pair -> :pair
          total + 1 > caps.per_invitee -> :invitee
          true -> nil
        end
      end)
    end
  end

  @sql_lock_keys "SELECT hashtextextended($1, 0), hashtextextended($2, 0)"

  @doc """
  The invitation write that ADDS a pending row, with the caps enforced HARD (review cycle 1, Kassandra M-1c): in ONE transaction
  it takes the transaction-scoped advisory locks of the inviter and of the invitee (always in key order: no deadlock, cluster-wide:
  the locks live in PostgreSQL), counts with `pending_invite_counts/3`, and inserts the row (`insert_invitation/3`, the re-arm
  upsert) only when no cap is broken. Concurrent capped writes to the same invitee or by the same inviter therefore see each
  other's rows: N concurrent invitations can never exceed a cap, whichever node they run on.

  Returns `:ok`, `{:error, {:cap, :inviter | :pair | :invitee}}` (nothing written), `{:error, :lock_timeout}` (the locks stayed
  busy for 2 s: `SET LOCAL lock_timeout`, nothing written, the caller answers 503) or `{:error, reason}` on a DB failure (the
  caller fails closed). The lock covers the count and the row only (not the signed invite event that follows). Writers that do not
  call this function (Admin force-add, `upgrade_room`) are not capped and do not take the locks; their rows are only counted.
  """
  @spec insert_invitation_capped(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def insert_invitation_capped(room_id, inviter_id, invitee_id, caps) do
    result =
      Nebu.Repo.transaction(fn ->
        # a bounded wait (delta gate L-2): a waiter holds a pool connection; contention on a hot invitee answers 503, not a timeout
        Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL lock_timeout = '2s'", [])
        lock_inviter_and_invitee(inviter_id, invitee_id)

        with {:ok, counts} <- pending_invite_counts(inviter_id, [invitee_id], count_bound(caps)),
             nil <- first_cap_violation(counts, [invitee_id], caps),
             :ok <- insert_invitation(room_id, inviter_id, invitee_id) do
          :ok
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
          violated when violated in [:inviter, :pair, :invitee] -> Nebu.Repo.rollback({:cap, violated})
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # lock_not_available: another capped write of the same inviter or invitee held the lock for more than 2 s
    e in Postgrex.Error ->
      if match?(%{pg_code: "55P03"}, e.postgres), do: {:error, :lock_timeout}, else: {:error, e}

    e ->
      {:error, e}
  end

  defp lock_inviter_and_invitee(inviter_id, invitee_id) do
    %{rows: [[inviter_key, invitee_key]]} =
      Ecto.Adapters.SQL.query!(Nebu.Repo, @sql_lock_keys, ["nebu:invite:inviter:" <> inviter_id, "nebu:invite:invitee:" <> invitee_id])

    for key <- Enum.sort(Enum.uniq([inviter_key, invitee_key])) do
      Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT pg_advisory_xact_lock($1)", [key])
    end

    :ok
  end

  @sql_reject_invitation """
  UPDATE room_invitations
  SET rejected_at = $3
  WHERE room_id = $1 AND invitee_id = $2
    AND accepted_at IS NULL AND rejected_at IS NULL
  """

  @doc """
  Marks a pending invitation as rejected by setting `rejected_at`.
  Called when a user declines an invite via POST /rooms/{roomId}/leave on an invited room.
  Returns `:ok` on success.
  """
  @spec reject_invitation(String.t(), String.t()) :: :ok | {:error, term()}
  def reject_invitation(room_id, invitee_id) do
    now_ms = System.system_time(:millisecond)

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_reject_invitation, [
           room_id,
           invitee_id,
           now_ms
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_accept_invitation """
  UPDATE room_invitations
  SET accepted_at = $3
  WHERE room_id = $1 AND invitee_id = $2
    AND accepted_at IS NULL AND rejected_at IS NULL
  """

  @doc """
  Marks a pending invitation as accepted by setting `accepted_at`.
  Called when a user joins a room they were invited to, so the invite
  disappears from `rooms.invite` in subsequent sync responses.

  No-op if there is no pending invitation (e.g. public room join without invite).
  Returns `:ok` on success, `{:error, reason}` on DB error.
  """
  @spec accept_invitation(String.t(), String.t()) :: :ok | {:error, term()}
  def accept_invitation(room_id, invitee_id) do
    now_ms = System.system_time(:millisecond)

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_accept_invitation, [
           room_id,
           invitee_id,
           now_ms
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_get_pending_invite_rooms """
  SELECT room_id FROM room_invitations
  WHERE invitee_id = $1 AND accepted_at IS NULL AND rejected_at IS NULL
  """

  @doc "Returns room_ids where user has a pending (not accepted, not rejected) invitation."
  @spec get_pending_invite_rooms_for_user(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_pending_invite_rooms_for_user(invitee_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_pending_invite_rooms, [invitee_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_get_declined_invite_rooms """
  SELECT room_id FROM room_invitations
  WHERE invitee_id = $1 AND rejected_at IS NOT NULL
  """

  @doc """
  Returns room_ids where the user has a declined invitation (rejected_at IS NOT NULL).

  NOT used by the sync since story sync-membership-partition: the sync classifies rooms with
  `Room.DB.membership_candidates/1` (a declined invitation is a `rejected` candidate row) and delivers a decline once as
  `rooms.leave`, never through `rooms.join`.
  """
  @spec get_declined_invite_rooms_for_user(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_declined_invite_rooms_for_user(invitee_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_declined_invite_rooms, [invitee_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_pending_invitation """
  SELECT invited_at FROM room_invitations
  WHERE room_id = $1 AND invitee_id = $2
    AND accepted_at IS NULL AND rejected_at IS NULL
  """

  @doc """
  The `invited_at` (ms) of the PENDING invitation (neither accepted nor rejected) of `invitee_id` to `room_id`, `nil`
  when there is none (story sync-membership-partition, D13). The join decision needs the timestamp to tell a valid
  invitation from a TAKEN-BACK one (a `leave` member event at least as new as `invited_at` behind a row whose reject
  failed). Read-only. `{:error, reason}` on a DB failure (the caller fails closed).
  """
  @spec pending_invitation(String.t(), String.t()) :: {:ok, integer() | nil} | {:error, term()}
  def pending_invitation(room_id, invitee_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_pending_invitation, [room_id, invitee_id]) do
      {:ok, %{rows: [[invited_at]]}} -> {:ok, invited_at}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
