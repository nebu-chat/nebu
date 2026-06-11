package migrations_test

import (
	"io/fs"
	"testing"

	"github.com/nebu/nebu/migrations"
)

func TestFS_ContainsExpectedMigrationFiles(t *testing.T) {
	// Verify the embedded FS contains exactly the expected migration files.
	// 000001_init: squashed baseline (Story 13.14)
	// 000002_add_missing_structures: idempotent catch-up for pre-squash instances (bugfix/fix-room-management-error)
	// 000003_compliance_rls_hardening: restrict UPDATE policies on compliance tables (bugfix/fix-compliance-rls-policies)
	files := []string{
		"000001_init.up.sql",
		"000001_init.down.sql",
		"000002_add_missing_structures.up.sql",
		"000002_add_missing_structures.down.sql",
		"000003_compliance_rls_hardening.up.sql",
		"000003_compliance_rls_hardening.down.sql",
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
	// The embedded FS must contain exactly these four files — no more, no less.
	// 000001_init: squashed baseline (Story 13.14)
	// 000002_add_missing_structures: idempotent catch-up for pre-squash instances
	// Any other file would indicate an unintended legacy migration was re-introduced.
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		t.Fatalf("fs.ReadDir embedded FS root: %v", err)
	}

	want := map[string]bool{
		"000001_init.up.sql":                        true,
		"000001_init.down.sql":                      true,
		"000002_add_missing_structures.up.sql":      true,
		"000002_add_missing_structures.down.sql":    true,
		"000003_compliance_rls_hardening.up.sql":    true,
		"000003_compliance_rls_hardening.down.sql":  true,
	}

	for _, e := range entries {
		name := e.Name()
		if !want[name] {
			t.Errorf("unexpected file in embedded FS: %q — only the six expected migration files should be present", name)
		}
	}

	if got := len(entries); got != len(want) {
		t.Errorf("embedded FS contains %d file(s), expected exactly %d", got, len(want))
	}
}
