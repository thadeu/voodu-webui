package poller

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/voodu/poller/client"
)

// fakeDocker serves one pod's log the way dockerd's json-file reader does:
// `tail` picks the last N lines FIRST, then `since` (inclusive) drops the
// older ones. It records the `tail` of every request ("" = no tail) so a
// test can tell a cheap tailed read from a full one.
type fakeDocker struct {
	mu    sync.Mutex
	lines []fakeLine
	tails []string
}

type fakeLine struct {
	ts   time.Time
	body string
}

func (d *fakeDocker) add(ts time.Time, body string) {
	d.mu.Lock()
	defer d.mu.Unlock()

	d.lines = append(d.lines, fakeLine{ts: ts, body: body})
}

func (d *fakeDocker) requestedTails() []string {
	d.mu.Lock()
	defer d.mu.Unlock()

	return append([]string(nil), d.tails...)
}

func (d *fakeDocker) server(t *testing.T, pod string) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/pat/v1/pods/"+pod+"/logs" {
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)

			return
		}

		q := r.URL.Query()

		d.mu.Lock()
		defer d.mu.Unlock()

		d.tails = append(d.tails, q.Get("tail"))

		out := d.lines

		if raw := q.Get("tail"); raw != "" {
			n, _ := strconv.Atoi(raw)

			if n < len(out) {
				out = out[len(out)-n:]
			}
		}

		var since time.Time

		if raw := q.Get("since"); raw != "" {
			since, _ = time.Parse(time.RFC3339Nano, raw)
		}

		for _, l := range out {
			if l.ts.Before(since) {
				continue
			}

			_, _ = w.Write([]byte(logLine(l.ts, l.body)))
		}
	}))
}

// tailPoller wires a poller for one pod against the fake docker, with the
// pod's floor already on disk (one persisted line at `floor`) so the next
// poll resumes from it, like a poller that has been running for a while.
func tailPoller(t *testing.T, d *fakeDocker, pod string, floor time.Time, tailLines int) (*ServerPoller, *Writer, string) {
	t.Helper()

	root := t.TempDir()
	w := NewWriter(root, nil)
	server := client.Server{ID: "isl-1"}

	if !floor.IsZero() {
		rec := Record{Pod: pod, TS: floor, Msg: "floor", Raw: "floor"}

		if err := w.Append(server.ID, pod, rec); err != nil {
			t.Fatalf("seed append: %v", err)
		}
	}

	srv := d.server(t, pod)
	t.Cleanup(srv.Close)

	server.Endpoint = srv.URL

	p := NewServerPoller(server, root, time.Minute, 12*time.Hour, w, nopMetrics{})
	p.TailLines = tailLines

	return p, w, server.ID
}

// Steady state: a quiet window (far under TailLines) is ONE tailed request.
// Without tail, dockerd decodes the pod's whole log file on every poll (a
// 71MB FreeSWITCH log cost ~2s of daemon CPU per tick).
func TestPollPod_SteadyStateIsOneTailedRead(t *testing.T) {
	pod := "fsw-freeswitch.0"
	floor := time.Now().UTC().Add(-time.Minute).Truncate(time.Millisecond)

	d := &fakeDocker{}

	for i := 0; i < 50; i++ {
		d.add(floor.Add(-time.Duration(50-i)*time.Second), fmt.Sprintf("old-%d", i))
	}

	d.add(floor, "floor")

	for i := 0; i < 20; i++ {
		d.add(floor.Add(time.Duration(i+1)*time.Millisecond), fmt.Sprintf("new-%d", i))
	}

	p, _, _ := tailPoller(t, d, pod, floor, 10000)

	written, _, _ := p.pollPod(context.Background(), pod)

	if written != 20 {
		t.Fatalf("wrote %d lines, want the 20 new ones", written)
	}

	if got := d.requestedTails(); len(got) != 1 || got[0] != "10000" {
		t.Fatalf("requests tails=%q, want exactly one request with tail=10000", got)
	}
}

