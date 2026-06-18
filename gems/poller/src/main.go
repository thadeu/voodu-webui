// poller — Go binary that polls voodu controllers in parallel
// and persists per-pod NDJSON to disk. See gems/poller/README.md
// for the full spec.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/voodu/poller/client"
	"github.com/voodu/poller/observability"
	"github.com/voodu/poller/poller"
	"github.com/voodu/poller/streams/digest"
	metricsstream "github.com/voodu/poller/streams/metrics"
	statestream "github.com/voodu/poller/streams/state"
)

// envGate exits cleanly when POLLER_SPAWN is not set to "1". Puma /
// foreman see a 0-exit and DO NOT restart-storm.
func envGate() {
	if os.Getenv("POLLER_SPAWN") != "1" {
		log.Print("[poller] POLLER_SPAWN != 1 — exiting cleanly")

		os.Exit(0)
	}
}

// Config captures every env var the binary reads. Populated once at
// startup; immutable for the lifetime of the process.
type Config struct {
	RailsURL          string
	InternalToken     string
	IntervalSeconds   int
	StorageDir        string
	ObservabilityAddr string
	Verbose           bool

	// Per-stream enable flags. Logs default ON (existing behaviour);
	// metrics + state default OFF and must be opted in.
	LogsEnabled    bool
	MetricsEnabled bool
	StateEnabled   bool

	// Per-stream tick intervals (seconds, floor 5).
	MetricsIntervalSeconds int
	StateIntervalSeconds   int

	// LogBackfillSeconds bounds how far back a per-pod log fetch reaches
	// on resume (default 24h — covers any overnight poller downtime). A pod
	// offline longer recovers only the last window; the rest is past
	// docker's retention anyway. Caps the one-time catch-up payload —
	// steady-state windows stay ~Interval.
	LogBackfillSeconds int

	// DigestRoot is the parent of storage/poller/<streamType>/. Defaults
	// to the same directory tree the logs poller uses so all on-disk
	// artefacts sit under one storage root.
	DigestRoot string
}

// loadConfig reads env vars with defaults. Returns an error if a
// required value (the internal token) is missing.
func loadConfig() (*Config, error) {
	token := os.Getenv("POLLER_TOKEN")
	if token == "" {
		return nil, fmt.Errorf("POLLER_TOKEN is required")
	}

	railsURL := os.Getenv("RAILS_INTERNAL_URL")
	if railsURL == "" {
		railsURL = "http://127.0.0.1:3000"
	}

	intervalStr := os.Getenv("POLLER_INTERVAL_SECONDS")
	interval := 15
	if intervalStr != "" {
		if n, err := strconv.Atoi(intervalStr); err == nil {
			interval = n
		}
	}
	if interval < 5 {
		interval = 5
	}

	storage := os.Getenv("POLLER_STORAGE_DIR")
	if storage == "" {
		storage = filepath.Join(".", "storage", "logs")
	}
	abs, err := filepath.Abs(storage)
	if err != nil {
		return nil, fmt.Errorf("resolve storage dir: %w", err)
	}

	obsAddr := os.Getenv("POLLER_OBSERVABILITY_ADDR")
	if obsAddr == "" {
		obsAddr = ":9999"
	}

	verbose := os.Getenv("POLLER_VERBOSE") == "1"

	metricsInterval := envIntSeconds("POLLER_METRICS_INTERVAL_SECONDS", 14, 5)
	stateInterval := envIntSeconds("POLLER_STATE_INTERVAL_SECONDS", 15, 5)
	logBackfill := envIntSeconds("POLLER_LOG_BACKFILL_SECONDS", 24*60*60, 60)

	// All three lanes default ON. `POLLER_SPAWN=1` alone is meant to
	// be the single switch operators flip — the binary owns logs,
	// state and metrics; the Ruby orchestrators check the same
	// `POLLER_SPAWN` and step aside. The per-stream flags are kept
	// as rollback levers: setting `POLLER_METRICS=0` disables that
	// one lane in the binary while logs + state keep flowing. (When
	// a per-stream flag is `0`, Ruby still defers — operator must
	// also flip `POLLER_SPAWN=0` to bring Ruby back; this avoids the
	// "nobody is doing X" trap that a finer-grained Ruby/Go gate
	// would create on misalignment.)
	logsEnabled := envFlag("POLLER_LOGS", true)
	metricsEnabled := envFlag("POLLER_METRICS", true)
	stateEnabled := envFlag("POLLER_STATE", true)

	// storage/poller/<type>/ sits as a sibling of storage/logs/, so the
	// digest root is the storage dir's parent. Operators can override
	// via POLLER_DIGEST_ROOT for tests.
	digestRoot := os.Getenv("POLLER_DIGEST_ROOT")
	if digestRoot == "" {
		digestRoot = filepath.Dir(abs)
	}

	return &Config{
		RailsURL:               railsURL,
		InternalToken:          token,
		IntervalSeconds:        interval,
		StorageDir:             abs,
		ObservabilityAddr:      obsAddr,
		Verbose:                verbose,
		LogsEnabled:            logsEnabled,
		MetricsEnabled:         metricsEnabled,
		StateEnabled:           stateEnabled,
		MetricsIntervalSeconds: metricsInterval,
		StateIntervalSeconds:   stateInterval,
		LogBackfillSeconds:     logBackfill,
		DigestRoot:             digestRoot,
	}, nil
}

