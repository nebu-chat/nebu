//go:build integration

package integration_test

// ─── Story admin-auto-join-rooms: New User Auto-Membership ───────────────────
//
// Godog step definitions for gateway/features/auto_join_rooms.feature.
// Written to complete ATDD wiring — the feature is already implemented.
//
// State:
//   - charlieAutoJoinAccessToken / charlieAutoJoinUserID — charlie's session for auto-join tests
//   - aliceAutoJoinAccessToken / aliceAutoJoinUserID     — alice's session for auto-join tests
//   - autoJoinRoomID                                     — DB room ID for the auto-join room under test
//   - charlieAutoJoinSyncBody                            — charlie's last GET /sync response
//
// Shared step definitions reused from other step files (same package):
//   "the docker compose stack is started"      → theDockerComposeStackIsStarted (steps_test.go)
//   "the response status is (\d+)"             → theResponseStatusIs (steps_test.go)
//   "the response body has errcode ..."        → theResponseHasErrcodeIs (steps_test.go)
//   "an unauthenticated client calls GET /sync"→ unauthenticatedClientCallsGetSync (personal_self_room_steps_test.go)
//   "the login response status is (\d+)"       → theLoginResponseStatusIs (personal_self_room_steps_test.go)
//   "the login response contains an access_token" → theLoginResponseContainsAccessToken
//   "the login response contains a device_id"  → theLoginResponseContainsDeviceID
//   "the login response contains a user_id"    → theLoginResponseContainsUserID
//   "the sync response status is (\d+)"        → theSyncResponseStatusIs
//   "alice calls GET /sync with timeout 0"     → aliceCallsGetSyncTimeout0 (personal_self_room_steps_test.go)
//
// New steps registered in initializeAutoJoinRoomsSteps (bottom of this file).

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/cucumber/godog"
)

// ─── State ────────────────────────────────────────────────────────────────────

var charlieAutoJoinAccessToken string
var charlieAutoJoinUserID string
var aliceAutoJoinAccessToken string
var aliceAutoJoinUserID string
var autoJoinRoomID string
var charlieAutoJoinSyncBody string

// ─── DB setup helpers ─────────────────────────────────────────────────────────

// roomExistsWithIsAutoJoinTrue ensures the named room exists with is_auto_join=true
// and is registered in the Elixir core's Room GenServer registry. It creates the
// room through the Matrix API (POST /createRoom) so the core knows about it, then
// sets is_auto_join=true directly in the DB.
//
// A direct DB INSERT would produce a room unknown to the core's GenServer registry,
// causing Nebu.Room.Server.join/2 to fail silently in ensure_auto_join_memberships/1.
// deleteUserAllData removes a Matrix user and all dependent rows so the next login
// sees the user as brand-new (is_new=true) in validate_token.
func deleteUserAllData(matrixUserID string) error {
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		return fmt.Errorf("deleteUserAllData: open DB: %w", err)
	}
	defer db.Close()
	ctx := context.Background()
	tables := []string{
		"room_invitations", // inviter_id / invitee_id both reference users
		"sync_tokens",
		"room_members",
		"sessions",
		"user_keys",
		"profiles",
		"forgotten_rooms",
	}
	for _, t := range tables {
		col := "user_id"
		if t == "room_invitations" {
			if _, err = db.ExecContext(ctx,
				"DELETE FROM room_invitations WHERE inviter_id = $1 OR invitee_id = $1",
				matrixUserID); err != nil {
				return fmt.Errorf("deleteUserAllData: room_invitations: %w", err)
			}
			continue
		}
		if _, err = db.ExecContext(ctx,
			fmt.Sprintf("DELETE FROM %s WHERE %s = $1", t, col),
			matrixUserID); err != nil {
			return fmt.Errorf("deleteUserAllData: %s: %w", t, err)
		}
	}
	if _, err = db.ExecContext(ctx, "DELETE FROM users WHERE user_id = $1", matrixUserID); err != nil {
		return fmt.Errorf("deleteUserAllData: users: %w", err)
	}
	return nil
}

