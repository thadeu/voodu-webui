package client

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestParseLine_PrefixAndTimestamp(t *testing.T) {
	raw := []byte("[newcall-api.e41c] 2026-05-28T12:34:56.789Z hello world")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "newcall-api.e41c" {
		t.Errorf("pod=%q, want newcall-api.e41c", pod)
	}
	want, _ := time.Parse(time.RFC3339Nano, "2026-05-28T12:34:56.789Z")
	if !ts.Equal(want) {
		t.Errorf("ts=%v, want %v", ts, want)
	}
	if body != "hello world" {
		t.Errorf("body=%q, want hello world", body)
	}
}

func TestParseLine_PrefixOnly_NoTimestamp(t *testing.T) {
	raw := []byte("[newcall-api.e41c] plain body without timestamp")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "newcall-api.e41c" {
		t.Errorf("pod=%q", pod)
	}
	if !ts.IsZero() {
		t.Errorf("ts=%v, want zero", ts)
	}
	if body != "plain body without timestamp" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_TimestampOnly_NoPrefix(t *testing.T) {
	raw := []byte("2026-05-28T12:34:56Z singleton body")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "" {
		t.Errorf("pod=%q, want empty", pod)
	}
	want, _ := time.Parse(time.RFC3339, "2026-05-28T12:34:56Z")
	if !ts.Equal(want) {
		t.Errorf("ts=%v, want %v", ts, want)
	}
	if body != "singleton body" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_PlainBody(t *testing.T) {
	raw := []byte("just text, no metadata")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "" {
		t.Errorf("pod=%q, want empty", pod)
	}
	if !ts.IsZero() {
		t.Errorf("ts=%v, want zero", ts)
	}
	if body != "just text, no metadata" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_EmptyLine_NotOK(t *testing.T) {
	if _, _, _, ok := ParseLine([]byte("")); ok {
		t.Error("empty line should be ok=false (heartbeat)")
	}
	if _, _, _, ok := ParseLine([]byte("\n")); ok {
		t.Error("newline-only line should be ok=false")
	}
}

func TestParseLine_TrimsTrailingCRLF(t *testing.T) {
	raw := []byte("[pod-x] body line\r\n")
	pod, _, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "pod-x" {
		t.Errorf("pod=%q", pod)
	}
	if body != "body line" {
		t.Errorf("body=%q", body)
	}
}

func TestParsePodNames(t *testing.T) {
	body := `{"status":"ok","data":{"degraded":false,"pods":[
		{"name":"fsw-freeswitch.0","kind":"statefulset","scope":"fsw"},
		{"name":"fsw-controller.0793","kind":"deployment"},
		{"name":""},
		{"name":"fsw-redis.0"}
	]}}`

	names, err := ParsePodNames(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}

	want := []string{"fsw-freeswitch.0", "fsw-controller.0793", "fsw-redis.0"}
	if len(names) != len(want) {
		t.Fatalf("names=%v, want %v (blank dropped)", names, want)
	}

	for i := range want {
		if names[i] != want[i] {
			t.Errorf("names[%d]=%q, want %q", i, names[i], want[i])
		}
	}
}

// FetchPodLogs must hit the per-pod endpoint with NO tail cap (so docker
// returns the whole since-window), the pod name path-escaped, and since as
// RFC3339Nano.
func TestFetchPodLogs_NoTailFullWindow(t *testing.T) {
	var gotPath, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		if r.Header.Get("Authorization") != "Bearer pat-1" {
			t.Errorf("missing bearer auth: %q", r.Header.Get("Authorization"))
		}
		_, _ = w.Write([]byte("2026-06-18T02:45:00Z hello\n"))
	}))
	defer srv.Close()

	c := NewVooduClient(srv.URL, "pat-1")
	since := time.Date(2026, 6, 18, 2, 45, 0, 0, time.UTC)

	body, err := c.FetchPodLogs(context.Background(), "fsw-freeswitch.0", since)
	if err != nil {
		t.Fatal(err)
	}
	body.Close()

	if gotPath != "/api/pat/v1/pods/fsw-freeswitch.0/logs" {
		t.Errorf("path=%q", gotPath)
	}

	q, _ := url.ParseQuery(gotQuery)
	if q.Has("tail") {
		t.Errorf("must NOT send tail (would cap the window): %q", gotQuery)
	}
	if q.Get("follow") != "false" {
		t.Errorf("follow=%q, want false", q.Get("follow"))
	}
	if q.Get("timestamps") != "true" {
		t.Errorf("timestamps=%q, want true", q.Get("timestamps"))
	}
	if q.Get("since") != "2026-06-18T02:45:00Z" {
		t.Errorf("since=%q, want 2026-06-18T02:45:00Z", q.Get("since"))
	}
}

// A zero since omits the param entirely (controller default), still no tail.
func TestFetchPodLogs_ZeroSinceOmitsParam(t *testing.T) {
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
	}))
	defer srv.Close()

	c := NewVooduClient(srv.URL, "pat-1")

	body, err := c.FetchPodLogs(context.Background(), "p", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	body.Close()

	q, _ := url.ParseQuery(gotQuery)
	if q.Has("since") {
		t.Errorf("zero since must be omitted: %q", gotQuery)
	}
	if q.Has("tail") {
		t.Errorf("must NOT send tail: %q", gotQuery)
	}
}

func TestParseLine_BracketInBody_NotConsumed(t *testing.T) {
	// Controller's per-pod stream-error suffix: "[pod] [stream error] EOF"
	raw := []byte("[pod-a] [stream error] EOF")
	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "pod-a" {
		t.Errorf("pod=%q", pod)
	}
	if !ts.IsZero() {
		t.Errorf("ts=%v, want zero", ts)
	}
	if body != "[stream error] EOF" {
		t.Errorf("body=%q", body)
	}
}
