//go:build integration

package integration_test

// ─── Story direct-room-heroes: DM Room Names — Populate Matrix Sync Heroes ────
//
// Godog step definitions for gateway/features/direct_room_heroes.feature.
// Written FIRST (ATDD gate) — all hero-summary assertions WILL FAIL until:
//   1. proto/core.proto SyncRoom gains heroes/joined_member_count/invited_member_count fields
//   2. make proto regenerates gateway/internal/grpc/pb/core.pb.go
//   3. Elixir event_dispatcher/server.ex computes heroes per spec §11.2.2.5
//   4. gateway/internal/matrix/sync.go attaches Summary (pointer + omitempty) to syncJoinedRoom
//
// NOTE: alice@example.com, bob@example.com, charlie@example.com must exist in
// dev/dex/config.yaml. Add them with the same hash (password: changeme) and
// userIDs 000...007, 000...008, 000...009 respectively.
// The personal-self-room story shares alice@example.com — ensure it is present.
//
// State (package-level, sequential Godog run — no concurrency risk):
//   bobAccessToken / bobUserID                — bob's Matrix session
//   charlieAccessToken / charlieUserID        — charlie's Matrix session
//   dmRoomID                                  — room ID of the 1-on-1 DM (alice ↔ bob)
//   groupDMRoomID                             — room ID of the 3-person DM (alice, bob, charlie)
//   namedRoomID                               — room ID of the named "Team" room
//   aliceSecondDMRoomID                       — second DM room for AC4 initial sync test
//   heroesSyncBody                            — last GET /sync response body (heroes tests)
//   heroesSecondSyncBody                      — alice's second DM room's sync body
//   heroesCapturedToken                       — next_batch from alice's initial sync (delta test)
//   heroesIncrementalSyncBody                 — response body from delta sync (AC5 / Oracle edge)
//
// Shared helpers available from other step files (same package):
//   authenticateUser(email, password, *token, *userID) — Dex + Matrix /login
//   aliceAccessToken / aliceUserID            — alice's session (personal_self_room_steps_test.go)
//   aliceCallsGetSyncTimeout0()               — alice's GET /sync?timeout=0 (personal_self_room)
//   aliceSyncBody                             — alice's last sync response
//   lastStatusCode / lastBody                 — most recent raw response (steps_test.go)
//   matrixURL                                 — base URL for the Matrix API (main_test.go)
//
// New steps registered in initializeDirectRoomHeroesSteps (bottom of this file).

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"

	"github.com/cucumber/godog"
)

// ─── State ────────────────────────────────────────────────────────────────────

var bobAccessToken string
var bobUserID string
var charlieAccessToken string
var charlieUserID string

// Room IDs created during heroes scenarios.
var dmRoomID string      // 1-on-1 alice ↔ bob
var groupDMRoomID string // 3-person alice, bob, charlie
var namedRoomID string   // named "Team" room

var aliceSecondDMRoomID string // alice ↔ charlie (AC4)

// Sync response bodies.
var heroesSyncBody string          // latest sync body for heroes assertions
var heroesIncrementalSyncBody string
var heroesCapturedToken string

// ─── Setup helpers ────────────────────────────────────────────────────────────

// bobIsAuthenticated authenticates bob@example.com and caches the token.
func bobIsAuthenticated() error {
	return authenticateUser("bob@example.com", "changeme", &bobAccessToken, &bobUserID)
}

// charlieIsAuthenticated authenticates charlie@example.com and caches the token.
func charlieIsAuthenticated() error {
	return authenticateUser("charlie@example.com", "changeme", &charlieAccessToken, &charlieUserID)
}

// ─── createRoom is a generic helper used by multiple "alice creates a … room" steps. ──

