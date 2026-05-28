// Package state owns the per-island "state" stream poller. Each tick
// fetches BOTH /api/pat/v1/pods?detail=true&spec=true and
// /api/pat/v1/system in parallel, writes both responses to a hashed
// folder under storage/poller/state/<hash>/, then notifies Rails via
// /internal/poller/digest.
//
// Notify is fired only AFTER both files are durably written + the
// meta.json marker is in place — Rails treats meta.json's presence as
// the "folder is complete" signal.
package state

import (
	"context"
	"errors"
	"io"
	"log"
	"sync"
	"time"

	"github.com/voodu/poller/client"
	"github.com/voodu/poller/streams/digest"
)

// StreamType is the canonical name used in folder paths, metrics
// labels and digest notifications.
const StreamType = "state"

// Metrics is the observability callback bundle. observability.State
// implements it.
type Metrics interface {
	StreamPollIncr(stream, island string)
	StreamLinesIncr(stream, island string, n int)
	StreamErrorIncr(stream, island string)
	StreamNotifyIncr(stream, island, result string)
}

// Fetcher runs one island's state polling goroutine.
type Fetcher struct {
	Island   client.Island
	Voodu    *client.VooduClient
	Rails    *client.RailsClient
	Root     string
	Interval time.Duration
	Metrics  Metrics
	Verbose  bool
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

// fetchResult is the per-endpoint payload + error pair carried out of
// the parallel fetch goroutines.
type fetchResult struct {
	body []byte
	err  error
}

func (f *Fetcher) tick(ctx context.Context) {
	start := time.Now()
	f.Metrics.StreamPollIncr(StreamType, f.Island.ID)

	pending, err := digest.CountPending(f.Root, StreamType)
	if err == nil && pending >= digest.MaxPendingFolders {
		log.Printf("[poller] state %s: pending backlog (%d) at cap — skipping tick", f.Island.ID, pending)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}

	var (
		podsRes   fetchResult
		systemRes fetchResult
		wg        sync.WaitGroup
	)

	wg.Add(2)
	go func() {
		defer wg.Done()
		podsRes = fetchAll(ctx, f.Voodu.FetchPods)
	}()
	go func() {
		defer wg.Done()
		systemRes = fetchAll(ctx, f.Voodu.FetchSystem)
	}()
	wg.Wait()

	if podsRes.err != nil {
		if !errors.Is(podsRes.err, context.Canceled) {
			log.Printf("[poller] state %s: pods fetch failed: %v", f.Island.ID, podsRes.err)
			f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)
		}

		return
	}

	if systemRes.err != nil {
		if !errors.Is(systemRes.err, context.Canceled) {
			log.Printf("[poller] state %s: system fetch failed: %v", f.Island.ID, systemRes.err)
			f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)
		}

		return
	}

	ts := time.Now()
	syncHash := digest.ComputeHash(StreamType, f.Island.ID, ts)
	totalSize := len(podsRes.body) + len(systemRes.body)

	files := map[string]io.Reader{
		"pods.json":   newBytesReader(podsRes.body),
		"system.json": newBytesReader(systemRes.body),
	}

	meta := digest.Meta{
		Type:     StreamType,
		TenantID: f.Island.ID,
		TS:       ts.Unix(),
		Size:     totalSize,
	}

	if err := digest.WriteHashedFolder(f.Root, StreamType, syncHash, files, meta); err != nil {
		log.Printf("[poller] state %s: write folder: %v", f.Island.ID, err)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)

		return
	}

	notifyErr := f.Rails.NotifyDigest(client.DigestRequest{
		Type:     StreamType,
		TenantID: f.Island.ID,
		SyncHash: syncHash,
		TS:       ts.Unix(),
		Size:     totalSize,
	})
	if notifyErr != nil {
		log.Printf("[poller] state %s: notify failed: %v", f.Island.ID, notifyErr)
		f.Metrics.StreamErrorIncr(StreamType, f.Island.ID)
		f.Metrics.StreamNotifyIncr(StreamType, f.Island.ID, "fail")

		return
	}

	f.Metrics.StreamNotifyIncr(StreamType, f.Island.ID, "ok")
	f.Metrics.StreamLinesIncr(StreamType, f.Island.ID, totalSize)

	if f.Verbose {
		log.Printf(
			"[poller] state tick island=%s size=%db hash=%s elapsed=%s",
			f.Island.ID, totalSize, syncHash,
			time.Since(start).Round(time.Millisecond),
		)
	}
}

// fetchAll calls one of the voodu endpoint getters and slurps the body
// to memory. The bodies are tiny (a few hundred KB at most) so an
// in-memory buffer keeps the WriteHashedFolder API simple.
func fetchAll(ctx context.Context, getter func(context.Context) (io.ReadCloser, error)) fetchResult {
	body, err := getter(ctx)
	if err != nil {
		return fetchResult{err: err}
	}
	defer body.Close()

	data, err := io.ReadAll(body)
	if err != nil {
		return fetchResult{err: err}
	}

	return fetchResult{body: data}
}

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
