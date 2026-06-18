package metrics

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

func iso(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

// metricLine builds a realistic dump line (ts + source + identity + a
// metric value), the shape the controller actually emits.
func metricLine(source, scope, name, container string, t time.Time) string {
	b := &strings.Builder{}
	b.WriteString(`{"ts":"`)
	b.WriteString(iso(t))
	b.WriteString(`","source":"`)
	b.WriteString(source)
	b.WriteString(`"`)
	if scope != "" {
		b.WriteString(`,"scope":"` + scope + `"`)
	}
	if name != "" {
		b.WriteString(`,"name":"` + name + `"`)
	}
	if container != "" {
		b.WriteString(`,"container":"` + container + `"`)
	}
	b.WriteString(`,"cpu_percent":1.5}`)

	return b.String()
}

func TestFetcher_HappyPath_WritesFolderAndNotifies(t *testing.T) {
	root := t.TempDir()
	now := time.Now()

	var fetchedSince atomic.Value
	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/pat/v1/metrics/dump" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer pat-1" {
			t.Errorf("missing bearer auth: %q", r.Header.Get("Authorization"))
		}
		fetchedSince.Store(r.URL.Query().Get("since"))
		_, _ = w.Write([]byte(
			metricLine("system", "", "", "", now) + "\n" +
				metricLine("pod", "fsw", "freeswitch", "fsw-freeswitch.0", now) + "\n",
		))
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

	// Watermarks committed after the successful notify — one per source.
	if f.sourceTS["system"] == 0 || f.sourceTS["pod"] == 0 {
		t.Errorf("per-source watermarks not advanced: %#v", f.sourceTS)
	}
}

func TestFetcher_RailsFailure_KeepsFolderAndDoesNotAdvanceWatermark(t *testing.T) {
	root := t.TempDir()
	now := time.Now()

	voodu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(metricLine("system", "", "", "", now) + "\n"))
	}))
	defer voodu.Close()

	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom"))
	}))
	defer rails.Close()

	f, m := newFetcherForTest(t, voodu, rails, root)

	f.tick(context.Background())

	if m.errors != 1 {
		t.Errorf("errors = %d, want 1", m.errors)
	}
	if m.notifyFail != 1 {
		t.Errorf("notifyFail = %d, want 1", m.notifyFail)
	}
	if m.notifyOk != 0 {
		t.Errorf("notifyOk = %d, want 0", m.notifyOk)
	}
	// Watermarks must NOT be committed on notify failure, so the next
	// tick re-fetches the same window.
	if len(f.sourceTS) != 0 {
		t.Errorf("watermarks advanced despite notify failure: %#v", f.sourceTS)
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

// ── since selection ─────────────────────────────────────────────────

func newBareFetcher() *Fetcher {
	return &Fetcher{
		seriesTS: make(map[string]int64),
		sourceTS: make(map[string]int64),
	}
}

// A fast source must not drag `since` past a slower one: the boundary is
// the OLDEST live source's watermark, so the laggard catches up. This is
// the exact bug — system racing ahead and freezing pod.
func TestComputeSince_UsesOldestLiveSource(t *testing.T) {
	now := time.Now()
	f := newBareFetcher()
	f.sourceTS["system"] = now.Add(-1 * time.Minute).Unix()
	f.sourceTS["pod"] = now.Add(-5 * time.Minute).Unix()

	got := f.computeSince(now)
	want := now.Add(-5 * time.Minute).Unix()
	if got != want {
		t.Fatalf("since = %d, want oldest (pod) = %d", got, want)
	}
}

func TestComputeSince_ColdStart(t *testing.T) {
	now := time.Now()
	got := newBareFetcher().computeSince(now)
	want := now.Add(-ColdStartLookback).Unix()
	if got != want {
		t.Fatalf("cold since = %d, want %d", got, want)
	}
}

// A source idle beyond BackfillCap is excluded so it can't drag `since`
// into an ever-widening re-stream; the live source sets the boundary.
func TestComputeSince_ExcludesStaleSource(t *testing.T) {
	now := time.Now()
	f := newBareFetcher()
	f.sourceTS["system"] = now.Add(-30 * time.Second).Unix()
	f.sourceTS["ingress"] = now.Add(-2 * time.Hour).Unix() // dead

	got := f.computeSince(now)
	want := now.Add(-30 * time.Second).Unix()
	if got != want {
		t.Fatalf("since = %d, want live system = %d (stale ingress must be ignored)", got, want)
	}
}

func TestComputeSince_AllStaleFallsBackToCap(t *testing.T) {
	now := time.Now()
	f := newBareFetcher()
	f.sourceTS["system"] = now.Add(-3 * time.Hour).Unix()

	got := f.computeSince(now)
	want := now.Add(-BackfillCap).Unix()
	if got != want {
		t.Fatalf("since = %d, want floor = %d", got, want)
	}
}

// ── cold-start backfill seed ─────────────────────────────────────────

// A seeded warehouse high-water mark wins on cold start: the first tick
// resumes from what Rails already holds (backfilling the offline gap),
// bypassing BOTH the short lookback AND the BackfillCap floor — an 8h gap
// must come through, not get clamped to 10m.
func TestComputeSince_ColdStartPrefersSeed(t *testing.T) {
	now := time.Now()
	f := newBareFetcher()
	f.seededSince = now.Add(-8 * time.Hour).Unix()

	got := f.computeSince(now)
	if got != f.seededSince {
		t.Fatalf("since = %d, want seeded = %d (must bypass the 10m cap to backfill the gap)", got, f.seededSince)
	}
}

// Once real rows arrive (sourceTS populated), the seed is ignored — the
// per-source path drives `since`, so the seed is strictly one-shot.
func TestComputeSince_SeedIgnoredOnceSourceSeen(t *testing.T) {
	now := time.Now()
	f := newBareFetcher()
	f.seededSince = now.Add(-8 * time.Hour).Unix()
	f.sourceTS["system"] = now.Add(-30 * time.Second).Unix()

	got := f.computeSince(now)
	want := now.Add(-30 * time.Second).Unix()
	if got != want {
		t.Fatalf("since = %d, want live system = %d (seed must not apply after first rows)", got, want)
	}
}

func TestSeedSince_FromWarehouse(t *testing.T) {
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/poller/metrics_watermark" {
			t.Errorf("rails path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("tenant_id") != "island-1" {
			t.Errorf("tenant_id = %q", r.URL.Query().Get("tenant_id"))
		}
		if r.Header.Get("X-Voodu-Internal-Token") != "tok" {
			t.Errorf("missing internal token")
		}
		_, _ = w.Write([]byte(`{"version":1,"since":1718700000}`))
	}))
	defer rails.Close()

	f := NewFetcher(client.Island{ID: "island-1"}, t.TempDir(), time.Second, client.NewRailsClient(rails.URL, "tok"), &stubMetrics{})
	f.seedSince()

	if f.seededSince != 1718700000 {
		t.Fatalf("seededSince = %d, want 1718700000", f.seededSince)
	}
}

