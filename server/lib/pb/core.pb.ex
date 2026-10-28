defmodule Core.Event do
  @moduledoc false
  defstruct [
    event_id: "",
    room_id: "",
    sender_id: "",
    event_type: "",
    content: "",
    origin_ts: 0,
    server_ts: 0,
    state_key: "",
    unsigned_relations: "",
    # Bugfix unsigned-replaces-state (Matrix CS API v1.19) — see proto/core.proto.
    replaces_state: "",
    # Story member-event-prev-content (D10) — see proto/core.proto.
    prev_content: "",
    prev_sender: "",
    # Code-review cycle 1 (MAJOR-2) — see proto/core.proto.
    is_state_event: false,
    # Story state-writer-redaction (D5, D6) — see proto/core.proto.
    redacts: "",
    redacted_because: ""
  ]
end

defmodule Core.RedactEventRequest do
  @moduledoc false
  defstruct [room_id: "", sender_id: "", event_id: "", txn_id: "", content_json: ""]
end

defmodule Core.RedactEventResponse do
  @moduledoc false
  defstruct [event_id: ""]
end

defmodule Core.SendEventRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    sender_id: "",
    event_type: "",
    txn_id: "",
    content: "",
    origin_ts: 0,
    state_key: "",
    is_state_event: false
  ]
end

defmodule Core.SendEventResponse do
  @moduledoc false
  defstruct [
    event_id: ""
  ]
end

defmodule Core.CreateRoomRequest do
  @moduledoc false
  # HAND-EDITED (stories create-room-input-validation, create-room-presets-power-levels-topic,
  # create-room-invites-direct): `room_version`, `room_alias_name`, `preset`, `visibility`,
  # `power_level_content_override`, `invite` and `invite_3pid` are not in the generated protobuf
  # output (they carry raw client JSON values of ANY type, see proto/core.proto); `topic` is a generated field that
  # now also carries a raw value (a non-string is a 400). A regeneration of this file MUST keep these keys, or
  # createRoom silently stops honouring them.
  defstruct [
    creator_id: "",
    name: nil,
    topic: nil,
    is_direct: false,
    room_type: "",
    creation_content_json: "",
    initial_state_json: "",
    room_version: nil,
    room_alias_name: nil,
    preset: nil,
    visibility: nil,
    power_level_content_override: nil,
    invite: nil,
    invite_3pid: nil
  ]
end

defmodule Core.CreateRoomResponse do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.JoinRoomRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    room_id_or_alias: ""
  ]
end

defmodule Core.JoinRoomResponse do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.LeaveRoomRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    room_id: ""
  ]
end

defmodule Core.LeaveRoomResponse do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.GetMessagesRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    from_token: "",
    to_token: nil,
    limit: 0,
    direction: ""
  ]
end

defmodule Core.GetMessagesResponse do
  @moduledoc false
  defstruct [
    events: [],
    next_batch: "",
    prev_batch: ""
  ]
end

defmodule Core.SetPresenceRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    presence: "",
    status_msg: nil
  ]
end

defmodule Core.SetPresenceResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.SetTypingRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    user_id: "",
    typing: false,
    timeout_ms: 0
  ]
end

defmodule Core.SetTypingResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.ValidateTokenRequest do
  @moduledoc false
  defstruct [
    display_name: "",
    email: ""
  ]
end

defmodule Core.ValidateTokenResponse do
  @moduledoc false
  defstruct [
    user_id: "",
    system_role: "",
    display_name: "",
    is_active: false
  ]
end

defmodule Core.GetPendingEventsRequest do
  @moduledoc false
  defstruct [
    node_id: "",
    since_token: ""
  ]
end

defmodule Core.GetPendingEventsResponse do
  @moduledoc false
  defstruct [
    events: [],
    next_token: ""
  ]
end

defmodule Core.EventBusRequest do
  @moduledoc false
  defstruct [
    node_id: "",
    since_token: nil
  ]
end

defmodule Core.GetMetricsRequest do
  @moduledoc false
  defstruct []
end

defmodule Core.GetMetricsResponse do
  @moduledoc false
  defstruct [
    msg_per_sec: 0.0,
    active_sessions: 0,
    room_count: 0
  ]
end

defmodule Core.InviteUserRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    inviter_id: "",
    invitee_id: ""
  ]
end

defmodule Core.InviteUserResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.GetRoomStateRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    event_type: "",
    state_key: ""
  ]
end

