// Package activity owns the per-server "activity" stream poller. One goroutine
// per server pulls /api/pat/v1/activity/dump on a fixed cadence, drops the raw
// NDJSON into a hashed folder under storage/poller/activity/<hash>/, then
// notifies Rails via /internal/poller/digest.
//
// Same three-step shape as the metrics and state lanes, and deliberately
// SIMPLER than metrics in one respect: there is no per-series dedup here.
//
// The metrics lane has to drop re-delivered rows itself, because the Rails
// ingest inserts and a duplicate row is a duplicate point on a chart. The
// activity ingest UPSERTS on the action's identity, so re-applying a line the
// warehouse already holds lands on the same row and changes nothing. That
// turns the hardest part of the metrics lane into a non-problem, and it lets
// this lane do something metrics cannot: overlap the boundary on purpose.
//
// Why overlap. The controller filters `ts > since` STRICTLY. Asking for
// `> newest` drops any line sharing that second — and unlike a metrics sample,
// a dropped action is a hole in an audit trail that nothing will ever refill.
// So we ask for `newest - Overlap` and let the upsert absorb what comes back
// twice.
package activity

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"strconv"
	"time"

	"github.com/voodu/poller/client"
	"github.com/voodu/poller/streams/digest"
)

// StreamType is the canonical name used in folder paths, metrics labels and
// digest notifications. Matches PollerDigest::TYPES on the Rails side.
const StreamType = "activity"

// ColdStartLookback is how far back the first tick reaches when the warehouse
// has nothing for this server and there is no watermark to resume from.
//
// Deliberately short. A brand-new server pulling the controller's full 30-day
// retention on its first tick would be a large payload for rows the operator
// has never been shown — and the very next action they take lands normally.
const ColdStartLookback = 5 * time.Minute

// Overlap is how far behind the watermark each tick asks from.
//
// One second, because that is the controller's filter resolution: `since` is
// unix SECONDS, so two actions in the same second are indistinguishable to it.
// Without the overlap, the second one is dropped forever.
const Overlap = 1 * time.Second

// BackfillCap bounds a single tick's reach. A poller that was down for a week
// should catch up over a few ticks rather than ask for the whole window at
// once and time out on a slow link.
const BackfillCap = 24 * time.Hour

// Metrics is the observability callback bundle. observability.State implements
// it — same interface the other lanes take.
type Metrics interface {
	StreamPollIncr(stream, server string)
	StreamLinesIncr(stream, server string, n int)
	StreamErrorIncr(stream, server string)
	StreamNotifyIncr(stream, server, result string)
}

// Fetcher runs one server's activity polling goroutine. Construct via
// NewFetcher; call Run to block until ctx is cancelled.
type Fetcher struct {
	Server   client.Server
	Voodu    *client.VooduClient
	Rails    *client.RailsClient
	Root     string
	Interval time.Duration
	Metrics  Metrics
	Verbose  bool

	// watermark is the newest action ts (unix seconds) we have successfully
	// handed to Rails. Advanced only AFTER the digest is acknowledged, so a
	// notify failure leaves it untouched and the next tick re-fetches the same
	// window rather than skipping it.
	watermark int64
}

// record is the minimal projection needed to advance the watermark. Everything
// else stays opaque in the raw line we forward untouched — a field added to
// the controller's Record reaches the warehouse without a change here.
type record struct {
	TS string `json:"ts"`
}

