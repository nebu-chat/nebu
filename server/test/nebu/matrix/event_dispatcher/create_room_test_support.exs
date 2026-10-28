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

defmodule Nebu.Test.ServerName do
  @moduledoc """
  Pins `:event_dispatcher, :server_name` for the calling test and restores the previous value afterwards (story
  create-room-invites-direct, DATA adaptation of the suites that invite through `POST /rooms/{roomId}/invite`).

  `POST /invite` and createRoom `invite` refuse a foreign-domain invitee (D3, the domain is compared with this key), and many older
  suites DELETE the key on exit, which falls back to "localhost": an invitee `@x:test.local` would then be foreign and the outcome of
  the suite would depend on the order of the suites. Call it from `setup` (it registers an `on_exit`, never a bare delete).
  """
  def pin!(name) do
    prior = Application.fetch_env(:event_dispatcher, :server_name)
    Application.put_env(:event_dispatcher, :server_name, name)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:event_dispatcher, :server_name, value)
        :error -> Application.delete_env(:event_dispatcher, :server_name)
      end
    end)

    :ok
  end
end

# story event-size-limit (test review MINOR-10): the shared legacy-row helper of the event-size-limit suites lives here because this file is already
# loaded by test_helper.exs and ignored by the `mix test` file filters (a new support file would need a mix.exs filter entry).
defmodule Nebu.Test.EventSizeSupport do
  @moduledoc """
  Shared helper of the event-size-limit suites (test review MINOR-10): a LEGACY row, i.e. an event written before the story, inserted with
  `Nebu.Matrix.Room.DB.insert_event/1` as the CURRENT event of its slot in a room the calling test owns.

  The event is stamped `max(now, newest event of the room) + 1` (never an arbitrary future stamp outside a room the test owns: follow-up `fj`) and the
  helper polls (1 ms steps, no fixed sleep) until the clock is past that stamp, so that a later write through the API is strictly newer.
  """
  import ExUnit.Assertions

  @doc "Inserts the legacy event, waits for the clock to pass its stamp, returns the stamp."
  def legacy_event!(room, sender, type, key, content) do
    newest = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT coalesce(max(origin_server_ts), 0) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()
    ts = max(System.system_time(:millisecond), newest) + 1

    assert :ok =
             Nebu.Matrix.Room.DB.insert_event(%{
               "event_id" => "$" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
               "room_id" => room,
               "sender" => sender,
               "type" => type,
               "state_key" => key,
               "content" => content,
               "origin_server_ts" => ts
             })

    wait_clock_past(ts)
    ts
  end

  @doc "Polls until `System.system_time(:millisecond)` is greater than `ts`."
  def wait_clock_past(ts, attempts \\ 300) do
    cond do
      System.system_time(:millisecond) > ts -> :ok
      attempts <= 0 -> flunk("the clock did not pass #{ts}")
      true -> (Process.sleep(1); wait_clock_past(ts, attempts - 1))
    end
  end
end