func roomExistsWithIsAutoJoinTrue(roomName string) error {
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		return fmt.Errorf("opening DB for auto-join setup: %w", err)
	}
	defer db.Close()

	// Clear all is_auto_join flags first — ensures only the test's room triggers
	// auto-join, preventing interference from rooms created by earlier scenarios.
	if _, err = db.ExecContext(context.Background(),
		"UPDATE rooms SET is_auto_join = false WHERE is_auto_join = true"); err != nil {
		return fmt.Errorf("clearing is_auto_join for test isolation: %w", err)
	}

	// If a room with this name already exists (created in a prior scenario), reuse it.
	var roomID string
	err = db.QueryRowContext(context.Background(),
		"SELECT room_id FROM rooms WHERE name = $1 LIMIT 1", roomName,
	).Scan(&roomID)
	if err == nil {
		if _, err = db.ExecContext(context.Background(),
			"UPDATE rooms SET is_auto_join = true WHERE room_id = $1", roomID); err != nil {
			return fmt.Errorf("re-enabling is_auto_join for %q: %w", roomID, err)
		}
		autoJoinRoomID = roomID
		return nil
	}
	if err != sql.ErrNoRows {
		return fmt.Errorf("querying room %q: %w", roomName, err)
	}

	// Create the room via Matrix API as kai so the Elixir core registers it.
	if err := iObtainDexTokenFor("kai@example.com", "changeme"); err != nil {
		return fmt.Errorf("roomExistsWithIsAutoJoinTrue: kai auth failed: %w", err)
	}
	kaiToken, err := obtainMatrixAccessToken()
	if err != nil {
		return fmt.Errorf("roomExistsWithIsAutoJoinTrue: kai matrix login failed: %w", err)
	}

	createPayload := fmt.Sprintf(`{"name":%q,"visibility":"public","preset":"public_chat"}`, roomName)
	req, err := http.NewRequest(http.MethodPost, matrixURL+"/_matrix/client/v3/createRoom",
		strings.NewReader(createPayload))
	if err != nil {
		return fmt.Errorf("building createRoom request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+kaiToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /createRoom: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("createRoom returned %d: %s", resp.StatusCode, body)
	}
	var createResp struct {
		RoomID string `json:"room_id"`
	}
	if err := json.Unmarshal(body, &createResp); err != nil {
		return fmt.Errorf("parsing createRoom response: %w", err)
	}
	roomID = createResp.RoomID

	// Mark the room as auto-join in the DB.
	if _, err = db.ExecContext(context.Background(),
		"UPDATE rooms SET is_auto_join = true WHERE room_id = $1", roomID); err != nil {
		return fmt.Errorf("setting is_auto_join=true for %q: %w", roomID, err)
	}
	autoJoinRoomID = roomID
	return nil
}

// obtainMatrixAccessToken exchanges lastDexIDToken for a Matrix access_token.
func obtainMatrixAccessToken() (string, error) {
	payload := fmt.Sprintf(`{"type":"m.login.token","token":%q}`, lastDexIDToken)
	req, err := http.NewRequest(http.MethodPost, matrixURL+"/_matrix/client/v3/login",
		strings.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("POST /login: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("login returned %d: %s", resp.StatusCode, body)
	}
	var lr struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &lr); err != nil {
		return "", fmt.Errorf("parsing login response: %w", err)
	}
	return lr.AccessToken, nil
}

// ─── Setup steps ─────────────────────────────────────────────────────────────

