package client

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// VooduClient hits a single voodu controller's PAT plane. One instance
// per island. The HTTP client has no overall timeout — the request can
// block for up to `tail=500` worth of log fetch, and the per-tick
// context (set by the poller) cancels it on shutdown.
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
