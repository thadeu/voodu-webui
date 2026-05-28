// Package metrics owns the per-island "metrics" stream poller. One
// goroutine per island pulls /api/pat/v1/metrics on a fixed cadence,
// drops the raw NDJSON into a hashed folder under
// storage/poller/metrics/<hash>/, then notifies Rails via
// /internal/poller/digest.
//
// Watermark is in-memory only: metrics data is short-lived and the
// Rails side dedups on (island, sync_hash) — a missed tick simply
// replays at the next interval with a wider `since` window.
package metrics

import (
	"context"
	"errors"
	"io"
	"log"
	"strconv"
	"time"

	"github.com/voodu/poller/client"
	"github.com/voodu/poller/streams/digest"
)

// StreamType is the canonical name used in folder paths, metrics
// labels and digest notifications.
const StreamType = "metrics"

// ColdStartLookback is how far back the first tick reaches when there
// is no in-memory watermark yet. Short enough to keep the first
// payload small; long enough to bridge a poller restart.
const ColdStartLookback = 30 * time.Second

// Metrics is the observability callback bundle. observability.State
// implements it.
type Metrics interface {
	StreamPollIncr(stream, island string)
	StreamLinesIncr(stream, island string, n int)
	StreamErrorIncr(stream, island string)
	StreamNotifyIncr(stream, island, result string)
}

// Fetcher runs one island's metrics polling goroutine. Construct via
// NewFetcher; call Run to block until ctx is cancelled.
type Fetcher struct {
	Island   client.Island
	Voodu    *client.VooduClient
	Rails    *client.RailsClient
	Root     string
	Interval time.Duration
	Metrics  Metrics
	Verbose  bool

	// In-memory watermark. Advanced after a successful notify; reset on
	// process restart (cold-start lookback handles the gap).
	watermark time.Time
}

// NewFetcher wires together an island descriptor and the shared
// dependencies. Does NOT spawn the goroutine — call Run.
func NewFetcher(island client.Island, root string, interval time.Duration, rails *client.RailsClient, m Metrics) *Fetcher {
	return &Fetcher{
		Island:   island,
		Voodu:    client.NewVooduClient(island.Endpoint, island.PAT),
		Rails:    rails,
		Root:     root,
		Interval: interval,
		Metrics:  m,
	}
}

// Run blocks until ctx is cancelled, ticking on f.Interval.
func (f *Fetcher) Run(ctx context.Context) {
	t := time.NewTicker(f.Interval)
	defer t.Stop()

	f.tick(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			f.tick(ctx)
		}
	}
}

func (f *Fetcher) tick(ctx context.Context) {
	start := time.Now()
	f.Metrics.StreamPollIncr(StreamType, f.Island.ID)

	pending, err := digest.CountPending(f.Root, StreamType)
	if err == nil && pending >= digest.MaxPendingFolders {
		log.Printf("[poller] metrics %s: pending backlog (%d) at cap — skipping tick", f.Island.ID, pending)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}

	since := f.sinceParam()

	body, err := f.Voodu.FetchMetrics(ctx, since)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}

		log.Printf("[poller] metrics %s: fetch failed: %v", f.Island.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}
	defer body.Close()

	raw, err := io.ReadAll(body)
	if err != nil {
		log.Printf("[poller] metrics %s: read body: %v", f.Island.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}

	ts := time.Now()
	syncHash := digest.ComputeHash(StreamType, f.Island.ID, ts)
	meta := digest.Meta{
		Type:     StreamType,
		TenantID: f.Island.ID,
		TS:       ts.Unix(),
		Size:     len(raw),
		Since:    since,
	}

	files := map[string]io.Reader{
		"data.ndjson": newBytesReader(raw),
	}

	if err := digest.WriteHashedFolder(f.Root, StreamType, syncHash, files, meta); err != nil {
		log.Printf("[poller] metrics %s: write folder: %v", f.Island.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}

	notifyErr := f.Rails.NotifyDigest(client.DigestRequest{
		Type:     StreamType,
		TenantID: f.Island.ID,
		SyncHash: syncHash,
		TS:       ts.Unix(),
		Size:     len(raw),
	})
	if notifyErr != nil {
		log.Printf("[poller] metrics %s: notify failed: %v", f.Island.ID, notifyErr)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)
		f.Metrics.StreamNotifyIncr(StreamType, f.Island.ID, "fail")
		// Folder stays on disk; cleanup GC will sweep it after PendingTTL
		// and the next tick's wider `since` window covers the gap.
		return
	}

	f.Metrics.StreamNotifyIncr(StreamType, f.Island.ID, "ok")
	f.Metrics.StreamLinesIncr(StreamType, f.Island.ID, len(raw))
	f.watermark = ts

	if f.Verbose {
		log.Printf(
			"[poller] metrics tick island=%s size=%db hash=%s elapsed=%s",
			f.Island.ID, len(raw), syncHash,
			time.Since(start).Round(time.Millisecond),
		)
	}
}

// sinceParam returns the controller `since` string for this tick. Uses
// the in-memory watermark when present; falls back to a fresh
// ColdStartLookback window on the first tick after process start.
//
// Format is unix seconds (integer-as-string) because the controller's
// /metrics/dump endpoint matches Ruby's `MetricsSyncIslandJob` wire
// shape: `since: since.to_i`. RFC3339 here would parse as 0 and trigger
// a full retention dump on every tick.
func (f *Fetcher) sinceParam() string {
	if f.watermark.IsZero() {
		return strconv.FormatInt(time.Now().Add(-ColdStartLookback).Unix(), 10)
	}

	return strconv.FormatInt(f.watermark.Unix(), 10)
}

// newBytesReader is a tiny reader for the raw response body. Avoids
// importing bytes just for one site.
func newBytesReader(b []byte) io.Reader {
	return &sliceReader{data: b}
}

type sliceReader struct {
	data []byte
	off  int
}

func (r *sliceReader) Read(p []byte) (int, error) {
	if r.off >= len(r.data) {
		return 0, io.EOF
	}

	n := copy(p, r.data[r.off:])
	r.off += n

	return n, nil
}
