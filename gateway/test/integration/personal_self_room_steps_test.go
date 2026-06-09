//go:build integration

package integration_test

// ─── Story personal-self-room: Personal Self-Room at First Login ──────────────
//
// Godog step definitions for gateway/features/personal_self_room.feature.
// Written FIRST (ATDD gate) — all scenario steps that test the self-room
// feature will fail until ensure_personal_room/1 is implemented in Core
// and migration 000002_personal_room_id is applied.
//
// State:
//   - aliceAccessToken / aliceUserID: alice's session token + Matrix ID
//   - aliceSyncBody:                  last GET /sync response body for alice
//   - aliceSelfRoomID:                room ID of alice's personal self-room (extracted from sync)
//   - lastLoginBody:                  raw body of the last POST /login response
//   - lastLoginStatus:                HTTP status of the last POST /login response
//
// Shared step definitions already registered in steps_test.go:
//   "the docker compose stack is started"  → theDockerComposeStackIsStarted
//   "the response status is (\d+)"         → theResponseStatusIs
//   "the response body has errcode "..."   → theResponseHasErrcodeIs
//
// New steps registered in initializePersonalSelfRoomSteps (bottom of this file).

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/cucumber/godog"
)

// ─── State ────────────────────────────────────────────────────────────────────

var aliceAccessToken string
var aliceUserID string
var aliceSyncBody string
var aliceSelfRoomID string
var lastLoginBody string
var lastLoginStatus int

// ─── Setup helpers ────────────────────────────────────────────────────────────

// aliceIsANewUserWhoHasNeverLoggedIn resets alice's state so each scenario
// treats her as a first-time user. The real Dex credentials (alice@example.com)
// are shared, but clearing aliceAccessToken forces a fresh /login call.
func aliceIsANewUserWhoHasNeverLoggedIn() error {
	// Reset alice's session state. personal_room_id in the DB is not reset here —
	// the integration test suite assumes a clean DB at startup (docker compose).
	aliceAccessToken = ""
	aliceUserID = ""
	aliceSyncBody = ""
	aliceSelfRoomID = ""
	return nil
}

// aliceIsAUserWhoHasLoggedInBefore ensures alice already has a self-room by
// completing one full login cycle first. Subsequent logins test idempotency.
func aliceIsAUserWhoHasLoggedInBefore() error {
	// Ensure alice has at least one previous login (self-room already created).
	if aliceAccessToken != "" {
		// Already authenticated — self-room was created on the first login.
		return nil
	}
	// First login to create the self-room.
	if err := authenticateUser("alice@example.com", "changeme", &aliceAccessToken, &aliceUserID); err != nil {
		return fmt.Errorf("alice first login (setup): %w", err)
	}
	// Clear the token so the scenario's "When alice logs in again" step forces a new session.
	aliceAccessToken = ""
	return nil
}

// aliceIsAuthenticatedViaOIDC is the idempotent auth step for scenarios that
// just need alice to be logged in (AC3, Oracle edge scenarios).
func aliceIsAuthenticatedViaOIDC() error {
	return authenticateUser("alice@example.com", "changeme", &aliceAccessToken, &aliceUserID)
}

// ─── Action steps ─────────────────────────────────────────────────────────────

// aliceLogsInViaOIDC performs the full Dex OIDC authorization code flow and
// then POST /_matrix/client/v3/login. Result stored in lastLoginBody / lastLoginStatus.
func aliceLogsInViaOIDC() error {
	if err := iObtainDexTokenFor("alice@example.com", "changeme"); err != nil {
		return fmt.Errorf("alice Dex token: %w", err)
	}
	if err := iPostLoginWithDexToken(); err != nil {
		return fmt.Errorf("alice Matrix login: %w", err)
	}
	lastLoginStatus = lastStatusCode
	lastLoginBody = lastBody

	// Parse and cache the access_token so subsequent sync calls work.
	if lastStatusCode == http.StatusOK {
		var loginResp struct {
			AccessToken string `json:"access_token"`
			UserID      string `json:"user_id"`
		}
		if err := json.Unmarshal([]byte(lastBody), &loginResp); err == nil {
			aliceAccessToken = loginResp.AccessToken
			aliceUserID = loginResp.UserID
		}
	}
	return nil
}

// aliceLogsInAgainViaOIDC is the "logs in again" step — clears the cached
// token first so a fresh session is established (tests idempotency).
func aliceLogsInAgainViaOIDC() error {
	aliceAccessToken = ""
	aliceSelfRoomID = ""
	return aliceLogsInViaOIDC()
}

