Feature: Membership state: invited and banned users after a reload, GET /members and the room upgrade (story membership-state-model)
  As a room member using Element
  I want the member list to show who is invited and the room settings to show who is banned (with the reason)
  So that this survives a reload, a new login and "Clear cache and reload", and an upgraded room invites its members for real

  # Story membership-state-model (epic oauth-broker, follow-ups `fb`, `fl` (c)): the initial `/sync` state lists the latest member event of EVERY user (join, invite,
  # ban, leave, from the member events in the database, real event ids, `unsigned`), `GET /rooms/{roomId}/members` honours `membership` / `not_membership` (Element
  # always asks `?not_membership=leave&at=<its /sync token>`), is visible to joined members only and answers 403 to everybody else, and `POST /upgrade` writes REAL
  # invite events in the upgrader's name. Before the story an invite / ban event was visible only while it was inside the last 20 timeline events, so the "Invited"
  # section and the "Banned users" list were empty after a reload.
  #
  # Scenario 1 (@membership-state-api) is the REGRESSION GUARD, no UI selectors: alex creates a `public_chat` room through the API; marie and tom join; alex invites kai,
  # bans tom with the reason "e2e ban" and sends 25 messages (every member event is then OUTSIDE the 20-event window of an initial sync); everything is set up and
  # asserted through the Matrix API. The users are alex, marie, tom and kai. The steps never print a token, a reason or a message body.
  # Scenario 2 (@membership-state-ui) is the Element path: marie logs in via Element Web in a context of her own (a fresh login: an initial sync), opens the room, the
  # room info "People" panel (an "Invited" section lists kai) and Room settings > "Roles & Permissions" (the "Banned users" list shows tom with "Reason: e2e ban").
  # Asserted additionally from the browser's own network log: Element asked `GET .../members?not_membership=leave&at=...` and got 200. VERIFIED in the Element Web 1.12.15
  # bundle (story, C9): `lazyLoadMembers` is always on, the member list loads `/members?not_membership=leave&at=<sync token>` once per room, the list shows the joined
  # members, then the invited ones under "Invited"; "Banned users" reads `room.getMembersWithMembership("ban")` with "Reason". UNVERIFIED: the selectors of the room info /
  # People panel and of the settings dialog tab (the accessible names of the header button, the "People" entry, the "Roles & Permissions" tab). If the first real run fails
  # for a UI reason (the browser log shows the `/members` 200 and Scenario 1 is green) the scenario moves to `@known-failure` with a new row in e2e/KNOWN-FAILURES.md (K13,
  # cause: Element room-info / settings selectors unverified) and Scenario 1 stays the guard; a `/members` answer other than 200 is a finding. (K8 and K10 are retired
  # paragraphs of that file, K11 is reserved by the moderation plan, K12 by the redaction feature.)

  Background:
    Given the Nebu stack is running

  @membership-state-api @regression
  Scenario: an initial sync and GET /members list the invited and the banned user, non-members get 403, and an upgrade invites for real
    Given alex has created the public membership room "membership-state-api" and "marie, tom" have joined it
    And alex has invited kai to the membership room "membership-state-api"
    And alex has banned tom from the membership room "membership-state-api" with the reason "e2e ban"
    And alex has sent 25 messages in the membership room "membership-state-api"
    Then marie's initial sync of "membership-state-api" lists kai as invite by alex and tom as ban by alex with the reason "e2e ban", both with real event ids
    And marie's members of "membership-state-api" with not_membership leave at her sync token are alex join, marie join, kai invite and tom ban
    And marie's members of "membership-state-api" with membership ban are tom only
    And tom's members request for "membership-state-api" is refused with M_FORBIDDEN
    And kai's members request for "membership-state-api" is refused with M_FORBIDDEN
    When alex upgrades the membership room "membership-state-api"
    Then marie's next sync lists the new room of "membership-state-api" in rooms.invite with the invite event by alex in its invite_state
    And alex's members of the new room of "membership-state-api" with membership invite are marie only

  @membership-state-ui @regression @ui @known-failure
  Scenario: marie sees kai under "Invited" and tom under "Banned users" with the reason in Element Web after a fresh login
    Given alex has created the public membership room "membership-state-ui" and "marie, tom" have joined it
    And alex has invited kai to the membership room "membership-state-ui"
    And alex has banned tom from the membership room "membership-state-ui" with the reason "e2e ban"
    And alex has sent 25 messages in the membership room "membership-state-ui"
    And marie is logged in via Element Web in a context of her own with her requests recorded
    When marie opens the membership room "membership-state-ui" in Element Web
    And marie opens the People panel of the room
    Then the People panel lists kai under "Invited"
    When marie opens the room settings tab "Roles & Permissions"
    Then the "Banned users" list shows tom with the reason "e2e ban"
    And marie's Element requested the members of "membership-state-ui" with not_membership leave and got 200