// An empty warehouse (since=0) or a Rails error leaves seededSince at 0 so
// computeSince falls back to the short cold-start lookback rather than
// pulling the controller's full retention on a brand-new island.
func TestSeedSince_EmptyWarehouseStaysZero(t *testing.T) {
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"version":1,"since":0}`))
	}))
	defer rails.Close()

	f := NewFetcher(client.Island{ID: "island-1"}, t.TempDir(), time.Second, client.NewRailsClient(rails.URL, "tok"), &stubMetrics{})
	f.seedSince()

	if f.seededSince != 0 {
		t.Fatalf("seededSince = %d, want 0", f.seededSince)
	}
}

// ── dedup ────────────────────────────────────────────────────────────

// The overlap a laggard-driven `since` re-delivers must be dropped, while
// genuinely new rows pass — keyed per time-series so distinct pods
// sampled in the same second both survive.
func TestDedup_DropsOverlapKeepsNewAndDistinct(t *testing.T) {
	base := time.Date(2026, 6, 16, 19, 44, 0, 0, time.UTC)
	f := newBareFetcher()
	// Already stored: system @ base, freeswitch @ base.
	f.seriesTS["system\x1f\x1f\x1f"] = base.Unix()
	f.seriesTS["pod\x1ffsw\x1ffreeswitch\x1ffsw-freeswitch.0"] = base.Unix()
	f.sourceTS["system"] = base.Unix()
	f.sourceTS["pod"] = base.Unix()

	body := strings.Join([]string{
		metricLine("system", "", "", "", base),                                               // re-delivered → drop
		metricLine("pod", "fsw", "freeswitch", "fsw-freeswitch.0", base.Add(60*time.Second)), // new → keep
		metricLine("system", "", "", "", base.Add(15*time.Second)),                           // new → keep
		metricLine("pod", "fsw", "api", "fsw-api.0", base.Add(30*time.Second)),               // same-second distinct
		metricLine("pod", "fsw", "web", "fsw-web.0", base.Add(30*time.Second)),               // same-second distinct
	}, "\n") + "\n"

	kept, count, seriesTS, _, err := f.dedup(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if count != 4 {
		t.Fatalf("kept %d rows, want 4 (1 overlap dropped)", count)
	}

	got := string(kept)
	if strings.Count(got, `"container":"fsw-api.0"`) != 1 || strings.Count(got, `"container":"fsw-web.0"`) != 1 {
		t.Fatalf("same-second distinct pods must both survive:\n%s", got)
	}
	if seriesTS["pod\x1ffsw\x1ffreeswitch\x1ffsw-freeswitch.0"] != base.Add(60*time.Second).Unix() {
		t.Fatalf("freeswitch series watermark did not advance in the returned map")
	}
	// dedup must NOT mutate the committed state (caller commits on success).
	if f.seriesTS["pod\x1ffsw\x1ffreeswitch\x1ffsw-freeswitch.0"] != base.Unix() {
		t.Fatalf("dedup mutated f.seriesTS before commit")
	}
}

// Re-running the same batch after committing the advances keeps nothing.
func TestDedup_IdempotentOnceCommitted(t *testing.T) {
	base := time.Date(2026, 6, 16, 19, 44, 0, 0, time.UTC)
	f := newBareFetcher()
	body := metricLine("pod", "fsw", "freeswitch", "fsw-freeswitch.0", base) + "\n"

	_, c1, seriesTS, sourceTS, _ := f.dedup(strings.NewReader(body))
	if c1 != 1 {
		t.Fatalf("first pass kept %d, want 1", c1)
	}
	// Commit, as tick does after a successful notify.
	f.seriesTS, f.sourceTS = seriesTS, sourceTS

	_, c2, _, _, _ := f.dedup(strings.NewReader(body))
	if c2 != 0 {
		t.Fatalf("second pass kept %d, want 0 (already persisted)", c2)
	}
}

// Malformed / ts-less lines pass through (Rails drops them at insert);
// dropping them here could lose a valid sample on a transient hiccup.
func TestDedup_PassesThroughUnparseable(t *testing.T) {
	f := newBareFetcher()
	body := "not-json\n" + `{"source":"pod","scope":"x","name":"y","container":"z"}` + "\n"

	_, count, _, _, err := f.dedup(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("kept %d, want 2 (both pass through)", count)
	}
}
