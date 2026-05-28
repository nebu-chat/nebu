//go:build integration

package integration_test

// ─── Bugfix: room list not updated after leave ────────────────────────────────
//
// Godog step definitions for gateway/features/room_leave.feature.
// Written FIRST (ATDD red-phase) — tests cover:
//
//   AC1: Leaving a room removes it from rooms.join in initial sync.
//   AC2: Left room appears in rooms.leave with m.room.member membership:"leave"
//        on the first incremental sync after leave.
//   AC3 (observable): POST /leave returns 200 and room is absent from initial sync
//        even in fallback scenarios (GenServer not running). The Core-level assertion
//        (left_at IS SET in room_members) is covered by leave_room_test.exs.
//
// Shared state (declared in room_flow_steps_test.go):
//   kaiAccessToken, kaiUserID, alexAccessToken, alexUserID — set by auth steps.
//   lastRoomID — set by kaiCreatesARoom.
//
// New state local to this file:
//   alexPreLeaveSyncToken   — captured before POST /leave
//   alexInitialSyncBody     — body from GET /sync (no since)
//   alexIncrementalSyncBody — body from GET /sync?since=<pre-leave-token>

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/cucumber/godog"
)

// alexPreLeaveSyncToken holds the since token captured by alex before calling /leave.
var alexPreLeaveSyncToken string

// alexInitialSyncBody holds the response body from alex's initial sync (no since).
var alexInitialSyncBody string

// alexLeaveIncrementalSyncBody holds the response body from alex's incremental sync after leave.
var alexLeaveIncrementalSyncBody string

// alexCapturesSyncTokenBeforeLeaving polls GET /sync?timeout=0 as alex until the room
// appears in rooms.join (confirming Core has persisted the join), then stores next_batch.
// This prevents a race where the join broadcast hasn't been processed by Core yet.
// Retries up to 5 times with 300ms between attempts.
func alexCapturesSyncTokenBeforeLeaving() error {
	const maxAttempts = 5
	const retryDelay = 300 * time.Millisecond

	for attempt := 0; attempt < maxAttempts; attempt++ {
		req, err := http.NewRequest(http.MethodGet,
			matrixURL+"/_matrix/client/v3/sync?timeout=0", nil)
		if err != nil {
			return fmt.Errorf("building sync request: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+alexAccessToken)

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return fmt.Errorf("GET /sync (pre-leave, attempt %d): %w", attempt+1, err)
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return fmt.Errorf("reading pre-leave sync body (attempt %d): %w", attempt+1, err)
		}
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("pre-leave sync returned %d (attempt %d): %s", resp.StatusCode, attempt+1, string(body))
		}

		var syncResp struct {
			NextBatch string `json:"next_batch"`
			Rooms     struct {
				Join map[string]json.RawMessage `json:"join"`
			} `json:"rooms"`
		}
		if err := json.Unmarshal(body, &syncResp); err != nil || syncResp.NextBatch == "" {
			return fmt.Errorf("no next_batch in pre-leave sync (attempt %d): %s", attempt+1, string(body))
		}

		// Only capture the token once the room is confirmed to be in rooms.join.
		// This ensures Core has processed the join before we proceed to leave.
		if _, ok := syncResp.Rooms.Join[lastRoomID]; ok {
			alexPreLeaveSyncToken = syncResp.NextBatch
			return nil
		}

		// Room not in rooms.join yet — wait and retry.
		time.Sleep(retryDelay)
	}

	return fmt.Errorf("room %q did not appear in rooms.join after %d attempts — Core may not have processed the join yet", lastRoomID, maxAttempts)
}

// alexCallsPostLeave calls POST /_matrix/client/v3/rooms/{lastRoomID}/leave as alex.
// Stores lastStatusCode / lastBody.
func alexCallsPostLeave() error {
	url := fmt.Sprintf("%s/_matrix/client/v3/rooms/%s/leave", matrixURL, lastRoomID)
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader("{}"))
	if err != nil {
		return fmt.Errorf("building POST /leave request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+alexAccessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /leave failed: %w", err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading POST /leave response: %w", err)
	}
	lastStatusCode = resp.StatusCode
	lastBody = string(respBody)
	return nil
}

