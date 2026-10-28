Feature: Room moderation: kick, ban and unban (story moderation-routes-atomic-ban)
  As a room moderator
  I want to kick, ban and unban users and to withdraw an invitation ("Disinvite")
  So that a removed user cannot come back until he is unbanned, whatever the client races

  # Story moderation-routes-atomic-ban (epic oauth-broker, follow-ups `ex`, `ew`): `POST /rooms/{roomId}/kick`, `/ban` and `/unban` exist and
  # are backed by ONE atomic room-process writer. Before the story they answered 404 M_UNRECOGNIZED, so Element's "Remove from room", "Ban",
  # "Unban" and "Disinvite" and the composer commands /remove, /ban and /unban could not work.
  #
  # Scenario 1 (@moderation-api) is the REGRESSION GUARD, no UI selectors: alex moderates marie in a public room and withdraws an invitation of
  # kai in an invite-only room, everything asserted through the Matrix API. (The story names the invitee of the Disinvite "bob"; the e2e users
  # are alex, marie, tom and kai, and kai is the one that is warmed by the global setup.) The reasons are plain texts of this feature, the steps
  # never print them and never log a token or message content.
  # Scenario 2 (@moderation-ui) types the composer slash commands /ban and /unban in Element Web and asserts SERVER-side. Element's slash-command
  # handling (autocomplete on Enter, a possible confirmation dialog) is UNVERIFIED against Element 1.12.15 and the scenario avoids the member
  # panel selectors on purpose: if the first real run fails for a UI reason (the server log shows a 200 /ban request) the scenario moves to
  # `@known-failure` with a row in e2e/KNOWN-FAILURES.md and Scenario 1 stays the guard; a server answer other than 200 is a finding.

  Background:
    Given the Nebu stack is running

  @moderation-api @regression
  Scenario: alex bans, unbans and kicks marie and withdraws an invitation of kai through the Matrix API
    Given alex has created the public moderation room "moderation-api-public" and marie has joined it
    And marie's sync position is recorded
    When alex bans marie from "moderation-api-public" with the reason "e2e ban"
    Then marie's join of "moderation-api-public" is refused with M_FORBIDDEN and the message "You are banned from this room"
    And marie's next sync lists "moderation-api-public" in rooms.leave ending with the ban event by alex with the reason "e2e ban"
    When alex unbans marie from "moderation-api-public"
    And marie joins the moderation room "moderation-api-public"
    And alex kicks marie from "moderation-api-public" with the reason "e2e kick"
    Then marie's latest membership in "moderation-api-public" is leave by alex
    Given alex has created the invite-only moderation room "moderation-api-invite" and invited kai
    Then kai's sync lists the invitation to "moderation-api-invite"
    When alex kicks kai from "moderation-api-invite" with the reason "e2e disinvite"
    Then kai's sync no longer lists an invitation to "moderation-api-invite"
    And kai's join of "moderation-api-invite" is refused with M_FORBIDDEN and the message "You are not invited to this room"

  @moderation-ui @regression @ui
  Scenario: alex bans and unbans marie with the composer commands in Element Web
    Given alex has created the public moderation room "moderation-ui-public" and marie has joined it
    And alex is logged in via Element Web
    When alex navigates to room "moderation-ui-public"
    And alex types "/ban @marie:localhost e2e ui ban" in the composer
    And alex presses Enter
    Then marie's latest membership in "moderation-ui-public" is ban by alex with the reason "e2e ui ban"
    When alex types "/unban @marie:localhost" in the composer
    And alex presses Enter
    Then marie's latest membership in "moderation-ui-public" is leave by alex
