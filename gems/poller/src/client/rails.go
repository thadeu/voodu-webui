// Package client wraps the two HTTP surfaces the log poller talks to:
//
//   - The Rails app (`/internal/poller/servers`) for the list of
//     servers to poll. Auth: `X-Voodu-Internal-Token` header.
//   - The voodu controllers themselves, via their PAT plane.
//     Auth: `Authorization: Bearer <pat>`.
//
// Both wrappers are intentionally small: no retries, no fancy
// connection pooling, no JSON streaming. The poller layer handles
// retry policy and rate limiting.
package client

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Server is one row from /internal/poller/servers. Mirrors the
// JSON the Rails endpoint emits — keep the field names in sync.
type Server struct {
	ID       string `json:"id"`
	Key      string `json:"key"`
	Endpoint string `json:"endpoint"`
	PAT      string `json:"pat"`
}

// ServersResponse is the envelope the Rails endpoint returns.
//
// `Version` is a hard gate — if the Rails side ever changes the wire
// shape (e.g. adds required fields), it bumps this and the Go binary
// must be re-released. The poller refuses unknown versions rather
// than silently misbehaving on missing data.
type ServersResponse struct {
	Version int      `json:"version"`
	Servers []Server `json:"servers"`
}

// SupportedVersion is the only `version` value FetchServers will
// accept from the Rails endpoint. Bump in lockstep with the Rails
// side when the envelope changes.
const SupportedVersion = 1

// RailsClient is a stateless wrapper around an http.Client preconfigured
// with the internal token. Cheap to construct — instantiate once in
// main.go and share.
type RailsClient struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// NewRailsClient returns a RailsClient with a 10s overall timeout.
// The Rails endpoint is in-process to the poller (loopback), so any
// request taking longer than 10s is almost certainly stuck.
func NewRailsClient(baseURL, token string) *RailsClient {
	return &RailsClient{
		BaseURL: baseURL,
		Token:   token,
		HTTP:    &http.Client{Timeout: 10 * time.Second},
	}
}

// FetchServers GETs `/internal/poller/servers` and returns the
// parsed server list. Refuses an unknown `version`.
func (c *RailsClient) FetchServers() ([]Server, error) {
	req, err := http.NewRequest("GET", c.BaseURL+"/internal/poller/servers", nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("X-Voodu-Internal-Token", c.Token)
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("rails GET: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("rails returned %d: %s", resp.StatusCode, string(body))
	}

	var env ServersResponse
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return nil, fmt.Errorf("decode rails response: %w", err)
	}

	if env.Version != SupportedVersion {
		return nil, fmt.Errorf("rails servers version %d unsupported (need %d)", env.Version, SupportedVersion)
	}

	return env.Servers, nil
}

// MetricsWatermarkResponse is the envelope /internal/poller/metrics_watermark
// returns: the newest metric ts (unix seconds) Rails has warehoused for the
// server. The metrics fetcher seeds its cold-start `since` from this so a
// restart backfills the gap the poller was offline for instead of starting at
// now-ColdStartLookback. `Since` is 0 when the warehouse is empty for the
// server (first-ever sync — nothing to backfill).
type MetricsWatermarkResponse struct {
	Version int   `json:"version"`
	Since   int64 `json:"since"`
}

// FetchMetricsWatermark GETs /internal/poller/metrics_watermark for one server
// and returns the warehoused high-water mark (unix seconds), 0 when the
// warehouse is empty. Refuses an unknown `version`. Same wire contract +
// boundary the Ruby MetricsSyncServerJob uses (MetricSample.last_ts_for): a
// global-max `since` means the controller re-delivers only strictly-newer rows
// — backfill with zero duplicates.
func (c *RailsClient) FetchMetricsWatermark(serverID string) (int64, error) {
	req, err := http.NewRequest("GET", c.BaseURL+"/internal/poller/metrics_watermark", nil)
	if err != nil {
		return 0, fmt.Errorf("build request: %w", err)
	}

	q := req.URL.Query()
	q.Set("server_id", serverID)
	req.URL.RawQuery = q.Encode()

	req.Header.Set("X-Voodu-Internal-Token", c.Token)
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, fmt.Errorf("rails GET: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))

		return 0, fmt.Errorf("rails returned %d: %s", resp.StatusCode, string(body))
	}

	var env MetricsWatermarkResponse
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return 0, fmt.Errorf("decode rails response: %w", err)
	}

	if env.Version != SupportedVersion {
		return 0, fmt.Errorf("rails metrics_watermark version %d unsupported (need %d)", env.Version, SupportedVersion)
	}

	return env.Since, nil
}

// DigestRequest is the body the Rails /internal/poller/digest endpoint
// expects. Rails uses (Type, ServerID, SyncHash) for dedup before
// reading the on-disk folder.
//
// `ServerID` is the platform-internal name for the Server row's
// primary key. The wire field is `server_id` so the Rails side can
// route it into the `poller_digests.server_id` column without an
// extra mapping step.
type DigestRequest struct {
	Type     string `json:"type"`
	ServerID string `json:"server_id"`
	SyncHash string `json:"sync_hash"`
	TS       int64  `json:"ts"`
	Size     int    `json:"size"`
}

// NotifyDigest POSTs /internal/poller/digest with the X-Voodu-Internal-Token
// header. Returns nil on any 2xx response; otherwise wraps the truncated
// response body in the error.
func (c *RailsClient) NotifyDigest(req DigestRequest) error {
	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("encode digest: %w", err)
	}

	httpReq, err := http.NewRequest("POST", c.BaseURL+"/internal/poller/digest", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("X-Voodu-Internal-Token", c.Token)
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		return fmt.Errorf("rails POST: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))

		return fmt.Errorf("rails digest returned %d: %s", resp.StatusCode, string(bodyBytes))
	}

	return nil
}