// alexCallsInitialSyncWithoutSinceToken calls GET /sync?timeout=0 (no since parameter)
// as alex and stores the response in alexInitialSyncBody.
// This simulates the "next login" scenario: a fresh initial sync.
func alexCallsInitialSyncWithoutSinceToken() error {
	req, err := http.NewRequest(http.MethodGet,
		matrixURL+"/_matrix/client/v3/sync?timeout=0", nil)
	if err != nil {
		return fmt.Errorf("building initial sync request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+alexAccessToken)

	// Retry up to 3 times to allow Core to process the leave event.
	var body []byte
	var statusCode int
	for i := 0; i < 3; i++ {
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return fmt.Errorf("GET /sync (initial, no since): %w", err)
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		statusCode = resp.StatusCode
		if statusCode == http.StatusOK {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if statusCode != http.StatusOK {
		return fmt.Errorf("initial sync returned %d: %s", statusCode, string(body))
	}
	alexInitialSyncBody = string(body)
	return nil
}

// alexCallsIncrementalSyncWithPreLeaveToken calls GET /sync?since=<pre-leave-token>&timeout=0
// as alex. This is the incremental sync that should deliver the leave event.
func alexCallsIncrementalSyncWithPreLeaveToken() error {
	if alexPreLeaveSyncToken == "" {
		return fmt.Errorf("alexPreLeaveSyncToken is empty — did alex capture a sync token before leaving?")
	}
	url := fmt.Sprintf("%s/_matrix/client/v3/sync?since=%s&timeout=0",
		matrixURL, alexPreLeaveSyncToken)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("building incremental sync request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+alexAccessToken)

	// Retry up to 5 times — the leave event must be persisted before the sync returns it.
	var body []byte
	var statusCode int
	for i := 0; i < 5; i++ {
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return fmt.Errorf("GET /sync (incremental, post-leave): %w", err)
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		statusCode = resp.StatusCode
		if statusCode == http.StatusOK {
			// Check if rooms.leave already contains the room — if not, retry briefly.
			var syncResp struct {
				Rooms struct {
					Leave map[string]json.RawMessage `json:"leave"`
				} `json:"rooms"`
			}
			if err2 := json.Unmarshal(body, &syncResp); err2 == nil {
				if _, ok := syncResp.Rooms.Leave[lastRoomID]; ok {
					break
				}
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	if statusCode != http.StatusOK {
		return fmt.Errorf("incremental sync returned %d: %s", statusCode, string(body))
	}
	alexLeaveIncrementalSyncBody = string(body)
	return nil
}

// ─── Assertion helpers ────────────────────────────────────────────────────────

// theInitialSyncDoesNotContainLeftRoomInJoin asserts that lastRoomID is absent
// from rooms.join in alex's initial sync response.
//
// AC1: rooms.join MUST NOT contain a room the user has left.
// Matrix spec §GET /sync: only rooms with current membership = "join" appear here.
//
// This assertion FAILS with the current bug because room_members.left_at stays NULL,
// so get_rooms_for_user (which filters WHERE left_at IS NULL) still returns the room.
func theInitialSyncDoesNotContainLeftRoomInJoin() error {
	var syncResp struct {
		Rooms struct {
			Join map[string]json.RawMessage `json:"join"`
		} `json:"rooms"`
	}
	if err := json.Unmarshal([]byte(alexInitialSyncBody), &syncResp); err != nil {
		return fmt.Errorf("parsing initial sync body: %w (body: %s)", err, alexInitialSyncBody)
	}
	if _, ok := syncResp.Rooms.Join[lastRoomID]; ok {
		return fmt.Errorf(
			"AC1 FAILED: room %q is still present in rooms.join after POST /leave.\n"+
				"This is the bug: room_members.left_at was NOT set, so get_rooms_for_user "+
				"(WHERE left_at IS NULL) still returns the room.\n"+
				"Fix: ensure Server.leave_room/2 calls rooms_db_module().delete_member/2 "+
				"on ALL code paths.\nInitial sync body: %s",
			lastRoomID, alexInitialSyncBody,
		)
	}
	return nil
}

// theIncrementalSyncContainsLeftRoomInLeave asserts that lastRoomID is present
// in rooms.leave in alex's incremental sync response.
//
// AC2: rooms.leave MUST contain the left room on the first incremental sync after leave.
func theIncrementalSyncContainsLeftRoomInLeave() error {
	var syncResp struct {
		Rooms struct {
			Leave map[string]json.RawMessage `json:"leave"`
		} `json:"rooms"`
	}
	if err := json.Unmarshal([]byte(alexLeaveIncrementalSyncBody), &syncResp); err != nil {
		return fmt.Errorf("parsing incremental sync body: %w (body: %s)", err, alexLeaveIncrementalSyncBody)
	}
	if _, ok := syncResp.Rooms.Leave[lastRoomID]; !ok {
		return fmt.Errorf(
			"AC2 FAILED: room %q is absent from rooms.leave on the first incremental sync after leave.\n"+
				"Expected rooms.leave to contain the room with an m.room.member leave event.\n"+
				"Incremental sync body: %s",
			lastRoomID, alexLeaveIncrementalSyncBody,
		)
	}
	return nil
}

// theRoomsLeaveEntryContainsMemberLeaveEvent asserts that the rooms.leave entry for
// lastRoomID contains at least one m.room.member event with:
//   - membership matching expectedMembership
//   - state_key matching alexUserID (ensures the event is for alex, not another member)
//
// AC2: The rooms.leave section must include the m.room.member leave state event for alex.
func theRoomsLeaveEntryContainsMemberLeaveEvent(expectedMembership string) error {
	var syncResp struct {
		Rooms struct {
			Leave map[string]struct {
				Timeline struct {
					Events []struct {
						Type       string `json:"type"`
						StateKey   string `json:"state_key"`
						Content    struct {
							Membership string `json:"membership"`
						} `json:"content"`
					} `json:"events"`
				} `json:"timeline"`
				State struct {
					Events []struct {
						Type     string `json:"type"`
						StateKey string `json:"state_key"`
						Content  struct {
							Membership string `json:"membership"`
						} `json:"content"`
					} `json:"events"`
				} `json:"state"`
			} `json:"leave"`
		} `json:"rooms"`
	}
	if err := json.Unmarshal([]byte(alexLeaveIncrementalSyncBody), &syncResp); err != nil {
		return fmt.Errorf("parsing incremental sync for member events: %w (body: %s)", err, alexLeaveIncrementalSyncBody)
	}

	leaveRoom, ok := syncResp.Rooms.Leave[lastRoomID]
	if !ok {
		return fmt.Errorf("room %q not in rooms.leave — run the previous assertion first", lastRoomID)
	}

	// Check timeline events.
	for _, ev := range leaveRoom.Timeline.Events {
		if ev.Type == "m.room.member" && ev.Content.Membership == expectedMembership && ev.StateKey == alexUserID {
			return nil
		}
	}

	// Check state events.
	for _, ev := range leaveRoom.State.Events {
		if ev.Type == "m.room.member" && ev.Content.Membership == expectedMembership && ev.StateKey == alexUserID {
			return nil
		}
	}

	return fmt.Errorf(
		"AC2 FAILED: rooms.leave entry for %q has no m.room.member event with membership=%q and state_key=%q.\n"+
			"Timeline events: %v\nState events: %v\nFull sync body: %s",
		lastRoomID, expectedMembership, alexUserID,
		leaveRoom.Timeline.Events, leaveRoom.State.Events,
		alexLeaveIncrementalSyncBody,
	)
}

// ─── Step registration ────────────────────────────────────────────────────────

// initializeRoomLeaveSteps registers all step definitions for room_leave.feature.
// Called from InitializeScenario in steps_test.go.
func initializeRoomLeaveSteps(sc *godog.ScenarioContext) {
	sc.Step(`^alex captures a sync token before leaving$`, alexCapturesSyncTokenBeforeLeaving)
	sc.Step(`^alex calls POST /leave on the room$`, alexCallsPostLeave)
	sc.Step(`^alex calls initial sync without a since token$`, alexCallsInitialSyncWithoutSinceToken)
	sc.Step(`^the initial sync does not contain the left room in rooms\.join$`, theInitialSyncDoesNotContainLeftRoomInJoin)
	sc.Step(`^alex calls incremental sync with the captured pre-leave token$`, alexCallsIncrementalSyncWithPreLeaveToken)
	sc.Step(`^the incremental sync contains the left room in rooms\.leave$`, theIncrementalSyncContainsLeftRoomInLeave)
	sc.Step(`^the rooms\.leave entry contains an m\.room\.member event with membership "([^"]*)"$`, theRoomsLeaveEntryContainsMemberLeaveEvent)
}
