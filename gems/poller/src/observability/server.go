// Package observability exposes the poller's liveness + metrics surface.
//
// Bound on :9999 by default. The metrics are hand-rolled Prometheus
// text format (no client_golang dependency) — this binary is small
// enough that pulling in the official lib's transitive deps doubles
// the binary size for two counters and three gauges.
package observability

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// State is the shared metrics ledger between the poller goroutines and
// the HTTP handlers. All callbacks are safe for concurrent use.
//
// Per-server counters are kept in maps protected by `mu`; the
// last-poll timestamp is kept as an int64 epoch for lockless reads.
type State struct {
	mu     sync.RWMutex
	lines  map[string]int64
	polls  map[string]int64
	errors map[string]int64
	caps   map[string]int64 // key = server + "|" + pod
	wmAge  map[string]float64

	// Per-(stream, server) counters for the metrics + state streams.
	// Key shape: "<stream>|<server>". Notify counters tack on a result
	// suffix: "<stream>|<server>|ok" or "<stream>|<server>|fail".
	streamPolls  map[string]int64
	streamLines  map[string]int64
	streamErrors map[string]int64
	streamNotify map[string]int64

	lastPollUnixNano atomic.Int64
	serverCount      atomic.Int64
}

// NewState returns a zero-valued State.
func NewState() *State {
	return &State{
		lines:        map[string]int64{},
		polls:        map[string]int64{},
		errors:       map[string]int64{},
		caps:         map[string]int64{},
		wmAge:        map[string]float64{},
		streamPolls:  map[string]int64{},
		streamLines:  map[string]int64{},
		streamErrors: map[string]int64{},
		streamNotify: map[string]int64{},
	}
}

// StreamPollIncr bumps poller_stream_polls_total{stream, server}.
func (s *State) StreamPollIncr(stream, server string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.streamPolls[stream+"|"+server]++
}

// StreamLinesIncr bumps poller_stream_lines_total{stream, server} by n.
// For state-style payloads (single JSON blob) n is the byte count,
// which doubles as a rough activity gauge.
func (s *State) StreamLinesIncr(stream, server string, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.streamLines[stream+"|"+server] += int64(n)
}

// StreamErrorIncr bumps poller_stream_errors_total{stream, server}.
func (s *State) StreamErrorIncr(stream, server string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.streamErrors[stream+"|"+server]++
}

// StreamNotifyIncr bumps poller_stream_notify_total{stream, server, result}
// where result is "ok" or "fail".
func (s *State) StreamNotifyIncr(stream, server, result string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.streamNotify[stream+"|"+server+"|"+result]++
}

// LinesIncr — implements poller.Metrics.
func (s *State) LinesIncr(server string, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lines[server] += int64(n)
}

// PollIncr — implements poller.Metrics.
func (s *State) PollIncr(server string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.polls[server]++
}

// ErrorIncr — implements poller.Metrics.
func (s *State) ErrorIncr(server string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.errors[server]++
}

// CapHitIncr — implements poller.Metrics.
func (s *State) CapHitIncr(server, pod string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.caps[server+"|"+pod]++
}

// WatermarkAge — implements poller.Metrics.
func (s *State) WatermarkAge(server string, age time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.wmAge[server] = age.Seconds()
}

// SetLastPoll — implements poller.Metrics.
func (s *State) SetLastPoll(t time.Time) {
	s.lastPollUnixNano.Store(t.UnixNano())
}

// SetServerCount is called by main.go after each refresh tick.
func (s *State) SetServerCount(n int) { s.serverCount.Store(int64(n)) }

// Handler returns an http.Handler mounting /healthz + /metrics.
func (s *State) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/metrics", s.metrics)

	return mux
}

// Listen starts the HTTP server. Blocks until the server exits.
func (s *State) Listen(addr string) error {
	srv := &http.Server{
		Addr:         addr,
		Handler:      s.Handler(),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}

	return srv.ListenAndServe()
}

