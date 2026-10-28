Feature: Power levels: change them, enforce them per event type (story power-levels-enforcement)
  As a room administrator
  I want to promote and demote room members and to restrict who may change a state event
  So that the levels a room shows are the levels the server enforces, and nobody can grant more than he has

  # Story power-levels-enforcement (epic oauth-broker, follow-ups `eq`, `er`, `fr`): `PUT /rooms/{roomId}/state/m.room.power_levels` exists with the room
  # version 10 change rules, one room-process writer, and the per-type `events` map is enforced for message and state events. Before the story the route
  # answered 403, so Element's Roles & Permissions and the composer commands /op and /deop could not work.
  #
  # Scenario 1 (@power-levels-api) is the REGRESSION GUARD, no UI selectors: alex administers a public room through the Matrix API, with the full content of
  # his own `/sync` as the body (what Element's `setPowerLevel` sends). The users are alex, marie, tom and kai. One deliberate difference from the story's
  # wording: a new room carries the default `events` map (D12), which asks level 100 for `m.room.power_levels`, so marie at 50 could not change anything
  # and would be refused for her LEVEL before the change rules apply; alex therefore lets level 50 change the power levels in the same PUT that makes marie
  # a moderator ("... and lets level 50 change the power levels"). The refusal texts are the fixed texts of the story; the steps never print a token or
  # message content.
  # Scenario 2 (@power-levels-ui) types the composer slash commands /op and /deop in Element Web and asserts SERVER-side. Element 1.12.15 has both commands
  # (`/op <user-id> [<power-level>]`, default 50; `/deop <user-id>`), enabled when alex may send `m.room.power_levels` (the creator at 100, required 100
  # by D12); that the composer handles a slash command on Enter without an extra autocomplete / confirmation step is UNVERIFIED (the moderation feature's
  # @moderation-ui scenario uses the same steps, its first real run is the evidence). If the first real run fails for a UI reason (the server log shows no
  # PUT of m.room.power_levels, or a 200 one) the scenario moves to `@known-failure` with a row in e2e/KNOWN-FAILURES.md and Scenario 1 stays the guard; a
  # server answer other than 200 is a finding.

  Background:
    Given the Nebu stack is running

  @power-levels-api @regression
  Scenario: alex promotes marie, the v10 change rules and the per-type levels hold, kai sees the latest levels with prev_content
    Given alex has created the public power-levels room "power-levels-api" and "marie, tom, kai" have joined it
    When alex sets marie to level 50 in "power-levels-api" and lets level 50 change the power levels
    Then marie's attempt to set marie to level 100 in "power-levels-api" is refused with M_FORBIDDEN and the message "You cannot grant a power level above your own"
    And marie's attempt to set alex to level 0 in "power-levels-api" is refused with M_FORBIDDEN and the message "You cannot change the power level of a user whose level is not lower than yours"
    When marie kicks tom from the power-levels room "power-levels-api"
    And alex requires level 100 for m.room.topic in "power-levels-api"
    Then marie's change of the topic of "power-levels-api" is refused with M_FORBIDDEN and the message "You do not have a high enough power level to set this state"
    When alex sets marie to level 0 in "power-levels-api"
    Then marie's kick of kai from "power-levels-api" is refused with M_FORBIDDEN and the message "You do not have a high enough power level to kick from this room."
    And kai's sync shows the latest power levels of "power-levels-api" with the previous content in unsigned.prev_content

  @power-levels-ui @regression @ui
  Scenario: alex promotes and demotes marie with the composer commands /op and /deop in Element Web
    Given alex has created the public power-levels room "power-levels-ui" and "marie" have joined it
    And alex is logged in via Element Web
    When alex navigates to room "power-levels-ui"
    And alex types "/op @marie:localhost 50" in the composer
    And alex presses Enter
    Then marie's power level in "power-levels-ui" is 50 as set by alex
    When alex types "/deop @marie:localhost" in the composer
    And alex presses Enter
    Then marie has no power level entry in "power-levels-ui"
