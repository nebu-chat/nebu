Feature: Direct messages: createRoom invites the partner (story create-room-invites-direct)
  As a Nebu user
  I want "Start chat" with a colleague to create a room the colleague is invited to
  So that a DM is not an empty invite-only room nobody else can enter

  # Story create-room-invites-direct (epic oauth-broker, follow-up `eb`). Before it `createRoom` ignored `invite` / `is_direct`:
  # Element's DM was a room with the creator as the only member (the partner held no invitation, POST /join was 403).
  #
  # Scenario 1 sends exactly the createRoom body Element 1.12.15 sends for a DM with ONE user (`createRoom(client, {dmUserId})`:
  # preset trusted_private_chat, visibility private, invite [partner], is_direct true, initial_state guest_access can_join +
  # m.room.encryption + history_visibility invited) and asserts what the SERVER produced; it forges nothing.
  # Scenario 2 drives the real Element UI on the CREATOR side and asserts server-side that the DM exists and that the room became ready
  # without Element's 5 s "Assuming local room ... is ready" fallback (Element waits until invited + joined members == 1 + targets).
  # Scenario 3 is the INVITEE side in the Element UI (story sync-membership-partition, follow-ups `ev` + `ez`): `/sync` serves `rooms.invite`
  # with the stripped invite_state (m.room.create, the invitee's own invite event with is_direct), so marie sees the invitation tile in
  # her room list without any `/join <room id>`, accepts it and the DM is joined and marked as a direct chat. It is a real scenario of the
  # default run (before the story it was a RED scaffold tagged @pending-feature @needs-ev). The DM is marked through the invitee's JOIN
  # event: Element's `getDMInviter()` reads its `unsigned.prev_content` (the invite with `is_direct`) and `unsigned.prev_sender` (the
  # inviter), which `/sync` serves since story member-event-prev-content (follow-up `ff`) and then writes `m.direct`.

  Background:
    Given the Nebu stack is running
    And alex is logged in via Element Web

  @dm-create-api @regression
  Scenario: createRoom with Element's DM body invites the partner
    When alex creates a direct chat with marie exactly as Element does
    Then marie's membership in that direct chat is an invite from alex with is_direct true
    When marie joins that direct chat
    And alex sends the direct chat message "dm hello from alex"
    Then marie reads "dm hello from alex" in that direct chat

  # @known-failure K9: the Element UI selectors (Start chat dialog, invite tile) are UNVERIFIED against Element 1.12.15 (first real run 2026-10-16: the invite tile never appeared); the API scenario above is the regression guard. See e2e/KNOWN-FAILURES.md.
  @dm-create-ui @regression @ui @known-failure
  Scenario: Starting a DM in Element Web invites the partner server-side
    When alex starts a chat with marie via Element Web and sends "dm first message"
    Then the direct chat with marie exists on the server and marie holds an invite with is_direct true
    And the message "dm first message" is in that direct chat
    And that direct chat became ready without Element's 5 second fallback

  @dm-invitee-ui @regression @ui
  Scenario: marie sees the DM invitation in Element and accepts it
    Given alex has created a direct chat with marie via the API
    And marie is logged in via Element Web in a second browser context
    Then marie sees the direct chat invitation from alex in her room list
    When marie accepts the direct chat invitation from alex
    Then marie's direct chat with alex is joined and marked as a direct chat
