// log-poller — Go binary that polls voodu controllers in parallel
// and persists per-pod NDJSON to disk. See gems/log_poller/README.md
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

	"github.com/voodu/log_poller/client"
	"github.com/voodu/log_poller/observability"
	"github.com/voodu/log_poller/poller"
)

// envGate exits cleanly when LOG_POLLER_SPAWN is not set to "1". Puma /
// foreman see a 0-exit and DO NOT restart-storm.
func envGate() {
	if os.Getenv("LOG_POLLER_SPAWN") != "1" {
		log.Print("[log_poller] LOG_POLLER_SPAWN != 1 — exiting cleanly")

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
}

// loadConfig reads env vars with defaults. Returns an error if a
// required value (the internal token) is missing.
func loadConfig() (*Config, error) {
	token := os.Getenv("LOG_POLLER_TOKEN")
	if token == "" {
		return nil, fmt.Errorf("LOG_POLLER_TOKEN is required")
	}

	railsURL := os.Getenv("RAILS_INTERNAL_URL")
	if railsURL == "" {
		railsURL = "http://127.0.0.1:3000"
	}

	intervalStr := os.Getenv("LOG_POLLER_INTERVAL_SECONDS")
	interval := 15
	if intervalStr != "" {
		if n, err := strconv.Atoi(intervalStr); err == nil {
			interval = n
		}
	}
	if interval < 5 {
		interval = 5
	}

	storage := os.Getenv("LOG_POLLER_STORAGE_DIR")
	if storage == "" {
		storage = filepath.Join(".", "storage", "logs")
	}
	abs, err := filepath.Abs(storage)
	if err != nil {
		return nil, fmt.Errorf("resolve storage dir: %w", err)
	}

	obsAddr := os.Getenv("LOG_POLLER_OBSERVABILITY_ADDR")
	if obsAddr == "" {
		obsAddr = ":9999"
	}

	verbose := os.Getenv("LOG_POLLER_VERBOSE") == "1"

	return &Config{
		RailsURL:          railsURL,
		InternalToken:     token,
		IntervalSeconds:   interval,
		StorageDir:        abs,
		ObservabilityAddr: obsAddr,
		Verbose:           verbose,
	}, nil
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
		log.Fatalf("[log_poller] config: %v", err)
	}

	if err := os.MkdirAll(cfg.StorageDir, 0o755); err != nil {
		log.Fatalf("[log_poller] mkdir storage: %v", err)
	}

	state := observability.NewState()
	go func() {
		if err := state.Listen(cfg.ObservabilityAddr); err != nil {
			log.Printf("[log_poller] observability listener exited: %v", err)
		}
	}()

	writer := poller.NewWriter(cfg.StorageDir, state.CapHitIncr)
	railsClient := client.NewRailsClient(cfg.RailsURL, cfg.InternalToken)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	// Track per-island goroutines so we can reap removed islands and
	// wait on them at shutdown.
	type runningIsland struct {
		cancel context.CancelFunc
		done   chan struct{}
	}
	running := map[string]runningIsland{}
	var wg sync.WaitGroup

	refresh := func() {
		islands, err := railsClient.FetchIslands()
		if err != nil {
			log.Printf("[log_poller] refresh: %v", err)

			return
		}

		state.SetIslandCount(len(islands))

		seen := map[string]bool{}
		interval := time.Duration(cfg.IntervalSeconds) * time.Second

		for _, isl := range islands {
			seen[isl.ID] = true
			if _, ok := running[isl.ID]; ok {
				continue
			}

			ictx, icancel := context.WithCancel(ctx)
			done := make(chan struct{})
			p := poller.NewIslandPoller(isl, cfg.StorageDir, interval, writer, state)
			p.Verbose = cfg.Verbose

			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				defer close(done)
				p.Run(ictx)
				log.Printf("[log_poller] %s: goroutine exited", id)
			}(isl.ID)

			running[isl.ID] = runningIsland{cancel: icancel, done: done}
			log.Printf("[log_poller] %s: spawned poller", isl.ID)
		}

		for id, r := range running {
			if seen[id] {
				continue
			}

			log.Printf("[log_poller] %s: island removed — cancelling poller", id)
			r.cancel()
			delete(running, id)
		}
	}

	// Cleanup goroutine: daily 03:00 UTC, purge ndjson older than 2 days.
	wg.Add(1)
	go func() {
		defer wg.Done()
		runCleanupLoop(ctx, cfg.StorageDir)
	}()

	refresh()

	refreshTicker := time.NewTicker(IslandRefreshInterval)
	defer refreshTicker.Stop()

	for {
		select {
		case sig := <-sigCh:
			log.Printf("[log_poller] %s — draining", sig)

			cancel()

			done := make(chan struct{})
			go func() {
				wg.Wait()
				close(done)
			}()

			select {
			case <-done:
				log.Print("[log_poller] drained cleanly")
			case <-time.After(DrainBudget):
				log.Printf("[log_poller] drain budget (%s) exceeded — exiting", DrainBudget)
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
			log.Printf("[log_poller] cleanup: %v", err)
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
			log.Printf("[log_poller] cleanup remove %s: %v", path, err)
		}

		return nil
	})
}
