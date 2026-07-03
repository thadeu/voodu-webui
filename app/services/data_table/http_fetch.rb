# frozen_string_literal: true

module DataTable
  # DataTable::HttpFetch — fires ONE outbound request to an operator-configured
  # external API and returns the parsed JSON. This is the only place the webui
  # talks to a third-party URL, so the safety rails live here: a hard timeout,
  # a response-size cap, and forced JSON parsing. Secrets (auth headers) are
  # applied server-side and never reach the browser.
  #
  # SSRF hardening (blocking internal / metadata targets) is deliberately NOT
  # here yet — it's a later milestone. Until then this must only be used for
  # trusted, operator-owned targets.
  #
  # Returns a Result: `ok?` + `json` on success, or `ok? == false` + `error`
  # (a short human message) on any failure — a bad URL, timeout, non-2xx, an
  # over-cap body, or unparseable JSON. Never raises to the caller.
  class HttpFetch
    TIMEOUT_SECONDS = 10
    MAX_BYTES = 5 * 1024 * 1024 # 5 MiB — a dashboard panel, not a bulk export
    ALLOWED_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS].freeze
    # Methods that carry a request body (so we attach it + a JSON Content-Type).
    BODY_METHODS = %w[POST PUT PATCH DELETE].freeze

    Result = Struct.new(:ok, :json, :error) do
      def ok? = ok
    end

    def self.call(url:, method: "GET", headers: {}, body: nil, query: {})
      new(url: url, method: method, headers: headers, body: body, query: query).call
    end

    def initialize(url:, method:, headers:, body:, query:)
      @url = url.to_s
      @method = method.to_s.upcase.presence_in(ALLOWED_METHODS) || "GET"
      @headers = headers.is_a?(Hash) ? headers : {}
      @body = body
      @query = query.is_a?(Hash) ? query.compact : {}
    end

    def call
      return failure("no URL configured") if @url.strip.empty?

      response = connection.run_request(@method.downcase.to_sym, @url, request_body, request_headers) do |req|
        req.params.update(@query.transform_keys(&:to_s))
      end

      interpret(response)
    rescue Faraday::TimeoutError
      failure("request timed out after #{TIMEOUT_SECONDS}s")
    rescue Faraday::ConnectionFailed => e
      failure("couldn't reach the API (#{e.message})")
    rescue Faraday::Error => e
      failure("request failed (#{e.class})")
    rescue URI::InvalidURIError
      failure("invalid URL")
    end

    private

    def interpret(response)
      return failure("API returned HTTP #{response.status}") unless response.success?

      body = response.body.to_s
      return failure("response too large (> #{MAX_BYTES / (1024 * 1024)} MiB)") if body.bytesize > MAX_BYTES

      Result.new(ok: true, json: JSON.parse(body))
    rescue JSON::ParserError
      # Name the Content-Type when it isn't JSON — the operator usually pointed
      # at the wrong endpoint (an HTML error page, a redirect) and the type says
      # so. gzip is already transparent (net/http inflates it before we get here).
      type = response.headers["content-type"].to_s.split(";").first.presence
      failure((type && !type.include?("json")) ? "expected JSON, the API returned #{type}" : "response wasn't valid JSON")
    end

    def failure(message)
      Result.new(ok: false, error: message)
    end

    def request_body
      return nil unless BODY_METHODS.include?(@method)

      @body.is_a?(String) ? @body : @body&.to_json
    end

    # request_headers — the operator's headers, plus a JSON Accept unless they
    # set their own. Content-Type defaults to JSON on a POST with a body.
    #
    # Accept-Encoding is DROPPED: compression is the HTTP client's concern, not
    # the operator's. Left to net/http, gzip/deflate is negotiated + inflated
    # transparently; but if WE (or the operator) set Accept-Encoding, net/http
    # disables that and hands back raw compressed bytes → JSON.parse fails. So
    # we never let it be set — the response always arrives decompressed.
    def request_headers
      h = @headers.transform_keys(&:to_s).transform_values(&:to_s)
      h.reject! { |k, _| k.casecmp?("accept-encoding") }
      h["Accept"] ||= "application/json"
      h["Content-Type"] ||= "application/json" if request_body
      h
    end

    def connection
      Faraday.new do |f|
        f.options.timeout = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
        f.response :raise_error
      end
    end
  end
end
