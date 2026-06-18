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

	// MaxBackfill bounds how far back a per-pod fetch reaches on resume.
	// A pod offline longer than this recovers only the last MaxBackfill
	// (the rest is beyond the controller's docker retention anyway). It
	// caps the ONE-TIME catch-up payload; steady-state windows are
	// ~Interval regardless. Wired from `POLLER_LOG_BACKFILL_SECONDS`.
	MaxBackfill time.Duration

	// Per-pod state, created lazily as pod names appear in the roster.
	//   rings    — content-hash dedup ring (boundary disambiguation only).
	//   floors   — max ts persisted per pod: the dedup floor AND the resume
	//              point. Seeded from disk on first touch, advanced on write.
	//   inflight — pods with a pollPod goroutine still running. A tick never
	//              waits on (nor re-launches) an in-flight pod, so one pod's
	//              slow fetch (a big backfill, a 60s timeout) can't gate the
	//              cadence of the chatty pods. THIS is the per-pod isolation.
	mu       sync.Mutex
	rings    map[string]*DedupRing
	floors   map[string]time.Time
	inflight map[string]struct{}
}

// DedupRingCapacity is the per-pod sliding window. With the unbounded
// timestamp floor doing the heavy overlap-drop (see pollPod), the ring
// only ever disambiguates a single boundary instant, so 5000 is vast
// headroom — it can never overflow into a duplicate.
const DedupRingCapacity = 5000

// maxPodConcurrency bounds how many pods one island polls at once, so a
// many-pod island doesn't open a request per pod simultaneously. Each
// fetch is small (a poll-interval window) except the rare backfill.
const maxPodConcurrency = 8

// NewIslandPoller wires together an island descriptor and the shared
// dependencies. Does NOT spawn the goroutine — call Run.
func NewIslandPoller(island client.Island, root string, interval, maxBackfill time.Duration, w *Writer, m Metrics) *IslandPoller {
	return &IslandPoller{
		Island:      island,
		Root:        root,
		Interval:    interval,
		MaxBackfill: maxBackfill,
		Voodu:       client.NewVooduClient(island.Endpoint, island.PAT),
		Writer:      w,
		Metrics:     m,
		rings:       map[string]*DedupRing{},
		floors:      map[string]time.Time{},
		inflight:    map[string]struct{}{},
	}
}

func (p *IslandPoller) ringFor(pod string) *DedupRing {
	p.mu.Lock()
	defer p.mu.Unlock()

	if r, ok := p.rings[pod]; ok {
		return r
	}

	r := NewDedupRing(DedupRingCapacity)
	// Warm the fresh ring from disk so a poller restart does not
	// re-write lines the previous process already persisted (the
	// `since=oldestWatermark` re-fetch overlap). See seedRing.
	p.seedRing(pod, r)
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

// tick runs one poll: fetch the current pod roster, then LAUNCH a per-pod
// fetch for each pod that isn't already in flight — and return WITHOUT waiting
// on them. This is the heart of per-pod isolation: a pod doing a heavy
// backfill (or stuck on its 60s timeout) keeps running in the background while
// the next tick fires on schedule for everyone else, so the chatty pods hold
// their ~Interval cadence regardless. Errors are logged + counted per pod;
// the tick itself only fails (and retries next tick) if the ROSTER fetch does.
func (p *IslandPoller) tick(ctx context.Context) {
	p.Metrics.PollIncr(p.Island.ID)
	p.Metrics.SetLastPoll(time.Now())

	pods, err := p.roster(ctx)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}

		log.Printf("[poller] %s: roster fetch failed: %v", p.Island.ID, err)
		p.Metrics.ErrorIncr(p.Island.ID)

		return
	}

	for _, pod := range pods {
		if !p.startPoll(pod) {
			// Already in flight (a prior tick's fetch is still running), or
			// the in-flight bound is hit — skip; a later tick picks it up.
			continue
		}

		go func(pod string) {
			defer p.endPoll(pod)
			p.pollPod(ctx, pod)
		}(pod)
	}

	// Watermark-age gauge: how stale is the oldest watermark right now?
	if oldest := p.oldestWatermark(); !oldest.IsZero() {
		p.Metrics.WatermarkAge(p.Island.ID, time.Since(oldest))
	}
}

// startPoll reserves an in-flight slot for `pod`, returning false when the
// pod already has a fetch running or the per-island concurrency bound is
// reached. Non-blocking by design: a busy/slow pod is simply skipped this
// tick rather than gating it.
func (p *IslandPoller) startPoll(pod string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()

	if _, running := p.inflight[pod]; running {
		return false
	}

	if len(p.inflight) >= maxPodConcurrency {
		return false
	}

	p.inflight[pod] = struct{}{}

	return true
}

func (p *IslandPoller) endPoll(pod string) {
	p.mu.Lock()
	defer p.mu.Unlock()

	delete(p.inflight, pod)
}

// roster fetches the island's CURRENT pod names. This is the discovery
// source for the per-pod fetch (the old multiplexed stream discovered pods
// implicitly; per-pod fetches need the list up front). A dead/decommissioned
// pod simply isn't in the roster, so we never waste a fetch on it — and never
// let its stale on-disk watermark drag anything.
func (p *IslandPoller) roster(ctx context.Context) ([]string, error) {
	body, err := p.Voodu.FetchPodList(ctx)
	if err != nil {
		return nil, err
	}
	defer body.Close()

	return client.ParsePodNames(body)
}