func (s *State) healthz(w http.ResponseWriter, _ *http.Request) {
	lastPollNano := s.lastPollUnixNano.Load()
	var lastPoll string
	if lastPollNano > 0 {
		lastPoll = time.Unix(0, lastPollNano).UTC().Format(time.RFC3339Nano)
	}

	body := map[string]any{
		"status":    "healthy",
		"last_poll": lastPoll,
		"servers":   s.serverCount.Load(),
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(body)
}

func (s *State) metrics(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var b strings.Builder

	writeCounter(&b, "poller_lines_total", "Total log lines persisted.", s.lines)
	writeCounter(&b, "poller_polls_total", "Total poll ticks executed.", s.polls)
	writeCounter(&b, "poller_errors_total", "Total poll-time errors.", s.errors)
	writeCapCounter(&b, "poller_disk_cap_hits_total", "Per-pod file-cap hits.", s.caps)
	writeGauge(&b, "poller_watermark_age_seconds", "Age of the oldest watermark per server.", s.wmAge)

	writeStreamCounter(&b, "poller_stream_polls_total", "Per-stream poll ticks executed.", s.streamPolls)
	writeStreamCounter(&b, "poller_stream_lines_total", "Per-stream lines or bytes persisted.", s.streamLines)
	writeStreamCounter(&b, "poller_stream_errors_total", "Per-stream poll-time errors.", s.streamErrors)
	writeStreamNotifyCounter(&b, "poller_stream_notify_total", "Per-stream Rails-notify outcomes.", s.streamNotify)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte(b.String()))
}

func writeCounter(b *strings.Builder, name, help string, m map[string]int64) {
	fmt.Fprintf(b, "# HELP %s %s\n", name, help)
	fmt.Fprintf(b, "# TYPE %s counter\n", name)

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(b, "%s{server=%q} %d\n", name, k, m[k])
	}
}

func writeCapCounter(b *strings.Builder, name, help string, m map[string]int64) {
	fmt.Fprintf(b, "# HELP %s %s\n", name, help)
	fmt.Fprintf(b, "# TYPE %s counter\n", name)

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts := strings.SplitN(k, "|", 2)
		server := parts[0]
		pod := ""
		if len(parts) == 2 {
			pod = parts[1]
		}
		fmt.Fprintf(b, "%s{server=%q,pod=%q} %d\n", name, server, pod, m[k])
	}
}

// writeStreamCounter emits a counter keyed on "<stream>|<server>".
func writeStreamCounter(b *strings.Builder, name, help string, m map[string]int64) {
	fmt.Fprintf(b, "# HELP %s %s\n", name, help)
	fmt.Fprintf(b, "# TYPE %s counter\n", name)

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts := strings.SplitN(k, "|", 2)
		stream := parts[0]
		server := ""
		if len(parts) == 2 {
			server = parts[1]
		}
		fmt.Fprintf(b, "%s{stream=%q,server=%q} %d\n", name, stream, server, m[k])
	}
}

// writeStreamNotifyCounter emits a counter keyed on
// "<stream>|<server>|<result>".
func writeStreamNotifyCounter(b *strings.Builder, name, help string, m map[string]int64) {
	fmt.Fprintf(b, "# HELP %s %s\n", name, help)
	fmt.Fprintf(b, "# TYPE %s counter\n", name)

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts := strings.SplitN(k, "|", 3)
		stream := parts[0]
		server := ""
		result := ""
		if len(parts) >= 2 {
			server = parts[1]
		}
		if len(parts) == 3 {
			result = parts[2]
		}
		fmt.Fprintf(b, "%s{stream=%q,server=%q,result=%q} %d\n", name, stream, server, result, m[k])
	}
}

func writeGauge(b *strings.Builder, name, help string, m map[string]float64) {
	fmt.Fprintf(b, "# HELP %s %s\n", name, help)
	fmt.Fprintf(b, "# TYPE %s gauge\n", name)

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(b, "%s{server=%q} %g\n", name, k, m[k])
	}
}
