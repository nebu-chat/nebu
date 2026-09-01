defmodule Nebu.Media.Permission do
  @moduledoc """
  Production default for the `:media_permission_module` seam
  (media-security-admin-control/2a-post-media-create, AC4).

  There is no per-user/per-room "upload permission" concept anywhere in this
  codebase today — see the story's "Open assumptions" section. The only
  currently-known reason an authenticated Matrix user could lack upload
  permission is a deactivated account, so `can_upload?/1` reuses that
  existing `{:error, :deactivated}` concept
  (`Nebu.Matrix.provision_identity/2`) via `Nebu.Matrix.active?/1`.

  Injectable (`:media_permission_module`, default this module) specifically
  so a future, more granular permission model (e.g. a room-power-level
  check, or a compliance hold) can be swapped in without touching
  `Nebu.Media.create/1` again.

  ADR-020: reaches the Matrix domain ONLY through `Nebu.Matrix`'s public API
  — never `Nebu.Matrix.Session.*`/`Nebu.Matrix.EventDispatcher.*` directly.
  """

  @doc "Returns `true` if `user_id` is allowed to reserve/upload media."
  @spec can_upload?(String.t()) :: boolean()
  def can_upload?(user_id) when is_binary(user_id) do
    Nebu.Matrix.active?(user_id)
  end
end
