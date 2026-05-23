# frozen_string_literal: true

# Voodu::Client — thin Faraday wrapper around one Island's PAT plane.
#
# Lifecycle:
#
#   client = Voodu::Client.new(island)
#   client.stats        # GET /api/pat/v1/stats
#   client.pods         # GET /api/pat/v1/pods
#   client.pod(name)    # GET /api/pat/v1/pods/{name}
#   client.logs(name)   # GET /api/pat/v1/pods/{name}/logs?tail=200
#   client.restart(name)# POST /api/pat/v1/pods/{name}/restart
#
# Every call:
#   - Targets <island.endpoint>/api/pat/v1/<path>
#   - Sends Authorization: Bearer <island.pat>
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
    Error           = Class.new(StandardError)
    AuthError       = Class.new(Error) # 401 / 403 — PAT bad or insufficient scope
    NotFoundError   = Class.new(Error) # 404 — resource missing
    RateLimitError  = Class.new(Error) # 429 — action burst exceeded
    ServerError     = Class.new(Error) # 5xx — controller broke
    TransportError  = Class.new(Error) # network failure, timeout

    DEFAULT_TIMEOUT = 6 # seconds

    def initialize(island, timeout: DEFAULT_TIMEOUT)
      @island  = island
      @timeout = timeout
    end

    def stats         = get("stats")
    def pods          = get("pods")
    def pod(name)     = get("pods/#{CGI.escape(name)}")
    def restart(name) = post("pods/#{CGI.escape(name)}/restart")

    # Logs are special — the controller streams chunked. For M4's
    # polling-mode logs view we ask for the last N lines (no follow)
    # and re-poll. M5+ can switch to a streaming response.
    def logs(name, tail: 200)
      raw_get("pods/#{CGI.escape(name)}/logs", params: { tail: tail })
    end

    private

    def conn
      @conn ||= Faraday.new(url: @island.endpoint) do |f|
        f.request  :url_encoded
        f.response :json, content_type: /\bjson$/
        f.options.timeout      = @timeout
        f.options.open_timeout = @timeout
        f.headers["Authorization"] = "Bearer #{@island.pat}"
        f.headers["User-Agent"]    = "voodu-webui/0.1"
      end
    end

    def get(path)
      resp = conn.get("/api/pat/v1/#{path}")
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
      when 401, 403 then raise AuthError,      error_msg(resp, "auth")
      when 404      then raise NotFoundError,  error_msg(resp, "not found")
      when 429      then raise RateLimitError, error_msg(resp, "rate limited")
      when 500..599 then raise ServerError,    error_msg(resp, "controller error")
      else               raise Error,          error_msg(resp, "unexpected #{resp.status}")
      end
    end

    def error_msg(resp, fallback)
      return resp.body["error"] if resp.body.is_a?(Hash) && resp.body["error"]

      "#{fallback} (HTTP #{resp.status})"
    end
  end
end