// THE no-loss guarantee: a burst bigger than TailLines between two polls.
// The tailed answer is the newest N lines only, so the poller must notice
// the gap (no line at its floor) and widen until it holds every line.
func TestPollPod_BurstLargerThanTailLosesNothing(t *testing.T) {
	pod := "fsw-freeswitch.0"
	floor := time.Now().UTC().Add(-time.Minute).Truncate(time.Millisecond)

	d := &fakeDocker{}
	d.add(floor, "floor")

	const burst = 500

	for i := 0; i < burst; i++ {
		d.add(floor.Add(time.Duration(i+1)*time.Millisecond), fmt.Sprintf("burst-%d", i))
	}

	p, w, serverID := tailPoller(t, d, pod, floor, 10)

	written, _, _ := p.pollPod(context.Background(), pod)

	if written != burst {
		t.Fatalf("wrote %d lines, want all %d — the burst lost lines", written, burst)
	}

	if got := countLines(t, w.DailyFile(serverID, pod, floor)); got != burst+1 {
		t.Fatalf("day file has %d lines, want %d (floor + burst, no gaps, no duplicates)", got, burst+1)
	}

	tails := d.requestedTails()

	if last := tails[len(tails)-1]; last != "" {
		t.Fatalf("requests tails=%q, want the last one without tail (full read)", tails)
	}
}

// A burst that fits the wider attempt does not fall back to the full read.
func TestPollPod_BurstWithinWiderTailSkipsFullRead(t *testing.T) {
	pod := "fsw-freeswitch.0"
	floor := time.Now().UTC().Add(-time.Minute).Truncate(time.Millisecond)

	d := &fakeDocker{}
	d.add(floor, "floor")

	const burst = 50

	for i := 0; i < burst; i++ {
		d.add(floor.Add(time.Duration(i+1)*time.Millisecond), fmt.Sprintf("burst-%d", i))
	}

	p, _, _ := tailPoller(t, d, pod, floor, 10)

	written, _, _ := p.pollPod(context.Background(), pod)

	if written != burst {
		t.Fatalf("wrote %d lines, want all %d", written, burst)
	}

	for _, tail := range d.requestedTails() {
		if tail == "" {
			t.Fatalf("requests tails=%q, want no full read for a burst under TailLines×%d", d.requestedTails(), tailEscalation)
		}
	}
}

// A brand-new pod has no floor line to find, so the "reached since" proof
// never holds. A pod with fewer lines than the tail must still be read
// cheaply: a wider tail that brings nothing more proves the window whole.
func TestPollPod_NewSmallPodNeverFullReads(t *testing.T) {
	pod := "fsw-jobs.3ae9"
	now := time.Now().UTC()

	d := &fakeDocker{}

	for i := 0; i < 5; i++ {
		d.add(now.Add(-time.Duration(5-i)*time.Second), fmt.Sprintf("line-%d", i))
	}

	p, _, _ := tailPoller(t, d, pod, time.Time{}, 10)

	written, _, _ := p.pollPod(context.Background(), pod)

	if written != 5 {
		t.Fatalf("wrote %d lines, want 5", written)
	}

	for _, tail := range d.requestedTails() {
		if tail == "" {
			t.Fatalf("requests tails=%q, want no full read for a pod smaller than the tail", d.requestedTails())
		}
	}
}

// A quiet pod whose newest lines are all older than the floor answers an
// empty window. That is complete as is: no wider read, no full read.
func TestPollPod_EmptyWindowIsOneRead(t *testing.T) {
	pod := "voodu-caddy"
	floor := time.Now().UTC().Add(-time.Minute).Truncate(time.Millisecond)

	d := &fakeDocker{}
	d.add(floor.Add(-time.Second), "older")

	p, _, _ := tailPoller(t, d, pod, floor, 10)

	written, _, _ := p.pollPod(context.Background(), pod)

	if written != 0 {
		t.Fatalf("wrote %d lines, want 0", written)
	}

	if got := d.requestedTails(); len(got) != 1 {
		t.Fatalf("requests tails=%q, want exactly one request", got)
	}
}

// TailLines=0 keeps the old behaviour (no tail, full read) as an escape hatch.
func TestPollPod_ZeroTailLinesReadsWithoutTail(t *testing.T) {
	pod := "fsw-freeswitch.0"
	floor := time.Now().UTC().Add(-time.Minute).Truncate(time.Millisecond)

	d := &fakeDocker{}
	d.add(floor, "floor")
	d.add(floor.Add(time.Millisecond), "new")

	p, _, _ := tailPoller(t, d, pod, floor, 0)

	written, _, _ := p.pollPod(context.Background(), pod)

	if written != 1 {
		t.Fatalf("wrote %d lines, want 1", written)
	}

	if got := d.requestedTails(); len(got) != 1 || got[0] != "" {
		t.Fatalf("requests tails=%q, want one request without tail", got)
	}
}