// charlieIsANewUserAutoJoin resets charlie's state and removes carol from the DB
// so each scenario treats carol as a genuine first-time user (is_new=true).
// Also resets charlieAccessToken/charlieUserID (from direct_room_heroes context)
// so the heroes test suite can re-authenticate charlie@example.com fresh.
func charlieIsANewUserAutoJoin() error {
	charlieAutoJoinAccessToken = ""
	charlieAutoJoinUserID = ""
	charlieAutoJoinSyncBody = ""
	// Clear the shared charlieAccessToken/charlieUserID bridge so that heroes
	// scenarios can authenticate charlie@example.com via authenticateUser (which
	// is idempotent and skips re-login when charlieAccessToken is already set).
	charlieAccessToken = ""
	charlieUserID = ""
	// Delete carol so validate_token sees her as brand-new on next login.
	if err := deleteUserAllData("@carol:localhost"); err != nil {
		// Ignore "not found" — carol might not exist yet on first run.
		if !strings.Contains(err.Error(), "no rows") {
			return fmt.Errorf("charlieIsANewUserAutoJoin: %w", err)
		}
	}
	return nil
}

// aliceIsAlreadyMemberOfRoom ensures alice is logged in and already a member of
// the named room. Stores alice's session in aliceAutoJoinAccessToken.
func aliceIsAlreadyMemberOfRoom(roomName string) error {
	// Ensure the room has is_auto_join = true.
	if err := roomExistsWithIsAutoJoinTrue(roomName); err != nil {
		return fmt.Errorf("aliceIsAlreadyMemberOfRoom setup: %w", err)
	}

	// Authenticate alice if not already done.
	if aliceAutoJoinAccessToken == "" {
		if err := authenticateUser("anna@example.com", "changeme", &aliceAutoJoinAccessToken, &aliceAutoJoinUserID); err != nil {
			return fmt.Errorf("alice auto-join first login: %w", err)
		}
	}

	// Join alice to the room if she is not already a member.
	joinURL := fmt.Sprintf("%s/_matrix/client/v3/join/%s", matrixURL, autoJoinRoomID)
	req, err := http.NewRequest(http.MethodPost, joinURL, strings.NewReader("{}"))
	if err != nil {
		return fmt.Errorf("building join request for alice: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+aliceAutoJoinAccessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /join for alice: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	// 200 OK (joined) or 403 (already a member via auto-join) are both acceptable.
	_ = body
	return nil
}

// charlieIsPreInvitedToRoom ensures charlie has a pre-existing invite to the room
// before his first login. Uses alice's admin token to invite.
func charlieIsPreInvitedToRoom(roomName string) error {
	// Reset charlie's state and delete carol from DB so she is new on next login.
	charlieAutoJoinAccessToken = ""
	charlieAutoJoinUserID = ""
	charlieAutoJoinSyncBody = ""
	if err := deleteUserAllData("@carol:localhost"); err != nil {
		if !strings.Contains(err.Error(), "no rows") {
			return fmt.Errorf("charlieIsPreInvitedToRoom: cleanup carol: %w", err)
		}
	}

	// Ensure the room exists with is_auto_join=true.
	if err := roomExistsWithIsAutoJoinTrue(roomName); err != nil {
		return fmt.Errorf("charlieIsPreInvitedToRoom setup: %w", err)
	}

	// Authenticate alice to use as the inviter.
	if aliceAutoJoinAccessToken == "" {
		if err := authenticateUser("anna@example.com", "changeme", &aliceAutoJoinAccessToken, &aliceAutoJoinUserID); err != nil {
			return fmt.Errorf("alice auto-join login for invite: %w", err)
		}
	}

	// Alice must be in the room to invite charlie.
	joinURL := fmt.Sprintf("%s/_matrix/client/v3/join/%s", matrixURL, autoJoinRoomID)
	joinReq, err := http.NewRequest(http.MethodPost, joinURL, strings.NewReader("{}"))
	if err != nil {
		return fmt.Errorf("building alice join request: %w", err)
	}
	joinReq.Header.Set("Content-Type", "application/json")
	joinReq.Header.Set("Authorization", "Bearer "+aliceAutoJoinAccessToken)
	joinResp, err := http.DefaultClient.Do(joinReq)
	if err != nil {
		return fmt.Errorf("alice join room: %w", err)
	}
	joinResp.Body.Close()

	// Invite charlie using a known userID pattern.
	charlieMatrixID := "@carol:localhost"
	inviteBody := fmt.Sprintf(`{"user_id":%q}`, charlieMatrixID)
	inviteURL := fmt.Sprintf("%s/_matrix/client/v3/rooms/%s/invite", matrixURL, autoJoinRoomID)
	invReq, err := http.NewRequest(http.MethodPost, inviteURL, strings.NewReader(inviteBody))
	if err != nil {
		return fmt.Errorf("building invite request: %w", err)
	}
	invReq.Header.Set("Content-Type", "application/json")
	invReq.Header.Set("Authorization", "Bearer "+aliceAutoJoinAccessToken)

	invResp, err := http.DefaultClient.Do(invReq)
	if err != nil {
		return fmt.Errorf("POST /invite for charlie: %w", err)
	}
	defer invResp.Body.Close()
	invBody, _ := io.ReadAll(invResp.Body)
	// 200 OK (invited) or 403 (already invited/member) are both acceptable.
	_ = invBody
	return nil
}

// ─── Action steps ─────────────────────────────────────────────────────────────

// charlieLogsInViaOIDCAutoJoin performs the OIDC login flow for charlie and
// forwards the result to shared lastLoginBody so shared assertions
// (login response contains access_token, etc.) work correctly.
func charlieLogsInViaOIDCAutoJoin() error {
	if err := iObtainDexTokenFor("carol@example.com", "changeme"); err != nil {
		return fmt.Errorf("charlie Dex token: %w", err)
	}
	if err := iPostLoginWithDexToken(); err != nil {
		return fmt.Errorf("charlie Matrix login: %w", err)
	}

	// Forward to shared lastLoginBody so shared assertions (login response
	// contains access_token etc.) work correctly.
	lastLoginStatus = lastStatusCode
	lastLoginBody = lastBody

	if lastStatusCode == http.StatusOK {
		var loginResp struct {
			AccessToken string `json:"access_token"`
			UserID      string `json:"user_id"`
		}
		if err := json.Unmarshal([]byte(lastBody), &loginResp); err == nil {
			charlieAutoJoinAccessToken = loginResp.AccessToken
			charlieAutoJoinUserID = loginResp.UserID
			// charlieCallsGetSyncTimeout0 now reads charlieAutoJoinAccessToken directly.
		}
	}
	return nil
}

// ─── Assertion steps ──────────────────────────────────────────────────────────

// theSyncRoomsJoinContainsRoomForCharlie asserts that the named room appears in
// charlie's rooms.join after auto-join. Retries up to 5 times with 1s delay to
// allow the async Task.start ensure_auto_join_memberships to complete.
func theSyncRoomsJoinContainsRoomForCharlie(roomName string) error {
	check := func() bool {
		joinRooms, err := parseSyncJoinRooms(charlieAutoJoinSyncBody)
		if err != nil {
			return false
		}
		if autoJoinRoomID != "" {
			if _, ok := joinRooms[autoJoinRoomID]; ok {
				return true
			}
		}
		for _, room := range joinRooms {
			for _, ev := range room.State.Events {
				if ev.Type == "m.room.name" && ev.StateKey == "" {
					var nameContent struct{ Name string `json:"name"` }
					if json.Unmarshal(ev.Content, &nameContent) == nil && nameContent.Name == roomName {
						return true
					}
				}
			}
		}
		return false
	}

	if check() {
		return nil
	}
	// Auto-join Task.start is async — retry with sync re-fetches.
	for i := 0; i < 5; i++ {
		time.Sleep(time.Second)
		if err := charlieCallsGetSyncTimeout0(); err != nil {
			return fmt.Errorf("re-fetch sync (attempt %d): %w", i+1, err)
		}
		if check() {
			return nil
		}
	}
	joinRooms, _ := parseSyncJoinRooms(charlieAutoJoinSyncBody)
	return fmt.Errorf("room %q (id=%q) not found in charlie's rooms.join after auto-join; keys: %v",
		roomName, autoJoinRoomID, roomIDKeys(joinRooms))
}

// aliceRoomMembershipUnchanged asserts that alice's membership in the named room
// is still "join" after re-login (no duplicate membership events added).
func aliceRoomMembershipUnchanged(roomName string) error {
	// Use aliceAutoJoinAccessToken (anna@example.com, the auto-join alice) as the
	// primary token. Fall back to aliceAccessToken (alice@example.com, personal_self_room)
	// when this function is called outside the auto-join context.
	token := aliceAutoJoinAccessToken
	if token == "" {
		token = aliceAccessToken
	}
	if token == "" {
		return fmt.Errorf("alice has no access_token for membership check")
	}
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?timeout=0", matrixURL)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building alice sync request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("alice GET /sync failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)

	if lastStatusCode != http.StatusOK {
		return fmt.Errorf("alice sync returned %d: %s", lastStatusCode, lastBody)
	}

	joinRooms, err := parseSyncJoinRooms(lastBody)
	if err != nil {
		return err
	}

	// Resolve alice's user ID — prefer aliceAutoJoinUserID (anna) in auto-join context.
	aliceUID := aliceAutoJoinUserID
	if aliceUID == "" {
		aliceUID = aliceUserID
	}

	// Find the room — first by ID, then by name.
	var targetRoomID string
	if autoJoinRoomID != "" {
		if _, ok := joinRooms[autoJoinRoomID]; ok {
			targetRoomID = autoJoinRoomID
		}
	}
	if targetRoomID == "" {
		for rid, room := range joinRooms {
			for _, ev := range room.State.Events {
				if ev.Type == "m.room.name" && ev.StateKey == "" {
					var nameContent struct {
						Name string `json:"name"`
					}
					if jsonErr := json.Unmarshal(ev.Content, &nameContent); jsonErr == nil && nameContent.Name == roomName {
						targetRoomID = rid
					}
				}
			}
		}
	}
	if targetRoomID == "" {
		return fmt.Errorf("room %q not found in alice's rooms.join after re-login", roomName)
	}

	// Assert alice has exactly one m.room.member event with membership=join.
	// Check State + Timeline — the core deduplicates member events out of State
	// when they also appear in the Timeline (Matrix-spec-compliant deduplication).
	room := joinRooms[targetRoomID]
	var memberCount int
	for _, ev := range allEventsOfType(room, "m.room.member") {
		if ev.StateKey == aliceUID {
			var content struct {
				Membership string `json:"membership"`
			}
			if err := json.Unmarshal(ev.Content, &content); err == nil && content.Membership == "join" {
				memberCount++
			}
		}
	}
	if memberCount == 0 {
		return fmt.Errorf("alice has no join membership event in room %q after re-login (expected 1)", roomName)
	}
	// Duplicate membership events would indicate a re-join on re-login (the bug we're testing against).
	if memberCount > 1 {
		return fmt.Errorf("alice has %d duplicate join membership events in room %q after re-login (expected 1)", memberCount, roomName)
	}
	return nil
}

// charlieHasExactlyOneMembershipEventInRoom asserts exactly one m.room.member
// event with state_key=charlieAutoJoinUserID in the named room. Retries up to
// 5 times to allow the async auto-join Task.start to complete.
func charlieHasExactlyOneMembershipEventInRoom(roomName string) error {
	charlieStateKey := charlieAutoJoinUserID
	if charlieStateKey == "" {
		charlieStateKey = "@carol:localhost"
	}

	check := func() (int, string, error) {
		joinRooms, err := parseSyncJoinRooms(charlieAutoJoinSyncBody)
		if err != nil {
			return 0, "", err
		}
		targetRoomID := autoJoinRoomID
		if targetRoomID == "" {
			for rid, room := range joinRooms {
				for _, ev := range room.State.Events {
					if ev.Type == "m.room.name" && ev.StateKey == "" {
						var nameContent struct{ Name string `json:"name"` }
						if json.Unmarshal(ev.Content, &nameContent) == nil && nameContent.Name == roomName {
							targetRoomID = rid
						}
					}
				}
			}
		}
		if targetRoomID == "" {
			return 0, targetRoomID, nil
		}
		room, ok := joinRooms[targetRoomID]
		if !ok {
			return 0, targetRoomID, nil
		}
		var count int
		for _, ev := range allEventsOfType(room, "m.room.member") {
			if ev.StateKey == charlieStateKey {
				count++
			}
		}
		return count, targetRoomID, nil
	}

	for attempt := 0; attempt <= 5; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Second)
			if err := charlieCallsGetSyncTimeout0(); err != nil {
				return fmt.Errorf("re-fetch sync (attempt %d): %w", attempt, err)
			}
		}
		count, roomID, err := check()
		if err != nil {
			return err
		}
		if roomID != "" && count == 1 {
			return nil
		}
	}
	count, _, _ := check()
	return fmt.Errorf("expected exactly 1 m.room.member event for %q in room %q, got %d",
		charlieStateKey, roomName, count)
}

