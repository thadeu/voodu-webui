# frozen_string_literal: true

# WebhookClient — POSTs a JSON payload to an operator-configured
# external URL (Slack incoming webhook, generic webhook). Mirrors the
# Faraday + error-class shape of Voodu::Client, minus the Authorization
# header, with a longer timeout (external endpoints are slower) and an
# SSRF guard the inbound-only InternalEndpointAuth concern doesn't
# cover.
#
# Error taxonomy drives the job's retry policy:
#   TransportError — network failure / timeout       → retry
#   ServerError    — 5xx                               → retry
#   ClientError    — 4xx (≠429) or blocked URL         → discard
class WebhookClient
  Error = Class.new(StandardError)
  TransportError = Class.new(Error)
  ServerError = Class.new(Error)
  ClientError = Class.new(Error)
  BlockedError = Class.new(ClientError)

  TIMEOUT = 10

  def self.post(url, payload, headers: {})
    new(url).post(payload, headers: headers)
  end

  # Kept as a delegation: the rule (and the VOODU_ALLOW_PRIVATE_WEBHOOKS
  # switch behind it) moved to SsrfGuard when DataTable::HttpFetch became the
  # second caller. Callers and tests that already ask WebhookClient keep working.
  def self.allow_private_hosts?
    SsrfGuard.allow_private_hosts?
  end

  def initialize(url)
    @url = url.to_s
  end

  def post(payload, headers: {})
    guard_ssrf!

    resp = conn.post(@url) do |req|
      req.headers["Content-Type"] = "application/json"
      headers.each { |name, value| req.headers[name.to_s] = value.to_s }
      # A pre-rendered template comes through as a String (sent
      # verbatim); the default structured payload is a Hash.
      req.body = payload.is_a?(String) ? payload : payload.to_json
    end

    raise_for_status(resp)
    resp
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
    raise TransportError, e.message
  end

  private

  def conn
    @conn ||= Faraday.new do |f|
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
      f.headers["User-Agent"] = "voodu-webui/0.1"
    end
  end

  def raise_for_status(resp)
    case resp.status
    when 200..299 then nil
    when 429 then raise ServerError, "rate limited (HTTP 429)"   # transient → retry
    when 400..499 then raise ClientError, "client error (HTTP #{resp.status})"
    when 500..599 then raise ServerError, "server error (HTTP #{resp.status})"
    else raise ServerError, "unexpected (HTTP #{resp.status})"
    end
  end

  # guard_ssrf! — refuse a URL this app should not be made to fetch. The rule
  # lives in SsrfGuard (shared with DataTable::HttpFetch); the mapping to our
  # error taxonomy lives here, because it is ours: a blocked URL is permanent
  # (discard, never retry), while an unresolvable host may be a resolver blip
  # worth retrying.
  def guard_ssrf!
    # Through our own predicate, not SsrfGuard's default: this class is the
    # seam callers and tests already reach for when they need to force the
    # strict behaviour (see test/services/webhook_client_test.rb#block_private).
    result = SsrfGuard.check(@url, allow_private: self.class.allow_private_hosts?)
    return if result.ok?
    raise TransportError, result.message if result.unresolvable?

    raise BlockedError, result.message
  end
end
