defmodule Nebu.Media.Membership do
  @moduledoc """
  Media access control as a LOCAL OTP/DB call (AC2/AC4), replacing the former
  gRPC `CheckMembership` RPC.

  The canonical membership truth is `room_members WHERE left_at IS NULL`
  (mirrors `Nebu.Matrix.Room.DB.load_members/1` and `Nebu.Matrix.Search.DB`). Production default
  for the `:media_membership_module` seam; tests swap it for
  `Nebu.Web.MediaFakes.Membership`.

  ## Room scoping

  `media_files` has no `room_id` column (see `Nebu.Media.DB`), so production
  cannot pin a media file to a single room. The membership policy is therefore:

    * `member?(room_id, user_id)` with a concrete `room_id` — true iff the user is
      an active member of that room.
    * `member?(nil, user_id)` — true iff the user is an active member of *any*
      room. This is the production fallback: an authenticated user who belongs to
      at least one room may read media; a user in no rooms (or an unknown user)
      is denied, preserving the AC4 403 for outsiders without a per-media room
      link the schema does not carry.

  ## KNOWN LIMITATION (tracked follow-up)

  The `nil`-room fallback means production access is "member of ANY room", not
  "member of THE media's room": any authenticated user in >=1 room can download
  any media id. It is FAIL-CLOSED (zero-room / unknown user → denied, 403
  M_FORBIDDEN) and stricter than the Matrix spec, but per-media room scoping
  requires the schema change described in `Nebu.Media.DB` and is a tracked
  follow-up flagged to security-review as a known, accepted gap.

  Fail-closed: a DB error returns `false` (deny), never leaks bytes.
  """

  @sql_member_of_room """
  SELECT 1 FROM room_members
  WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL
  LIMIT 1
  """

  @sql_member_of_any """
  SELECT 1 FROM room_members
  WHERE user_id = $1 AND left_at IS NULL
  LIMIT 1
  """

  @spec member?(String.t() | nil, String.t()) :: boolean()
  def member?(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    query?(@sql_member_of_room, [room_id, user_id])
  end

  def member?(nil, user_id) when is_binary(user_id) do
    query?(@sql_member_of_any, [user_id])
  end

  def member?(_room_id, _user_id), do: false

  defp query?(sql, params) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, params) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end
end