defmodule Core.GetRoomStateResponse do
  @moduledoc false
  defstruct [
    members: [],
    power_levels_json: "",
    room_name: "",
    state_events: []
  ]
end

defmodule Core.SetPowerLevelsRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    power_levels_json: ""
  ]
end

defmodule Core.SetPowerLevelsResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.SendReceiptRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    user_id: "",
    receipt_type: "",
    event_id: ""
  ]
end

defmodule Core.SendReceiptResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.GetInitialSyncRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    # Story sync-token-per-device (D1, D4) — see proto/core.proto: the key of the persisted since token ("" = the per-user row).
    device_id: ""
  ]
end

defmodule Core.GetInitialSyncResponse do
  @moduledoc false
  defstruct [
    since_token: "",
    # Story sync-membership-partition — see proto/core.proto: `rooms` = the DELIVERED joined rooms, `join_room_ids` = the
    # whole join class, `invite_rooms` = [Core.SyncInviteRoom], `leave_rooms` = [Core.SyncRoom] (empty in an initial sync).
    rooms: [],
    join_room_ids: [],
    invite_rooms: [],
    leave_rooms: []
  ]
end

# Story sync-membership-partition — see proto/core.proto. Exactly the four properties of a spec stripped state event;
# `content` is a JSON string like the other proto-shaped structs.
defmodule Core.StrippedStateEvent do
  @moduledoc false
  defstruct [type: "", state_key: "", sender: "", content: ""]
end

defmodule Core.SyncInviteRoom do
  @moduledoc false
  defstruct [room_id: "", invite_state: []]
end

defmodule Core.SyncRoomStateEvent do
  @moduledoc false
  defstruct [
    type: "",
    state_key: "",
    content: "",
    sender: "",
    event_id: "",
    origin_server_ts: 0,
    # Bugfix unsigned-replaces-state (Matrix CS API v1.19) — see proto/core.proto.
    replaces_state: "",
    # Story member-event-prev-content (D10) — see proto/core.proto.
    prev_content: "",
    prev_sender: ""
  ]
end

defmodule Core.GetSyncDeltaRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    since_token: "",
    timeout_ms: 0,
    device_id: "",
    # Story sync-membership-partition (D14) — see proto/core.proto.
    full_state: false
  ]
end

defmodule Core.GetSyncDeltaResponse do
  @moduledoc false
  defstruct [
    since_token: "",
    rooms: [],
    fallback_to_initial: false,
    # Story sync-membership-partition — see proto/core.proto (same meaning as in GetInitialSyncResponse; the
    # invite / leave entries are the NEW ones since the token).
    join_room_ids: [],
    invite_rooms: [],
    leave_rooms: [],
    # Story sync-stream-position (D11) — see proto/core.proto: the join rooms the device had no joined cursor for (newly joined:
    # the HTTP layer delivers ALL their room account data; the join event may be outside a newest-20 timeline).
    newly_joined_room_ids: []
  ]
end

defmodule Core.SyncRoom do
  @moduledoc false
  defstruct [
    room_id: "",
    state_events: [],
    timeline_events: [],
    limited: false,
    prev_batch: "",
    heroes: [],
    joined_member_count: 0,
    invited_member_count: 0
  ]
end

defmodule Core.GetPresenceRequest do
  @moduledoc false
  defstruct [
    user_id: ""
  ]
end

defmodule Core.GetPresenceResponse do
  @moduledoc false
  defstruct [
    presence: "",
    last_active_ago: 0
  ]
end

defmodule Core.UpdateProfileRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    displayname: "",
    avatar_url: ""
  ]
end

defmodule Core.UpdateProfileResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.WriteAuditLogRequest do
  @moduledoc false
  defstruct [
    actor_user_id: "",
    action: "",
    target_type: "",
    target_id: "",
    metadata_json: "",
    outcome: "",
    error_detail: ""
  ]
end

defmodule Core.WriteAuditLogResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.DeleteUserKeysRequest do
  @moduledoc false
  defstruct [
    admin_user_id: "",
    target_user_id: "",
    reason: ""
  ]
end

defmodule Core.DeleteUserKeysResponse do
  @moduledoc false
  defstruct [
    status: "",
    keys_deleted_at: 0
  ]
end

defmodule Core.KickUserRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    caller_id: "",
    target_id: "",
    reason: ""
  ]
end

defmodule Core.KickUserResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.BanUserRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    caller_id: "",
    target_id: "",
    reason: ""
  ]
