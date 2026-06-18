# frozen_string_literal: true

# InternalEndpointAuth — shared defence-in-depth guards for the
# `/internal/*` family of machine-to-machine endpoints.
#
# Two guards, applied in this order:
#
#   1. `enforce_loopback_or_private!` — refuses any request whose
#      remote_ip is neither loopback (127.0.0.1, ::1) nor inside an
#      RFC1918 private block (10/8, 172.16/12, 192.168/16). The Go
#      binary always runs on the same host as Rails (loopback) or on
#      the same private LAN; a public-internet hit here means
#      something is wrong with the reverse proxy and the right answer
#      is 403, not "leak adjacent data".
#
#      We use `request.remote_ip` (not raw REMOTE_ADDR) so X-Forwarded-
#      For from a trusted proxy still resolves correctly; Rails
#      already filters spoofed values through its trusted_proxies
#      config.
#
#   2. `authenticate_internal_token!` — constant-time check against
#      the shared token in `ENV["POLLER_TOKEN"]`. When the env var is
#      unset OR doesn't match the request header, returns 401.
#      Fail-closed: a misconfigured deploy (env var missing) never
#      accidentally opens the endpoint.
#
# ## Token setup
#
# The operator sets `POLLER_TOKEN` as an environment variable.
# Generate once per environment:
#
#   POLLER_TOKEN=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
#
# Then export it the same way you set RAILS_ENV / DATABASE_URL —
# kamal secrets, docker `-e`, .env file, systemd Environment=, etc.
# Both Rails and the Go binary read the same env var.
module InternalEndpointAuth
  extend ActiveSupport::Concern

  included do
    before_action :enforce_loopback_or_private!
    before_action :authenticate_internal_token!
  end

  private

  def authenticate_internal_token!
    expected = ENV["POLLER_TOKEN"].to_s
    provided = request.headers["X-Voodu-Internal-Token"].to_s

    if expected.blank? || provided.blank? ||
        !ActiveSupport::SecurityUtils.secure_compare(expected, provided)
      head :unauthorized
    end
  end

  def enforce_loopback_or_private!
    ip = IPAddr.new(request.remote_ip)

    return if ip.loopback?
    return if ip.private?

    head :forbidden
  rescue IPAddr::InvalidAddressError
    head :forbidden
  end
end