// charliesSyncContainsMemberEvent asserts that charlie's rooms.join for the
// named room contains an m.room.member event.
// charliesSyncContainsMemberEvent asserts that charlie's rooms.join for the named
// room contains an m.room.member event. Retries up to 5 times for async auto-join.
func charliesSyncContainsMemberEvent(roomName string) error {
	charlieStateKey := charlieAutoJoinUserID
	if charlieStateKey == "" {
		charlieStateKey = "@carol:localhost"
	}

	findRoom := func() (string, bool) {
		joinRooms, err := parseSyncJoinRooms(charlieAutoJoinSyncBody)
		if err != nil {
			return "", false
		}
		if autoJoinRoomID != "" {
			if room, ok := joinRooms[autoJoinRoomID]; ok {
				// Check specifically for carol's m.room.member event (not any user's).
				for _, ev := range allEventsOfType(room, "m.room.member") {
					if ev.StateKey == charlieStateKey {
						return autoJoinRoomID, true
					}
				}
				return autoJoinRoomID, false
			}
		}
		return "", false
	}

	for attempt := 0; attempt <= 5; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Second)
			if err := charlieCallsGetSyncTimeout0(); err != nil {
				return fmt.Errorf("re-fetch sync (attempt %d): %w", attempt, err)
			}
		}
		roomID, found := findRoom()
		if found {
			return nil
		}
		if roomID != "" && attempt == 5 {
			return fmt.Errorf("no m.room.member event found in charlie's sync for room %q (id=%q)", roomName, roomID)
		}
	}
	return fmt.Errorf("room %q (id=%q) not found in charlie's rooms.join after %d retries", roomName, autoJoinRoomID, 5)
}