// envFlag reads a "1"/"0" env var, returning `def` when the var is
// unset.
func envFlag(name string, def bool) bool {
	v := os.Getenv(name)
	if v == "" {
		return def
	}

	return v == "1" || v == "true" || v == "TRUE"
}

// envIntSeconds reads an integer env var with a default + floor. The
// floor protects against runaway tick rates if someone sets a small or
// negative value by mistake.
func envIntSeconds(name string, def, floor int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}

	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}

	if n < floor {
		return floor
	}

	return n
}

// IslandRefreshInterval is how often main.go re-fetches the island
// list from Rails. New islands get a goroutine, removed islands have
// their goroutine cancelled (next refresh tick).
const IslandRefreshInterval = 5 * time.Minute

// DrainBudget is how long we wait for in-flight ticks to finish on
// SIGTERM before yanking the rug.
const DrainBudget = 5 * time.Second

func main() {
	envGate()

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("[poller] config: %v", err)
	}

	if err := os.MkdirAll(cfg.StorageDir, 0o755); err != nil {
		log.Fatalf("[poller] mkdir storage: %v", err)
	}

	state := observability.NewState()
	go func() {
		if err := state.Listen(cfg.ObservabilityAddr); err != nil {
			log.Printf("[poller] observability listener exited: %v", err)
		}
	}()

	writer := poller.NewWriter(cfg.StorageDir, state.CapHitIncr)
	railsClient := client.NewRailsClient(cfg.RailsURL, cfg.InternalToken)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	// Track per-(island, stream) goroutines so we can reap removed
	// islands and wait on them at shutdown. The key is
	// "<stream>|<islandID>".
	type runningStream struct {
		cancel context.CancelFunc
		done   chan struct{}
	}
	running := map[string]runningStream{}
	var wg sync.WaitGroup

	logsInterval := time.Duration(cfg.IntervalSeconds) * time.Second
	logBackfill := time.Duration(cfg.LogBackfillSeconds) * time.Second
	metricsInterval := time.Duration(cfg.MetricsIntervalSeconds) * time.Second
	stateInterval := time.Duration(cfg.StateIntervalSeconds) * time.Second

	spawn := func(stream, islandID string, run func(context.Context)) {
		key := stream + "|" + islandID
		if _, ok := running[key]; ok {
			return
		}

		ictx, icancel := context.WithCancel(ctx)
		done := make(chan struct{})

		wg.Add(1)
		go func() {
			defer wg.Done()
			defer close(done)
			run(ictx)
			log.Printf("[poller] %s %s: goroutine exited", stream, islandID)
		}()

		running[key] = runningStream{cancel: icancel, done: done}
		log.Printf("[poller] %s %s: spawned", stream, islandID)
	}

	refresh := func() {
		islands, err := railsClient.FetchIslands()
		if err != nil {
			log.Printf("[poller] refresh: %v", err)

			return
		}

		state.SetIslandCount(len(islands))

		seen := map[string]bool{} // key = "<stream>|<islandID>"

		for _, isl := range islands {
			isl := isl // capture for closures

			if cfg.LogsEnabled {
				seen["logs|"+isl.ID] = true
				p := poller.NewIslandPoller(isl, cfg.StorageDir, logsInterval, logBackfill, writer, state)
				p.Verbose = cfg.Verbose
				spawn("logs", isl.ID, p.Run)
			}

			if cfg.MetricsEnabled {
				seen["metrics|"+isl.ID] = true
				f := metricsstream.NewFetcher(isl, cfg.DigestRoot, metricsInterval, railsClient, state)
				f.Verbose = cfg.Verbose
				spawn("metrics", isl.ID, f.Run)
			}

			if cfg.StateEnabled {
				seen["state|"+isl.ID] = true
				f := statestream.NewFetcher(isl, cfg.DigestRoot, stateInterval, railsClient, state)
				f.Verbose = cfg.Verbose
				spawn("state", isl.ID, f.Run)
			}
		}

		for key, r := range running {
			if seen[key] {
				continue
			}

			log.Printf("[poller] %s: stream removed — cancelling", key)
			r.cancel()
			delete(running, key)
		}
	}

	// Cleanup goroutine: daily 03:00 UTC, purge ndjson older than 2 days.
	wg.Add(1)
	go func() {
		defer wg.Done()
		runCleanupLoop(ctx, cfg.StorageDir)
	}()

	// Digest cleanup: hourly sweep removing stale metrics/state folders
	// (Rails should have processed them; if not, GC after PendingTTL).
	wg.Add(1)
	go func() {
		defer wg.Done()
		runDigestCleanupLoop(ctx, cfg.DigestRoot)
	}()

	refresh()

	refreshTicker := time.NewTicker(IslandRefreshInterval)
	defer refreshTicker.Stop()

	for {
		select {
		case sig := <-sigCh:
			log.Printf("[poller] %s — draining", sig)

			cancel()

			done := make(chan struct{})
			go func() {
				wg.Wait()
				close(done)
			}()

			select {
			case <-done:
				log.Print("[poller] drained cleanly")
			case <-time.After(DrainBudget):
				log.Printf("[poller] drain budget (%s) exceeded — exiting", DrainBudget)
			}

			return

		case <-refreshTicker.C:
			refresh()
		}
	}
}

