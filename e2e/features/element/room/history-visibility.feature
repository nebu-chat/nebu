Feature: History visibility: members who are invited or join later do not see the earlier history (story history-visibility-enforcement)
  As a member of a room whose history visibility is "Members only (since they were invited)" or "Members only (since they joined)"
  I want users who are invited or join later NOT to see the messages sent before their invitation / join
  So that the room setting does what it says, in the timeline, in search, through a permalink and in a fresh login

  # Story history-visibility-enforcement (epic oauth-broker, follow-up `es`): ONE SQL rule decides which events a member may read on every event read path
  # (`/messages`, the initial and incremental `/sync`, `/event`, `/relations`, `/search`, `/initialSync`, the unsigned predecessor keys). Before the story every member of
  # a room read the whole history, whatever "Who can read history?" said.
  #
  # Scenario 1 (@history-visibility-api) is the REGRESSION GUARD, no UI selectors: alex creates three `private_chat` rooms through the API and sets
  # `m.room.history_visibility` to `joined` ("hv-joined"), `invited` ("hv-invited") and `shared` ("hv-shared") with `PUT /state`; in each alex sends
  # "before-invite-<marker>", invites the later user (marie into hv-joined, tom into hv-invited, kai into hv-shared), sends "while-invited-<marker>", the user joins, and alex
  # sends "after-join-<marker>" (the markers are random per run; the steps never print a token or a message body). The users are alex, marie, tom and kai. Asserted through
  # the Matrix API: marie's `/messages?dir=b&limit=50` on hv-joined holds the after-join message and her join, not the other two; tom's on hv-invited the while-invited and
  # the after-join message; kai's on hv-shared all three; marie's `GET /event/{before-invite}` is a 404; marie's `POST /search` for the before-invite marker finds nothing
  # and alex's finds one result; marie's INITIAL `/sync` timeline of hv-joined holds neither the before-invite nor the while-invited event id.
  # Scenario 2 (@history-visibility-ui) is the Element path: marie logs in via Element Web in a context of her own (a fresh login), opens "hv-joined-ui" and scrolls up until
  # Element stops paginating (bounded to 10 s): the timeline shows the after-join text and NOT the before-invite / while-invited texts; kai (own context) opens "hv-shared-ui"
  # and sees all three texts (the positive control: Element paginates there). Asserted additionally (non-blocking, zero calls tolerated) from the browser's own network log: every `GET .../messages?...dir=b`
  # answer Element got was a 200. UNVERIFIED against Element Web 1.12.15: its rendering at the start of a `joined` history (a "You can't see earlier messages" style notice is NOT
  # asserted) and the timeline scroll selectors. If the first real run fails for a UI reason (Scenario 1 green, the `/messages` answer was 200) the scenario moves to
  # `@known-failure` with a new row in e2e/KNOWN-FAILURES.md: K14 (cause: Element timeline pagination / selectors unverified; K13 is the membership-state UI row, K12 is named by
  # the redaction feature, K11 is reserved by the moderation plan, K8 and K10 are retired paragraphs) and Scenario 1 stays the guard; a `/messages` answer other than 200
  # for a member, or an invisible marker in any response, is a finding.

  Background:
    Given the Nebu stack is running

  @history-visibility-api @regression
  Scenario: a joined, an invited and a shared room give the later user exactly what the setting says: /messages, /event, search and the initial /sync
    Given alex has created the history visibility room "hv-joined" with the setting "joined"
    And alex has created the history visibility room "hv-invited" with the setting "invited"
    And alex has created the history visibility room "hv-shared" with the setting "shared"
    And alex has played the history of "hv-joined" with marie as the later user
    And alex has played the history of "hv-invited" with tom as the later user
    And alex has played the history of "hv-shared" with kai as the later user
    Then marie's backward messages of "hv-joined" hold the after-join message and her join but neither the before-invite nor the while-invited message
    And tom's backward messages of "hv-invited" hold the while-invited and the after-join message but not the before-invite message
    And kai's backward messages of "hv-shared" hold all three messages
    And marie's GET of the before-invite event of "hv-joined" is a 404
    And marie's search for the before-invite marker of "hv-joined" finds nothing
    And alex's search for the before-invite marker of "hv-joined" finds one result
    And marie's initial sync timeline of "hv-joined" holds neither the before-invite nor the while-invited event

  @history-visibility-ui @regression @ui
  Scenario: marie sees only the after-join text at the top of the joined room in Element Web, kai sees all three texts in the shared room
    Given alex has created the history visibility room "hv-joined-ui" with the setting "joined"
    And alex has created the history visibility room "hv-shared-ui" with the setting "shared"
    And alex has played the history of "hv-joined-ui" with marie as the later user
    And alex has played the history of "hv-shared-ui" with kai as the later user
    And marie is logged in via Element Web in a history visibility context of her own with her requests recorded
    When marie opens the history visibility room "hv-joined-ui" in Element Web and scrolls to the top
    Then marie's timeline of "hv-joined-ui" shows the after-join text and neither the before-invite nor the while-invited text
    And every messages answer marie's Element got for "hv-joined-ui" was a 200
    Given kai is logged in via Element Web in a history visibility context of his own
    When kai opens the history visibility room "hv-shared-ui" in Element Web and scrolls to the top
    Then kai's timeline of "hv-shared-ui" shows all three texts
