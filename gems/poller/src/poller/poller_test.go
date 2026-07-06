package poller

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/voodu/poller/client"
)

// podLogServer routes the two endpoints a per-pod tick hits: the roster
// (/api/pat/v1/pods) and a per-pod log stream (/api/pat/v1/pods/<name>/logs).
// logsBody is returned verbatim for any pod logs request.
func podLogServer(t *testing.T, podNames []string, logsBody string) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/pat/v1/pods":
			parts := make([]string, 0, len(podNames))
			for _, n := range podNames {
				parts = append(parts, fmt.Sprintf(`{"name":%q}`, n))
			}
			// PAT plane wraps JSON in {"status","data"}; roster is data.pods.
			_, _ = fmt.Fprintf(w, `{"status":"ok","data":{"degraded":false,"pods":[%s]}}`, strings.Join(parts, ","))

		case strings.HasPrefix(r.URL.Path, "/api/pat/v1/pods/") && strings.HasSuffix(r.URL.Path, "/logs"):
			_, _ = w.Write([]byte(logsBody))

		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

// logLine is the single-pod stream shape (timestamps=true): "<RFC3339Nano> <body>".
func logLine(ts time.Time, body string) string {
	return ts.UTC().Format(time.RFC3339Nano) + " " + body + "\n"
}

// THE guarantee: a re-delivered overlap LARGER than the dedup ring still
// produces ZERO duplicates. The unbounded timestamp floor drops the bulk; the
// ring only disambiguates the single boundary instant, so it never overflows.
func TestPollPod_NoDuplicatesOnHugeOverlap(t *testing.T) {
	root := t.TempDir()
	w := NewWriter(root, nil)
	server := client.Server{ID: "isl-1"}
	pod := "fsw-freeswitch.0"

	// Seed MORE lines than the ring can hold (5000), so if the ring were the
	// only dedup, the oldest overlap would slip through as duplicates.
	const seeded = 5500
	base := time.Now().UTC().Add(-1 * time.Hour).Truncate(time.Second)

	seedTS := func(i int) time.Time { return base.Add(time.Duration(i) * time.Millisecond) }
	body := func(i int) string { return fmt.Sprintf(`{"n":%d}`, i) }

	for i := 0; i < seeded; i++ {
		rec := Record{Pod: pod, TS: seedTS(i), Msg: body(i), Raw: body(i)}
		if err := w.Append(server.ID, pod, rec); err != nil {
			t.Fatalf("seed append: %v", err)
		}
	}

	// The controller re-delivers the ENTIRE seeded window (overlap) plus 10
	// genuinely new lines after it.
	var sb strings.Builder
	for i := 0; i < seeded; i++ {
		sb.WriteString(logLine(seedTS(i), body(i)))
	}
	newBase := seedTS(seeded - 1).Add(time.Second)
	for j := 0; j < 10; j++ {
		sb.WriteString(logLine(newBase.Add(time.Duration(j)*time.Millisecond), fmt.Sprintf(`{"new":%d}`, j)))
	}

	srv := podLogServer(t, []string{pod}, sb.String())
	defer srv.Close()

	server.Endpoint = srv.URL
	p := NewServerPoller(server, root, time.Minute, 12*time.Hour, w, nopMetrics{})

	written, _, deduped := p.pollPod(context.Background(), pod)

	if written != 10 {
		t.Fatalf("wrote %d lines, want 10 (only the genuinely-new ones)", written)
	}
	if deduped != seeded {
		t.Fatalf("deduped %d, want %d (the whole re-delivered overlap)", deduped, seeded)
	}

	// The day file must hold exactly one copy of everything: seeded + new.
	path := w.DailyFile(server.ID, pod, base)
	if got := countLines(t, path); got != seeded+10 {
		t.Fatalf("day file has %d lines, want %d — duplicates leaked", got, seeded+10)
	}
}

// A whole tick: discover the roster, fetch each pod from its resume point,
// persist the new lines. A brand-new pod (no prior watermark) backfills the
// cold-start window.
func TestTick_BackfillsRosterPods(t *testing.T) {
	root := t.TempDir()
	w := NewWriter(root, nil)
	server := client.Server{ID: "isl-1"}
	pod := "fsw-controller.0793"

	now := time.Now().UTC().Truncate(time.Second)
	body := logLine(now.Add(-2*time.Minute), `{"msg":"a"}`) +
		logLine(now.Add(-1*time.Minute), `{"msg":"b"}`)

	srv := podLogServer(t, []string{pod}, body)
	defer srv.Close()

	server.Endpoint = srv.URL
	p := NewServerPoller(server, root, time.Minute, 12*time.Hour, w, nopMetrics{})

	p.tick(context.Background())
	waitIdle(t, p, 2*time.Second) // tick is fire-and-forget — let the pod goroutine finish

	path := w.DailyFile(server.ID, pod, now)
	if got := countLines(t, path); got != 2 {
		t.Fatalf("day file has %d lines, want 2", got)
	}
}

// waitIdle blocks until no per-pod fetch is in flight (the fire-and-forget
// goroutines a tick launched have all finished), or fails after timeout.
func waitIdle(t *testing.T, p *ServerPoller, timeout time.Duration) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for {
		p.mu.Lock()
		n := len(p.inflight)
		p.mu.Unlock()

		if n == 0 {
			return
		}

		if time.Now().After(deadline) {
			t.Fatalf("pollers still in flight after %s", timeout)
		}

		time.Sleep(5 * time.Millisecond)
	}
}

func TestSinceFor(t *testing.T) {
	p := &ServerPoller{MaxBackfill: 12 * time.Hour}
	now := time.Now()

	// brand-new pod (zero floor) → cold-start lookback.
	cold := p.sinceFor(time.Time{})
	if d := now.Add(-ColdStartLookback).Sub(cold).Abs(); d > 2*time.Second {
		t.Errorf("zero floor: since=%v, want ~now-%s", cold, ColdStartLookback)
	}

	// floor within the cap → resume from the floor itself.
	recent := now.Add(-30 * time.Second)
	if got := p.sinceFor(recent); !got.Equal(recent) {
		t.Errorf("recent floor: since=%v, want %v", got, recent)
	}

	// floor older than the cap → clamp to now-MaxBackfill (bounded recovery).
	old := now.Add(-48 * time.Hour)
	got := p.sinceFor(old)
	if d := now.Add(-p.MaxBackfill).Sub(got).Abs(); d > 2*time.Second {
		t.Errorf("old floor: since=%v, want ~now-%s (capped)", got, p.MaxBackfill)
	}
}
