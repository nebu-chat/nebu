defmodule Nebu.Matrix.DeviceListStore do
  @moduledoc """
  The device-list change STREAM (story device-key-directory, epic e2ee-client-support, REQ-2026-013): what `GET /keys/changes` and the `device_lists` of
  `GET /sync` read. Directory metadata only; ADR-011 stays (this enables no E2EE room). Plain module, inline SQL (ADR-018), PostgreSQL only (cluster safe,
  ADR-020): no process state.

  ## The table (migration 000060)

  `device_list_changes (user_id, room_id, kind, pos)`, the LATEST change per (user, room): kind `keys` (room_id `''`: the user's device identity keys, device
  list or cross-signing keys changed; written by `stamp_keys/2`), kind `join` / `leave` (the user's membership of the room changed; written by a trigger on
  `room_members`). `pos` is drawn from `sync_global_pos_seq` AT COMMIT by a deferred constraint trigger under ONE global advisory lock, so the visible positions
  are commit ordered: a reader that has seen position M never later sees a row at or below M. `position/0` takes the same lock for an instant, so the
  position it returns is above every position that is visible now.

  ## The token position

  The position travels in the sync `next_batch` as an optional LAST group `.d<digits>` (`strip_position/1`, `put_position/2`). A token without it means
  "unknown" (`nil`): the readers answer conservatively with every user the caller currently shares a joined room with. An incremental answer carries
  `max(since, bound)` (`changes/3`): `bound/0` is read BEFORE the two stream reads and is their upper limit, so the position advances even for a caller none of
  the new rows concerns, and its next sync does not scan those rows again.

  ## Who is reported

  Always through the caller's OWN shared rooms (both sides `join`): `changed` = users (and the caller itself) whose keys changed after `since`, users who joined
  a room the caller is in after `since`, and, when the caller joined a room after `since`, every other member of it; `left` = users who share no joined room
  with the caller any more although a `leave` was stamped after `since` in a room both were in (it can over-report a user who shared a room only at another
  time; it never under-reports a real loss).
  """

  @lock_class 4760
  @lock_obj 60
  @max_pos 9_223_372_036_854_775_807
  @token_re ~r/\A[A-Za-z0-9_\-=]{1,256}(\.[0-9]{1,19}){0,2}(\.d[0-9]{1,19})?\z/

  @changed_sql """
  WITH me AS MATERIALIZED (SELECT room_id FROM room_members WHERE user_id = $1 AND left_at IS NULL),
       shared AS MATERIALIZED (
         SELECT DISTINCT o.user_id FROM room_members o JOIN me ON me.room_id = o.room_id WHERE o.left_at IS NULL AND o.user_id <> $1),
       hits AS (
         SELECT c.user_id, c.pos FROM device_list_changes c
          WHERE c.kind = 'keys' AND c.pos > $2 AND c.pos <= $3
            AND (c.user_id = $1 OR c.user_id IN (SELECT user_id FROM shared))
         UNION ALL
         SELECT c.user_id, c.pos FROM device_list_changes c JOIN me ON me.room_id = c.room_id
          WHERE c.kind = 'join' AND c.user_id <> $1 AND c.pos > $2 AND c.pos <= $3
         UNION ALL
         SELECT m.user_id, c.pos FROM device_list_changes c
           JOIN me ON me.room_id = c.room_id
           JOIN room_members m ON m.room_id = c.room_id AND m.left_at IS NULL AND m.user_id <> $1
          WHERE c.user_id = $1 AND c.kind = 'join' AND c.pos > $2 AND c.pos <= $3)
  SELECT user_id, max(pos) FROM hits GROUP BY user_id ORDER BY user_id
  """

  @left_sql """
  WITH hits AS (
         SELECT c.user_id, c.pos FROM device_list_changes c
          WHERE c.kind = 'leave' AND c.user_id <> $1 AND c.pos > $2 AND c.pos <= $3
            AND EXISTS (SELECT 1 FROM room_members m WHERE m.room_id = c.room_id AND m.user_id = $1 AND m.left_at IS NULL)
         UNION ALL
         SELECT m.user_id, c.pos FROM device_list_changes c
           JOIN room_members m ON m.room_id = c.room_id AND m.user_id <> $1
          WHERE c.user_id = $1 AND c.kind = 'leave' AND c.pos > $2 AND c.pos <= $3)
  SELECT h.user_id, max(h.pos) FROM hits h
   WHERE NOT EXISTS (SELECT 1 FROM room_members a JOIN room_members b ON b.room_id = a.room_id
                      WHERE a.user_id = h.user_id AND a.left_at IS NULL AND b.user_id = $1 AND b.left_at IS NULL)
   GROUP BY h.user_id ORDER BY h.user_id
  """

  # ── the token ────────────────────────────────────────────────────────────────

  @doc """
  Splits the device-list position off a sync token: `{token_without_group, position | nil}`. A token whose last group is not `.d<digits>` is returned as it
  is with `nil`. A last group `.d<digits>` whose number does not fit an int8 (above 9223372036854775807, or more than 19 digits) is STRIPPED all the same and
  the position is `nil` (the caller then answers conservatively; the stripped token still names the core part, so nothing else is lost).
  """
  @spec strip_position(String.t() | nil) :: {String.t() | nil, non_neg_integer() | nil}
  def strip_position(token) when is_binary(token) do
    case Regex.run(~r/\A(.+)\.d([0-9]+)\z/s, token) do
      [_, rest, digits] -> {rest, to_pos(digits)}
      _ -> {token, nil}
    end
  end

  def strip_position(other), do: {other, nil}

  @doc "Appends the position group (`nil` appends nothing)."
  @spec put_position(String.t(), non_neg_integer() | nil) :: String.t()
  def put_position(token, nil), do: token
  def put_position(token, pos) when is_integer(pos), do: token <> ".d" <> Integer.to_string(pos)

  @doc """
  Validates a token for `GET /keys/changes`: `{:ok, position | nil}` (nil: well formed, no device-list position) or `:error` (malformed: outside the token
  alphabet, a bad group, longer than 512 bytes, a number that does not fit an int8).
  """
  @spec parse_token(term()) :: {:ok, non_neg_integer() | nil} | :error
  def parse_token(token) when is_binary(token) and byte_size(token) in 1..512 do
    if Regex.match?(@token_re, token) do
      case Regex.run(~r/\.d([0-9]+)\z/, token) do
        [_, digits] -> if to_pos(digits), do: {:ok, to_pos(digits)}, else: :error
        _ -> {:ok, nil}
      end
    else
      :error
    end
  end

  def parse_token(_), do: :error

  defp to_pos(digits) do
    pos = if byte_size(digits) <= 19, do: String.to_integer(digits)
    if is_integer(pos) and pos <= @max_pos, do: pos
  end

  # ── writing ──────────────────────────────────────────────────────────────────

  @doc """
  Marks the user's device list as changed (keys / devices / cross-signing). The position is drawn at the COMMIT of the surrounding transaction; run it inside
  the transaction of the write it belongs to (`repo` is the repo of that transaction). Raises on a database error so the write rolls back with it.
  """
  @spec stamp_keys!(module(), String.t()) :: :ok
  def stamp_keys!(repo \\ Nebu.Repo, user_id) when is_binary(user_id) do
    case Ecto.Adapters.SQL.query(
           repo,
           """
           INSERT INTO device_list_changes (user_id, room_id, kind, pos) VALUES ($1, '', 'keys', NULL)
           ON CONFLICT (user_id, room_id) DO UPDATE SET kind = 'keys', pos = NULL
           """,
           [user_id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  # ── reading ──────────────────────────────────────────────────────────────────

  @doc """
  A fresh position that is above every position visible now (a short transaction that takes the commit lock, then draws the next value). `{:ok, pos}` or
  `{:error, reason}`; never raises.
  """
  @spec position() :: {:ok, non_neg_integer()} | {:error, term()}
  def position do
    if Process.whereis(Nebu.Repo) do
      case Nebu.Repo.transaction(fn ->
             Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT pg_advisory_xact_lock($1, $2)", [@lock_class, @lock_obj])
             %{rows: [[pos]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT nextval('sync_global_pos_seq')", [])
             pos
           end) do
        {:ok, pos} -> {:ok, pos}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  The highest device-list position that is visible now (0 for an empty stream): one index read, no lock. Visible positions are commit ordered (see the
  moduledoc), so a row stamped later always gets a position ABOVE this value; a reader that reads the stream up to it never skips a later change.
  """
  @spec bound() :: {:ok, non_neg_integer()} | {:error, term()}
  def bound do
    if Process.whereis(Nebu.Repo) do
      with {:ok, %{rows: [[max_pos]]}} <- query("SELECT max(pos) FROM device_list_changes", []),
           do: {:ok, max_pos || 0}
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  The users to report to `user_id` between `since` (exclusive, a position; `nil` = unknown: everyone currently shared) and `upto` (inclusive; `nil` = the
  bound read by `bound/0` BEFORE the two reads below): `{:ok, %{changed: [user], left: [user], pos: position}}` where `pos` is `max(since, upto)`: the
  position moves up to the bound the reads covered, whether or not a row was reported, so a quiet caller's token advances and its next sync does not scan the
  old rows again (story device-key-directory, D11). Never raises.
  """
  @spec changes(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          {:ok, %{changed: [String.t()], left: [String.t()], pos: non_neg_integer() | nil}} | {:error, term()}
  def changes(user_id, nil, _upto) do
    with {:ok, shared} <- shared_users(user_id), do: {:ok, %{changed: Enum.uniq([user_id | shared]), left: [], pos: nil}}
  end

  def changes(user_id, since, upto) when is_integer(since) do
    if Process.whereis(Nebu.Repo) do
      with {:ok, limit} <- if(is_integer(upto), do: {:ok, upto}, else: bound()),
           {:ok, %{rows: changed}} <- query(@changed_sql, [user_id, since, limit]),
           {:ok, %{rows: left}} <- query(@left_sql, [user_id, since, limit]) do
        {:ok, %{changed: Enum.map(changed, &hd/1), left: Enum.map(left, &hd/1), pos: max(since, limit)}}
      end
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Every other user the caller currently shares a joined room with (both sides `join`)."
  @spec shared_users(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def shared_users(user_id) do
    if Process.whereis(Nebu.Repo) do
      with {:ok, %{rows: rows}} <-
             query(
               """
               SELECT DISTINCT o.user_id FROM room_members o JOIN room_members m ON m.room_id = o.room_id
                WHERE m.user_id = $1 AND m.left_at IS NULL AND o.left_at IS NULL AND o.user_id <> $1
               """,
               [user_id]
             ),
           do: {:ok, List.flatten(rows)}
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
end
