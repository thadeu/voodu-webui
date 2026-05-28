package metrics

import (
	"context"
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
	"github.com/voodu/poller/streams/digest"
)

// stubMetrics implements the Metrics interface for tests.
type stubMetrics struct {
	mu         sync.Mutex
	polls      int
	lines      int
	errors     int
	notifyOk   int
	notifyFail int
	lastStream string
	lastIsland string
}

func (s *stubMetrics) StreamPollIncr(stream, island string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.polls++
	s.lastStream = stream
	s.lastIsland = island
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

func newFetcherForTest(t *testing.T, vooduSrv, railsSrv *httptest.Server, root string) (*Fetcher, *stubMetrics) {
	t.Helper()

	rails := client.NewRailsClient(railsSrv.URL, "tok")
	isl := client.Island{ID: "island-1", Endpoint: vooduSrv.URL, PAT: "pat-1"}

	m := &stubMetrics{}
	f := NewFetcher(isl, root, 100*time.Millisecond, rails, m)

	return f, m
}

func TestFetcher_HappyPath_WritesFolderAndNotifies(t *testing.T) {
	root := t.TempDir()

	var fetchedSince atomic.Value
	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/pat/v1/metrics/dump" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer pat-1" {
			t.Errorf("missing bearer auth: %q", r.Header.Get("Authorization"))
		}
		fetchedSince.Store(r.URL.Query().Get("since"))
		_, _ = w.Write([]byte(`{"name":"cpu","val":1}` + "\n" + `{"name":"mem","val":2}` + "\n"))
	}))
	defer voodu.Close()

	var notifyCalls atomic.Int32
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/poller/digest" {
			t.Errorf("rails path: %s", r.URL.Path)
		}
		if r.Header.Get("X-Voodu-Internal-Token") != "tok" {
			t.Errorf("missing internal token")
		}
		notifyCalls.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	f.tick(ctx)

	if m.polls != 1 {
		t.Errorf("polls = %d", m.polls)
	}
	if m.errors != 0 {
		t.Errorf("errors = %d", m.errors)
	}
	if m.notifyOk != 1 {
		t.Errorf("notifyOk = %d", m.notifyOk)
	}
	if notifyCalls.Load() != 1 {
		t.Errorf("rails called %d times", notifyCalls.Load())
	}

	streamRoot := digest.StreamRoot(root, "metrics")
	entries, err := os.ReadDir(streamRoot)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("want 1 folder, got %d", len(entries))
	}

	folder := filepath.Join(streamRoot, entries[0].Name())
	data, err := os.ReadFile(filepath.Join(folder, "data.ndjson"))
	if err != nil {
		t.Fatalf("read data: %v", err)
	}
	if !strings.Contains(string(data), "cpu") {
		t.Errorf("data missing payload: %q", string(data))
	}

	metaPath := filepath.Join(folder, "meta.json")
	if _, err := os.Stat(metaPath); err != nil {
		t.Errorf("meta.json missing: %v", err)
	}

	// Watermark should have advanced after the successful notify.
	if f.watermark.IsZero() {
		t.Error("watermark not advanced")
	}
}

func TestFetcher_RailsFailure_KeepsFolderAndDoesNotAdvanceWatermark(t *testing.T) {
	root := t.TempDir()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("payload\n"))
	}))
	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom"))
	}))
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)
	before := f.watermark

	ctx := context.Background()
	f.tick(ctx)

	if m.errors != 1 {
		t.Errorf("errors = %d, want 1", m.errors)
	}
	if m.notifyFail != 1 {
		t.Errorf("notifyFail = %d, want 1", m.notifyFail)
	}
	if m.notifyOk != 0 {
		t.Errorf("notifyOk = %d, want 0", m.notifyOk)
	}
	if !f.watermark.Equal(before) {
		t.Errorf("watermark advanced despite notify failure")
	}

	// Folder should still be on disk so cleanup GC handles it later.
	entries, err := os.ReadDir(digest.StreamRoot(root, "metrics"))
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("want 1 stale folder, got %d", len(entries))
	}
}

func TestFetcher_VooduFailure_NoFolderWritten(t *testing.T) {
	root := t.TempDir()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("rails should not be called when voodu fails")
	}))
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)
	f.tick(context.Background())

	if m.errors != 1 {
		t.Errorf("errors = %d, want 1", m.errors)
	}

	entries, _ := os.ReadDir(digest.StreamRoot(root, "metrics"))
	if len(entries) != 0 {
		t.Errorf("folder created on voodu failure: %d entries", len(entries))
	}
}

func TestFetcher_SinceParam_ColdStart(t *testing.T) {
	f := &Fetcher{}
	got := f.sinceParam()

	if got == "" {
		t.Fatal("empty since on cold start")
	}

	// Format is unix seconds (integer-as-string) — matches Ruby's
	// `MetricsSyncIslandJob` wire shape (`since: since.to_i`) and the
	// controller's `/metrics/dump` parser.
	secs, err := strconv.ParseInt(got, 10, 64)
	if err != nil {
		t.Fatalf("parse unix seconds: %v", err)
	}
	ts := time.Unix(secs, 0)
	age := time.Since(ts)
	if age < ColdStartLookback-time.Second || age > ColdStartLookback+time.Second {
		t.Errorf("cold-start watermark age = %v, want ~%v", age, ColdStartLookback)
	}
}