// runCleanupLoop fires once a day at 03:00 UTC and removes NDJSON
// files older than poller's retention (2 days). Watermarks are left in
// place — they are tiny and a stale watermark is harmless (the poller
// will read the latest line from disk on next tick).
func runCleanupLoop(ctx context.Context, root string) {
	for {
		next := nextCleanupTime(time.Now().UTC())
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Until(next)):
		}

		cutoff := time.Now().Add(-2 * 24 * time.Hour)
		if err := cleanupOlderThan(root, cutoff); err != nil {
			log.Printf("[poller] cleanup: %v", err)
		}
	}
}

func nextCleanupTime(now time.Time) time.Time {
	candidate := time.Date(now.Year(), now.Month(), now.Day(), 3, 0, 0, 0, time.UTC)
	if !candidate.After(now) {
		candidate = candidate.Add(24 * time.Hour)
	}

	return candidate
}

// runDigestCleanupLoop fires hourly and removes digest folders older
// than digest.PendingTTL. This protects against disk fill when Rails is
// down — the fetcher itself caps pending folders, but the cleanup loop
// is what actually frees the slot.
func runDigestCleanupLoop(ctx context.Context, root string) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()

	sweep := func() {
		cutoff := time.Now().Add(-digest.PendingTTL)
		if err := digest.CleanupOlderThan(root, "", cutoff); err != nil {
			log.Printf("[poller] digest cleanup: %v", err)
		}
	}

	sweep()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweep()
		}
	}
}

func cleanupOlderThan(root string, cutoff time.Time) error {
	return filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // skip unreadable entries; don't abort the walk
		}
		if info.IsDir() {
			return nil
		}
		if filepath.Ext(path) != ".ndjson" {
			return nil
		}
		if info.ModTime().After(cutoff) {
			return nil
		}

		if err := os.Remove(path); err != nil {
			log.Printf("[poller] cleanup remove %s: %v", path, err)
		}

		return nil
	})
}
