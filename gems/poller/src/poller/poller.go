package poller

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/voodu/poller/client"
)

// Metrics is the callback bundle main.go hands to each island poller.
// Implementations live in observability/server.go.
//
// All callbacks must be safe for concurrent use — the poller calls
// them from per-island goroutines.
type Metrics interface {
	LinesIncr(islandID string, n int)
	PollIncr(islandID string)
	ErrorIncr(islandID string)
	WatermarkAge(islandID string, age time.Duration)
	CapHitIncr(islandID, pod string)
	SetLastPoll(t time.Time)
}

// IslandPoller owns one island's goroutine.
type IslandPoller struct {
	Island   client.Island
	Root     string
	Interval time.Duration
	Voodu    *client.VooduClient
	Writer   *Writer
	Metrics  Metrics

	// Verbose toggles a per-tick summary log line (one per island per
	// tick: counts + elapsed). Errors + lifecycle events still log
	// regardless. Wired from `POLLER_VERBOSE=1` in main.go.
	Verbose bool

	// One DedupRing per pod (created lazily as new pod names appear).
	mu    sync.Mutex
	rings map[string]*DedupRing
}

// DedupRingCapacity is the per-pod sliding window. Keep at 5000 —
// roughly ten minutes of high-volume traffic, leaving headroom for
// `tail=500` repeats across consecutive polls.
const DedupRingCapacity = 5000

// NewIslandPoller wires together an island descriptor and the shared
// dependencies. Does NOT spawn the goroutine — call Run.
func NewIslandPoller(island client.Island, root string, interval time.Duration, w *Writer, m Metrics) *IslandPoller {
	return &IslandPoller{
		Island:   island,
		Root:     root,
		Interval: interval,
		Voodu:    client.NewVooduClient(island.Endpoint, island.PAT),
		Writer:   w,
		Metrics:  m,
		rings:    map[string]*DedupRing{},
	}
}

func (p *IslandPoller) ringFor(pod string) *DedupRing {
	p.mu.Lock()
	defer p.mu.Unlock()

	if r, ok := p.rings[pod]; ok {
		return r
	}

	r := NewDedupRing(DedupRingCapacity)
	p.rings[pod] = r

	return r
}

// Run blocks until ctx is cancelled. Takes the per-island writer lock
// on startup and holds it for the lifetime of the goroutine; if the
// lock is already held (e.g. legacy Ruby tail job mid-rollout), Run
// logs and returns immediately — main.go can retry next refresh tick.
//
// Per-tick behaviour:
//   - read watermark for each known pod
//   - GET /logs?since=<oldest watermark or now-5m>
//   - parse + dedup + write
//   - bump watermarks
func (p *IslandPoller) Run(ctx context.Context) {
	lockPath, unlock, err := p.acquireIslandLock()
	if err != nil {
		log.Printf("[poller] %s: lock failed (%v) — skipping this run", p.Island.ID, err)

		return
	}
	defer unlock()
	defer os.Remove(lockPath) // best-effort cleanup so stale flocks do not linger across restarts

	t := time.NewTicker(p.Interval)
	defer t.Stop()

	// First tick immediately, then on cadence.
	p.tick(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.tick(ctx)
		}
	}
}

// acquireIslandLock takes an exclusive non-blocking flock on
// storage/logs/<island>/.writer.lock. Returns the unlock fn AND the
// path so the caller can remove the file on shutdown.
func (p *IslandPoller) acquireIslandLock() (string, func(), error) {
	dir := filepath.Join(p.Root, p.Island.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", nil, fmt.Errorf("mkdir island dir: %w", err)
	}

	path := filepath.Join(dir, ".writer.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return "", nil, fmt.Errorf("open lock file: %w", err)
	}

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()

		return "", nil, fmt.Errorf("flock: %w", err)
	}

	unlock := func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}

	return path, unlock, nil
}

