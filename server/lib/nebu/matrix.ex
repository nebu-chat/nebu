defmodule Nebu.Matrix do
  @moduledoc """
  Public API for the Matrix domain (ADR-020).

  This module is the **only** entry point other domains (`Nebu.Admin`, `Nebu.Media`,
  `Nebu.Web`) may call into the Matrix domain. Internal Matrix modules
  (`Nebu.Matrix.Room.*`, `Nebu.Matrix.Session.*`, `Nebu.Matrix.EventDispatcher.*`,
  `Nebu.Matrix.Presence.*`, `Nebu.Matrix.Permissions.*`, `Nebu.Matrix.Signature.*`,
  …) are private to the domain and must not be called directly from outside it.

  Kassandra flags any cross-domain call into `Nebu.Matrix.*` (other than this module)
  as a finding.

  The Matrix domain owns: rooms and room state, the event log and dispatch, sync,
  sessions/tokens, presence, typing, receipts, profiles, power levels, message
  signing, and the Matrix Client-Server HTTP surface.

  `defdelegate` entries are added here as concrete cross-domain operations are
  introduced; today the in-process callers within the Matrix domain use the internal
  modules directly, and no other domain reaches into Matrix internals.

  ## Spaces S5 — Admin Spaces management surface

  The Admin UI (`Nebu.Admin.SpacesLive`) manages Spaces through this module only
  (ADR-020). Each function below routes to the same authorized in-process command
  path the Matrix HTTP routers use (`Nebu.Matrix.EventDispatcher.Server`), so admin
  writes go through the identical signing / power-level / allowlist checks — there is
  no second, unauthorised write path. The admin acts as a Matrix user (`actor_id`):
  for `create_space/2` that user becomes the room creator (power level 100); for
  `set_space_state/5` the actor must be a member with the power to set state (the S2
  `set_room_state` authorization).
  """

  alias Nebu.Matrix.EventDispatcher.Server, as: Dispatcher

  @doc """
  Creates a Matrix Space (a room with `creation_content.type = "m.space"`), with
  `creator_id` as the creator (power level 100). `name` may be `nil`/`""`.

  Returns `{:ok, room_id}` or `{:error, reason}`. Routes through the authorized
  createRoom command path (Spaces S1) — same signing/persistence as a client create.
  """
  @spec create_space(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def create_space(creator_id, name) do
    req = %Core.CreateRoomRequest{
      creator_id: creator_id,
      name: name || "",
      is_direct: false,
      room_type: "m.space",
      creation_content_json: Jason.encode!(%{"type" => "m.space"})
    }

    try do
      %Core.CreateRoomResponse{room_id: room_id} = Dispatcher.create_room(req, nil)
      {:ok, room_id}
    rescue
      e in Nebu.Matrix.Error -> {:error, e.message}
    end
  end

  @doc """
  Writes a state event into a Space through the S2 authorized `set_room_state` path
  (allowlist + membership + power-level check). Used by the Admin UI to edit a
  Space's name/topic (`m.room.name` / `m.room.topic`) and to add/remove child rooms
  (`m.space.child` with content / empty-content unlink).

  `sender_id` is the acting admin's Matrix user id. `content` is a plain map.

  Returns `{:ok, event_id}` or `{:error, reason}`.
  """
  @spec set_space_state(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def set_space_state(room_id, sender_id, event_type, state_key, content)
      when is_map(content) do
    req = %Core.SetRoomStateRequest{
      room_id: room_id,
      sender_id: sender_id,
      event_type: event_type,
      state_key: state_key || "",
      content_json: Jason.encode!(content)
    }

    try do
      %Core.SetRoomStateResponse{event_id: event_id} = Dispatcher.set_room_state(req, nil)
      {:ok, event_id}
    rescue
      e in Nebu.Matrix.Error -> {:error, e.message}
    end
  end

  @doc """
  Returns the current `m.space.child` edges of `space_id` as `{:ok, [{child_room_id,
  content_map}]}` (Spaces S3). Empty (unlinked) children are already dropped.
  """
  @spec get_space_children(String.t()) :: {:ok, [{String.t(), map()}]} | {:error, term()}
  defdelegate get_space_children(space_id), to: Nebu.Matrix.Room.DB

  @doc """
  Returns all auto-join Space room IDs (`room_type = 'm.space' AND is_auto_join AND
  status = 'active'`). Spaces S5 (AC6).
  """
  @spec list_auto_join_spaces() :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list_auto_join_spaces, to: Nebu.Matrix.Room.DB

  @doc """
  Auto-joins `user_id` to every flagged Space (first-login provisioning). Non-fatal.
  Spaces S5 (AC6).
  """
  @spec ensure_auto_join_space_memberships(String.t()) :: :ok
  defdelegate ensure_auto_join_space_memberships(user_id), to: Dispatcher

  @doc """
  Persists the `is_auto_join` flag for a Space (or room) and emits the audit_log
  entry, performed as `actor_id` (Spaces S5 AC5). This is the same audited write the
  `update_room_settings` command path uses for the rooms admin toggle — a Space is a
  room, so the persistence + audit are identical. Routed through the Matrix domain so
  the Admin UI never reaches into Matrix/Admin internals directly (ADR-020).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_room_auto_join(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  defdelegate set_room_auto_join(actor_id, room_id, value), to: Dispatcher

  @doc """
  Persists a room's `visibility` ("public" | "private") and emits the audit_log entry,
  performed as `actor_id` (Story rm1-room-visibility). This is the same audited,
  validated, parameterised write the `update_room_settings` command path performs for
  its visibility branch. Routed through the Matrix domain so the Admin UI never reaches
  into Matrix/Admin internals directly (ADR-020).

  Default-deny: only "public"/"private" are accepted; any other value returns
  `{:error, :invalid_visibility}` without touching the DB.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_room_visibility(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate set_room_visibility(actor_id, room_id, visibility), to: Dispatcher

  @doc """
  Adds `user_id` to `room_id` as the acting admin `actor_id` (Story rm4). Wraps the
  SAME authorized join write path the Matrix client flow uses (`join_room`): it emits
  a proper `m.room.member` join event and upserts `room_members` (`left_at = NULL`),
  then writes a `member_added` audit row with the admin as actor.

  Default-deny: `user_id` is shape-validated (`Nebu.Matrix.UserId.valid?/1`) before any
  write; a malformed id returns `{:error, :invalid_user_id}` without touching the DB.
  An unknown room surfaces as `{:error, :not_found}`. Routed through the Matrix domain
  so the Admin UI never reaches into Matrix internals directly (ADR-020).

  Returns `{:ok, room_id}` or `{:error, reason}`.
  """
  @spec admin_add_room_member(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate admin_add_room_member(room_id, user_id, actor_id), to: Dispatcher

  @doc """
  Removes `user_id` from `room_id` as the acting admin `actor_id` (Story rm4). Wraps the
  SAME authorized leave write path the Matrix client flow uses (`leave_room`): it emits a
  proper `m.room.member` leave event and sets `room_members.left_at`, then writes a
  `member_removed` audit row with the admin as actor.

  Self-removal is rejected server-side (`{:error, :self_removal}`) so an admin can never
  drop their own membership through this path (defence-in-depth; the UI also hides the
  control). `user_id` is shape-validated before any write. Routed through the Matrix
  domain (ADR-020).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec admin_remove_room_member(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate admin_remove_room_member(room_id, user_id, actor_id), to: Dispatcher

  @doc """
  Creates an ordinary Matrix room with `creator_id` as the creator (power level 100),
  through the SAME authorized `createRoom` command path the Matrix `POST /createRoom`
  flow uses (`Nebu.Matrix.EventDispatcher.Server.create_room/2`). The created room is
  audited (`room_created`) with `creator_id` as the actor.

  `opts`:
    * `:name`       — the room name (`m.room.name`); `nil`/`""` leaves it unnamed.
    * `:visibility` — `"public"` | `"private"` (default `"private"`). When `"public"`,
      the room's `visibility` is set through the audited `set_room_visibility/3` path
      after creation (an ordinary room's default is `"private"`). Any value other than
      `"public"`/`"private"` returns `{:error, :invalid_visibility}` without creating a
      room (default-deny — same allowlist `set_room_visibility/3` enforces).

  Routed through the Matrix domain so the Admin UI never reaches into Matrix internals
  directly (ADR-020).

  Returns `{:ok, room_id}` or `{:error, reason}`.
  """
  @spec create_room(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_room(creator_id, opts \\ []) when is_list(opts) do
    name = opts[:name] || ""
    visibility = opts[:visibility] || "private"

    # Default-deny: validate the visibility allowlist BEFORE creating the room so an
    # invalid value never produces an orphan room. Mirrors set_room_visibility/3.
    if visibility not in ["public", "private"] do
      {:error, :invalid_visibility}
    else
      req = %Core.CreateRoomRequest{
        creator_id: creator_id,
        name: name,
        is_direct: false,
        room_type: "",
        creation_content_json: ""
      }

      try do
        %Core.CreateRoomResponse{room_id: room_id} = Dispatcher.create_room(req, nil)

        # An ordinary room defaults to private; only flip to public via the audited
        # visibility write path. A failed visibility write is non-fatal — the room
        # exists; surface it as a warning rather than failing the whole create.
        if visibility == "public" do
          case set_room_visibility(creator_id, room_id, "public") do
            :ok -> :ok
            {:error, reason} ->
              require Logger
              Logger.warning("create_room: visibility write failed for #{room_id}: #{inspect(reason)}")
          end
        end

        {:ok, room_id}
      rescue
        e in Nebu.Matrix.Error -> {:error, e.message}
      end
    end
  end

  @doc """
  Archives a room as `actor_id` (the acting admin's Matrix user id), through the SAME
  authorized command path the admin archive RPC uses
  (`Nebu.Matrix.EventDispatcher.Server.archive_room/2`): it atomically sets
  `rooms.status='archived'` (SELECT FOR UPDATE), terminates any running Room GenServer
  (best-effort, GenServer-independent), and writes a `room_archived` audit row.

  Returns `:ok`, `{:error, :not_found}` for an unknown room, or `{:error, reason}`.
  Routed through the Matrix domain (ADR-020).
  """
  @spec archive_room(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def archive_room(actor_id, room_id) do
    req = %Core.ArchiveRoomRequest{room_id: room_id}

    try do
      %Core.ArchiveRoomResponse{ok: true} = Dispatcher.archive_room(req, actor_stream(actor_id))
      :ok
    rescue
      e in Nebu.Matrix.Error -> map_room_error(e)
    end
  end

  @doc """
  Unarchives a room as `actor_id`, through the SAME authorized command path the admin
  unarchive RPC uses (`Nebu.Matrix.EventDispatcher.Server.unarchive_room/2`): it sets
  `rooms.status='active'`, (re)starts the Room GenServer best-effort, and writes a
  `room_unarchived` audit row.

  Returns `:ok`, `{:error, :not_found}`, or `{:error, reason}`. Routed through the
  Matrix domain (ADR-020).
  """
  @spec unarchive_room(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def unarchive_room(actor_id, room_id) do
    req = %Core.UnarchiveRoomRequest{room_id: room_id}

    try do
      %Core.UnarchiveRoomResponse{ok: true} = Dispatcher.unarchive_room(req, actor_stream(actor_id))
      :ok
    rescue
      e in Nebu.Matrix.Error -> map_room_error(e)
    end
  end

  @doc """
  Invalidates the node-local `oidc_user_id_claim` cache and propagates the
  invalidation across the cluster via `:pg` (story `oidc-claim-boot-cache`,
  ADR-020).

  This is the Public-API entry point (ADR-020) the admin write path calls after
  `Nebu.Admin.DB.upsert_server_config/1` persists a change that includes the
  `oidc_user_id_claim` key — `Nebu.Admin` must never reach into the Matrix-domain
  cache module directly. Triggers a local re-read and a `:pg` broadcast so every
  node refreshes its cached value; a change that does not touch
  `oidc_user_id_claim` never calls this.

  Returns `:ok`. Best-effort and non-fatal: a re-read failure leaves the cache in
  a state that a subsequent request will lazily repopulate.
  """
  @spec invalidate_oidc_claim_cache() :: :ok
  defdelegate invalidate_oidc_claim_cache(), to: Nebu.Matrix.OidcClaimCache, as: :refresh

  @doc """
  Returns the space-separated extra OIDC scopes configured for the Matrix SSO
  login flow (bugfix-unify-admin-matrix-oidc-identity).

  `Nebu.Admin.Auth.admin_oidc_scope/0` folds this into the admin flow's own
  requested scope (union, not replace) so the admin ID token is always a
  claim-superset of the Matrix ID token — this is the Public-API entry point
  (ADR-020) that call site must use instead of reaching into
  `Nebu.Matrix.SsoLogin` directly.
  """
  @spec matrix_oidc_extra_scopes() :: String.t()
  defdelegate matrix_oidc_extra_scopes(), to: Nebu.Matrix.SsoLogin, as: :matrix_extra_scopes

  # ── Device management (device-management S4 — Admin UI per-user devices) ──────
  #
  # The Admin domain manages a user's devices through this facade only (ADR-020);
  # it must never reach into `Nebu.Matrix.DeviceKeyStore` / `Session.DeviceBinding`
  # directly. The underlying user-scoped operations live in those internal modules.

  @doc """
  Lists a user's registered devices for the Admin UI (S4 AC1). Each map carries
  `"device_id"`, and (when present) `"display_name"`, `"last_seen_ts"`,
  `"last_seen_ip"`, `"created_ts"`. Sourced from the durable `devices` registry,
  so a keyless device still appears. Read-path: never raises.
  """
  @spec list_user_devices(String.t()) :: [map()]
  defdelegate list_user_devices(user_id), to: Nebu.Matrix.DeviceKeyStore, as: :list_devices

  @doc """
  Renames a device's display name, scoped to the OWNING `user_id` (S4 AC2). Returns
  `:ok` when exactly that user's device row was updated, `:error` for an unknown /
  foreign device (no IDOR — the Admin UI maps `:error` to a flash, never to another
  user's device).
  """
  @spec rename_user_device(String.t(), String.t(), String.t() | nil) :: :ok | :error
  defdelegate rename_user_device(user_id, device_id, display_name),
    to: Nebu.Matrix.DeviceKeyStore,
    as: :rename_device

  @doc """
  Revokes a user's device (S4 AC3): kills its bound sessions (S3 kill-switch) AND
  removes all its persisted state (identity row + device/one-time/fallback keys).
  Both halves are user-scoped (never another user's device — no IDOR) and best-effort
  (idempotent: revoking an absent device is a no-op). Returns `:ok`.

  The session revocation runs FIRST: any raw-JWT token bound to `(user_id, device_id)`
  is denylisted until its own expiry, then the binding rows and key material are
  deleted. One facade call performs both so the Admin controller stays thin.
  """
  @spec delete_user_device(String.t(), String.t()) :: :ok
  def delete_user_device(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    # S3 F-1 kill-switch: denylist every raw-JWT bound to this device (by token hash)
    # until its own exp, then drop the binding rows. (Unlike the Matrix self-delete
    # path there is no caller credential to preserve — an admin acts on another user's
    # device, so EVERY token is revoked.)
    for {token_hash, exp} <-
          Nebu.Matrix.Session.DeviceBinding.list_for_user_device(user_id, device_id) do
      Nebu.Web.TokenDenylist.revoke_by_hash(token_hash, exp)
    end

    _ = Nebu.Matrix.Session.DeviceBinding.delete_for_user_device(user_id, device_id)

    # Revoke the opaque session bound to this device (logout-equivalent).
    _ = Nebu.Matrix.Session.MatrixSessionStore.delete_for_user_device(user_id, device_id)

    # Remove the device identity row + all key material.
    _ = Nebu.Matrix.DeviceKeyStore.delete_device(user_id, device_id)
    :ok
  end

  # The dispatcher reads the acting identity from the request-context map
  # (Nebu.Matrix.RequestMetadata). In-process callers (HTTP/Admin) pass a minimal
  # context map carrying the trusted identity — same shape as Nebu.Matrix.Http.stream/1.
  defp actor_stream(actor_id) do
    %{http_request_headers: %{"x-user-id" => actor_id, "x-system-role" => "instance_admin"}}
  end

  # not_found → {:error, :not_found} so the Admin UI can render a "Room not found"
  # flash; everything else is a generic {:error, message}.
  defp map_room_error(%Nebu.Matrix.Error{status: status, message: message}) do
    if status == Nebu.Matrix.Status.not_found() do
      {:error, :not_found}
    else
      {:error, message}
    end
  end
end
