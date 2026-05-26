package main

// loaders_test.go — Red-phase acceptance tests for bugfix-sso-bootstrap-credentials.
//
// Tests 4 and 5 from the story's Acceptance Tests section.
//
// These tests are written BEFORE the implementation exists (TDD Red Phase).
// They will fail to compile or fail at runtime until main.go gains:
//   - newServerConfigClientIDLoader (new function, mirroring newServerConfigClaimLoader)
//   - newServerConfigClientSecretLoader (new function with decryption, no envOverride shortcut)
//
// AC3: Fallback to env var when DB is empty
//   When server_config has no oidc_client_id / oidc_client_secret (pre-bootstrap
//   state), the loader falls back to the env-var value without error.
//
// AC4: 60s TTL cache
//   The DB is queried at most once per 60 seconds (inherited from claimLoader).
//
// AC5: Broken encrypted value falls back safely
//   If decryption of the stored secret fails (corrupted value), the loader
//   logs a warning and falls back to the env var — no panic, no 500 error.

import (
	"context"
	"database/sql"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/nebu/nebu/internal/admin"
)

// ── Fake ServerConfigReader for loader tests ──────────────────────────────────

// fakeConfigReader implements admin.ServerConfigReader for unit tests.
// LoadServerConfigKey returns preconfigured values or errors per key.
type fakeConfigReader struct {
	values map[string]string
	err    map[string]error
}

func newFakeConfigReader() *fakeConfigReader {
	return &fakeConfigReader{
		values: make(map[string]string),
		err:    make(map[string]error),
	}
}

func (f *fakeConfigReader) set(key, value string)       { f.values[key] = value }
func (f *fakeConfigReader) setErr(key string, e error)  { f.err[key] = e }

func (f *fakeConfigReader) LoadServerConfigKey(_ context.Context, key string) (string, error) {
	if e, ok := f.err[key]; ok {
		return "", e
	}
	v, ok := f.values[key]
	if !ok {
		return "", sql.ErrNoRows
	}
	return v, nil
}

// Unused ServerConfigReader methods — required by the interface.
func (f *fakeConfigReader) LoadOIDCConfig(_ context.Context) (string, string, string, string, error) {
	return "", "", "", "", nil
}
func (f *fakeConfigReader) CompleteBootstrap(_ context.Context) error { return nil }
func (f *fakeConfigReader) LoadAdminGroupClaim(_ context.Context) (string, error) {
	return "instance_admin", nil
}
func (f *fakeConfigReader) SaveAdminGroupClaim(_ context.Context, _ string) error { return nil }
func (f *fakeConfigReader) LoadClaimMapping(_ context.Context) (string, string, string, error) {
	return "sub", "name", "email", nil
}
func (f *fakeConfigReader) SaveClaimMapping(_ context.Context, _, _, _ string) error { return nil }

// Ensure fakeConfigReader satisfies the interface at compile time.
var _ admin.ServerConfigReader = (*fakeConfigReader)(nil)

// ── Test 4: TestServerConfigClientIDLoader ────────────────────────────────────

// TestServerConfigClientIDLoader verifies AC1 + AC3 for the client-ID loader:
//
//   - When server_config contains "db-client-id" for oidc_client_id,
//     the loader returns "db-client-id".
//   - When server_config has no value (sql.ErrNoRows), the loader falls back
//     to the provided env-var fallback value.
//
// RED PHASE: newServerConfigClientIDLoader does not yet exist in main.go.
// This test will fail to compile until the function is added.
//
// Expected signature (mirrors newServerConfigClaimLoader):
//
//	func newServerConfigClientIDLoader(reader admin.ServerConfigReader, envFallback string) *claimLoader
func TestServerConfigClientIDLoader(t *testing.T) {
	t.Parallel()

	t.Run("returns DB value when server_config has oidc_client_id", func(t *testing.T) {
		t.Parallel()

		reader := newFakeConfigReader()
		reader.set("oidc_client_id", "db-client-id")

		loader := newServerConfigClientIDLoader(reader, "env-fallback-client-id")
		ctx := context.Background()

		got := loader.get(ctx)
		if got != "db-client-id" {
			t.Errorf(
				"AC1 FAIL: expected loader to return DB value 'db-client-id', got %q\n\n"+
					"Fix: newServerConfigClientIDLoader must read oidc_client_id from server_config "+
					"and return the DB value when present.",
				got,
			)
		}
	})

	t.Run("falls back to env var when server_config has no oidc_client_id", func(t *testing.T) {
		t.Parallel()

		reader := newFakeConfigReader()
		// No oidc_client_id set → LoadServerConfigKey returns sql.ErrNoRows.

		loader := newServerConfigClientIDLoader(reader, "env-fallback-client-id")
		ctx := context.Background()

		got := loader.get(ctx)
		if got != "env-fallback-client-id" {
			t.Errorf(
				"AC3 FAIL: expected loader to return env-var fallback 'env-fallback-client-id' "+
					"when DB has no oidc_client_id, got %q\n\n"+
					"Fix: when LoadServerConfigKey returns sql.ErrNoRows (or empty string), "+
					"newServerConfigClientIDLoader must return the envFallback value.",
				got,
			)
		}
	})

	t.Run("respects 60s TTL cache — DB called at most once per TTL window", func(t *testing.T) {
		t.Parallel()

		var callCount int
		reader := newCountingConfigReader(t, map[string]func() (string, error){
			"oidc_client_id": func() (string, error) { callCount++; return "db-client-id", nil },
		})

		loader := newServerConfigClientIDLoader(reader, "env-fallback")
		// Override TTL to a short window for testing.
		loader.ttl = 50 * time.Millisecond

		ctx := context.Background()

		v1 := loader.get(ctx) // first call — fills cache
		v2 := loader.get(ctx) // second call within TTL — should hit cache

		if callCount != 1 {
			t.Errorf(
				"AC4 FAIL: expected DB to be called once within TTL window, got %d calls\n\n"+
					"Fix: newServerConfigClientIDLoader must use the claimLoader TTL-cache mechanism.",
				callCount,
			)
		}
		if v1 != "db-client-id" || v2 != "db-client-id" {
			t.Errorf("expected both calls to return 'db-client-id', got v1=%q v2=%q", v1, v2)
		}
	})
}