// tick runs one poll. Errors are logged + counted but never propagated
// — the goroutine carries on into the next tick.
func (p *IslandPoller) tick(ctx context.Context) {
	start := time.Now()
	p.Metrics.PollIncr(p.Island.ID)
	p.Metrics.SetLastPoll(start)

	// We pull `since` per pod, but the controller endpoint takes a
	// single `since` for the whole multiplexed stream. Use the OLDEST
	// known watermark across known pods so no pod's lines are skipped.
	// On cold start (no known pods) we fall back to now-5m.
	since := p.oldestWatermark()

	body, err := p.Voodu.FetchLogs(ctx, since)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}

		log.Printf("[poller] %s: fetch failed: %v", p.Island.ID, err)
		p.Metrics.ErrorIncr(p.Island.ID)

		return
	}
	defer body.Close()

	written := 0
	scanned := 0
	deduped := 0
	latest := map[string]time.Time{} // pod -> max ts seen this tick

	scanner := bufio.NewScanner(body)
	// Long log lines blow past bufio's default 64KB token. Bump to 1MB.
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		raw := scanner.Bytes()
		pod, ts, msg, ok := client.ParseLine(raw)
		if !ok {
			continue
		}
		scanned++
		if pod == "" {
			pod = "unknown"
		}
		if ts.IsZero() {
			ts = time.Now()
		}

		h := xxhash.Sum64String(pod + "|" + ts.Format(time.RFC3339Nano) + "|" + msg)
		ring := p.ringFor(pod)
		if ring.Seen(h) {
			deduped++
			continue
		}
		ring.Record(h)

		rec := Record{
			Pod: pod,
			TS:  ts,
			Msg: msg,
			Raw: string(raw),
		}
		if err := p.Writer.Append(p.Island.ID, pod, rec); err != nil {
			log.Printf("[poller] %s/%s: append failed: %v", p.Island.ID, pod, err)
			p.Metrics.ErrorIncr(p.Island.ID)

			continue
		}

		written++

		if cur, ok := latest[pod]; !ok || ts.After(cur) {
			latest[pod] = ts
		}
	}

	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		log.Printf("[poller] %s: scan error: %v", p.Island.ID, err)
		p.Metrics.ErrorIncr(p.Island.ID)
	}

	// Bump watermarks AFTER all appends so a crash mid-tick replays
	// the dropped suffix on next run.
	for pod, ts := range latest {
		if err := WriteWatermark(p.Root, p.Island.ID, pod, ts); err != nil {
			log.Printf("[poller] %s/%s: watermark write failed: %v", p.Island.ID, pod, err)
			p.Metrics.ErrorIncr(p.Island.ID)
		}
	}

	if written > 0 {
		p.Metrics.LinesIncr(p.Island.ID, written)
	}

	// Watermark-age gauge: how stale is the oldest watermark right now?
	wmLag := time.Duration(0)
	if oldest := p.oldestWatermark(); !oldest.IsZero() {
		wmLag = time.Since(oldest)
		p.Metrics.WatermarkAge(p.Island.ID, wmLag)
	}

	// Verbose summary — one line per tick per island when
	// POLLER_VERBOSE=1. Skipped otherwise so a healthy poller
	// stays silent (errors + lifecycle still log either way).
	if p.Verbose {
		log.Printf(
			"[poller] tick island=%s pods=%d scanned=%d written=%d deduped=%d elapsed=%s wm_lag=%s",
			p.Island.ID, len(latest), scanned, written, deduped,
			time.Since(start).Round(time.Millisecond),
			wmLag.Round(time.Second),
		)
	}
}

// oldestWatermark walks the island's pod directories on disk and
// returns the minimum watermark. Returns zero if there are no pods yet
// (cold start) — caller's Voodu client treats a zero `since` as "let
// the controller choose".
func (p *IslandPoller) oldestWatermark() time.Time {
	islandDir := filepath.Join(p.Root, p.Island.ID)
	entries, err := os.ReadDir(islandDir)
	if err != nil {
		// Cold start — directory does not exist yet.
		return time.Now().Add(-ColdStartLookback)
	}

	var oldest time.Time
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}

		t, err := ReadWatermark(p.Root, p.Island.ID, e.Name())
		if err != nil {
			continue
		}

		if oldest.IsZero() || t.Before(oldest) {
			oldest = t
		}
	}

	if oldest.IsZero() {
		return time.Now().Add(-ColdStartLookback)
	}

	return oldest
}