// pollPod fetches + persists one pod's new lines, resuming from its own
// floor. Two-layer dedup makes a duplicate STRUCTURALLY impossible no matter
// how large the re-delivered window:
//
//  1. timestamp floor (UNBOUNDED): drop anything strictly older than the
//     newest line we already hold — a plain compare, no size limit.
//  2. content-hash ring (boundary only): for ts == floor (docker's `--since`
//     is inclusive + second-granular) the ring tells a true re-delivery from
//     a distinct same-instant line. It only ever sees one instant's worth of
//     lines, so it can't overflow.
func (p *IslandPoller) pollPod(ctx context.Context, pod string) (written, scanned, deduped int) {
	start := time.Now()
	floor := p.dedupFloor(pod)
	since := p.sinceFor(floor)

	body, err := p.Voodu.FetchPodLogs(ctx, pod, since)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}

		log.Printf("[poller] %s/%s: fetch failed: %v", p.Island.ID, pod, err)
		p.Metrics.ErrorIncr(p.Island.ID)

		return
	}
	defer body.Close()

	ring := p.ringFor(pod)
	var latest time.Time

	sc := bufio.NewScanner(body)
	// Long log lines blow past bufio's default 64KB token. Bump to 1MB.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for sc.Scan() {
		raw := sc.Bytes()
		// Single-pod stream: lines have no `[pod]` prefix, so ParseLine's
		// pod is empty — we already know it. msg+ts match the multiplexed
		// shape, so the (pod, ts, msg) hash stays consistent with what's on
		// disk (dedup survives the multiplex→per-pod switch).
		_, ts, msg, ok := client.ParseLine(raw)
		if !ok {
			continue
		}
		scanned++
		if ts.IsZero() {
			ts = time.Now()
		}

		if !floor.IsZero() && ts.Before(floor) {
			deduped++

			continue
		}

		h := lineHash(pod, ts, msg)
		if ring.Seen(h) {
			deduped++

			continue
		}
		ring.Record(h)

		rec := Record{Pod: pod, TS: ts, Msg: msg, Raw: string(raw)}
		if err := p.Writer.Append(p.Island.ID, pod, rec); err != nil {
			log.Printf("[poller] %s/%s: append failed: %v", p.Island.ID, pod, err)
			p.Metrics.ErrorIncr(p.Island.ID)

			continue
		}

		written++
		if ts.After(latest) {
			latest = ts
		}
	}

	if err := sc.Err(); err != nil && !errors.Is(err, io.EOF) {
		// A 60s timeout mid-backfill lands here: we keep what we read and
		// resume next tick (stream is oldest-first + the watermark advances
		// below), so it self-chunks. Counted as an error for visibility.
		log.Printf("[poller] %s/%s: scan error: %v", p.Island.ID, pod, err)
		p.Metrics.ErrorIncr(p.Island.ID)
	}

	// Advance the floor + watermark AFTER appends so a cut-off mid-stream
	// replays the unwritten suffix next tick.
	if !latest.IsZero() {
		p.advanceFloor(pod, latest)
		if err := WriteWatermark(p.Root, p.Island.ID, pod, latest); err != nil {
			log.Printf("[poller] %s/%s: watermark write failed: %v", p.Island.ID, pod, err)
			p.Metrics.ErrorIncr(p.Island.ID)
		}
	}

	// Report metrics here (not in the caller): the tick fire-and-forgets us,
	// so it can't aggregate our counts.
	if written > 0 {
		p.Metrics.LinesIncr(p.Island.ID, written)
	}

	if p.Verbose {
		log.Printf(
			"[poller] pod island=%s pod=%s scanned=%d written=%d deduped=%d since=%s elapsed=%s",
			p.Island.ID, pod, scanned, written, deduped,
			since.UTC().Format(time.RFC3339), time.Since(start).Round(time.Millisecond),
		)
	}

	return
}

// sinceFor maps a pod's dedup floor to the `since` it fetches from:
//   - zero floor (brand-new pod)            → now - ColdStartLookback
//   - floor older than MaxBackfill          → now - MaxBackfill (bounded)
//   - otherwise                             → the floor itself
func (p *IslandPoller) sinceFor(floor time.Time) time.Time {
	now := time.Now()
	if floor.IsZero() {
		return now.Add(-ColdStartLookback)
	}

	if earliest := now.Add(-p.MaxBackfill); floor.Before(earliest) {
		return earliest
	}

	return floor
}

// dedupFloor returns the pod's max-persisted-ts (the overlap-drop boundary),
// seeding it from disk on first touch. Cached + advanced in memory so we
// don't re-read the tail every tick.
func (p *IslandPoller) dedupFloor(pod string) time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()

	if f, ok := p.floors[pod]; ok {
		return f
	}

	f := p.latestPersistedTS(pod) // the on-disk data is the source of truth
	p.floors[pod] = f

	return f
}

// advanceFloor bumps a pod's floor to `ts` when newer (called after a
// successful write so the floor tracks what's actually persisted).
func (p *IslandPoller) advanceFloor(pod string, ts time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if ts.After(p.floors[pod]) {
		p.floors[pod] = ts
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
