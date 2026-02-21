package redirect

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaultConstants(t *testing.T) {
	if DefaultTargetPort != "15001" {
		t.Errorf("DefaultTargetPort = %q, want 15001", DefaultTargetPort)
	}
	if DefaultNoRedirectUID != "0" {
		t.Errorf("DefaultNoRedirectUID = %q, want 0", DefaultNoRedirectUID)
	}
}

func TestProgram_RequiresNodeIP(t *testing.T) {
	err := Program("/proc/self/ns/net", "", "", "", "")
	if err == nil {
		t.Fatal("Program expected to fail without nodeIP")
	}
	if !strings.Contains(err.Error(), "nodeIP is required") {
		t.Errorf("error should mention nodeIP is required, got: %v", err)
	}
}

// withFakeScript creates a temporary prysm-iptables.sh and overrides
// scriptSearchPaths so findScript resolves to it. It also puts a fake
// nsenter on PATH so exec.Command("nsenter", ...) finds it.
func withFakeScript(t *testing.T) (cleanup func()) {
	t.Helper()
	tmpDir := t.TempDir()

	// Fake nsenter that always exits 1
	fakeNsenter := filepath.Join(tmpDir, "nsenter")
	if err := os.WriteFile(fakeNsenter, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatalf("failed to create fake nsenter: %v", err)
	}

	// Fake script so findScript succeeds
	fakeScript := filepath.Join(tmpDir, "prysm-iptables.sh")
	if err := os.WriteFile(fakeScript, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatalf("failed to create fake script: %v", err)
	}

	origPaths := scriptSearchPaths
	scriptSearchPaths = []string{fakeScript}

	origEnvPath := os.Getenv("PATH")
	os.Setenv("PATH", tmpDir+string(filepath.ListSeparator)+origEnvPath)

	return func() {
		scriptSearchPaths = origPaths
		os.Setenv("PATH", origEnvPath)
	}
}

func TestProgram_DefaultsApplied(t *testing.T) {
	cleanup := withFakeScript(t)
	defer cleanup()

	// Provide nodeIP now that it's required
	err := Program("/proc/self/ns/net", "", "", "", "10.0.0.1")
	if err == nil {
		t.Fatal("Program expected to fail with fake nsenter")
	}
	if !strings.Contains(err.Error(), "prysm-iptables failed") {
		t.Errorf("error should mention prysm-iptables failed, got: %v", err)
	}
}

func TestProgram_EmptyTargetPortUsesDefault(t *testing.T) {
	cleanup := withFakeScript(t)
	defer cleanup()

	// Provide nodeIP now that it's required
	err := Program("/proc/1/ns/net", "", "0", "", "192.168.1.1")
	if err == nil {
		t.Fatal("expected error")
	}
	if err.Error() == "" {
		t.Error("expected non-empty error")
	}
}

func TestClean_BestEffort(t *testing.T) {
	cleanup := withFakeScript(t)
	defer cleanup()

	// Clean does best-effort — just ensure it doesn't panic
	Clean("/proc/1/ns/net")
}

func TestFindScript_PrefersFirstExistingPath(t *testing.T) {
	tmpDir := t.TempDir()
	primary := filepath.Join(tmpDir, "primary", "prysm-iptables.sh")
	fallback := filepath.Join(tmpDir, "fallback", "prysm-iptables.sh")

	os.MkdirAll(filepath.Dir(primary), 0755)
	os.MkdirAll(filepath.Dir(fallback), 0755)
	os.WriteFile(primary, []byte("#!/bin/sh\n"), 0755)
	os.WriteFile(fallback, []byte("#!/bin/sh\n"), 0755)

	orig := scriptSearchPaths
	defer func() { scriptSearchPaths = orig }()
	scriptSearchPaths = []string{primary, fallback}

	got, err := findScript()
	if err != nil {
		t.Fatalf("findScript failed: %v", err)
	}
	if got != primary {
		t.Errorf("findScript = %q, want %q (should prefer first path)", got, primary)
	}
}

func TestFindScript_FallsBackToSecondPath(t *testing.T) {
	tmpDir := t.TempDir()
	primary := filepath.Join(tmpDir, "primary", "prysm-iptables.sh") // does not exist
	fallback := filepath.Join(tmpDir, "fallback", "prysm-iptables.sh")

	os.MkdirAll(filepath.Dir(fallback), 0755)
	os.WriteFile(fallback, []byte("#!/bin/sh\n"), 0755)

	orig := scriptSearchPaths
	defer func() { scriptSearchPaths = orig }()
	scriptSearchPaths = []string{primary, fallback}

	got, err := findScript()
	if err != nil {
		t.Fatalf("findScript failed: %v", err)
	}
	if got != fallback {
		t.Errorf("findScript = %q, want %q (should fall back)", got, fallback)
	}
}

func TestFindScript_ErrorWhenNoneExist(t *testing.T) {
	orig := scriptSearchPaths
	defer func() { scriptSearchPaths = orig }()
	scriptSearchPaths = []string{"/nonexistent/a", "/nonexistent/b"}

	_, err := findScript()
	if err == nil {
		t.Fatal("findScript should fail when no paths exist")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Errorf("error should mention 'not found', got: %v", err)
	}
}

func TestCheck_FailsWithFakeNsenter(t *testing.T) {
	// Check runs iptables -L in the netns — with a fake nsenter it should fail
	tmpDir := t.TempDir()
	fakeNsenter := filepath.Join(tmpDir, "nsenter")
	if err := os.WriteFile(fakeNsenter, []byte("#!/bin/sh\necho 'no chain'\nexit 1\n"), 0755); err != nil {
		t.Fatalf("failed to create fake nsenter: %v", err)
	}
	origPath := os.Getenv("PATH")
	os.Setenv("PATH", tmpDir+string(filepath.ListSeparator)+origPath)
	defer os.Setenv("PATH", origPath)

	err := Check("/proc/self/ns/net")
	if err == nil {
		t.Fatal("Check should fail when iptables chain doesn't exist")
	}
	if !strings.Contains(err.Error(), "redirect rules missing") {
		t.Errorf("error should mention 'redirect rules missing', got: %v", err)
	}
}
