package state

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/voodu/poller/client"
	"github.com/voodu/poller/streams/digest"
)

type stubMetrics struct {
	mu         sync.Mutex
	polls      int
	errors     int
	notifyOk   int
	notifyFail int
	lines      int
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

// trackingServer stamps each request path with a monotonic counter so
// the test can prove BOTH endpoints were hit (and concurrently).
func newVooduServer(t *testing.T, podsBody, systemBody string, onPods, onSystem func()) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/pat/v1/pods":
			if q := r.URL.Query(); q.Get("detail") != "true" || q.Get("spec") != "true" {
				t.Errorf("pods query missing flags: %v", q)
			}
			if onPods != nil {
				onPods()
			}
			_, _ = w.Write([]byte(podsBody))
		case "/api/pat/v1/system":
			if onSystem != nil {
				onSystem()
			}
			_, _ = w.Write([]byte(systemBody))
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func TestFetcher_BothFilesCommittedBeforeNotify(t *testing.T) {
	root := t.TempDir()

	var notifyHit atomic.Bool

	voodu := newVooduServer(t, `[{"id":"pod-a"}]`, `{"hostname":"host"}`, nil, nil)
	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// At notify time both files MUST already be on disk under the
		// digest folder. We can't peek at the sync_hash here so walk
		// the state dir and assert both expected files exist in any
		// folder we find.
		entries, err := os.ReadDir(digest.StreamRoot(root, "state"))
		if err != nil || len(entries) == 0 {
			t.Errorf("notify fired before folder existed: err=%v entries=%d", err, len(entries))
		}
		for _, e := range entries {
			folder := filepath.Join(digest.StreamRoot(root, "state"), e.Name())
			for _, name := range []string{"pods.json", "system.json", "meta.json"} {
				if _, err := os.Stat(filepath.Join(folder, name)); err != nil {
					t.Errorf("notify fired with %s missing: %v", name, err)
				}
			}
		}
		notifyHit.Store(true)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer rails.Close()

	railsClient := client.NewRailsClient(rails.URL, "tok")
	isl := client.Island{ID: "island-1", Endpoint: voodu.URL, PAT: "pat-1"}
	m := &stubMetrics{}
	f := NewFetcher(isl, root, time.Second, railsClient, m)

	f.tick(context.Background())

	if !notifyHit.Load() {
		t.Error("notify never fired")
	}
	if m.notifyOk != 1 {
		t.Errorf("notifyOk = %d", m.notifyOk)
	}
	if m.errors != 0 {
		t.Errorf("errors = %d", m.errors)
	}
}

func TestFetcher_ParallelFetch(t *testing.T) {
	root := t.TempDir()

	var (
		podsStart, podsDone     time.Time
		systemStart, systemDone time.Time
	)

	const work = 30 * time.Millisecond

	voodu := newVooduServer(t, "{}", "{}",
		func() {
			podsStart = time.Now()
			time.Sleep(work)
			podsDone = time.Now()
		},
		func() {
			systemStart = time.Now()
			time.Sleep(work)
			systemDone = time.Now()
		},
	)
	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer rails.Close()

	railsClient := client.NewRailsClient(rails.URL, "tok")
	isl := client.Island{ID: "island-1", Endpoint: voodu.URL, PAT: "pat-1"}
	f := NewFetcher(isl, root, time.Second, railsClient, &stubMetrics{})

	tickStart := time.Now()
	f.tick(context.Background())
	tickElapsed := time.Since(tickStart)

	// Parallel fetch: tick should finish in ~work, not ~2*work.
	if tickElapsed > 2*work-5*time.Millisecond {
		t.Errorf("tick elapsed %v looks serial (>= 2*work=%v)", tickElapsed, 2*work)
	}

	// Both handlers should have started before either finished — a
	// truly parallel run.
	earliestDone := podsDone
	if systemDone.Before(earliestDone) {
		earliestDone = systemDone
	}
	latestStart := podsStart
	if systemStart.After(latestStart) {
		latestStart = systemStart
	}
	if !latestStart.Before(earliestDone) {
		t.Errorf("handlers were serial: latestStart=%v earliestDone=%v", latestStart, earliestDone)
	}
}

func TestFetcher_PodsFails_NoFolderWritten(t *testing.T) {
	root := t.TempDir()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/pat/v1/pods" {
			w.WriteHeader(http.StatusInternalServerError)

			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("rails should not be called when pods fetch fails")
	}))
	defer rails.Close()

	railsClient := client.NewRailsClient(rails.URL, "tok")
	isl := client.Island{ID: "island-1", Endpoint: voodu.URL, PAT: "pat-1"}
	m := &stubMetrics{}
	f := NewFetcher(isl, root, time.Second, railsClient, m)

	f.tick(context.Background())

	if m.errors != 1 {
		t.Errorf("errors = %d, want 1", m.errors)
	}

	entries, _ := os.ReadDir(digest.StreamRoot(root, "state"))
	if len(entries) != 0 {
		t.Errorf("folder created despite pods failure: %d", len(entries))
	}
}
