package migrations_test

import (
	"io/fs"
	"testing"

	"github.com/nebu/nebu/migrations"
)

func TestFS_ContainsExpectedMigrationFiles(t *testing.T) {
	// Verify the embedded FS contains the squashed migration files only.
	// After Story 13.14 squash: all 49 migrations are combined into a single 000001_init.
	files := []string{
		"000001_init.up.sql",
		"000001_init.down.sql",
	}

	for _, name := range files {
		_, err := migrations.FS.Open(name)
		if err != nil {
			t.Errorf("embedded FS missing required file %q: %v", name, err)
		}
	}
}

func TestFS_UpMigrationIsNotEmpty(t *testing.T) {
	// The squashed up migration must not be empty — it creates the full schema.
	f, err := migrations.FS.Open("000001_init.up.sql")
	if err != nil {
		t.Fatalf("cannot open 000001_init.up.sql: %v", err)
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		t.Fatalf("cannot stat 000001_init.up.sql: %v", err)
	}

	if stat.Size() == 0 {
		t.Error("000001_init.up.sql must not be empty")
	}
}

func TestFS_NoLegacyMigrationFiles(t *testing.T) {
	// After Story 13.14 squash, the embedded FS must contain exactly two files:
	// 000001_init.up.sql and 000001_init.down.sql.
	// Any other file would cause golang-migrate to attempt unexpected migrations.
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		t.Fatalf("fs.ReadDir embedded FS root: %v", err)
	}

	want := map[string]bool{
		"000001_init.up.sql":   true,
		"000001_init.down.sql": true,
	}

	for _, e := range entries {
		name := e.Name()
		if !want[name] {
			t.Errorf("unexpected file in embedded FS: %q — only 000001_init.up.sql and 000001_init.down.sql are expected after squash", name)
		}
	}

	if got := len(entries); got != len(want) {
		t.Errorf("embedded FS contains %d file(s), expected exactly %d", got, len(want))
	}
}