// ── Test 5: TestServerConfigClientSecretLoader ────────────────────────────────

// TestServerConfigClientSecretLoader verifies AC2 + AC3 + AC5 for the
// client-secret loader:
//
//   - When server_config contains a valid AES-256-GCM encrypted secret,
//     the loader decrypts it and returns the plaintext.
//   - When server_config has no value, the loader falls back to the env var.
//   - When the stored value cannot be decrypted (corrupted/tampered), the
//     loader falls back to the env var — no panic, no 500 error.
//
// RED PHASE: newServerConfigClientSecretLoader does not yet exist in main.go.
// This test will fail to compile until the function is added.
//
// Expected signature:
//
//	func newServerConfigClientSecretLoader(reader admin.ServerConfigReader, secret []byte, envFallback string) *claimLoader
func TestServerConfigClientSecretLoader(t *testing.T) {
	t.Parallel()

	// Use a deterministic AES-256-GCM key (32 bytes).
	internalSecret := []byte("test-internal-secret-32byteslong")

	t.Run("decrypts and returns plaintext when DB has valid encrypted secret", func(t *testing.T) {
		t.Parallel()

		// Encrypt "my-oidc-secret" with the internal secret — this is what the
		// bootstrap wizard stores in server_config.
		encrypted := encryptForTest(t, internalSecret, "my-oidc-secret")

		reader := newFakeConfigReader()
		reader.set("oidc_client_secret", encrypted)

		loader := newServerConfigClientSecretLoader(reader, internalSecret, "env-fallback-secret")
		ctx := context.Background()

		got := loader.get(ctx)
		if got != "my-oidc-secret" {
			t.Errorf(
				"AC2 FAIL: expected loader to decrypt and return 'my-oidc-secret', got %q\n\n"+
					"Fix: newServerConfigClientSecretLoader must call admin.DecryptAES256GCM on the "+
					"stored value using the internal secret.",
				got,
			)
		}
	})

	t.Run("falls back to env var when server_config has no oidc_client_secret", func(t *testing.T) {
		t.Parallel()

		reader := newFakeConfigReader()
		// No oidc_client_secret set → LoadServerConfigKey returns sql.ErrNoRows.

		loader := newServerConfigClientSecretLoader(reader, internalSecret, "env-fallback-secret")
		ctx := context.Background()

		got := loader.get(ctx)
		if got != "env-fallback-secret" {
			t.Errorf(
				"AC3 FAIL: expected loader to return env-var fallback 'env-fallback-secret' "+
					"when DB has no oidc_client_secret, got %q\n\n"+
					"Fix: when LoadServerConfigKey returns sql.ErrNoRows (or empty string), "+
					"newServerConfigClientSecretLoader must return the envFallback.",
				got,
			)
		}
	})

	t.Run("respects 60s TTL cache — DB called at most once per TTL window", func(t *testing.T) {
		t.Parallel()

		var callCount int
		// Encrypt a value so the loader can decrypt it successfully and count the call.
		encrypted := encryptForTest(t, internalSecret, "db-cached-secret")
		reader := newCountingConfigReader(t, map[string]func() (string, error){
			"oidc_client_secret": func() (string, error) { callCount++; return encrypted, nil },
		})

		loader := newServerConfigClientSecretLoader(reader, internalSecret, "env-fallback")
		// Override TTL to a short window for testing.
		loader.ttl = 50 * time.Millisecond

		ctx := context.Background()

		v1 := loader.get(ctx) // first call — fills cache
		v2 := loader.get(ctx) // second call within TTL — should hit cache

		if callCount != 1 {
			t.Errorf(
				"AC4 FAIL: expected DB to be called once within TTL window, got %d calls\n\n"+
					"Fix: newServerConfigClientSecretLoader must use the claimLoader TTL-cache mechanism.",
				callCount,
			)
		}
		if v1 != "db-cached-secret" || v2 != "db-cached-secret" {
			t.Errorf("expected both calls to return 'db-cached-secret', got v1=%q v2=%q", v1, v2)
		}
	})

	t.Run("falls back to env var and logs warning on corrupted encrypted value", func(t *testing.T) {
		// NOTE: t.Parallel() is intentionally omitted here.
		// This subtest calls slog.SetDefault() which mutates package-global state.
		// Running it in parallel with other subtests that also trigger slog.Warn would
		// corrupt the log capture and produce flaky assertions.

		reader := newFakeConfigReader()
		// Store a corrupted / invalid hex string that cannot be decrypted.
		reader.set("oidc_client_secret", "not-valid-hex-ciphertext-zzzzzzzz")

		// Capture slog output so we can assert the warning is emitted (MINOR-2).
		logCapture := &slogCapture{}
		originalLogger := slog.Default()
		slog.SetDefault(slog.New(logCapture))
		defer slog.SetDefault(originalLogger)

		loader := newServerConfigClientSecretLoader(reader, internalSecret, "env-fallback-secret")
		ctx := context.Background()

		// This must not panic — deferred recover is not needed; if it panics the
		// test itself fails with a panic message.
		got := loader.get(ctx)

		// AC5: corrupted value → fall back to env var, no panic.
		if got != "env-fallback-secret" {
			t.Errorf(
				"AC5 FAIL: expected loader to fall back to env-var 'env-fallback-secret' when "+
					"decryption fails (corrupted value), got %q\n\n"+
					"Fix: newServerConfigClientSecretLoader must catch decryption errors, log a "+
					"warning, and return the envFallback — never propagate the error to callers.",
				got,
			)
		}

		// MINOR-2: verify that a slog.Warn was emitted for the decryption failure.
		if !logCapture.hasWarn() {
			t.Error(
				"AC5 / MINOR-2 FAIL: expected a slog.Warn to be emitted when decryption fails, " +
					"but no Warn-level log record was captured.\n\n" +
					"Fix: newServerConfigClientSecretLoader must call slog.Warn on decryption error.",
			)
		}
	})
}

