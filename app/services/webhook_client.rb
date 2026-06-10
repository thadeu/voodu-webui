# frozen_string_literal: true

require "ipaddr"
require "resolv"

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
  Error          = Class.new(StandardError)
  TransportError = Class.new(Error)
  ServerError    = Class.new(Error)
  ClientError    = Class.new(Error)
  BlockedError   = Class.new(ClientError)

  TIMEOUT = 10

  def self.post(url, payload, headers: {})
    new(url).post(payload, headers: headers)
  end

  # Whether to permit non-routable (loopback / private / link-local)
  # hosts. voodu-webui is a single-operator self-hosted dashboard, so
  # in dev/test we allow them (the operator legitimately webhooks a
  # local API). In production we block by default as SSRF
  # defence-in-depth — an operator running on a private network can
  # opt back in with VOODU_ALLOW_PRIVATE_WEBHOOKS=1.
  def self.allow_private_hosts?
    Rails.env.local? || ENV["VOODU_ALLOW_PRIVATE_WEBHOOKS"] == "1"
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
      f.options.timeout      = TIMEOUT
      f.options.open_timeout = TIMEOUT
      f.headers["User-Agent"] = "voodu-webui/0.1"
    end
  end

  def raise_for_status(resp)
    case resp.status
    when 200..299 then nil
    when 429      then raise ServerError, "rate limited (HTTP 429)"   # transient → retry
    when 400..499 then raise ClientError, "client error (HTTP #{resp.status})"
    when 500..599 then raise ServerError, "server error (HTTP #{resp.status})"
    else               raise ServerError, "unexpected (HTTP #{resp.status})"
    end
  end

  # guard_ssrf! — require an http(s) URL with a host. Unless private
  # hosts are permitted (see .allow_private_hosts?), refuse URLs whose
  # host resolves to a loopback / private / link-local address —
  # defence-in-depth against pointing the app at its own metadata
  # service or an internal box on an exposed production deploy.
  def guard_ssrf!
    uri = URI.parse(@url)
    raise BlockedError, "must be an http(s) URL" unless %w[http https].include?(uri.scheme)
    raise BlockedError, "missing host" if uri.host.blank?

    return if self.class.allow_private_hosts?

    addresses(uri.host).each do |ip|
      addr = IPAddr.new(ip)
      if addr.loopback? || addr.private? || addr.link_local?
        raise BlockedError, "host resolves to a non-routable address (#{ip})"
      end
    end
  rescue URI::InvalidURIError
    raise BlockedError, "invalid URL"
  end

  # Resolve the host to its IPs. A bare IP literal is checked directly;
  # a hostname is resolved (both A and AAAA). DNS failure → transport
  # error so it retries (could be a transient resolver blip).
  def addresses(host)
    return [host] if ip_literal?(host)

    Resolv.getaddresses(host).presence || raise(TransportError, "cannot resolve #{host}")
  end

  def ip_literal?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::InvalidAddressError
    false
  end
end
