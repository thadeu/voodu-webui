# frozen_string_literal: true

# Voodu::Client — thin Faraday wrapper around one Server's PAT plane.
#
# Lifecycle:
#
#   client = Voodu::Client.new(server)
#   client.stats        # GET /api/pat/v1/stats
#   client.pods         # GET /api/pat/v1/pods
#   client.pod(name)    # GET /api/pat/v1/pods/{name}
#   client.logs(name)   # GET /api/pat/v1/pods/{name}/logs?tail=200
#   client.restart(name)# POST /api/pat/v1/pods/{name}/restart
#
# Every call:
#   - Targets <server.endpoint>/api/pat/v1/<path>
#   - Sends Authorization: Bearer <server.pat>
#   - 6s read timeout (the WebUI is doing user-facing polling; we'd
#     rather show a "controller slow" message than hang the page)
#   - Returns the parsed `data` slice from the JSON envelope. Errors
#     raise Voodu::Client::Error subclasses so controllers can rescue
#     selectively (Auth/RateLimit/NotFound/Transport).
#
# No retries — restart actions are deliberately not retried (would
# trigger double restarts on intermittent network). Reads can be
# retried by the caller if appropriate.
module Voodu
  class Client
    Error = Class.new(StandardError)
    AuthError = Class.new(Error) # 401 / 403 — PAT bad or insufficient scope
    NotFoundError = Class.new(Error) # 404 — resource missing
    RateLimitError = Class.new(Error) # 429 — action burst exceeded
    ServerError = Class.new(Error) # 5xx — controller broke
    TransportError = Class.new(Error) # network failure, timeout

    DEFAULT_TIMEOUT = 6 # seconds

    def initialize(server, timeout: DEFAULT_TIMEOUT)
      @server = server
      @timeout = timeout
    end

    def stats = get("stats")
    def restart(name) = post("pods/#{CGI.escape(name)}/restart")

    # system — host-level snapshot: CPU%, memory, disk usage, disk I/O
    # rate, network rate, uptime, kernel. Powers the Overview header
    # and StatCards (replaces the silent-nil reads of @stats.dig("host", ...)
    # that always coerced to 0).
    #
    # IO + Net rates are deltas server-side — the first request after
    # the controller starts returns 0 for those fields (no baseline).
    # Subsequent calls populate them. The cache TTL on the WebUI side
    # is short enough that two consecutive page loads see real numbers.
    #
    # Shape (see internal/systemstats.Snapshot in clowk-voodu):
    #   data.host.{hostname, kernel, uptime_seconds, boot_time}
    #   data.cpu.{percent, cores, load_1, load_5, load_15}
    #   data.mem.{used_bytes, total_bytes, available_bytes}
    #   data.disk[].{mount, used_bytes, total_bytes}
    #   data.io.{read_bytes_per_sec, write_bytes_per_sec}
    #   data.net.{rx_bytes_per_sec, tx_bytes_per_sec}
    def system = get("system")

    # metrics — time-series chart data backed by the controller's
    # NDJSON store (see internal/metrics on the Go side).
    #
    #   source:   "system" | "pod"     — required
    #   metric:   "cpu_percent" | "mem_usage_bytes" | ...
    #             — see internal/metrics/reader.go metricExtractors
    #   range:    "1h" | "24h" | "7d"  (default 1h)
    #   interval: "auto" | "15s" | "1m" | ... (default auto)
    #   scope/name: pod-only filters; aggregation groups on
    #             (scope, name) so charts survive container restarts.
    #
    # Response shape (data slice — handle() unwraps the envelope):
    #
    #   { "metric" => "cpu_percent",
    #     "interval_seconds" => 60,
    #     "available_from" => "2026-05-17T10:00:00Z",
    #     "truncated" => false,
    #     "series" => [
    #       { "ts" => "2026-05-24T09:00:00Z", "value" => 12.4 },
    #       { "ts" => "2026-05-24T09:01:00Z", "value" => 13.1 }
    #     ] }
    def metrics(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil, pod: nil)
      params = {source: source, metric: metric, range: range, interval: interval}
      params[:scope] = scope if scope.present?
      params[:name] = name if name.present?
      params[:pod] = pod if pod.present?
      get("metrics", params)
    end

    # pats — list every PAT registered on this server, redacted.
    # Returns an Array of `{ id, name, prefix, suffix, scopes,
    # created_at, last_used_at }` hashes (newest first).
    #
    # Requires the configured PAT to carry `actions` scope (the
    # controller's PAT-plane proxy gates this endpoint at the same
    # tier as restart, since the names + prefixes are admin
    # metadata). When the PAT only has `read`, raises
    # Voodu::Client::AuthError (401/403) — the WebUI's Settings
    # page catches it and renders the "admin PAT required" hint
    # inline instead of the list.
    def pats
      payload = get("pats")
      Array(payload && payload["pats"])
    end

    # revoke_pat — DELETE one PAT by id. 404 when the id doesn't
    # exist anymore (idempotent at the etcd level). Same scope
    # gate as `pats`.
    def revoke_pat(id)
      delete("pats/#{CGI.escape(id)}")
    end

    # pods — listing. Two opt-in enrichments:
    #
    #   detail: true — each row carries the full PodDetail shape
    #     (env, networks, ports, state, stats). Same payload `vd
    #     describe pod` consumes via a single round-trip.
    #
    #   spec: true — each row carries the declared manifest from etcd
    #     (kind, scope, name, spec body, metadata). Lets the WebUI
    #     render probes / env / resources from the source of truth
    #     in a single request instead of fanning out to /apply.
    #
    # Composable: passing both is the shape `StateSyncServerJob` uses
    # to populate the snapshot table — full runtime + declared spec
    # in one fetch per sync tick.
    # stats: false → opt OUT of the live docker stats batch the
    # controller normally joins when detail=true. That batch is
    # the single biggest CPU consumer on the controller side
    # (`docker stats --no-stream` samples cgroup files TWICE per
    # container to compute CPU%, in a synchronous batch). Polling
    # consumers like StateSyncServerJob pass `stats: false` —
    # their UI table can show "—" for live CPU/Mem (operator has
    # /metrics charts for that anyway) in exchange for letting
    # the controller breathe between ticks.
    #
    # No-op when detail is false (stats are never collected on
    # the compact list path).
    def pods(detail: false, spec: false, stats: true)
      params = {}
      params[:detail] = "true" if detail
      params[:spec] = "true" if spec
      params[:stats] = "false" if detail && stats == false
      get("pods", params.presence)
    end

    # pod — fetches a single container's detail. The PAT plane envelopes
    # this one differently than `pods`: the response is
    # `{ data: { pod: {...} } }`, so after our base `handle()` unwraps
    # `data`, we still need to peel `pod`. Other endpoints (stats, pods)
    # put their primary payload directly in `data` and leave the unwrap
    # to the caller — that's why this is the only spot doing it.
    #
    # `spec: true` enriches the single-pod response the same way
    # `pods(spec: true)` does the list — declared manifest joined in
    # from etcd.
    def pod(name, spec: false)
      params = spec ? {spec: "true"} : nil
      data = get("pods/#{CGI.escape(name)}", params)
      data.is_a?(Hash) ? (data["pod"] || data) : data
    end

    # Logs — non-follow snapshot. Returns the last `tail` lines as a
    # single string. Use for "show me what's in the buffer right now"
    # paths (one-off render, no live update).
    def logs(name, tail: 200)
      raw_get("pods/#{CGI.escape(name)}/logs", params: {tail: tail})
    end

    # Logs — single-pod follow stream. The PAT plane keeps the chunked
    # transfer open until the container exits or the caller disconnects;
    # each raw chunk (may be a partial line, multiple lines, etc.) is
    # yielded to the supplied block.
    #
    # The caller is responsible for line buffering. We deliberately do
    # NOT split on \n here — the controller streams via
    # ActionController::Live and wants to flush bytes ASAP, and the
    # client (browser) does its own line assembly anyway.
    #
    # Timeout is bumped to `nil` (no read timeout) because follow
    # streams are intentionally long-lived; the default 6s would cut
    # the first idle minute.
    # since: passed verbatim to controller's `?since=`, which forwards
    # to `docker logs --since`. Accepts RFC3339 ("2026-05-26T23:30Z"),
    # relative ("10m", "1h"), or unix string. Nil/empty skips the
    # flag. Used by polling consumers to advance a watermark and
    # avoid re-tailing the same lines every cycle.
    def logs_stream(name, follow: true, tail: 20, since: nil, timestamps: false, &on_chunk)
      raise ArgumentError, "block required" unless on_chunk

      params = {follow: follow, tail: tail}
      params[:since] = since if since.present?
      # timestamps=true anchors each line to docker's clock (RFC3339Nano
      # prefix). The viewer uses it to set a reliable resume watermark AND
      # to dedup the overlap on reconnect — so no line is lost OR
      # duplicated when the long-lived stream blips.
      params[:timestamps] = true if timestamps

      streaming_conn.get("/api/pat/v1/pods/#{CGI.escape(name)}/logs", params) do |req|
        req.options.on_data = proc do |chunk, _overall, _env|
          on_chunk.call(chunk)
        end
      end
      nil
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    # Logs — multi-pod tail. Server-side fan-out across every pod
    # matching the (kind, scope, name) filter; the controller
    # multiplexes their lines into one chunked stream, each line
    # prefixed with `[pod-name] ` so the browser can attribute it back.
    #
    # Empty filter → every pod on the host. Same vocabulary as
    # `pods(detail: false)`, just applied to logs.
    #
    # Same chunk semantics as logs_stream — yields raw bytes, caller
    # buffers + splits.
    # since: same semantics as logs_stream above — passes through
    # to `docker logs --since`. Tail job sends a moving watermark
    # to fetch only new lines per poll.
    def logs_stream_multi(follow: true, tail: 20, scope: nil, kind: nil, name: nil, since: nil, timestamps: false, &on_chunk)
      raise ArgumentError, "block required" unless on_chunk

      params = {follow: follow, tail: tail}
      params[:scope] = scope if scope.present?
      params[:kind] = kind if kind.present?
      params[:name] = name if name.present?
      params[:since] = since if since.present?
      params[:timestamps] = true if timestamps

      streaming_conn.get("/api/pat/v1/logs", params) do |req|
        req.options.on_data = proc do |chunk, _overall, _env|
          on_chunk.call(chunk)
        end
      end
      nil
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    # metrics_dump — incremental NDJSON warehouse pull. Streams the
    # controller's `/metrics/dump?since=<unix_ts>` endpoint and yields
    # one Hash per parsed line, shaped for MetricSample#bulk_insert
    # consumption (minus `server_id`, which the caller adds).
    #
    # Streaming + line-buffered: Faraday's on_data delivers arbitrary
    # byte boundaries. We accumulate in `buffer`, split on `\n`,
    # yield each complete line, and carry any trailing partial across
    # chunks. A line that lacks `ts` or `source` is silently skipped
    # — the controller already filters by ts, so this would only
    # happen on a malformed line which both sides tolerate (matches
    # reader.go / dump.go behaviour).
    #
    # `since` is unix seconds (integer). 0 (or `since.to_i.zero?`)
    # tells the controller to dump the full retention window —
    # the natural backfill path for a brand-new server.
    #
    # No return value (streaming). Caller counts rows via the yield
    # callback if it needs a tally.
    #
    # Errors surface as Voodu::Client::Error subclasses — the
    # MetricsSyncServerJob lets solid_queue retry transient transport
    # failures and logs auth errors for operator follow-up.
    def metrics_dump(since:, &on_row)
      raise ArgumentError, "block required" unless on_row

      buffer = +""

      streaming_conn.get("/api/pat/v1/metrics/dump", {since: since.to_i}) do |req|
        req.options.on_data = proc do |chunk, _overall, _env|
          buffer << chunk

          while (nl = buffer.index("\n"))
            line = buffer.slice!(0..nl).chomp
            next if line.empty?

            row = parse_dump_line(line)
            on_row.call(row) if row
          end
        end
      end

      # Trailing partial line — shouldn't happen if the controller
      # writes whole lines + flushes, but defensive: try the rump.
      if buffer.present?
        row = parse_dump_line(buffer.chomp)
        on_row.call(row) if row
      end

      nil
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    # hep_export — pulls one bounded page of a voodu-hep3 reader's
    # /export NDJSON tail for (scope, name), resuming at the `since`
    # cursor (nil/"" = from the beginning). Returns [body, next_cursor]:
    # the raw NDJSON string and the X-Hep-Cursor to pass on the next
    # call. The reader caps each response (~8 MiB) and reports the resume
    # point in the header — the Hep3 poller loops on the cursor until the
    # body comes back empty.
    #
    # Routed through the controller's PAT plugin proxy:
    #   GET /api/pat/v1/hep3/<scope>/<name>/export?since=<cursor>
    #
    # Uses `conn` (not streaming_conn): /export is bounded, so a normal
    # request with the read timeout applies, and the JSON middleware is
    # content-type-gated so it leaves the application/x-ndjson body as a
    # raw string.
    def hep_export(scope, name, since: nil)
      path = "hep3/#{CGI.escape(scope)}/#{CGI.escape(name)}/export"
      params = since.to_s.empty? ? {} : {since: since}
      resp = conn.get("/api/pat/v1/#{path}", params)
      raise_for_status(resp)

      [resp.body.to_s, resp.headers["X-Hep-Cursor"].to_s]
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    private

    # parse_dump_line — minimal validation of a single NDJSON line.
    # Returns the bulk_insert-ready Hash, or nil to skip the line
    # (malformed JSON, missing required field). Tolerant by design:
    # the warehouse sync runs every 30s, so a single bad line should
    # never poison the batch.
    def parse_dump_line(line)
      parsed = JSON.parse(line)
      ts = parsed["ts"]
      source = parsed["source"]
      return nil if ts.blank? || source.blank?

      {source: source, ts_iso: ts, payload: line}
    rescue JSON::ParserError
      nil
    end

    def conn
      @conn ||= Faraday.new(url: @server.endpoint) do |f|
        f.request :url_encoded
        f.response :json, content_type: /\bjson$/
        f.options.timeout = @timeout
        f.options.open_timeout = @timeout
        f.headers["Authorization"] = "Bearer #{@server.pat}"
        f.headers["User-Agent"] = "voodu-webui/0.1"
      end
    end

    # Separate Faraday connection for log follow streams: no read
    # timeout (follow holds the socket open indefinitely), no JSON
    # middleware (the body is text/plain chunked). Otherwise identical
    # to the main `conn`.
    def streaming_conn
      @streaming_conn ||= Faraday.new(url: @server.endpoint) do |f|
        f.options.timeout = nil
        f.options.open_timeout = @timeout
        f.headers["Authorization"] = "Bearer #{@server.pat}"
        f.headers["User-Agent"] = "voodu-webui/0.1"
      end
    end

    def get(path, params = nil)
      resp = conn.get("/api/pat/v1/#{path}", params)
      handle(resp)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    def post(path)
      resp = conn.post("/api/pat/v1/#{path}")
      handle(resp)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    def delete(path)
      resp = conn.delete("/api/pat/v1/#{path}")
      handle(resp)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    # raw_get returns the response body verbatim (string) instead of
    # the JSON envelope's `data` slice. Used by `logs` because the
    # log endpoint sends text/plain chunks, not JSON.
    def raw_get(path, params: {})
      resp = conn.get("/api/pat/v1/#{path}", params)
      raise_for_status(resp)
      resp.body
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise TransportError, e.message
    end

    def handle(resp)
      raise_for_status(resp)
      body = resp.body
      # Expected envelope: { "status": "ok", "data": {...} }
      body.is_a?(Hash) ? (body["data"] || body) : body
    end

    def raise_for_status(resp)
      case resp.status
      when 200..299 then nil
      when 401, 403 then raise AuthError, error_msg(resp, "auth")
      when 404 then raise NotFoundError, error_msg(resp, "not found")
      when 429 then raise RateLimitError, error_msg(resp, "rate limited")
      when 500..599 then raise ServerError, error_msg(resp, "controller error")
      else raise Error, error_msg(resp, "unexpected #{resp.status}")
      end
    end

    def error_msg(resp, fallback)
      return resp.body["error"] if resp.body.is_a?(Hash) && resp.body["error"]

      "#{fallback} (HTTP #{resp.status})"
    end
  end
end
