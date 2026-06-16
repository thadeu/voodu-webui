// Package metrics owns the per-island "metrics" stream poller. One
// goroutine per island pulls /api/pat/v1/metrics on a fixed cadence,
// drops the raw NDJSON into a hashed folder under
// storage/poller/metrics/<hash>/, then notifies Rails via
// /internal/poller/digest.
//
// Watermark is in-memory and derived from the DATA, per source. An
// earlier version advanced a single watermark to wall-clock `now` after
// every tick, regardless of what came back — so once a source's sample
// timestamps fell more than one interval behind the wall clock (e.g.
// pod stats collection lag, a slow tick, a restart), the controller's
// strict `ts > since` filtered that source out and it never recovered,
// while system (stamped ~now) stayed live. We now track the high-water
// mark PER SOURCE from the rows we actually persist and pull from the
// OLDEST one, so a lagging source catches up instead of starving.
//
// The dump filters by ONE `since` across a stream that mixes system /
// pod / ingress, so pulling from the laggard re-delivers rows we already
// hold for the faster sources. Rails' digest ingest has no row-level
// dedup, so we drop that overlap here, keyed per time-series.
package metrics

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"maps"
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

// BackfillCap bounds how far back a single tick reaches to catch a
// lagging source up. A source whose newest persisted sample is older
// than this is dropped from the `since` calc, so a stream that stopped
// reporting (e.g. pods all deleted, or ingress on a SIP-only host with
// no HTTP traffic) can't drag `since` into an ever-widening re-stream
// every tick. We accept a gap on a source down longer than this rather
// than re-pulling unbounded history 4×/min.
const BackfillCap = 10 * time.Minute

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

	// In-memory high-water marks (unix seconds), derived from the rows
	// we persist — NOT wall-clock. Reset on process restart; the
	// cold-start lookback covers the gap.
	//
	//   seriesTS — newest ts per time-series (source|scope|name|container),
	//              for dropping the re-delivered overlap.
	//   sourceTS — newest ts per source, for choosing `since` (the
	//              oldest live source, so the laggard catches up).
	seriesTS map[string]int64
	sourceTS map[string]int64
}

// sample is the minimal projection of a dump line we need to attribute
// a row to its source + time-series. The metric values stay opaque in
// the raw line we forward to Rails untouched.
type sample struct {
	TS        string `json:"ts"`
	Source    string `json:"source"`
	Scope     string `json:"scope"`
	Name      string `json:"name"`
	Container string `json:"container"`
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
		seriesTS: make(map[string]int64),
		sourceTS: make(map[string]int64),
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

	since := f.computeSince(time.Now())

	body, err := f.Voodu.FetchMetrics(ctx, strconv.FormatInt(since, 10))
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}

		log.Printf("[poller] metrics %s: fetch failed: %v", f.Island.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}
	defer body.Close()

	// Drop the overlap the laggard-driven `since` re-delivers, keyed per
	// time-series. dedup works on CLONES of the watermark maps and hands
	// them back — we commit the advances only after Rails confirms the
	// digest (below), so a notify failure leaves f's watermarks untouched
	// and the next tick re-fetches the same window.
	kept, count, seriesTS, sourceTS, err := f.dedup(body)
	if err != nil {
		log.Printf("[poller] metrics %s: read body: %v", f.Island.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}

	if count == 0 {
		// Caught up — nothing past every source's watermark. Skip writing
		// an empty digest + notifying Rails; the next tick re-checks.
		if f.Verbose {
			log.Printf("[poller] metrics %s: no new rows (since=%d)", f.Island.ID, since)
		}

		return
	}

	ts := time.Now()
	syncHash := digest.ComputeHash(StreamType, f.Island.ID, ts)
	meta := digest.Meta{
		Type:     StreamType,
		TenantID: f.Island.ID,
		TS:       ts.Unix(),
		Size:     len(kept),
		Since:    strconv.FormatInt(since, 10),
	}

	files := map[string]io.Reader{
		"data.ndjson": bytes.NewReader(kept),
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
		Size:     len(kept),
	})
	if notifyErr != nil {
		log.Printf("[poller] metrics %s: notify failed: %v", f.Island.ID, notifyErr)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)
		f.Metrics.StreamNotifyIncr(StreamType, f.Island.ID, "fail")
		// Folder stays on disk; cleanup GC will sweep it after PendingTTL.
		// We do NOT commit the watermark advances, so the next tick's
		// `since` re-fetches this window and writes a fresh digest.
		return
	}

	// Rails has the digest — commit the watermark advances so the next
	// tick moves forward instead of re-delivering these rows.
	f.seriesTS = seriesTS
	f.sourceTS = sourceTS

	f.Metrics.StreamNotifyIncr(StreamType, f.Island.ID, "ok")
	f.Metrics.StreamLinesIncr(StreamType, f.Island.ID, count)

	if f.Verbose {
		log.Printf(
			"[poller] metrics tick island=%s rows=%d size=%db hash=%s since=%d elapsed=%s",
			f.Island.ID, count, len(kept), syncHash, since,
			time.Since(start).Round(time.Millisecond),
		)
	}
}

