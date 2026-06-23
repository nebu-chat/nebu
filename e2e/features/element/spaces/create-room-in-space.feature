Feature: Create a room inside a Space links it to the Space hierarchy
  As a Nebu user organising my work
  I want a room I create inside a Space to become a child of that Space
  So that the new room appears under the Space, not only in my personal room list

  # REGRESSION TARGET — confirmed user report:
  #   The Space OWNER creates a new room inside their own Space. The room lands in
  #   the personal/home area and never appears under the Space.
  #
  # ROOT CAUSE (captured from the real Element Web flow, see steps file):
  #   When Element creates a room inside a Space it sends, in ONE POST /createRoom,
  #   an `initial_state` array containing the child's `m.space.parent` edge (and a
  #   restricted `m.room.join_rules` referencing the parent Space). Nebu's
  #   POST /createRoom DROPS `initial_state` entirely — `Core.CreateRoomRequest`
  #   has no `initial_state` field and the handler reads only
  #   name / is_direct / creation_content / room_type. So the parent→child link the
  #   client supplied is silently discarded.
  #
  # These scenarios MUST be RED against current Nebu and turn GREEN only once
  # createRoom honours `initial_state`. The test issues ONLY the requests Element
  # itself issues — it never forges a compensating m.space.child / m.space.parent
  # state write, so the linkage being asserted is one the SERVER must produce.

  Background:
    Given the Nebu stack is running
    And alex is logged in via Element Web

  @bug-room-in-space @regression
  Scenario: createRoom honours the m.space.parent link Element sends in initial_state
    # Pure createRoom contract — the exact POST /createRoom body Element issues for an
    # in-space room (initial_state with m.space.parent). NO separate m.space.child PUT
    # is issued by the test, so nothing can mask the drop. RED until createRoom honours
    # initial_state and persists the child's m.space.parent edge.
    Given alex owns a Space named "e2e-space-host"
    When alex creates a room "e2e-room-in-space" inside the Space "e2e-space-host" exactly as Element does
    Then the room "e2e-room-in-space" carries an m.space.parent link to the Space "e2e-space-host"

  @bug-room-in-space @regression @ui
  Scenario: A room created inside a Space via Element Web is linked to the Space server-side
    # End-to-end through the REAL Element UI: owner selects the Space, uses the in-space
    # "Add -> New room" entry point (which sets parentSpace, so Element puts m.space.parent
    # in createRoom's initial_state). The test forges NO server state — it asserts the
    # server-side edge Element relied on. Element's UI happens to also show the room under
    # the Space via its separate m.space.child PUT, but the server still DROPS the
    # m.space.parent the client sent in initial_state. RED until createRoom honours
    # initial_state and persists that edge.
    Given alex creates a Space named "e2e-space-host-ui" via Element Web
    When alex creates a room "e2e-room-in-space-ui" inside that Space via Element Web
    Then the room "e2e-room-in-space-ui" carries an m.space.parent link to the Space "e2e-space-host-ui"