end

defmodule Core.BanUserResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.UnbanUserRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    caller_id: "",
    target_id: "",
    reason: ""
  ]
end

defmodule Core.UnbanUserResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.ForgetRoomRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    user_id: ""
  ]
end

defmodule Core.ForgetRoomResponse do
  @moduledoc false
  defstruct []
end

defmodule Core.ListPublicRoomsRequest do
  @moduledoc false
  defstruct [
    limit: 0,
    since: "",
    filter_term: ""
  ]
end

defmodule Core.RoomSummary do
  @moduledoc false
  defstruct [
    room_id: "",
    name: "",
    topic: "",
    num_joined_members: 0,
    world_readable: false,
    guest_can_join: false
  ]
end

defmodule Core.ListPublicRoomsResponse do
  @moduledoc false
  defstruct [
    rooms: [],
    next_cursor: "",
    total_estimate: 0
  ]
end

defmodule Core.GetEventContextRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    event_id: "",
    limit: 0
  ]
end

defmodule Core.ContextStateEvent do
  @moduledoc false
  defstruct [
    event_type: "",
    state_key: "",
    content: "",
    sender: ""
  ]
end

defmodule Core.GetEventContextResponse do
  @moduledoc false
  defstruct [
    event: nil,
    events_before: [],
    events_after: [],
    state: [],
    start_token: "",
    end_token: ""
  ]
end

defmodule Core.InvalidateUserSessionsRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    device_id: ""
  ]
end

defmodule Core.InvalidateUserSessionsResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.UpdateRoomSettingsRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    max_members: 0,
    is_auto_join: nil,
    visibility: ""
  ]
end

defmodule Core.UpdateRoomSettingsResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.ArchiveRoomRequest do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.ArchiveRoomResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.UnarchiveRoomRequest do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.UnarchiveRoomResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.InvalidateAllAdminSessionsRequest do
  @moduledoc false
  defstruct []
end

defmodule Core.InvalidateAllAdminSessionsResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.AdminUserProto do
  @moduledoc false
  defstruct [
    user_id: "",
    display_name: "",
    email_masked: "",
    is_active: false,
    system_role: "",
    created_at: 0
  ]
end

defmodule Core.ListAdminUsersRequest do
  @moduledoc false
  defstruct [
    limit: 0,
    cursor: "",
    search: ""
  ]
end

defmodule Core.ListAdminUsersResponse do
  @moduledoc false
  defstruct [
    users: [],
    total: 0,
    next_cursor: ""
  ]
end

defmodule Core.GetAdminUserRequest do
  @moduledoc false
  defstruct [
    user_id: ""
  ]
end

defmodule Core.GetAdminUserResponse do
  @moduledoc false
  defstruct [
    user: nil
  ]
end

defmodule Core.DeactivateUserRequest do
  @moduledoc false
  defstruct [
    user_id: ""
  ]
end

defmodule Core.DeactivateUserResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.ReactivateUserRequest do
  @moduledoc false
  defstruct [
    user_id: ""
  ]
end

defmodule Core.ReactivateUserResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.UpdateUserRoleRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    role: ""
  ]
end

defmodule Core.UpdateUserRoleResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.AdminRoomProto do
  @moduledoc false
  defstruct [
    room_id: "",
    name: "",
    status: "",
    member_count: 0,
    created_at: 0
  ]
end

defmodule Core.AdminRoomDetailProto do
  @moduledoc false
  defstruct [
    room_id: "",
    name: "",
    status: "",
    member_count: 0,
    max_members: 0,
    visibility: "",
    created_at: 0,
    is_auto_join: false
  ]
end

defmodule Core.ListAdminRoomsRequest do
  @moduledoc false
  defstruct [
    limit: 0,
    cursor: "",
    status_filter: "",
    search: ""
  ]
end

defmodule Core.ListAdminRoomsResponse do
  @moduledoc false
  defstruct [
    rooms: [],
    total: 0,
    next_cursor: ""
  ]
end

defmodule Core.GetAdminRoomRequest do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.GetAdminRoomResponse do
  @moduledoc false
  defstruct [
    room: nil
  ]
end

defmodule Core.ServerConfigProto do
  @moduledoc false
  defstruct [
    instance_name: "",
    oidc_issuer: "",
    oidc_client_id: "",
    room_default_max_members: 0,
    room_default_visibility: "",
    audit_log_retention_days: 0,
    oidc_directory_enabled: false,
    oidc_directory_endpoint: ""
  ]
