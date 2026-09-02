package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Credentials is one server's connection identity as currently configured
// in the WebUI: where the controller lives and which PAT to present.
type Credentials struct {
	Endpoint string
	PAT      string
}

// CredentialsFunc resolves the CURRENT credentials, called once per
// request.
//
// This indirection is the whole point of the type: a PAT revoked and
// reissued in the WebUI used to stay stuck for the life of the stream
// goroutine, because the token was copied into the client at spawn time
// and the roster refresh skipped servers that were already running. Every
// request answered 401 until the process restarted. Resolving per request
// means the next roster refresh republishes the token and the very next
// call carries it — no goroutine restart, no lost cursor state.
type CredentialsFunc func() Credentials

// VooduClient hits a single voodu controller's PAT plane. One instance
// per server. The HTTP client has a 60s round-trip timeout. Per-pod log
// backfill that can't drain its whole window inside 60s is RESUMABLE: the
// stream is oldest-first, the poller persists what it read and advances the
// watermark, so the next tick continues where it left off.
type VooduClient struct {
	// Creds is resolved once per request. Never cache what it returns
	// across calls — that would reintroduce the stuck-token bug.
	Creds CredentialsFunc
	HTTP  *http.Client
}

// NewVooduClient returns a VooduClient pinned to fixed credentials — for
// tests and one-off calls where nothing can rotate underneath. Long-lived
// stream goroutines want NewLiveVooduClient instead.
func NewVooduClient(endpoint, pat string) *VooduClient {
	fixed := Credentials{Endpoint: endpoint, PAT: pat}

	return NewLiveVooduClient(func() Credentials { return fixed })
}

// NewLiveVooduClient returns a client that re-reads its credentials from
// `fn` on every request. `fn` MUST be safe for concurrent use — the
// per-stream goroutines call it from their own goroutines.
func NewLiveVooduClient(fn CredentialsFunc) *VooduClient {
	return &VooduClient{
		Creds: fn,
		HTTP:  &http.Client{Timeout: 60 * time.Second},
	}
}

// current resolves the credentials for ONE request. Each exported method
// calls this exactly once and threads the result through, so a refresh
// landing mid-request can't pair an old endpoint with a new PAT.
//
// Trimming happens here rather than at construction because a live
// provider hands us whatever the operator most recently saved.
func (c *VooduClient) current() Credentials {
	cr := c.Creds()
	cr.Endpoint = strings.TrimRight(cr.Endpoint, "/")

	return cr
}

