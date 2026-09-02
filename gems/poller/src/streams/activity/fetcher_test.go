package activity

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/voodu/poller/client"
)

type stubMetrics struct {
	mu         sync.Mutex
	polls      int
	lines      int
	errors     int
	notifyOk   int
	notifyFail int
}

func (s *stubMetrics) StreamPollIncr(_, _ string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.polls++
}

func (s *stubMetrics) StreamLinesIncr(_, _ string, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lines += n
}

func (s *stubMetrics) StreamErrorIncr(_, _ string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.errors++
}

func (s *stubMetrics) StreamNotifyIncr(_, _, result string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if result == "ok" {
		s.notifyOk++
	} else {
		s.notifyFail++
	}
}

func iso(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

// activityLine is the shape the controller's trail actually emits.
func activityLine(id, event string, t time.Time) string {
	b, _ := json.Marshal(map[string]any{
		"id":     id,
		"ts":     iso(t),
		"event":  event,
		"action": "apply",
		"origin": "cli",
	})

	return string(b)
}

func newFetcherForTest(t *testing.T, vooduSrv, railsSrv *httptest.Server, root string) (*Fetcher, *stubMetrics) {
	t.Helper()

	var rails *client.RailsClient
	if railsSrv != nil {
		rails = client.NewRailsClient(railsSrv.URL, "tok")
	}

	server := client.Server{ID: "server-1", Endpoint: vooduSrv.URL, PAT: "pat-1"}
	m := &stubMetrics{}

	return NewFetcher(server, root, 100*time.Millisecond, rails, m), m
}

// okRails answers both endpoints this lane talks to.
func okRails(t *testing.T, watermark int64, notifyCalls *atomic.Int32) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Voodu-Internal-Token") != "tok" {
			t.Errorf("missing internal token on %s", r.URL.Path)
		}

		switch r.URL.Path {
		case "/internal/poller/activity_watermark":
			_ = json.NewEncoder(w).Encode(map[string]any{"version": 1, "since": watermark})
		case "/internal/poller/digest":
			if notifyCalls != nil {
				notifyCalls.Add(1)
			}

			w.WriteHeader(http.StatusNoContent)
		default:
			t.Errorf("unexpected rails path: %s", r.URL.Path)
		}
	}))
}

func TestTickWritesFolderAndNotifies(t *testing.T) {
	root := t.TempDir()
	now := time.Now()

	var fetchedSince atomic.Value

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/pat/v1/activity/dump" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}

		if !strings.HasPrefix(r.Header.Get("Authorization"), "Voodu ") {
			t.Errorf("request was not signed: %q", r.Header.Get("Authorization"))
		}

		fetchedSince.Store(r.URL.Query().Get("since"))

		_, _ = w.Write([]byte(
			activityLine("a1", "started", now) + "\n" +
				activityLine("a1", "finished", now.Add(2*time.Second)) + "\n",
		))
	}))

	defer voodu.Close()

	var notify atomic.Int32

	rails := okRails(t, 0, &notify)
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	f.tick(ctx)

	if m.polls != 1 || m.errors != 0 || m.notifyOk != 1 {
		t.Fatalf("polls=%d errors=%d notifyOk=%d", m.polls, m.errors, m.notifyOk)
	}

	if m.lines != 2 {
		t.Errorf("lines = %d, want 2", m.lines)
	}

	// The folder must hold the controller's bytes verbatim — a field added to
	// the trail has to reach the warehouse without a change in this lane.
	entries, err := os.ReadDir(filepath.Join(root, "poller", StreamType))
	if err != nil {
		t.Fatal(err)
	}

	if len(entries) != 1 {
		t.Fatalf("want 1 digest folder, got %d", len(entries))
	}

	raw, err := os.ReadFile(filepath.Join(root, "poller", StreamType, entries[0].Name(), "data.ndjson"))
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(string(raw), `"id":"a1"`) || strings.Count(string(raw), "\n") != 2 {
		t.Errorf("unexpected payload:\n%s", raw)
	}
}

// The reason this lane exists at 30s and not 14s: an idle box must not
// generate a digest folder and a Rails round trip every tick.
func TestEmptyResponseWritesNothing(t *testing.T) {
	root := t.TempDir()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	defer voodu.Close()

	var notify atomic.Int32

	rails := okRails(t, 0, &notify)
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)

	f.tick(context.Background())

	if notify.Load() != 0 {
		t.Errorf("notified Rails about nothing (%d calls)", notify.Load())
	}

	if _, err := os.Stat(filepath.Join(root, "poller", StreamType)); err == nil {
		entries, _ := os.ReadDir(filepath.Join(root, "poller", StreamType))
		if len(entries) != 0 {
			t.Errorf("wrote %d folders for an empty response", len(entries))
		}
	}

	if m.notifyOk != 0 {
		t.Errorf("notifyOk = %d", m.notifyOk)
	}
}

