defmodule Nebu.Matrix.KeyClaimStore do
  @moduledoc """
  `POST /keys/claim` (story device-key-directory, epic e2ee-client-support, REQ-2026-013): hands out one-time keys EXACTLY ONCE and the fallback key of a
  device without consuming it. Plain module, inline SQL (ADR-018), PostgreSQL only (cluster safe, ADR-020).

  ONE statement serves the whole request (a set based claim, no statement per target, no early return per target), so every kind of target (unknown user,
  unknown device, keyless device, a user the caller shares no joined room with, an invite-only share, a remote user) runs the SAME statements: no existence
  oracle, not even by statement count. The restriction (the caller itself, or a user who shares a room with the caller where BOTH sides are `join`, the rule
  of `ToDeviceStore`) is evaluated inside that statement at request time, and so is the status of both sides: a deactivated or erased caller claims nothing and the keys of a
  deactivated or erased user are not handed out.

  The one-time key is taken with `UPDATE ... WHERE ctid = ANY(<picked>)` where `<picked>` selects the oldest unclaimed key of every target with
  `FOR UPDATE SKIP LOCKED` (a key another claim holds is skipped, never waited for and never handed out twice; a SELECT followed by an UPDATE would hand a key
  out twice). A target without an unclaimed key of the requested algorithm gets its fallback key, which is only marked `used` (never deleted; the mark skips a row another
  transaction holds, so a claim never waits for a lock: a delete or an upload of that device in flight does not block it).
  The key objects are returned verbatim (the stored JSON).
  """

  @sql """
  WITH req AS MATERIALIZED (
         SELECT t.u AS user_id, t.d AS device_id, t.a AS algorithm FROM unnest($2::text[], $3::text[], $4::text[]) AS t(u, d, a)),
       allowed AS MATERIALIZED (
         SELECT r.user_id, r.device_id, r.algorithm FROM req r
          WHERE (r.user_id = $1
             OR EXISTS (SELECT 1 FROM room_members o JOIN room_members m ON m.room_id = o.room_id
                         WHERE o.user_id = r.user_id AND o.left_at IS NULL AND m.user_id = $1 AND m.left_at IS NULL))
            AND EXISTS (SELECT 1 FROM users c WHERE c.user_id = $1 AND c.is_active AND c.deletion_status IS NULL)
            AND EXISTS (SELECT 1 FROM users t WHERE t.user_id = r.user_id AND t.is_active AND t.deletion_status IS NULL)),
       picked AS MATERIALIZED (
         SELECT k.tid FROM allowed a
           CROSS JOIN LATERAL (SELECT o.ctid AS tid FROM device_one_time_keys o
                                WHERE o.user_id = a.user_id AND o.device_id = a.device_id AND o.algorithm = a.algorithm AND o.claimed_at IS NULL
                                ORDER BY o.created_at, o.key_id LIMIT 1 FOR UPDATE SKIP LOCKED) k),
       otk AS (
         UPDATE device_one_time_keys o SET claimed_at = $5
          WHERE o.ctid = ANY(ARRAY(SELECT tid FROM picked))
          RETURNING o.user_id, o.device_id, o.algorithm, o.key_id, o.key_json),
       fb AS (
         SELECT f.user_id, f.device_id, f.algorithm, f.key_id, f.key_json FROM device_fallback_keys f
           JOIN allowed a ON f.user_id = a.user_id AND f.device_id = a.device_id AND f.algorithm = a.algorithm
          WHERE NOT EXISTS (SELECT 1 FROM otk WHERE otk.user_id = a.user_id AND otk.device_id = a.device_id AND otk.algorithm = a.algorithm)),
       mark AS (
         UPDATE device_fallback_keys f SET used = TRUE
          WHERE f.ctid = ANY(ARRAY(SELECT f2.ctid FROM device_fallback_keys f2 JOIN fb ON f2.user_id = fb.user_id AND f2.device_id = fb.device_id AND f2.algorithm = fb.algorithm
                                    WHERE NOT f2.used FOR UPDATE OF f2 SKIP LOCKED))
          RETURNING 1)
  SELECT user_id, device_id, algorithm || ':' || key_id, key_json FROM otk
  UNION ALL
  SELECT user_id, device_id, algorithm || ':' || COALESCE(key_id, 'fallback'), key_json FROM fb
  """

  @doc """
  Claims for `caller`: `targets` is `[{user_id, device_id, algorithm}]` (unique). Returns `{:ok, %{user => %{device => %{"<alg>:<id>" => key object}}}}`
  with only the devices that yielded a key. A fallback key is returned under its own stored id (`device_fallback_keys.key_id`, `<algorithm>:fallback` for a
  row stored before migration 000060).
  """
  @spec claim(String.t(), [{String.t(), String.t(), String.t()}]) :: {:ok, map()} | {:error, term()}
  def claim(caller, targets) when is_binary(caller) and is_list(targets) do
    {us, ds, as} = {Enum.map(targets, &elem(&1, 0)), Enum.map(targets, &elem(&1, 1)), Enum.map(targets, &elem(&1, 2))}

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql, [caller, us, ds, as, System.system_time(:millisecond)]) do
      {:ok, %{rows: rows}} -> {:ok, build(rows)}
      {:error, error} -> {:error, error}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp build(rows) do
    Enum.reduce(rows, %{}, fn [uid, did, key_id, json], acc ->
      key = Jason.decode!(json)
      put_in_nested(acc, uid, did, key_id, key)
    end)
  end

  defp put_in_nested(acc, uid, did, key_id, key) do
    Map.update(acc, uid, %{did => %{key_id => key}}, fn devices ->
      Map.update(devices, did, %{key_id => key}, &Map.put(&1, key_id, key))
    end)
  end
end
