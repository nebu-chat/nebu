//go:build integration

package migrations_test

// migrations_testhelper_test.go — shared test helpers for migration integration tests.
// Consolidates duplicated pgx5URL and testDBURL helpers previously found in
// migrations_042, migrations_046, and migrations_squash integration test files.

import (
	"os"
	"strings"
	"testing"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	"github.com/golang-migrate/migrate/v4/source/iofs"

	"github.com/nebu/nebu/migrations"
)

// testMigrationDBURL returns the PostgreSQL connection string for integration tests.
// Falls back to the dev Compose default if NEBU_TEST_DB_URL is not set.
func testMigrationDBURL() string {
	u := os.Getenv("NEBU_TEST_DB_URL")
	if u == "" {
		u = "postgresql://nebu_app:nebu_app_dev_pw@postgres:5432/nebu"
	}
	return u
}

// pgx5MigrationURL converts postgres:// or postgresql:// to pgx5:// for golang-migrate.
func pgx5MigrationURL(dbURL string) string {
	if strings.HasPrefix(dbURL, "postgres://") {
		return "pgx5://" + dbURL[len("postgres://"):]
	}
	if strings.HasPrefix(dbURL, "postgresql://") {
		return "pgx5://" + dbURL[len("postgresql://"):]
	}
	return dbURL
}

// newMigrate constructs a golang-migrate instance pointed at the embedded FS.
func newMigrate(t *testing.T, dbURL string) *migrate.Migrate {
	t.Helper()
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		t.Fatalf("creating migration source from embedded FS: %v", err)
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, pgx5MigrationURL(dbURL))
	if err != nil {
		t.Fatalf("connecting to database for migrations: %v", err)
	}
	return m
}