// THE property of this lane. The controller filters `ts > since` strictly, so
// asking for `> newest` drops any line sharing that second — and a dropped
// action is a hole in an audit trail nothing will refill.
func TestSinceOverlapsTheWatermark(t *testing.T) {
	f := &Fetcher{watermark: 1_000_000}

	got := f.computeSince(time.Unix(1_000_010, 0))
	want := int64(1_000_000) - int64(Overlap.Seconds())

	if got != want {
		t.Fatalf("since = %d, want %d (watermark minus the overlap)", got, want)
	}
}

func TestSinceColdStartsShort(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	f := &Fetcher{}

	if got, want := f.computeSince(now), now.Add(-ColdStartLookback).Unix(); got != want {
		t.Fatalf("cold since = %d, want %d", got, want)
	}
}

// A poller down for a week must catch up over several ticks, not ask for the
// whole window at once.
func TestSinceIsFlooredByBackfillCap(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	f := &Fetcher{watermark: now.Add(-30 * 24 * time.Hour).Unix()}

	if got, want := f.computeSince(now), now.Add(-BackfillCap).Unix(); got != want {
		t.Fatalf("since = %d, want the backfill floor %d", got, want)
	}
}

func TestWatermarkSeedsFromRails(t *testing.T) {
	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	defer voodu.Close()

	rails := okRails(t, 1_700_000_000, nil)
	defer rails.Close()

	f, _ := newFetcherForTest(t, voodu, rails, t.TempDir())

	f.seedWatermark()

	if f.watermark != 1_700_000_000 {
		t.Fatalf("watermark = %d, want the warehouse high-water mark", f.watermark)
	}
}

// A notify that failed means Rails does NOT have the lines. Advancing anyway
// would skip them permanently.
func TestWatermarkDoesNotAdvanceWhenNotifyFails(t *testing.T) {
	root := t.TempDir()
	now := time.Now()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(activityLine("a1", "done", now) + "\n"))
	}))

	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/internal/poller/digest" {
			w.WriteHeader(http.StatusInternalServerError)

			return
		}

		_ = json.NewEncoder(w).Encode(map[string]any{"version": 1, "since": 0})
	}))

	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)

	f.tick(context.Background())

	if f.watermark != 0 {
		t.Fatalf("watermark advanced to %d after a failed notify", f.watermark)
	}

	if m.notifyFail != 1 {
		t.Errorf("notifyFail = %d", m.notifyFail)
	}
}

// A line we cannot parse is still forwarded. Rails has its own tolerant parse,
// and dropping a line the controller wrote on a guess is the one thing an
// audit trail must not do.
func TestUnparseableLinesAreStillForwarded(t *testing.T) {
	root := t.TempDir()
	now := time.Now()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("{not json\n" + activityLine("a1", "done", now) + "\n"))
	}))

	defer voodu.Close()

	var notify atomic.Int32

	rails := okRails(t, 0, &notify)
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)

	f.tick(context.Background())

	if m.lines != 2 {
		t.Fatalf("lines = %d, want both forwarded", m.lines)
	}

	// The unparseable line must not have poisoned the watermark either.
	if f.watermark != now.UTC().Unix() {
		t.Errorf("watermark = %d, want %d", f.watermark, now.UTC().Unix())
	}
}

func TestFetchFailureIsNotFatal(t *testing.T) {
	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))

	defer voodu.Close()

	rails := okRails(t, 0, nil)
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, t.TempDir())

	f.tick(context.Background())

	if m.errors != 1 {
		t.Errorf("errors = %d", m.errors)
	}

	if f.watermark != 0 {
		t.Errorf("watermark moved on a failed fetch: %d", f.watermark)
	}
}

// The since the controller receives is a plain unix-seconds integer; anything
// else and the controller answers 400 and the lane silently stops working.
func TestSinceIsSentAsUnixSeconds(t *testing.T) {
	var got atomic.Value

	// Inside BackfillCap of the real clock: tick() reads time.Now(), and a
	// watermark older than the cap is floored rather than overlapped, which
	// is a different code path from the one under test here.
	watermark := time.Now().Add(-time.Minute).Unix()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.Store(r.URL.Query().Get("since"))
		w.WriteHeader(http.StatusOK)
	}))

	defer voodu.Close()

	rails := okRails(t, watermark, nil)
	defer rails.Close()

	f, _ := newFetcherForTest(t, voodu, rails, t.TempDir())

	f.seedWatermark()
	f.tick(context.Background())

	raw, _ := got.Load().(string)

	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		t.Fatalf("since %q is not an integer: %v", raw, err)
	}

	if n != watermark-int64(Overlap.Seconds()) {
		t.Errorf("since = %d", n)
	}
}