// aliceCallsGetSyncTimeout0 calls GET /_matrix/client/v3/sync?timeout=0
// authenticated as alice. The full sync response body is stored in aliceSyncBody.
// Also writes to heroesSyncBody so direct_room_heroes scenarios share the same
// response without a duplicate step registration.
func aliceCallsGetSyncTimeout0() error {
	if aliceAccessToken == "" {
		return fmt.Errorf("alice has no access_token — call a login step first")
	}
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?timeout=0", matrixURL)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building GET /sync request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+aliceAccessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("GET /sync failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	aliceSyncBody = lastBody
	heroesSyncBody = lastBody // shared with direct_room_heroes scenarios
	return nil
}

// unauthenticatedClientCallsGetSync calls GET /sync without any Authorization header.
func unauthenticatedClientCallsGetSync() error {
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?timeout=0", matrixURL)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building unauthenticated GET /sync request: %w", err)
	}
	// Deliberately no Authorization header.
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("unauthenticated GET /sync failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	return nil
}

// ─── Login response assertions ────────────────────────────────────────────────

// theLoginResponseStatusIs asserts the HTTP status of the last POST /login.
func theLoginResponseStatusIs(expected int) error {
	if lastLoginStatus != expected {
		return fmt.Errorf("expected login status %d, got %d (body: %s)",
			expected, lastLoginStatus, lastLoginBody)
	}
	return nil
}

// theLoginResponseContainsAccessToken asserts access_token is present and non-empty.
func theLoginResponseContainsAccessToken() error {
	var resp struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal([]byte(lastLoginBody), &resp); err != nil {
		return fmt.Errorf("parsing login response: %w (body: %s)", err, lastLoginBody)
	}
	if resp.AccessToken == "" {
		return fmt.Errorf("access_token missing or empty in login response: %s", lastLoginBody)
	}
	return nil
}

// theLoginResponseContainsDeviceID asserts device_id is present.
func theLoginResponseContainsDeviceID() error {
	var resp struct {
		DeviceID string `json:"device_id"`
	}
	if err := json.Unmarshal([]byte(lastLoginBody), &resp); err != nil {
		return fmt.Errorf("parsing login response: %w", err)
	}
	if resp.DeviceID == "" {
		return fmt.Errorf("device_id missing or empty in login response: %s", lastLoginBody)
	}
	return nil
}

// theLoginResponseContainsUserID asserts user_id is present.
func theLoginResponseContainsUserID() error {
	var resp struct {
		UserID string `json:"user_id"`
	}
	if err := json.Unmarshal([]byte(lastLoginBody), &resp); err != nil {
		return fmt.Errorf("parsing login response: %w", err)
	}
	if resp.UserID == "" {
		return fmt.Errorf("user_id missing or empty in login response: %s", lastLoginBody)
	}
	return nil
}

// ─── Sync assertion helpers ───────────────────────────────────────────────────

// syncRoomEvent is a single state or timeline event in a sync room.
type syncRoomEvent struct {
	Type     string          `json:"type"`
	StateKey string          `json:"state_key"`
	Content  json.RawMessage `json:"content"`
	Sender   string          `json:"sender"`
}

// syncRoomsJoin parses aliceSyncBody and returns the rooms.join map.
// Timeline is included so assertions can find m.room.member events that were
// deduplicated out of State by the core (Matrix-spec-compliant deduplication).
type syncRoomState struct {
	State struct {
		Events []syncRoomEvent `json:"events"`
	} `json:"state"`
	Timeline struct {
		Events []syncRoomEvent `json:"events"`
	} `json:"timeline"`
}

// allEventsOfType returns all events of a given type from both State and Timeline,
// deduplicated by (type, state_key) — State wins when both contain the same key.
func allEventsOfType(room syncRoomState, eventType string) []syncRoomEvent {
	seen := map[string]bool{}
	var result []syncRoomEvent
	for _, ev := range room.State.Events {
		if ev.Type == eventType {
			seen[ev.StateKey] = true
			result = append(result, ev)
		}
	}
	for _, ev := range room.Timeline.Events {
		if ev.Type == eventType && !seen[ev.StateKey] {
			seen[ev.StateKey] = true
			result = append(result, ev)
		}
	}
	return result
}

func parseSyncJoinRooms(body string) (map[string]syncRoomState, error) {
	var sync struct {
		Rooms struct {
			Join map[string]syncRoomState `json:"join"`
		} `json:"rooms"`
	}
	if err := json.Unmarshal([]byte(body), &sync); err != nil {
		return nil, fmt.Errorf("parsing sync response: %w (body: %s)", err, body)
	}
	return sync.Rooms.Join, nil
}

// theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice finds a room in rooms.join
// whose state contains m.room.name with content.name equal to alice's localpart.
// Stores the room ID in aliceSelfRoomID for subsequent assertions.
//
// THIS STEP WILL FAIL until ensure_personal_room/1 creates the self-room.
func theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice() error {
	joinRooms, err := parseSyncJoinRooms(aliceSyncBody)
	if err != nil {
		return err
	}
	aliceLocalpart := extractLocalpart(aliceUserID)
	var selfRooms []string
	for roomID, room := range joinRooms {
		for _, ev := range room.State.Events {
			if ev.Type == "m.room.name" && ev.StateKey == "" {
				var nameContent struct {
					Name string `json:"name"`
				}
				if jsonErr := json.Unmarshal(ev.Content, &nameContent); jsonErr == nil {
					if nameContent.Name == aliceLocalpart {
						selfRooms = append(selfRooms, roomID)
					}
				}
			}
		}
	}
	if len(selfRooms) == 0 {
		return fmt.Errorf("no self-room with m.room.name content.name=%q found in rooms.join "+
			"(localpart=%q, rooms.join keys: %v) — ensure_personal_room not yet implemented",
			aliceLocalpart, aliceLocalpart, roomIDKeys(joinRooms))
	}
	if len(selfRooms) > 1 {
		return fmt.Errorf("expected exactly one self-room, found %d: %v", len(selfRooms), selfRooms)
	}
	aliceSelfRoomID = selfRooms[0]
	return nil
}

// aliceSRoomsJoinContainsExactlyOneSelfRoomNoDuplicates asserts no duplicate self-rooms.
func aliceRoomsJoinContainsExactlyOneSelfRoomNoDuplicates() error {
	return theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice()
}

// theAliceSelfRoomStateContainsMRoomNameEvent asserts m.room.name is in the self-room state.
func theAliceSelfRoomStateContainsMRoomNameEventWithName(expectedName string) error {
	if aliceSelfRoomID == "" {
		// Try to resolve it first.
		if err := theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice(); err != nil {
			return fmt.Errorf("cannot assert m.room.name: self-room not found: %w", err)
		}
	}
	joinRooms, err := parseSyncJoinRooms(aliceSyncBody)
	if err != nil {
		return err
	}
	room, ok := joinRooms[aliceSelfRoomID]
	if !ok {
		return fmt.Errorf("self-room %q not found in rooms.join", aliceSelfRoomID)
	}
	for _, ev := range room.State.Events {
		if ev.Type == "m.room.name" && ev.StateKey == "" {
			var content struct {
				Name string `json:"name"`
			}
			if err := json.Unmarshal(ev.Content, &content); err != nil {
				return fmt.Errorf("parsing m.room.name content: %w", err)
			}
			if content.Name != expectedName {
				return fmt.Errorf("m.room.name content.name: expected %q, got %q", expectedName, content.Name)
			}
			return nil
		}
	}
	return fmt.Errorf("m.room.name event not found in self-room %q state events", aliceSelfRoomID)
}

// theAliceSelfRoomStateContainsMRoomMemberEventWithMembershipForAlice asserts
// m.room.member with the given membership value and state_key = aliceUserID.
func theAliceSelfRoomStateContainsMRoomMemberEventWithMembershipForAlice(membership string) error {
	if aliceSelfRoomID == "" {
		if err := theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice(); err != nil {
			return fmt.Errorf("cannot assert m.room.member: self-room not found: %w", err)
		}
	}
	joinRooms, err := parseSyncJoinRooms(aliceSyncBody)
	if err != nil {
		return err
	}
	room, ok := joinRooms[aliceSelfRoomID]
	if !ok {
		return fmt.Errorf("self-room %q not found in rooms.join", aliceSelfRoomID)
	}
	// Check both State and Timeline — the core deduplicates member events out of
	// State when they appear in the Timeline (Matrix-spec-compliant deduplication).
	for _, ev := range allEventsOfType(room, "m.room.member") {
		if ev.StateKey == aliceUserID {
			var content struct {
				Membership string `json:"membership"`
			}
			if err := json.Unmarshal(ev.Content, &content); err != nil {
				return fmt.Errorf("parsing m.room.member content: %w", err)
			}
			if content.Membership != membership {
				return fmt.Errorf("m.room.member membership: expected %q, got %q (state_key=%q)",
					membership, content.Membership, aliceUserID)
			}
			return nil
		}
	}
	return fmt.Errorf("m.room.member event with state_key=%q not found in self-room %q state events",
		aliceUserID, aliceSelfRoomID)
}

// theAliceSelfRoomSyncResponseStatusIs asserts the last GET /sync status.
func theSyncResponseStatusIs(expected int) error {
	if lastStatusCode != expected {
		return fmt.Errorf("expected sync status %d, got %d (body: %.200s)",
			expected, lastStatusCode, aliceSyncBody)
	}
	return nil
}

