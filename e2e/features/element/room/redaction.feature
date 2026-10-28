Feature: Redaction: "Remove" a message, the redact level and the pruned read paths (story state-writer-redaction)
  As a room member using Element
  I want "Remove" to work for my own messages and, as a moderator, for other users' messages
  So that nobody below the room's redact level can hide other users' messages and a removed message disappears for everybody

  # Story state-writer-redaction (epic oauth-broker, follow-ups `fw`, `fv`, `fz`, `fx`): `PUT /rooms/{roomId}/redact/{eventId}/{txnId}` exists and
  # `m.room.redaction` on `/send` goes through the same room-process writer; a redacted event is served with `content: {}` and `unsigned.redacted_because`
  # on every client read path while the stored content stays in the database (Compliance Mode). Before the story Element's "Remove" failed (no route)
  # and an `m.room.redaction` sent through `/send` was stored as sent and delivered to every member, whatever the sender's level.
  #
  # Scenario 1 (@redaction-api) is the REGRESSION GUARD, no UI selectors: alex creates a public room through the API, marie, tom and kai join, everything is
  # set up and asserted through the Matrix API. The users are alex, marie, tom and kai. The steps never print a token, a reason or a message body; the
  # messages carry a unique marker word (the search step looks for it).
  # Scenario 2 (@redaction-ui) is the Element path: tom is logged in via Element Web in a context of his own (the shared `page` fixture is alex's), opens the room,
  # hovers his own message M3, opens its options ("Options"), clicks "Remove" and confirms with the dialog's "Remove" button; asserted SERVER-side. VERIFIED in
  # the Element 1.12.15 bundle: "Remove" (`action|remove`) is offered when `maySendRedactionForEvent` holds (an own message at events_default), the confirm
  # dialog's button is "Remove" with an optional reason field, the request is `PUT /rooms/{roomId}/redact/{eventId}/{txnId}` with `{}` or `{"reason"}`.
  # UNVERIFIED: the tile hover / "Options" button selectors of Element 1.12.15 and the dialog's accessible names. If the first real run fails for a UI reason
  # (the server log shows no `PUT .../redact/`) the scenario moves to `@known-failure` with a new row in e2e/KNOWN-FAILURES.md (K12, cause: Element message-options
  # selectors unverified) and Scenario 1 stays the guard; a server answer other than 200 is a finding.

  Background:
    Given the Nebu stack is running

  @redaction-api @regression
  Scenario: marie removes her own message, cannot remove tom's, alex can; the pruned message is served everywhere and a topic event cannot be redacted
    Given alex has created the public redaction room "redaction-api" and "marie, tom, kai" have joined it
    And marie has sent a message in the redaction room "redaction-api" remembered as "M1"
    And tom has sent a message in the redaction room "redaction-api" remembered as "M2"
    And kai's search for the marker word of "M2" finds the message "M2"
    When marie redacts "M1" in the redaction room "redaction-api" with the reason "e2e remove"
    Then kai's sync of "redaction-api" shows "M1" with empty content and unsigned.redacted_because and the redaction with a top-level redacts
    And marie's attempt to redact "M2" in "redaction-api" is refused with M_FORBIDDEN and the message "You do not have a high enough power level to redact other users' events"
    And marie's send of an m.room.redaction for "M2" in "redaction-api" is refused with M_FORBIDDEN and the message "You do not have a high enough power level to redact other users' events"
    And kai's GET of "M2" in "redaction-api" still has its content
    When alex redacts "M2" in the redaction room "redaction-api" with the reason "e2e moderation"
    Then kai's GET of "M2" in "redaction-api" has empty content and unsigned.redacted_because by alex
    And kai's search for the marker word of "M2" finds nothing
    And alex's attempt to redact the topic event of "redaction-api" is refused with M_FORBIDDEN and the message "This event cannot be redacted on this server"

  @redaction-ui @regression @ui
  Scenario: tom removes his own message with the message options in Element Web
    Given alex has created the public redaction room "redaction-ui" and "tom, kai" have joined it
    And tom has sent a message in the redaction room "redaction-ui" remembered as "M3"
    And tom is logged in via Element Web in a context of his own
    When tom opens the redaction room "redaction-ui" in Element Web
    And tom removes his message "M3" with the message options and confirms
    Then kai's GET of "M3" in "redaction-ui" has empty content and unsigned.redacted_because by tom