// computeSince returns the controller `since` (unix seconds) for this
// tick: the OLDEST live source's watermark, so a lagging source catches
// up. Sources with no watermark yet (never seen) don't constrain it;
// sources older than BackfillCap are excluded so a dead stream can't
// drag `since` backwards forever.
//
//   - cold (no source seen yet)   → now - ColdStartLookback
//   - every known source is stale → now - BackfillCap (bounded recovery)
//   - otherwise                   → min(live source watermarks)
func (f *Fetcher) computeSince(now time.Time) int64 {
	if len(f.sourceTS) == 0 {
		return now.Add(-ColdStartLookback).Unix()
	}

	floor := now.Add(-BackfillCap).Unix()
	min := int64(0)
	have := false

	for _, ts := range f.sourceTS {
		if ts < floor {
			continue
		}

		if !have || ts < min {
			min = ts
			have = true
		}
	}

	if !have {
		return floor
	}

	return min
}

// dedup reads the NDJSON body, drops rows we've already persisted for
// their time-series, advances the per-series + per-source watermarks
// from the rows it keeps, and returns the kept lines (newline-joined)
// plus their count. Unparseable / ts-less lines pass through untouched —
// Rails skips anything malformed at insert, and dropping here could lose
// a valid sample on a transient hiccup.
func (f *Fetcher) dedup(body io.Reader) ([]byte, int, map[string]int64, map[string]int64, error) {
	// Clone the watermark maps so the caller commits the advances only
	// once the digest is safely with Rails. A notify failure discards
	// these clones and the next tick re-fetches the same window.
	seriesTS := cloneInt64Map(f.seriesTS)
	sourceTS := cloneInt64Map(f.sourceTS)

	sc := bufio.NewScanner(body)
	// Match the log path's allowance: a metrics line is small, but be
	// safe against an unexpectedly fat payload rather than truncating.
	sc.Buffer(make([]byte, 64*1024), 1024*1024)

	var out bytes.Buffer
	count := 0

	for sc.Scan() {
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}

		if !keepLine(line, seriesTS, sourceTS) {
			continue
		}

		out.Write(line)
		out.WriteByte('\n')
		count++
	}

	if err := sc.Err(); err != nil {
		return nil, 0, nil, nil, err
	}

	return out.Bytes(), count, seriesTS, sourceTS, nil
}

// keepLine reports whether `line` is newer than the last sample stored
// for its time-series, advancing the marks in the passed maps when it
// is. Keying per-series (not per-source) preserves distinct pods sampled
// in the same second — a whole-host batch isn't collapsed to one row.
func keepLine(line []byte, seriesTS, sourceTS map[string]int64) bool {
	var s sample
	if err := json.Unmarshal(line, &s); err != nil {
		return true
	}

	ts, ok := parseTSSeconds(s.TS)
	if !ok {
		return true
	}

	key := s.Source + "\x1f" + s.Scope + "\x1f" + s.Name + "\x1f" + s.Container
	if prev, seen := seriesTS[key]; seen && ts <= prev {
		return false
	}

	seriesTS[key] = ts
	if ts > sourceTS[s.Source] {
		sourceTS[s.Source] = ts
	}

	return true
}

// cloneInt64Map returns a shallow copy so dedup can stage watermark
// advances without touching the committed state until the tick succeeds.
func cloneInt64Map(m map[string]int64) map[string]int64 {
	out := make(map[string]int64, len(m))
	maps.Copy(out, m)

	return out
}

// parseTSSeconds parses the dump line's RFC3339(Nano) `ts` into unix
// seconds. Second granularity is enough: a single time-series is
// sampled ~every 15s, so two samples never share a second, while an
// exact re-delivery shares it (and gets dropped). Returns ok=false when
// the timestamp is missing or unparseable.
func parseTSSeconds(raw string) (int64, bool) {
	if raw == "" {
		return 0, false
	}

	if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
		return t.Unix(), true
	}

	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t.Unix(), true
	}

	return 0, false
}