// NewFetcher wires a server descriptor to the shared dependencies. Does NOT
// spawn the goroutine — call Run.
func NewFetcher(server client.Server, root string, interval time.Duration, rails *client.RailsClient, m Metrics) *Fetcher {
	return &Fetcher{
		Server:   server,
		Voodu:    client.NewVooduClient(server.Endpoint, server.PAT),
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

	f.seedWatermark()

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

// seedWatermark asks Rails what the warehouse already holds, so a restart
// resumes there instead of cold-starting and losing whatever happened while
// the poller was down.
//
// Non-fatal: a failure logs and leaves the watermark at 0, which falls back to
// the short lookback. The Rails dependency is optional (nil in tests).
func (f *Fetcher) seedWatermark() {
	if f.Rails == nil {
		return
	}

	since, err := f.Rails.FetchActivityWatermark(f.Server.ID)
	if err != nil {
		log.Printf("[poller] activity %s: watermark seed failed: %v (cold-starting at -%s)", f.Server.ID, err, ColdStartLookback)

		return
	}

	if since > 0 {
		f.watermark = since

		if f.Verbose {
			log.Printf("[poller] activity %s: seeded watermark=%d from warehouse", f.Server.ID, since)
		}
	}
}

func (f *Fetcher) tick(ctx context.Context) {
	start := time.Now()
	f.Metrics.StreamPollIncr(StreamType, f.Server.ID)

	pending, err := digest.CountPending(f.Root, StreamType)
	if err == nil && pending >= digest.MaxPendingFolders {
		log.Printf("[poller] activity %s: pending backlog (%d) at cap — skipping tick", f.Server.ID, pending)
		f.Metrics.StreamErrorIncr(StreamType, f.Server.ID)

		return
	}

	since := f.computeSince(time.Now())

	body, err := f.Voodu.FetchActivity(ctx, strconv.FormatInt(since, 10))
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}

		log.Printf("[poller] activity %s: fetch failed: %v", f.Server.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Server.ID)

		return
	}

	defer body.Close()

	raw, count, newest, err := f.read(body)
	if err != nil {
		log.Printf("[poller] activity %s: read body: %v", f.Server.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Server.ID)

		return
	}

	if count == 0 {
		// Nothing new. Skip the folder + notify entirely; the next tick
		// re-checks. This is the common case — a box sits idle for hours
		// between actions, unlike metrics which always has a sample.
		if f.Verbose {
			log.Printf("[poller] activity %s: no new lines (since=%d)", f.Server.ID, since)
		}

		return
	}

	ts := time.Now()
	syncHash := digest.ComputeHash(StreamType, f.Server.ID, ts)
	meta := digest.Meta{
		Type:     StreamType,
		ServerID: f.Server.ID,
		TS:       ts.Unix(),
		Size:     len(raw),
		Since:    strconv.FormatInt(since, 10),
	}

	files := map[string]io.Reader{
		"data.ndjson": bytes.NewReader(raw),
	}

	if err := digest.WriteHashedFolder(f.Root, StreamType, syncHash, files, meta); err != nil {
		log.Printf("[poller] activity %s: write folder: %v", f.Server.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Server.ID)

		return
	}

	notifyErr := f.Rails.NotifyDigest(client.DigestRequest{
		Type:     StreamType,
		ServerID: f.Server.ID,
		SyncHash: syncHash,
		TS:       ts.Unix(),
		Size:     len(raw),
	})
	if notifyErr != nil {
		log.Printf("[poller] activity %s: notify failed: %v", f.Server.ID, notifyErr)
		f.Metrics.StreamErrorIncr(StreamType, f.Server.ID)
		f.Metrics.StreamNotifyIncr(StreamType, f.Server.ID, "fail")
		// Folder stays on disk for the cleanup GC. The watermark is NOT
		// advanced, so the next tick re-fetches this window — which the
		// upserting ingest absorbs without duplicating anything.
		return
	}

	if newest > f.watermark {
		f.watermark = newest
	}

	f.Metrics.StreamNotifyIncr(StreamType, f.Server.ID, "ok")
	f.Metrics.StreamLinesIncr(StreamType, f.Server.ID, count)

	if f.Verbose {
		log.Printf(
			"[poller] activity tick server=%s lines=%d size=%db hash=%s since=%d elapsed=%s",
			f.Server.ID, count, len(raw), syncHash, since,
			time.Since(start).Round(time.Millisecond),
		)
	}
}

// read drains the response, returning the raw bytes to forward, the line count
// and the newest ts seen.
//
// The bytes go to Rails VERBATIM — parsing here is only to find the newest
// timestamp. A line we cannot parse is still forwarded: the Rails ingest has
// its own tolerant parse, and silently dropping a line the controller wrote is
// the one thing an audit trail must not do on a guess.
func (f *Fetcher) read(body io.Reader) ([]byte, int, int64, error) {
	out := new(bytes.Buffer)
	count := 0
	newest := int64(0)

	sc := bufio.NewScanner(body)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)

	for sc.Scan() {
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}

		out.Write(line)
		out.WriteByte('\n')
		count++

		var rec record
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}

		t, err := time.Parse(time.RFC3339Nano, rec.TS)
		if err != nil {
			continue
		}

		if t.Unix() > newest {
			newest = t.Unix()
		}
	}

	if err := sc.Err(); err != nil {
		return nil, 0, 0, err
	}

	return out.Bytes(), count, newest, nil
}

// computeSince returns the `since` (unix seconds) for this tick.
//
//   - cold (no watermark) → now - ColdStartLookback
//   - watermark older than BackfillCap → now - BackfillCap (bounded recovery)
//   - otherwise → watermark - Overlap
//
// The overlap is the point: see the package doc. Re-delivery is free because
// the ingest upserts, and a dropped line is not recoverable.
func (f *Fetcher) computeSince(now time.Time) int64 {
	if f.watermark <= 0 {
		return now.Add(-ColdStartLookback).Unix()
	}

	floor := now.Add(-BackfillCap).Unix()
	if f.watermark < floor {
		return floor
	}

	since := f.watermark - int64(Overlap.Seconds())
	if since < 0 {
		return 0
	}

	return since
}