// createRoomAs calls POST /_matrix/client/v3/createRoom with the given JSON body,
// authenticated with the provided token. Returns the new room_id.
func createRoomAs(accessToken, bodyJSON string) (string, error) {
	req, err := http.NewRequest(
		http.MethodPost,
		matrixURL+"/_matrix/client/v3/createRoom",
		strings.NewReader(bodyJSON),
	)
	if err != nil {
		return "", fmt.Errorf("building createRoom request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("POST /createRoom: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("createRoom returned %d: %s", resp.StatusCode, body)
	}
	var result struct {
		RoomID string `json:"room_id"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("parsing createRoom response: %w (body: %s)", err, body)
	}
	if result.RoomID == "" {
		return "", fmt.Errorf("empty room_id in createRoom response: %s", body)
	}
	return result.RoomID, nil
}

// inviteUserToRoom calls POST /_matrix/client/v3/rooms/{roomId}/invite.
func inviteUserToRoom(roomID, inviteeUserID, inviterToken string) error {
	bodyJSON := fmt.Sprintf(`{"user_id":%q}`, inviteeUserID)
	req, err := http.NewRequest(
		http.MethodPost,
		fmt.Sprintf("%s/_matrix/client/v3/rooms/%s/invite", matrixURL, roomID),
		strings.NewReader(bodyJSON),
	)
	if err != nil {
		return fmt.Errorf("building invite request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+inviterToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /invite: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("invite returned %d: %s", resp.StatusCode, body)
	}
	return nil
}

// joinRoom calls POST /_matrix/client/v3/join/{roomId}.
func joinRoom(roomID, accessToken string) error {
	req, err := http.NewRequest(
		http.MethodPost,
		fmt.Sprintf("%s/_matrix/client/v3/join/%s", matrixURL, roomID),
		strings.NewReader("{}"),
	)
	if err != nil {
		return fmt.Errorf("building join request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /join: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("join returned %d: %s", resp.StatusCode, body)
	}
	return nil
}

// ─── Given / When step implementations ───────────────────────────────────────

// aliceCreatesDMRoomWithBob creates a private room, marks it is_direct via account data,
// invites bob, and waits for bob to join. Stores the room ID in dmRoomID.
//
// THIS STEP WILL SUCCEED (room creation is already implemented).
// The heroes assertion steps below will FAIL.
func aliceCreatesDMRoomWithBob() error {
	if aliceAccessToken == "" {
		return fmt.Errorf("alice has no access_token — call 'alice is authenticated via OIDC' first")
	}
	if bobUserID == "" {
		return fmt.Errorf("bob has no user_id — call 'bob is authenticated via OIDC' first")
	}
	// Create private room (no name → heroes are needed by the client).
	bodyJSON := fmt.Sprintf(`{"preset":"private_chat","invite":[%q],"is_direct":true}`, bobUserID)
	roomID, err := createRoomAs(aliceAccessToken, bodyJSON)
	if err != nil {
		return fmt.Errorf("alice creating DM room with bob: %w", err)
	}
	dmRoomID = roomID
	// Bob accepts the invite.
	if err := joinRoom(dmRoomID, bobAccessToken); err != nil {
		return fmt.Errorf("bob joining DM room: %w", err)
	}
	return nil
}

// bobCallsGetSyncTimeout0 calls GET /sync?timeout=0 authenticated as bob.
// Stores the full response in heroesSyncBody.
func bobCallsGetSyncTimeout0() error {
	if bobAccessToken == "" {
		return fmt.Errorf("bob has no access_token — call a login step first")
	}
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?timeout=0", matrixURL)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building bob GET /sync request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+bobAccessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("bob GET /sync failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	heroesSyncBody = lastBody
	return nil
}

// aliceCreatesDMRoomWithBob3person creates a group DM with alice, bob, and charlie.
// Stores the room ID in groupDMRoomID.
func aliceCreatesGroupDMRoomWithBobAndCharlie() error {
	if aliceAccessToken == "" {
		return fmt.Errorf("alice has no access_token")
	}
	if bobUserID == "" {
		return fmt.Errorf("bob has no user_id")
	}
	if charlieUserID == "" {
		return fmt.Errorf("charlie has no user_id")
	}
	bodyJSON := fmt.Sprintf(`{"preset":"private_chat","invite":[%q,%q],"is_direct":true}`,
		bobUserID, charlieUserID)
	roomID, err := createRoomAs(aliceAccessToken, bodyJSON)
	if err != nil {
		return fmt.Errorf("alice creating group DM: %w", err)
	}
	groupDMRoomID = roomID
	if err := joinRoom(groupDMRoomID, bobAccessToken); err != nil {
		return fmt.Errorf("bob joining group DM: %w", err)
	}
	if err := joinRoom(groupDMRoomID, charlieAccessToken); err != nil {
		return fmt.Errorf("charlie joining group DM: %w", err)
	}
	return nil
}

// charlieCallsGetSyncTimeout0 calls GET /sync?timeout=0 authenticated as charlie.
// Prefers charlieAutoJoinAccessToken (carol in auto_join_rooms context) so the
// auto_join_rooms bridge no longer needs to overwrite charlieAccessToken.
// Also writes to charlieAutoJoinSyncBody so auto_join_rooms scenarios share the response.
func charlieCallsGetSyncTimeout0() error {
	// Use charlieAutoJoinAccessToken (carol in auto_join context) ONLY when
	// charlieAccessToken is empty — prevents carol's stale token from being used
	// in heroes scenarios where charlie@example.com is the real charlie.
	token := charlieAccessToken
	if token == "" && charlieAutoJoinAccessToken != "" {
		token = charlieAutoJoinAccessToken
	}
	if token == "" {
		return fmt.Errorf("charlie has no access_token")
	}
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?timeout=0", matrixURL)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building charlie GET /sync: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("charlie GET /sync failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	heroesSyncBody = lastBody
	charlieAutoJoinSyncBody = lastBody // shared with auto_join_rooms scenarios
	return nil
}

// aliceCreatesNamedRoomTeamWithBob creates a named room "Team" and invites bob.
// Stores the room ID in namedRoomID.
func aliceCreatesNamedRoomWithBob(name string) error {
	if aliceAccessToken == "" {
		return fmt.Errorf("alice has no access_token")
	}
	if bobUserID == "" {
		return fmt.Errorf("bob has no user_id")
	}
	bodyJSON := fmt.Sprintf(`{"name":%q,"preset":"private_chat","invite":[%q]}`, name, bobUserID)
	roomID, err := createRoomAs(aliceAccessToken, bodyJSON)
	if err != nil {
		return fmt.Errorf("alice creating named room %q: %w", name, err)
	}
	namedRoomID = roomID
	if err := joinRoom(namedRoomID, bobAccessToken); err != nil {
		return fmt.Errorf("bob joining named room: %w", err)
	}
	return nil
}

// aliceCreatesSecondDMRoomWithCharlie creates a DM room between alice and charlie.
func aliceCreatesSecondDMRoomWithCharlie() error {
	if aliceAccessToken == "" {
		return fmt.Errorf("alice has no access_token")
	}
	if charlieUserID == "" {
		return fmt.Errorf("charlie has no user_id")
	}
	bodyJSON := fmt.Sprintf(`{"preset":"private_chat","invite":[%q],"is_direct":true}`, charlieUserID)
	roomID, err := createRoomAs(aliceAccessToken, bodyJSON)
	if err != nil {
		return fmt.Errorf("alice creating second DM room: %w", err)
	}
	aliceSecondDMRoomID = roomID
	if err := joinRoom(aliceSecondDMRoomID, charlieAccessToken); err != nil {
		return fmt.Errorf("charlie joining second DM: %w", err)
	}
	return nil
}

// aliceCapturesSyncNextBatch extracts next_batch from heroesSyncBody and stores it
// in heroesCapturedToken for use in subsequent incremental sync.
func aliceCapturesSyncNextBatch() error {
	var syncResp struct {
		NextBatch string `json:"next_batch"`
	}
	if err := json.Unmarshal([]byte(heroesSyncBody), &syncResp); err != nil {
		return fmt.Errorf("parsing sync body to capture next_batch: %w (body: %s)", err, heroesSyncBody)
	}
	if syncResp.NextBatch == "" {
		return fmt.Errorf("next_batch missing or empty in sync response: %s", heroesSyncBody)
	}
	heroesCapturedToken = syncResp.NextBatch
	return nil
}

// aliceCallsIncrementalSyncWithCapturedToken calls GET /sync?since=<token>&timeout=0
// authenticated as alice. Stores response in heroesIncrementalSyncBody.
func aliceCallsIncrementalSyncWithCapturedToken() error {
	if aliceAccessToken == "" {
		return fmt.Errorf("alice has no access_token")
	}
	if heroesCapturedToken == "" {
		return fmt.Errorf("no captured sync token — call 'alice captures the sync next_batch token' first")
	}
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?timeout=0&since=%s", matrixURL, heroesCapturedToken)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building alice incremental GET /sync: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+aliceAccessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("alice incremental GET /sync failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	heroesIncrementalSyncBody = lastBody
	return nil
}

// ─── Sync parse helpers ───────────────────────────────────────────────────────

// syncRoomWithSummary extends syncRoomState to include the summary field.
type heroSyncRoom struct {
	State struct {
		Events []struct {
			Type     string          `json:"type"`
			StateKey string          `json:"state_key"`
			Content  json.RawMessage `json:"content"`
		} `json:"events"`
	} `json:"state"`
	Summary *heroRoomSummary `json:"summary,omitempty"`
}

type heroRoomSummary struct {
	Heroes             []string `json:"m.heroes"`
	JoinedMemberCount  *int32   `json:"m.joined_member_count,omitempty"`
	InvitedMemberCount *int32   `json:"m.invited_member_count,omitempty"`
}

func parseHeroSyncJoinRooms(body string) (map[string]heroSyncRoom, error) {
	var sync struct {
		Rooms struct {
			Join map[string]heroSyncRoom `json:"join"`
		} `json:"rooms"`
	}
	if err := json.Unmarshal([]byte(body), &sync); err != nil {
		return nil, fmt.Errorf("parsing heroes sync response: %w (body: %s)", err, body)
	}
	return sync.Rooms.Join, nil
}

// parseNextBatch returns the next_batch field from the given sync body.
func parseNextBatch(body string) (string, error) {
	var s struct {
		NextBatch string `json:"next_batch"`
	}
	if err := json.Unmarshal([]byte(body), &s); err != nil {
		return "", fmt.Errorf("parsing next_batch: %w", err)
	}
	return s.NextBatch, nil
}

// ─── Assertion steps ──────────────────────────────────────────────────────────

// theHeroesSyncResponseStatusIs asserts the HTTP status for heroes scenarios.
// Delegates to theResponseStatusIs (shared step).
func theHeroesSyncResponseStatusIs(expected int) error {
	return theResponseStatusIs(expected)
}

// bobsSyncResponseContainsSummaryForDMRoom asserts that rooms.join[dmRoomID] has a
// non-nil summary with a non-empty m.heroes list.
//
// THIS ASSERTION WILL FAIL until Elixir computes heroes and sync.go attaches Summary.
func bobsSyncResponseContainsSummaryForDMRoom() error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[dmRoomID]
	if !ok {
		return fmt.Errorf("DM room %q not found in bob's rooms.join (body: %.400s)",
			dmRoomID, heroesSyncBody)
	}
	if room.Summary == nil {
		return fmt.Errorf(
			"expected DM room %q to have a summary object, got nil — "+
				"heroes not yet implemented (SyncRoom proto missing heroes field)",
			dmRoomID)
	}
	if len(room.Summary.Heroes) == 0 {
		return fmt.Errorf(
			"expected DM room %q summary.m.heroes to be non-empty, got [] — "+
				"Elixir hero computation not yet implemented",
			dmRoomID)
	}
	return nil
}

// theDMRoomSummaryHasMHeroesContaining asserts that summary["m.heroes"] contains the given MXID.
//
// THIS ASSERTION WILL FAIL until heroes computation is implemented.
func theDMRoomSummaryHasMHeroesContaining(mxid string) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[dmRoomID]
	if !ok {
		return fmt.Errorf("DM room %q not found in rooms.join", dmRoomID)
	}
	if room.Summary == nil {
		return fmt.Errorf("DM room %q has no summary — heroes not implemented", dmRoomID)
	}
	for _, hero := range room.Summary.Heroes {
		if hero == mxid {
			return nil
		}
	}
	return fmt.Errorf(
		"expected summary.m.heroes to contain %q, got %v (room %q) — heroes not computed yet",
		mxid, room.Summary.Heroes, dmRoomID)
}

// theDMRoomSummaryDoesNotContainInMHeroes asserts the given MXID is absent from heroes.
func theDMRoomSummaryDoesNotContainInMHeroes(mxid string) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[dmRoomID]
	if !ok {
		// Room not present at all — cannot assert heroes absence, but that's also wrong.
		return fmt.Errorf("DM room %q not in rooms.join — cannot verify hero exclusion", dmRoomID)
	}
	if room.Summary == nil {
		// No summary → heroes implicitly absent; spec §11.2.2 allows omitting summary
		// for rooms with no hero data, but for a DM room we expect it to be present.
		// If we reach here during the FAIL phase it means heroes aren't implemented at all.
		return fmt.Errorf("DM room %q has no summary — cannot verify hero exclusion (heroes not implemented)", dmRoomID)
	}
	for _, hero := range room.Summary.Heroes {
		if hero == mxid {
			return fmt.Errorf(
				"expected summary.m.heroes NOT to contain syncing user %q, but found it — "+
					"spec §11.2.2.5: syncing user must be excluded",
				mxid)
		}
	}
	return nil
}

// theDMRoomSummaryHasMJoinedMemberCount asserts the joined_member_count value.
//
// THIS ASSERTION WILL FAIL until the heroes proto fields and Elixir counts are implemented.
func theDMRoomSummaryHasMJoinedMemberCount(expected int32) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[dmRoomID]
	if !ok {
		return fmt.Errorf("DM room %q not in rooms.join", dmRoomID)
	}
	if room.Summary == nil {
		return fmt.Errorf("DM room %q has no summary — joined_member_count not implemented", dmRoomID)
	}
	if room.Summary.JoinedMemberCount == nil {
		return fmt.Errorf("DM room %q summary.m.joined_member_count is absent — not implemented", dmRoomID)
	}
	if *room.Summary.JoinedMemberCount != expected {
		return fmt.Errorf(
			"expected m.joined_member_count %d, got %d (room %q)",
			expected, *room.Summary.JoinedMemberCount, dmRoomID)
	}
	return nil
}

// ─── Group DM assertions ─────────────────────────────────────────────────────

// charliesSyncResponseContainsSummaryForGroupDMRoom asserts rooms.join[groupDMRoomID]
// has a summary with heroes.
func charliesSyncResponseContainsSummaryForGroupDMRoom() error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[groupDMRoomID]
	if !ok {
		return fmt.Errorf("group DM room %q not found in charlie's rooms.join (body: %.400s)",
			groupDMRoomID, heroesSyncBody)
	}
	if room.Summary == nil {
		return fmt.Errorf(
			"expected group DM room %q to have a summary, got nil — heroes not implemented",
			groupDMRoomID)
	}
	if len(room.Summary.Heroes) == 0 {
		return fmt.Errorf(
			"expected group DM room %q summary.m.heroes to be non-empty — heroes not computed",
			groupDMRoomID)
	}
	return nil
}

// theGroupDMRoomSummaryHasMHeroesContaining asserts the given MXID is in the group DM heroes.
func theGroupDMRoomSummaryHasMHeroesContaining(mxid string) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[groupDMRoomID]
	if !ok {
		return fmt.Errorf("group DM room %q not in rooms.join", groupDMRoomID)
	}
	if room.Summary == nil {
		return fmt.Errorf("group DM room %q has no summary — heroes not implemented", groupDMRoomID)
	}
	for _, hero := range room.Summary.Heroes {
		if hero == mxid {
			return nil
		}
	}
	return fmt.Errorf(
		"expected group DM summary.m.heroes to contain %q, got %v (room %q)",
		mxid, room.Summary.Heroes, groupDMRoomID)
}

// theGroupDMRoomSummaryDoesNotContainInMHeroes asserts MXID absent from group DM heroes.
func theGroupDMRoomSummaryDoesNotContainInMHeroes(mxid string) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[groupDMRoomID]
	if !ok {
		return fmt.Errorf("group DM room %q not in rooms.join", groupDMRoomID)
	}
	if room.Summary == nil {
		return fmt.Errorf("group DM room %q has no summary — cannot verify exclusion (not implemented)", groupDMRoomID)
	}
	for _, hero := range room.Summary.Heroes {
		if hero == mxid {
			return fmt.Errorf(
				"syncing user %q must not appear in group DM heroes, but was found — spec §11.2.2.5",
				mxid)
		}
	}
	return nil
}

// theGroupDMRoomSummaryHasMJoinedMemberCount asserts the count for the group DM room.
func theGroupDMRoomSummaryHasMJoinedMemberCount(expected int32) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[groupDMRoomID]
	if !ok {
		return fmt.Errorf("group DM room %q not in rooms.join", groupDMRoomID)
	}
	if room.Summary == nil {
		return fmt.Errorf("group DM room %q has no summary — counts not implemented", groupDMRoomID)
	}
	if room.Summary.JoinedMemberCount == nil {
		return fmt.Errorf("group DM room %q summary.m.joined_member_count absent", groupDMRoomID)
	}
	if *room.Summary.JoinedMemberCount != expected {
		return fmt.Errorf("expected m.joined_member_count %d, got %d (room %q)",
			expected, *room.Summary.JoinedMemberCount, groupDMRoomID)
	}
	return nil
}

// ─── AC3: Named room has no heroes ───────────────────────────────────────────

// theTeamRoomInAliceSyncResponseHasNoSummaryHeroes asserts that the named room
// "Team" (namedRoomID) has either no summary or an empty m.heroes list.
//
// THIS ASSERTION WILL SUCCEED if the current code never attaches summary —
// but it will then need to STILL PASS after heroes are implemented (named rooms must NOT get heroes).
func theNamedRoomInAliceSyncResponseHasNoSummaryHeroes(roomName string) error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	// Find the named room — use namedRoomID if set, otherwise search by m.room.name.
	targetRoomID := namedRoomID
	if targetRoomID == "" {
		// Fallback: search by m.room.name state event.
		for id, room := range rooms {
			for _, ev := range room.State.Events {
				if ev.Type == "m.room.name" {
					var content struct {
						Name string `json:"name"`
					}
					if jsonErr := json.Unmarshal(ev.Content, &content); jsonErr == nil {
						if content.Name == roomName {
							targetRoomID = id
							break
						}
					}
				}
			}
			if targetRoomID != "" {
				break
			}
		}
	}
	if targetRoomID == "" {
		return fmt.Errorf("named room %q not found in alice's rooms.join — cannot assert no heroes", roomName)
	}
	room, ok := rooms[targetRoomID]
	if !ok {
		return fmt.Errorf("named room %q (ID %q) not in rooms.join", roomName, targetRoomID)
	}
	if room.Summary == nil {
		// Correct: named rooms should have no summary (omitempty pointer).
		return nil
	}
	if len(room.Summary.Heroes) == 0 {
		// Also acceptable per spec.
		return nil
	}
	// Sort for deterministic error output.
	sorted := make([]string, len(room.Summary.Heroes))
	copy(sorted, room.Summary.Heroes)
	sort.Strings(sorted)
	return fmt.Errorf(
		"named room %q (ID %q) must not have m.heroes, but got %v — "+
			"spec §11.2.2: named rooms do not need heroes",
		roomName, targetRoomID, sorted)
}

// ─── AC4: Initial sync populates heroes for both DM rooms ────────────────────

// aliceFirstDMRoomHasSummaryMHeroesPopulated asserts dmRoomID has heroes in alice's sync.
func aliceFirstDMRoomHasSummaryMHeroesPopulated() error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[dmRoomID]
	if !ok {
		return fmt.Errorf("first DM room %q not in alice's initial sync rooms.join", dmRoomID)
	}
	if room.Summary == nil || len(room.Summary.Heroes) == 0 {
		return fmt.Errorf(
			"first DM room %q: expected summary.m.heroes populated on initial sync, got none — "+
				"Elixir GetInitialSyncResponse must include heroes",
			dmRoomID)
	}
	return nil
}

// aliceSecondDMRoomHasSummaryMHeroesPopulated asserts aliceSecondDMRoomID has heroes.
func aliceSecondDMRoomHasSummaryMHeroesPopulated() error {
	rooms, err := parseHeroSyncJoinRooms(heroesSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[aliceSecondDMRoomID]
	if !ok {
		return fmt.Errorf("second DM room %q not in alice's initial sync rooms.join", aliceSecondDMRoomID)
	}
	if room.Summary == nil || len(room.Summary.Heroes) == 0 {
		return fmt.Errorf(
			"second DM room %q: expected summary.m.heroes populated on initial sync, got none",
			aliceSecondDMRoomID)
	}
	return nil
}

// ─── Oracle edge: Delta sync omits summary when unchanged ────────────────────

// theIncrementalSyncResponseStatusIs asserts the status from the incremental sync.
func theIncrementalSyncResponseStatusIs(expected int) error {
	if lastStatusCode != expected {
		return fmt.Errorf("expected incremental sync status %d, got %d (body: %.400s)",
			expected, lastStatusCode, heroesIncrementalSyncBody)
	}
	return nil
}

// theDMRoomInIncrementalSyncResponseHasNoSummaryKey asserts that the DM room in the
// incremental sync response either does not appear (no changes) or appears without a
// summary key (delta with no membership changes → summary MAY be omitted, spec §11.2.2).
//
// THIS ASSERTION WILL FAIL until Elixir only sends summary in delta when heroes changed.
func theDMRoomInIncrementalSyncResponseHasNoSummaryKey() error {
	rooms, err := parseHeroSyncJoinRooms(heroesIncrementalSyncBody)
	if err != nil {
		return err
	}
	room, ok := rooms[dmRoomID]
	if !ok {
		// Room absent from delta → no changes → correct (summary definitely absent).
		return nil
	}
	if room.Summary == nil {
		// Room present but no summary → correct per spec.
		return nil
	}
	return fmt.Errorf(
		"delta sync must omit summary when heroes/counts unchanged, "+
			"but DM room %q has summary %+v — "+
			"Elixir must compare heroes to previous sync token before including summary",
		dmRoomID, room.Summary)
}

// ─── Step registration ────────────────────────────────────────────────────────

// initializeDirectRoomHeroesSteps registers all Godog step definitions for
// gateway/features/direct_room_heroes.feature.
// Called from InitializeScenario in steps_test.go.
func initializeDirectRoomHeroesSteps(sc *godog.ScenarioContext) {
	// AC1 — 1-on-1 DM
	sc.Step(`^bob is authenticated via OIDC$`, bobIsAuthenticated)
	sc.Step(`^alice creates a DM room with bob$`, aliceCreatesDMRoomWithBob)
	sc.Step(`^bob calls GET /sync with timeout 0$`, bobCallsGetSyncTimeout0)
	sc.Step(`^bob's sync response contains a summary for the DM room$`, bobsSyncResponseContainsSummaryForDMRoom)
	sc.Step(`^the DM room summary has m\.heroes containing "([^"]*)"$`, theDMRoomSummaryHasMHeroesContaining)
	sc.Step(`^the DM room summary does not contain "([^"]*)" in m\.heroes$`, theDMRoomSummaryDoesNotContainInMHeroes)
	sc.Step(`^the DM room summary has m\.joined_member_count (\d+)$`, theDMRoomSummaryHasMJoinedMemberCount)

	// AC2 — Group DM (charlie)
	sc.Step(`^charlie is authenticated via OIDC$`, charlieIsAuthenticated)
	sc.Step(`^alice creates a group DM room with bob and charlie$`, aliceCreatesGroupDMRoomWithBobAndCharlie)
	sc.Step(`^charlie calls GET /sync with timeout 0$`, charlieCallsGetSyncTimeout0)
	sc.Step(`^charlie's sync response contains a summary for the group DM room$`, charliesSyncResponseContainsSummaryForGroupDMRoom)
	sc.Step(`^the group DM room summary has m\.heroes containing "([^"]*)"$`, theGroupDMRoomSummaryHasMHeroesContaining)
	sc.Step(`^the group DM room summary does not contain "([^"]*)" in m\.heroes$`, theGroupDMRoomSummaryDoesNotContainInMHeroes)
	sc.Step(`^the group DM room summary has m\.joined_member_count (\d+)$`, theGroupDMRoomSummaryHasMJoinedMemberCount)

	// AC3 — Named room has no heroes
	sc.Step(`^alice creates a named room "([^"]*)" with bob$`, aliceCreatesNamedRoomWithBob)
	// Note: "alice calls GET /sync with timeout 0" is registered by
	// initializePersonalSelfRoomSteps. aliceCallsGetSyncTimeout0 now also writes to
	// heroesSyncBody so heroes assertions remain correct.
	sc.Step(`^the "([^"]*)" room in alice's sync response has no summary heroes$`, theNamedRoomInAliceSyncResponseHasNoSummaryHeroes)

	// AC4 — Initial sync heroes for both DM rooms
	sc.Step(`^alice creates a second DM room with charlie$`, aliceCreatesSecondDMRoomWithCharlie)
	sc.Step(`^alice's first DM room has summary\.m\.heroes populated$`, aliceFirstDMRoomHasSummaryMHeroesPopulated)
	sc.Step(`^alice's second DM room has summary\.m\.heroes populated$`, aliceSecondDMRoomHasSummaryMHeroesPopulated)

	// Oracle edge: delta sync omits summary
	sc.Step(`^alice captures the sync next_batch token$`, aliceCapturesSyncNextBatch)
	sc.Step(`^alice calls GET /sync with the captured since token$`, aliceCallsIncrementalSyncWithCapturedToken)
	sc.Step(`^the incremental sync response status is (\d+)$`, theIncrementalSyncResponseStatusIs)
	sc.Step(`^the DM room in the incremental sync response has no summary key$`, theDMRoomInIncrementalSyncResponseHasNoSummaryKey)
}