end

defmodule Core.GetServerConfigRequest do
  @moduledoc false
  defstruct []
end

defmodule Core.GetServerConfigResponse do
  @moduledoc false
  defstruct [
    config: nil
  ]
end

defmodule Core.UpdateServerConfigRequest do
  @moduledoc false
  defstruct [
    instance_name: "",
    oidc_issuer: "",
    oidc_client_id: "",
    room_default_max_members: 0,
    room_default_visibility: "",
    audit_log_retention_days: 0,
    matrix_user_id_claim: "",
    oidc_directory_enabled: false,
    oidc_directory_endpoint: ""
  ]
end

defmodule Core.UpdateServerConfigResponse do
  @moduledoc false
  defstruct [
    ok: false
  ]
end

defmodule Core.UpgradeRoomRequest do
  @moduledoc false
  defstruct [
    old_room_id: "",
    requester_id: "",
    new_version: ""
  ]
end

defmodule Core.UpgradeRoomResponse do
  @moduledoc false
  defstruct [
    new_room_id: ""
  ]
end

defmodule Core.AdminRoomMemberProto do
  @moduledoc false
  defstruct [
    user_id: "",
    display_name: "",
    joined_at: 0
  ]
end

defmodule Core.ListAdminRoomMembersRequest do
  @moduledoc false
  defstruct [
    room_id: ""
  ]
end

defmodule Core.ListAdminRoomMembersResponse do
  @moduledoc false
  defstruct [
    members: []
  ]
end

defmodule Core.GetRelationsRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    room_id: "",
    event_id: "",
    rel_type: "",
    limit: 0,
    event_type: "",
    dir: "",
    recurse: false,
    from: ""
  ]
end

defmodule Core.GetRelationsResponse do
  @moduledoc false
  defstruct [
    events: [],
    next_batch: "",
    prev_batch: ""
  ]
end

defmodule Core.GetEventRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    event_id: "",
    user_id: ""
  ]
end

defmodule Core.GetEventResponse do
  @moduledoc false
  defstruct [
    event: nil
  ]
end

defmodule Core.ProfileInfo do
  @moduledoc false
  defstruct [
    displayname: "",
    avatar_url: ""
  ]
end

defmodule Core.SearchResult do
  @moduledoc false
  defstruct [
    rank: 0.0,
    event: "",
    events_before: [],
    events_after: [],
    profile_info: %{}
  ]
end

defmodule Core.SearchMessagesRequest do
  @moduledoc false
  defstruct [
    user_id: "",
    search_term: "",
    room_filter: [],
    sender_filter: [],
    limit: 0,
    next_batch: ""
  ]
end

defmodule Core.SearchMessagesResponse do
  @moduledoc false
  defstruct [
    results: [],
    next_batch: "",
    total_count: 0
  ]
end

defmodule Core.OIDCUserClaims do
  @moduledoc false
  defstruct [
    user_id: "",
    display_name: "",
    email: ""
  ]
end

defmodule Core.BulkImportUsersRequest do
  @moduledoc false
  defstruct [
    users: []
  ]
end

defmodule Core.BulkImportUsersResponse do
  @moduledoc false
  defstruct [
    imported: 0,
    skipped: 0,
    failed: 0
  ]
end

defmodule Core.SetRoomStateRequest do
  @moduledoc false
  defstruct [
    room_id: "",
    sender_id: "",
    event_type: "",
    state_key: "",
    content_json: ""
  ]
end

defmodule Core.SetRoomStateResponse do
  @moduledoc false
  defstruct [
    event_id: ""
  ]
end

defmodule Core.GetSpaceHierarchyRequest do
  @moduledoc false
  defstruct [
    root_room_id: "",
    user_id: "",
    limit: 0,
    max_depth: 0,
    suggested_only: false,
    from_token: ""
  ]
end

defmodule Core.GetSpaceHierarchyResponse do
  @moduledoc false
  defstruct [
    rooms: [],
    next_batch_token: ""
  ]
end

defmodule Core.HierarchyRoom do
  @moduledoc false
  defstruct [
    room_id: "",
    name: "",
    topic: "",
    canonical_alias: "",
    num_joined_members: 0,
    world_readable: false,
    guest_can_join: false,
    join_rule: "",
    room_type: "",
    avatar_url: "",
    children_state_json: ""
  ]
end
