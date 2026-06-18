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

// VooduClient hits a single voodu controller's PAT plane. One instance
// per island. The HTTP client has a 60s round-trip timeout. Per-pod log
// backfill that can't drain its whole window inside 60s is RESUMABLE: the
// stream is oldest-first, the poller persists what it read and advances the
// watermark, so the next tick continues where it left off.
type VooduClient struct {
	Endpoint string
	PAT      string
	HTTP     *http.Client
}

// NewVooduClient returns a VooduClient with sensible defaults. The
// HTTP client has a 60s timeout on the round-trip; the poll itself is
// `follow=false` so it should return quickly with the queued lines.
func NewVooduClient(endpoint, pat string) *VooduClient {
	return &VooduClient{
		Endpoint: strings.TrimRight(endpoint, "/"),
		PAT:      pat,
		HTTP:     &http.Client{Timeout: 60 * time.Second},
	}
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

	req, err := http.NewRequestWithContext(ctx, "GET", c.Endpoint+"/api/pat/v1/logs?"+q.Encode(), nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.PAT)
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

	endpoint := c.Endpoint + "/api/pat/v1/pods/" + url.PathEscape(pod) + "/logs?" + q.Encode()

	return c.doGet(ctx, endpoint, "text/plain")
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
//     `MetricsSyncIslandJob` uses: streams ALL rows newer than `since`
//     as NDJSON, no `source` filter. This is the one the poller wants.
//
// `since` is unix seconds (integer, as a string). 0 / empty tells the
// controller to dump the full retention window — the natural backfill
// path for a brand-new island or a process restart.
func (c *VooduClient) FetchMetrics(ctx context.Context, since string) (io.ReadCloser, error) {
	q := url.Values{}
	if since != "" {
		q.Set("since", since)
	}

	endpoint := c.Endpoint + "/api/pat/v1/metrics/dump"
	if encoded := q.Encode(); encoded != "" {
		endpoint += "?" + encoded
	}

	return c.doGet(ctx, endpoint, "application/x-ndjson")
}

// FetchPods GETs `/api/pat/v1/pods?detail=true&spec=true` and returns
// the response body. The caller MUST Close() the returned ReadCloser.
func (c *VooduClient) FetchPods(ctx context.Context) (io.ReadCloser, error) {
	q := url.Values{}
	q.Set("detail", "true")
	q.Set("spec", "true")

	return c.doGet(ctx, c.Endpoint+"/api/pat/v1/pods?"+q.Encode(), "application/json")
}

// FetchPodList GETs `/api/pat/v1/pods` with NO detail/spec — the lightweight
// roster the per-pod log tail needs (names only). FetchPods, by contrast,
// sends detail+spec for the state stream's full snapshot; fetching that every
// log tick just to read names would be wasteful. Caller MUST Close().
func (c *VooduClient) FetchPodList(ctx context.Context) (io.ReadCloser, error) {
	return c.doGet(ctx, c.Endpoint+"/api/pat/v1/pods", "application/json")
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
	return c.doGet(ctx, c.Endpoint+"/api/pat/v1/system", "application/json")
}

// doGet is the shared GET helper for the PAT plane: Bearer auth, single
// Accept header, surfaces non-2xx with a truncated body in the error.
func (c *VooduClient) doGet(ctx context.Context, url, accept string) (io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.PAT)
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
