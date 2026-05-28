package poller

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Watermark — per-pod sidecar file recording the timestamp of the
// last line persisted to NDJSON for that pod.
//
// File path: storage/logs/<island>/<pod>/.watermark
// Wire format: a single RFC3339Nano string, no trailing newline.
//
// We write via temp + atomic rename to avoid torn reads if the binary
// crashes mid-write. The reader tolerates a missing file (cold start)
// by returning `now - 5 minutes`, so a fresh deploy backfills 5min of
// recent history before catching up.

// ColdStartLookback is how far back to start reading on a brand-new
// pod (no watermark file). 5 minutes is enough to catch the tail of
// what the controller has cached without overwhelming the NDJSON.
const ColdStartLookback = 5 * time.Minute

// watermarkPath returns the absolute path of the sidecar file for the
// given (root, island, pod). Caller is responsible for ensuring the
// pod directory exists before calling WriteWatermark.
func watermarkPath(root, islandID, pod string) string {
	return filepath.Join(root, islandID, safePodName(pod), ".watermark")
}

// ReadWatermark loads the timestamp from disk. Missing file is NOT an
// error — we return `time.Now().Add(-ColdStartLookback)` instead, so
// the caller does not have to special-case cold starts.
func ReadWatermark(root, islandID, pod string) (time.Time, error) {
	path := watermarkPath(root, islandID, pod)

	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return time.Now().Add(-ColdStartLookback), nil
		}

		return time.Time{}, fmt.Errorf("read watermark %s: %w", path, err)
	}

	t, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(string(raw)))
	if err != nil {
		// Corrupt watermark — treat as cold start rather than wedge.
		return time.Now().Add(-ColdStartLookback), nil
	}

	return t, nil
}

// WriteWatermark persists `t` for the given pod. Atomic:
//  1. write to .watermark.tmp
//  2. fsync
//  3. rename to .watermark (atomic on POSIX)
//
// The pod directory must exist; the writer.go path ensures this on the
// hot path (it mkdirs before opening the NDJSON file).
func WriteWatermark(root, islandID, pod string, t time.Time) error {
	dir := filepath.Join(root, islandID, safePodName(pod))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir watermark dir: %w", err)
	}

	final := filepath.Join(dir, ".watermark")
	tmp := final + ".tmp"

	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("open watermark tmp: %w", err)
	}

	if _, err := f.WriteString(t.UTC().Format(time.RFC3339Nano)); err != nil {
		f.Close()
		os.Remove(tmp)

		return fmt.Errorf("write watermark tmp: %w", err)
	}

	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)

		return fmt.Errorf("sync watermark tmp: %w", err)
	}

	if err := f.Close(); err != nil {
		os.Remove(tmp)

		return fmt.Errorf("close watermark tmp: %w", err)
	}

	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)

		return fmt.Errorf("rename watermark: %w", err)
	}

	return nil
}

// safePodName mirrors Ruby's LogTail::FilePath#safe_pod_name —
// alphanumeric + `_.-` only, anything else becomes `_`. Empty → `_unknown`.
// Keep this in sync with the Ruby version.
func safePodName(raw string) string {
	if raw == "" {
		return "_unknown"
	}

	out := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		isAlnum := (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
		if isAlnum || c == '_' || c == '.' || c == '-' {
			out = append(out, c)
		} else {
			out = append(out, '_')
		}
	}

	if len(out) == 0 {
		return "_unknown"
	}

	return string(out)
}