// theAliceSelfRoomMRoomNameEventHasStateKey asserts state_key on the m.room.name event.
func theAliceSelfRoomMRoomNameEventHasStateKey(expectedStateKey string) error {
	if aliceSelfRoomID == "" {
		if err := theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice(); err != nil {
			return fmt.Errorf("cannot assert state_key: self-room not found: %w", err)
		}
	}
	joinRooms, err := parseSyncJoinRooms(aliceSyncBody)
	if err != nil {
		return err
	}
	room, ok := joinRooms[aliceSelfRoomID]
	if !ok {
		return fmt.Errorf("self-room %q not found in rooms.join", aliceSelfRoomID)
	}
	for _, ev := range room.State.Events {
		if ev.Type == "m.room.name" {
			if ev.StateKey != expectedStateKey {
				return fmt.Errorf("m.room.name state_key: expected %q, got %q (spec requires empty string)",
					expectedStateKey, ev.StateKey)
			}
			return nil
		}
	}
	return fmt.Errorf("m.room.name event not found in self-room %q state", aliceSelfRoomID)
}

// theAliceSelfRoomMRoomNameEventHasContentName asserts content.name value.
func theAliceSelfRoomMRoomNameEventHasContentName(expectedName string) error {
	return theAliceSelfRoomStateContainsMRoomNameEventWithName(expectedName)
}

// ─── Utility ──────────────────────────────────────────────────────────────────

// extractLocalpart extracts the localpart from a Matrix user ID.
// "@alice:nebu.local" → "alice"
func extractLocalpart(userID string) string {
	// Strip leading "@"
	s := strings.TrimPrefix(userID, "@")
	// Take everything before ":"
	if idx := strings.Index(s, ":"); idx >= 0 {
		return s[:idx]
	}
	return s
}

// roomIDKeys returns the keys of a rooms.join map for diagnostic output.
func roomIDKeys(m map[string]syncRoomState) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

// ─── Step registration ────────────────────────────────────────────────────────

// initializePersonalSelfRoomSteps registers all step definitions for
// gateway/features/personal_self_room.feature.
// Called from InitializeScenario in steps_test.go.
func initializePersonalSelfRoomSteps(sc *godog.ScenarioContext) {
	// Setup / Given
	sc.Step(`^alice is a new user who has never logged in$`, aliceIsANewUserWhoHasNeverLoggedIn)
	sc.Step(`^alice is a user who has logged in before \(self-room already exists\)$`, aliceIsAUserWhoHasLoggedInBefore)
	sc.Step(`^alice is authenticated via OIDC$`, aliceIsAuthenticatedViaOIDC)

	// Actions / When
	sc.Step(`^alice logs in via OIDC$`, aliceLogsInViaOIDC)
	sc.Step(`^alice logs in again via OIDC$`, aliceLogsInAgainViaOIDC)
	sc.Step(`^alice calls GET /sync with timeout 0$`, aliceCallsGetSyncTimeout0)
	sc.Step(`^an unauthenticated client calls GET /sync$`, unauthenticatedClientCallsGetSync)

	// Login response assertions / Then
	sc.Step(`^the login response status is (\d+)$`, theLoginResponseStatusIs)
	sc.Step(`^the login response contains an access_token$`, theLoginResponseContainsAccessToken)
	sc.Step(`^the login response contains a device_id$`, theLoginResponseContainsDeviceID)
	sc.Step(`^the login response contains a user_id$`, theLoginResponseContainsUserID)

	// Sync response status
	sc.Step(`^the sync response status is (\d+)$`, theSyncResponseStatusIs)

	// Self-room sync assertions / Then
	sc.Step(`^the sync rooms\.join contains exactly one self-room for alice$`, theSyncRoomsJoinContainsExactlyOneSelfRoomForAlice)
	sc.Step(`^alice's self-room state contains an m\.room\.name event with name "([^"]*)"$`, theAliceSelfRoomStateContainsMRoomNameEventWithName)
	sc.Step(`^alice's self-room state contains an m\.room\.member event with membership "([^"]*)" for alice$`, theAliceSelfRoomStateContainsMRoomMemberEventWithMembershipForAlice)
	sc.Step(`^alice's rooms\.join contains exactly one self-room \(no duplicates\)$`, aliceRoomsJoinContainsExactlyOneSelfRoomNoDuplicates)
	sc.Step(`^alice's self-room m\.room\.name event has state_key "([^"]*)"$`, theAliceSelfRoomMRoomNameEventHasStateKey)
	sc.Step(`^alice's self-room m\.room\.name event has content\.name "([^"]*)"$`, theAliceSelfRoomMRoomNameEventHasContentName)
}