// ── Helpers ────────────────────────────────────────────────────────────────────

// countingConfigReader wraps per-key delegate functions to count LoadServerConfigKey calls.
// It satisfies admin.ServerConfigReader via embedding fakeConfigReader for unused methods.
// Use the delegates map to register expected keys; calling an unregistered key fails the test.
type countingConfigReader struct {
	fakeConfigReader
	t         *testing.T
	delegates map[string]func() (string, error)
}

// newCountingConfigReader creates a countingConfigReader that will fail the test
// if LoadServerConfigKey is called with an unexpected key.
func newCountingConfigReader(t *testing.T, delegates map[string]func() (string, error)) *countingConfigReader {
	t.Helper()
	return &countingConfigReader{t: t, delegates: delegates}
}

func (c *countingConfigReader) LoadServerConfigKey(_ context.Context, key string) (string, error) {
	fn, ok := c.delegates[key]
	if !ok {
		c.t.Errorf("countingConfigReader: unexpected key %q — register it in delegates", key)
		return "", nil
	}
	return fn()
}

var _ admin.ServerConfigReader = (*countingConfigReader)(nil)

// encryptForTest is a local helper that calls admin.EncryptAES256GCM and fails
// the test on error. Used to produce test fixtures without inline error handling.
func encryptForTest(t *testing.T, secret []byte, plaintext string) string {
	t.Helper()
	enc, err := admin.EncryptAES256GCM(secret, plaintext)
	if err != nil {
		t.Fatalf("encryptForTest: %v", err)
	}
	return enc
}

// ── slogCapture ───────────────────────────────────────────────────────────────

// slogCapture is a minimal slog.Handler that records whether any Warn-level
// records were emitted. Used by the AC5 test to assert that the decryption
// failure warning is logged.
type slogCapture struct {
	mu      sync.Mutex
	records []slog.Level
}

func (c *slogCapture) Enabled(_ context.Context, _ slog.Level) bool { return true }

func (c *slogCapture) Handle(_ context.Context, r slog.Record) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.records = append(c.records, r.Level)
	return nil
}

func (c *slogCapture) WithAttrs(_ []slog.Attr) slog.Handler  { return c }
func (c *slogCapture) WithGroup(_ string) slog.Handler        { return c }

// hasWarn reports whether at least one Warn-level record was captured.
func (c *slogCapture) hasWarn() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, lvl := range c.records {
		if lvl == slog.LevelWarn {
			return true
		}
	}
	return false
}
