package poller

import (
	"bufio"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/voodu/poller/client"
)

// nopMetrics satisfies the Metrics interface for tests that exercise the
// dedup/write path without an observability backend.
type nopMetrics struct{}

func (nopMetrics) LinesIncr(string, int)            {}
func (nopMetrics) PollIncr(string)                  {}
func (nopMetrics) ErrorIncr(string)                 {}
func (nopMetrics) WatermarkAge(string, time.Duration) {}
func (nopMetrics) CapHitIncr(string, string)        {}
func (nopMetrics) SetLastPoll(time.Time)            {}

// applyLines mirrors the per-line core of IslandPoller.tick (parse →
// hash → ring dedup → append). It deliberately omits the HTTP fetch and
// watermark bump, which are irrelevant to dedup, so the test can drive
// the real lineHash + ringFor (disk-seeded) + Writer.Append seam.
// Returns the number of lines actually written to disk.
func applyLines(t *testing.T, p *IslandPoller, rawLines [][]byte) int {
	t.Helper()

	written := 0
	for _, raw := range rawLines {
		pod, ts, msg, ok := client.ParseLine(raw)
		if !ok {
			continue
		}

		if pod == "" {
			pod = "unknown"
		}

		if ts.IsZero() {
			ts = time.Now()
		}

		ring := p.ringFor(pod)
		h := lineHash(pod, ts, msg)
		if ring.Seen(h) {
			continue
		}

		ring.Record(h)

		rec := Record{Pod: pod, TS: ts, Msg: msg, Raw: string(raw)}
		if err := p.Writer.Append(p.Island.ID, pod, rec); err != nil {
			t.Fatalf("append: %v", err)
		}

		written++
	}

	return written
}

func countLines(t *testing.T, path string) int {
	t.Helper()

	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer f.Close()

	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		n++
	}

	return n
}

// TestSeedRing_DedupesReTailAcrossRestart is the regression pin for the
// duplicate-blocks bug: a poller restart used to re-append every line
// the `since=oldestWatermark` overlap re-delivered, because the
// in-memory ring started empty. Seeding the ring from the on-disk tail
// must make that re-tail a no-op — exactly one persisted copy per line.
func TestSeedRing_DedupesReTailAcrossRestart(t *testing.T) {
	root := t.TempDir()
	w := NewWriter(root, nil)
	island := client.Island{ID: "isl-1"}
	pod := "fsw-adapter.9031"

	// Build a batch of distinct lines stamped "today" (UTC) so seedRing,
	// which reads today + yesterday, covers them. Wire shape matches the
	// controller's multi-pod fan-out: "[pod] <RFC3339Nano> <msg>".
	base := time.Now().UTC().Add(-30 * time.Second)
	var lines [][]byte
	for i := 0; i < 25; i++ {
		ts := base.Add(time.Duration(i) * time.Second)
		msg := fmt.Sprintf(`{"level":"INFO","msg":"redirectgroup attempt %d failed"}`, i)
		lines = append(lines, []byte(fmt.Sprintf("[%s] %s %s", pod, ts.Format(time.RFC3339Nano), msg)))
	}

	// Process A: cold ring, everything is new and gets written.
	pA := NewIslandPoller(island, root, time.Minute, w, nopMetrics{})
	if got := applyLines(t, pA, lines); got != len(lines) {
		t.Fatalf("first pass wrote %d lines, want %d", got, len(lines))
	}

	// Process B: fresh poller (restart) re-fetches the SAME lines (the
	// since=oldestWatermark overlap). With disk-seeding, none are
	// re-written.
	pB := NewIslandPoller(island, root, time.Minute, w, nopMetrics{})
	if got := applyLines(t, pB, lines); got != 0 {
		t.Fatalf("re-tail after restart wrote %d duplicate lines, want 0", got)
	}

	// And the day file holds exactly one copy of each line.
	path := w.DailyFile(island.ID, pod, base)
	if got := countLines(t, path); got != len(lines) {
		t.Fatalf("day file has %d lines, want %d (duplicates persisted)", got, len(lines))
	}
}

// TestSeedRing_DedupesAcrossDayFiles pins that the seed covers lines
// spanning more than the current day — a low-volume pod's `tail=500`
// re-fetch after a restart can re-deliver several days of lines, and
// all of them must be recognised, not just today's.
func TestSeedRing_DedupesAcrossDayFiles(t *testing.T) {
	root := t.TempDir()
	w := NewWriter(root, nil)
	island := client.Island{ID: "isl-1"}
	pod := "fsw-events.48b6"

	// Lines on three consecutive UTC days.
	now := time.Now().UTC().Add(-1 * time.Minute)
	days := []time.Time{now.AddDate(0, 0, -2), now.AddDate(0, 0, -1), now}

	var lines [][]byte
	for d, day := range days {
		for i := 0; i < 5; i++ {
			ts := day.Add(time.Duration(i) * time.Second)
			msg := fmt.Sprintf(`{"msg":"day%d line%d"}`, d, i)
			lines = append(lines, []byte(fmt.Sprintf("[%s] %s %s", pod, ts.Format(time.RFC3339Nano), msg)))
		}
	}

	pA := NewIslandPoller(island, root, time.Minute, w, nopMetrics{})
	if got := applyLines(t, pA, lines); got != len(lines) {
		t.Fatalf("first pass wrote %d, want %d", got, len(lines))
	}

	pB := NewIslandPoller(island, root, time.Minute, w, nopMetrics{})
	if got := applyLines(t, pB, lines); got != 0 {
		t.Fatalf("multi-day re-tail wrote %d duplicates, want 0", got)
	}

	for d, day := range days {
		path := w.DailyFile(island.ID, pod, day)
		if got := countLines(t, path); got != 5 {
			t.Fatalf("day %d file has %d lines, want 5 (duplicates persisted)", d, got)
		}
	}
}

// TestSeedRing_HashRoundTripsThroughNDJSON pins the subtle requirement
// that a timestamp parsed fresh from the wire hashes identically to the
// same timestamp after a JSON round-trip through the NDJSON file —
// otherwise the disk seed would never match a re-fetched line.
func TestSeedRing_HashRoundTripsThroughNDJSON(t *testing.T) {
	root := t.TempDir()
	w := NewWriter(root, nil)
	island := client.Island{ID: "isl-1"}
	pod := "fsw-controller.e1e1"

	ts := time.Now().UTC()
	msg := `{"level":"INFO","msg":"record-to-s3 ok"}`
	wantHash := lineHash(pod, ts, msg)

	if err := w.Append(island.ID, pod, Record{Pod: pod, TS: ts, Msg: msg, Raw: "raw"}); err != nil {
		t.Fatalf("append: %v", err)
	}

	p := NewIslandPoller(island, root, time.Minute, w, nopMetrics{})
	ring := p.ringFor(pod) // lazily created → seeded from disk

	if !ring.Seen(wantHash) {
		t.Fatal("seeded ring did not recognise the persisted line — ts hash did not round-trip through NDJSON")
	}
}