// charliesMemberEventHasMembership asserts the last-found m.room.member event
// for charlie has the given membership value.
func charliesMemberEventHasMembership(membership string) error {
	joinRooms, err := parseSyncJoinRooms(charlieAutoJoinSyncBody)
	if err != nil {
		return err
	}

	targetRoomID := autoJoinRoomID
	if targetRoomID == "" {
		return fmt.Errorf("autoJoinRoomID is empty — run roomExistsWithIsAutoJoinTrue first")
	}

	room, ok := joinRooms[targetRoomID]
	if !ok {
		return fmt.Errorf("room ID %q not in rooms.join", targetRoomID)
	}

	charlieStateKey := charlieAutoJoinUserID
	if charlieStateKey == "" {
		charlieStateKey = "@carol:localhost"
	}

	for _, ev := range allEventsOfType(room, "m.room.member") {
		if ev.StateKey == charlieStateKey {
			var content struct {
				Membership string `json:"membership"`
			}
			if err := json.Unmarshal(ev.Content, &content); err != nil {
				return fmt.Errorf("parsing m.room.member content: %w", err)
			}
			if content.Membership != membership {
				return fmt.Errorf("m.room.member membership: expected %q, got %q", membership, content.Membership)
			}
			return nil
		}
	}
	return fmt.Errorf("no m.room.member event with state_key=%q found in room %q", charlieStateKey, targetRoomID)
}

