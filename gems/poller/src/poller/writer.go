package poller

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// PerFileCapBytes — soft cap at which the writer emits a warning. We
// do NOT rotate mid-day; the Rails reader expects one file per UTC
// day. Operator decides whether to bump the cap or shed traffic.
const PerFileCapBytes = 250 * 1024 * 1024

// Record is one persisted log line. Field tags match what the Rails
// reader expects.
type Record struct {
	Pod string    `json:"pod"`
	TS  time.Time `json:"ts"`
	Msg string    `json:"msg"`
	Raw string    `json:"raw"`
}

// Writer serialises appends per (island, pod, day) tuple. Lock
// granularity is per pod because two pods on the same island write to
// different files, so they never contend.
//
// Acquisition order: caller -> Writer.mu (cheap, just protects the map)
// -> per-pod mutex (held only during the actual write).
type Writer struct {
	Root     string
	OnCapHit func(islandID, pod string)

	mu    sync.Mutex
	locks map[string]*sync.Mutex // key = islandID + "|" + pod
}

// NewWriter returns a Writer rooted at `root`. The cap-hit callback is
// invoked once per (island, pod) write that finds the file already
// over PerFileCapBytes; main.go wires this to a Prometheus counter.
func NewWriter(root string, onCapHit func(islandID, pod string)) *Writer {
	return &Writer{
		Root:     root,
		OnCapHit: onCapHit,
		locks:    map[string]*sync.Mutex{},
	}
}

func (w *Writer) podMutex(islandID, pod string) *sync.Mutex {
	key := islandID + "|" + pod

	w.mu.Lock()
	defer w.mu.Unlock()

	if m, ok := w.locks[key]; ok {
		return m
	}

	m := &sync.Mutex{}
	w.locks[key] = m

	return m
}

// DailyFile returns the absolute path the writer would target for a
// (island, pod, ts) triple. Exported for use by the reader / cleanup.
func (w *Writer) DailyFile(islandID, pod string, ts time.Time) string {
	day := ts.UTC().Format("2006-01-02")

	return filepath.Join(w.Root, islandID, safePodName(pod), day+".ndjson")
}

// Append writes one Record as an NDJSON line. Idempotent for the
// caller's purposes (dedup is handled upstream).
//
// File handle is opened, written, fsync'd (implicit on close on most
// OSs but we do not Sync explicitly to keep latency low — the OS page
// cache plus the watermark-after-flush ordering keeps us safe enough)
// and closed per call. Per-pod traffic is modest (≤ ~tens of
// lines/sec); a long-lived handle would complicate rotation across
// the UTC midnight boundary.
func (w *Writer) Append(islandID, pod string, rec Record) error {
	path := w.DailyFile(islandID, pod, rec.TS)

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir pod dir: %w", err)
	}

	mu := w.podMutex(islandID, pod)
	mu.Lock()
	defer mu.Unlock()

	if info, err := os.Stat(path); err == nil && info.Size() >= PerFileCapBytes {
		if w.OnCapHit != nil {
			w.OnCapHit(islandID, pod)
		}
		// Cap is a SOFT warning — we still write. Operator decides.
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open ndjson: %w", err)
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(rec); err != nil {
		return fmt.Errorf("encode ndjson: %w", err)
	}

	return nil
}
