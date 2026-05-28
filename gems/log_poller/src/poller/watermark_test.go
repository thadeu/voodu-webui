package poller

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWatermark_MissingFileReturnsColdStart(t *testing.T) {
	root := t.TempDir()

	got, err := ReadWatermark(root, "isl-1", "pod-a")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}

	expected := time.Now().Add(-ColdStartLookback)
	delta := got.Sub(expected)
	if delta < -2*time.Second || delta > 2*time.Second {
		t.Fatalf("cold-start watermark %v drifted too far from expected %v (delta=%v)", got, expected, delta)
	}
}

func TestWatermark_WriteThenReadRoundTrip(t *testing.T) {
	root := t.TempDir()

	want := time.Date(2026, 5, 28, 12, 34, 56, 789000000, time.UTC)
	if err := WriteWatermark(root, "isl-1", "pod-a", want); err != nil {
		t.Fatalf("write: %v", err)
	}

	got, err := ReadWatermark(root, "isl-1", "pod-a")
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	if !got.Equal(want) {
		t.Fatalf("roundtrip: got %v, want %v", got, want)
	}
}

func TestWatermark_AtomicRename_NoTmpLeft(t *testing.T) {
	root := t.TempDir()

	if err := WriteWatermark(root, "isl-1", "pod-a", time.Now()); err != nil {
		t.Fatalf("write: %v", err)
	}

	dir := filepath.Join(root, "isl-1", "pod-a")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}

	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("leftover tmp file after atomic write: %s", e.Name())
		}
	}
}

func TestWatermark_CorruptFileFallsBackToColdStart(t *testing.T) {
	root := t.TempDir()

	dir := filepath.Join(root, "isl-1", "pod-a")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".watermark"), []byte("not-a-timestamp"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := ReadWatermark(root, "isl-1", "pod-a")
	if err != nil {
		t.Fatalf("err: %v", err)
	}

	expected := time.Now().Add(-ColdStartLookback)
	delta := got.Sub(expected)
	if delta < -2*time.Second || delta > 2*time.Second {
		t.Fatalf("corrupt-file watermark %v drifted too far from cold-start expected %v", got, expected)
	}
}

func TestSafePodName(t *testing.T) {
	cases := map[string]string{
		"":                   "_unknown",
		"newcall-api.e41c":   "newcall-api.e41c",
		"pod/with/slash":     "pod_with_slash",
		"weird ! chars#here": "weird___chars_here",
	}

	for in, want := range cases {
		if got := safePodName(in); got != want {
			t.Errorf("safePodName(%q)=%q, want %q", in, got, want)
		}
	}
}