// FetchLogs GETs `/api/pat/v1/logs?follow=false&tail=500&since=...&timestamps=true`
// and returns the response body for streaming line-by-line by the
// caller. The caller MUST Close() the returned ReadCloser.
//
// `since` is formatted as RFC3339Nano. A zero `since` means "as old as
// `tail` will give us" — we still send the param (empty string) so the
// controller picks its own default.
func (c *VooduClient) FetchLogs(ctx context.Context, since time.Time) (io.ReadCloser, error) {
	q := url.Values{}
	q.Set("follow", "false")
	q.Set("tail", "500")
	q.Set("timestamps", "true")
	if !since.IsZero() {
		q.Set("since", since.UTC().Format(time.RFC3339Nano))
	}

	cr := c.current()

	req, err := http.NewRequestWithContext(ctx, "GET", cr.Endpoint+"/api/pat/v1/logs?"+q.Encode(), nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	if err := SignRequest(req, cr.PAT); err != nil {
		return nil, err
	}

	req.Header.Set("Accept", "text/plain")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("voodu GET: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()
		return nil, fmt.Errorf("voodu returned %d: %s", resp.StatusCode, string(body))
	}

	return resp.Body, nil
}

// FetchPodLogs GETs `/api/pat/v1/pods/<pod>/logs?since=...&timestamps=true&follow=false`
// for ONE pod and returns the body for line-by-line streaming. Caller MUST
// Close() it.
//
// Unlike FetchLogs (the legacy multiplexed call), this sends NO `tail` cap.
// The controller omits `--tail` when the param is absent, so docker returns
// the FULL window since `since` instead of just the most-recent 500 lines —
// that's what lets a restart backfill an offline gap. Because the window is
// per-pod (each pod resumes from its OWN watermark), a quiet pod can't drag a
// chatty pod's `since` backwards, so steady-state stays a ~poll-interval
// window. A zero `since` omits the param (controller default).
//
// Lines come back as `<ts> <body>` with no `[pod]` prefix (single-pod
// stream) — the caller already knows the pod and attaches it.
func (c *VooduClient) FetchPodLogs(ctx context.Context, pod string, since time.Time) (io.ReadCloser, error) {
	q := url.Values{}
	q.Set("follow", "false")
	q.Set("timestamps", "true")
	if !since.IsZero() {
		q.Set("since", since.UTC().Format(time.RFC3339Nano))
	}

	cr := c.current()
	endpoint := cr.Endpoint + "/api/pat/v1/pods/" + url.PathEscape(pod) + "/logs?" + q.Encode()

	return c.doGet(ctx, cr, endpoint, "text/plain")
}

// FetchMetrics GETs `/api/pat/v1/metrics/dump?since=<unix_seconds>` and
// returns the NDJSON response body for streaming line-by-line by the
// caller. The caller MUST Close() the returned ReadCloser.
//
// IMPORTANT — `/metrics/dump` (not `/metrics`):
//
//   - `/metrics` is the read-by-source endpoint used by the WebUI's
//     chart frames: requires `source=system|pod|ingress` + returns a
//     bounded JSON array.
//   - `/metrics/dump` is the warehouse-sync endpoint Ruby's
//     `MetricsSyncServerJob` uses: streams ALL rows newer than `since`
//     as NDJSON, no `source` filter. This is the one the poller wants.
//
// `since` is unix seconds (integer, as a string). 0 / empty tells the
// controller to dump the full retention window — the natural backfill
// path for a brand-new server or a process restart.
func (c *VooduClient) FetchMetrics(ctx context.Context, since string) (io.ReadCloser, error) {
	q := url.Values{}
	if since != "" {
		q.Set("since", since)
	}

	cr := c.current()

	endpoint := cr.Endpoint + "/api/pat/v1/metrics/dump"
	if encoded := q.Encode(); encoded != "" {
		endpoint += "?" + encoded
	}

	return c.doGet(ctx, cr, endpoint, "application/x-ndjson")
}

// FetchActivity GETs `/api/pat/v1/activity/dump?since=<unix_seconds>` and
// returns the NDJSON body for the caller to stream. The caller MUST Close it.
//
// `/activity/dump` and not `/activity`, for the same reason the metrics lane
// takes `/metrics/dump`: `/activity` answers a bounded, filtered, newest-first
// query for a screen, and the warehouse wants every line past a timestamp in
// the order they happened.
//
// Requires `scope=read` on the PAT — the same scope the metrics and logs lanes
// already use, so a server the poller can already tail needs no new token.
func (c *VooduClient) FetchActivity(ctx context.Context, since string) (io.ReadCloser, error) {
	q := url.Values{}
	if since != "" {
		q.Set("since", since)
	}

	cr := c.current()

	endpoint := cr.Endpoint + "/api/pat/v1/activity/dump"
	if encoded := q.Encode(); encoded != "" {
		endpoint += "?" + encoded
	}

	return c.doGet(ctx, cr, endpoint, "application/x-ndjson")
}

// FetchPods GETs `/api/pat/v1/pods?detail=true&spec=true` and returns
// the response body. The caller MUST Close() the returned ReadCloser.
func (c *VooduClient) FetchPods(ctx context.Context) (io.ReadCloser, error) {
	q := url.Values{}
	q.Set("detail", "true")
	q.Set("spec", "true")

	cr := c.current()

	return c.doGet(ctx, cr, cr.Endpoint+"/api/pat/v1/pods?"+q.Encode(), "application/json")
}

// FetchPodList GETs `/api/pat/v1/pods` with NO detail/spec — the lightweight
// roster the per-pod log tail needs (names only). FetchPods, by contrast,
// sends detail+spec for the state stream's full snapshot; fetching that every
// log tick just to read names would be wasteful. Caller MUST Close().
func (c *VooduClient) FetchPodList(ctx context.Context) (io.ReadCloser, error) {
	cr := c.current()

	return c.doGet(ctx, cr, cr.Endpoint+"/api/pat/v1/pods", "application/json")
}

// podsEnvelope mirrors the controller's GET /pods response. The PAT plane
// wraps every JSON body in {"status","data"}; the roster lives at
// data.pods[].name — the container identity (e.g. "fsw-web.a3f9") that tags
// each log line and keys the on-disk log tree. (Logs + metrics are
// text/NDJSON and skip this envelope.)
type podsEnvelope struct {
	Data struct {
		Pods []struct {
			Name string `json:"name"`
		} `json:"pods"`
	} `json:"data"`
}

// ParsePodNames extracts the current pod roster (container names) from a
// FetchPodList response body. This is the discovery source for the per-pod
// log fetch — it's how we learn which pods exist (the legacy multiplexed log
// stream discovered them implicitly; per-pod fetches need the list up front).
// Blank names are skipped.
func ParsePodNames(r io.Reader) ([]string, error) {
	var env podsEnvelope
	if err := json.NewDecoder(r).Decode(&env); err != nil {
		return nil, fmt.Errorf("decode pods: %w", err)
	}

	names := make([]string, 0, len(env.Data.Pods))
	for _, p := range env.Data.Pods {
		if p.Name != "" {
			names = append(names, p.Name)
		}
	}

	return names, nil
}

// FetchSystem GETs `/api/pat/v1/system` and returns the response body.
// The caller MUST Close() the returned ReadCloser.
func (c *VooduClient) FetchSystem(ctx context.Context) (io.ReadCloser, error) {
	cr := c.current()

	return c.doGet(ctx, cr, cr.Endpoint+"/api/pat/v1/system", "application/json")
}

// doGet is the shared GET helper for the PAT plane: signed auth, single
// Accept header, surfaces non-2xx with a truncated body in the error.
//
// Takes the credentials the caller already resolved rather than resolving
// again, so the URL and the token always come from the same snapshot.
func (c *VooduClient) doGet(ctx context.Context, cr Credentials, url, accept string) (io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	// Signed rather than bearing the PAT: an intercepted request is one
	// request, not a credential. See signature.go.
	if err := SignRequest(req, cr.PAT); err != nil {
		return nil, err
	}

	req.Header.Set("Accept", accept)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("voodu GET: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()

		return nil, fmt.Errorf("voodu returned %d: %s", resp.StatusCode, string(body))
	}

	return resp.Body, nil
}

// ParseLine pulls structured fields out of one raw line. The controller
// emits either of two shapes:
//
//	[pod-name] 2026-05-28T12:34:56.789Z body text
//	[pod-name] body text (no timestamp)
//
// And, for single-pod streams (not what this poller uses, but tolerated):
//
//	2026-05-28T12:34:56.789Z body
//	plain body
//
// Empty lines (used as heartbeats by the controller) are reported with
// `ok=false`. The returned `ts` is zero when no timestamp was found —
// callers should fall back to `time.Now()` in that case.
func ParseLine(raw []byte) (pod string, ts time.Time, body string, ok bool) {
	line := strings.TrimRight(string(raw), "\r\n")
	if line == "" {
		return "", time.Time{}, "", false
	}

	// Optional [pod] prefix.
	if strings.HasPrefix(line, "[") {
		if end := strings.Index(line, "] "); end > 1 {
			pod = line[1:end]
			line = line[end+2:]
		}
	}

	// Optional RFC3339[Nano] timestamp at the head.
	if sp := strings.IndexByte(line, ' '); sp > 0 {
		if t, err := time.Parse(time.RFC3339Nano, line[:sp]); err == nil {
			ts = t
			line = line[sp+1:]
		} else if t, err := time.Parse(time.RFC3339, line[:sp]); err == nil {
			ts = t
			line = line[sp+1:]
		}
	}

	return pod, ts, line, true
}
