defmodule Nebu.Test.NoOpUserStore do
  @moduledoc """
  Shared test fake for the `Nebu.Matrix.EventDispatcher.Server` `user_store_module()`
  seam (story admin-room-creator-provisioning).

  `create_room/2` provisions the creator into `users` via this seam before the
  creator-join. Unit tests that mock the room DB (and therefore have no live Repo)
  inject this no-op so the provisioning step succeeds without PostgreSQL:

      Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)

  Idempotent and role-preserving by construction — it does not persist anything.
  """
  def upsert_user(user_id, _system_role), do: {:ok, user_id}
end