// charliesMemberEventHasStateKey asserts the m.room.member event has the given state_key.
func charliesMemberEventHasStateKey(stateKey string) error {
	joinRooms, err := parseSyncJoinRooms(charlieAutoJoinSyncBody)
	if err != nil {
		return err
	}

	targetRoomID := autoJoinRoomID
	if targetRoomID == "" {
		return fmt.Errorf("autoJoinRoomID is empty — run roomExistsWithIsAutoJoinTrue first")
	}

	room, ok := joinRooms[targetRoomID]
	if !ok {
		return fmt.Errorf("room ID %q not in rooms.join", targetRoomID)
	}

	for _, ev := range allEventsOfType(room, "m.room.member") {
		if ev.StateKey == stateKey {
			return nil
		}
	}
	return fmt.Errorf("no m.room.member event with state_key=%q found in room %q", stateKey, targetRoomID)
}

// ─── Step registration ────────────────────────────────────────────────────────

// initializeAutoJoinRoomsSteps registers all Godog step definitions for
// gateway/features/auto_join_rooms.feature.
// Called from InitializeScenario in steps_test.go.
func initializeAutoJoinRoomsSteps(sc *godog.ScenarioContext) {
	// DB precondition
	sc.Step(`^room "([^"]*)" exists with is_auto_join set to true$`, roomExistsWithIsAutoJoinTrue)

	// User setup / Given
	sc.Step(`^charlie is a new user who has never logged in$`, charlieIsANewUserAutoJoin)
	sc.Step(`^alice is a user who has logged in before and is already a member of "([^"]*)"$`, aliceIsAlreadyMemberOfRoom)
	sc.Step(`^charlie is a new user who has been pre-invited to "([^"]*)" before first login$`, charlieIsPreInvitedToRoom)

	// Actions / When
	// Note: "alice logs in again via OIDC" is already registered by
	// initializePersonalSelfRoomSteps — not re-registered here.
	//
	// Note: "charlie calls GET /sync with timeout 0" is registered by
	// initializeDirectRoomHeroesSteps. charlieCallsGetSyncTimeout0 now also writes
	// to charlieAutoJoinSyncBody so auto-join sync assertions remain correct.
	sc.Step(`^charlie logs in via OIDC$`, charlieLogsInViaOIDCAutoJoin)

	// Sync assertions / Then
	sc.Step(`^the sync rooms\.join contains room "([^"]*)" for charlie$`, theSyncRoomsJoinContainsRoomForCharlie)
	sc.Step(`^alice's room membership in "([^"]*)" is unchanged from before login$`, aliceRoomMembershipUnchanged)
	sc.Step(`^charlie has exactly one membership event in "([^"]*)"$`, charlieHasExactlyOneMembershipEventInRoom)
	sc.Step(`^charlie's sync rooms\.join\["([^"]*)"\] state contains an m\.room\.member event$`, charliesSyncContainsMemberEvent)
	sc.Step(`^charlie's m\.room\.member event has membership "([^"]*)"$`, charliesMemberEventHasMembership)
	sc.Step(`^charlie's m\.room\.member event has state_key "([^"]*)"$`, charliesMemberEventHasStateKey)
}
