# frozen_string_literal: true

module Internal
  # Internal::LogPollerController — feeds the out-of-process Go log
  # poller binary the list of islands it should tail.
  #
  # Lives under /internal/ and does NOT inherit ApplicationController:
  #
  #   - No tenant scoping (the binary is global, sees every island).
  #   - No CSRF (machine-to-machine, no browser).
  #   - No view rendering (JSON only).
  #
  # Defence in depth — three independent guards:
  #
  #   1. The endpoint is only reachable from loopback or RFC1918
  #      private addresses (see `enforce_loopback_or_private!`).
  #      Catches the misconfigured-reverse-proxy footgun where this
  #      route accidentally gets exposed to the public internet.
  #   2. A shared token (`X-Voodu-Internal-Token` header) must match
  #      `ENV["LOG_POLLER_TOKEN"]` (constant-time compare via
  #      SecurityUtils.secure_compare).
  #   3. JSON-only response, narrow shape — no opportunity to leak
  #      adjacent data even if a guard slips.
  #
  # ## Token setup
  #
  # The operator sets `LOG_POLLER_TOKEN` as an environment
  # variable. Generate once per environment:
  #
  #   LOG_POLLER_TOKEN=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
  #
  # Then export it the same way you set RAILS_ENV / DATABASE_URL —
  # kamal secrets, docker `-e`, .env file, systemd Environment=, etc.
  # Both Rails and the Go binary read the same env var.
  #
  # When the env var is unset, every request 401s (fail-closed —
  # never accidentally open the endpoint in a misconfigured deploy).
  class LogPollerController < ActionController::API
    before_action :enforce_loopback_or_private!
    before_action :authenticate_internal_token!

    # GET /internal/log_poller/islands
    #
    # Returns the full island roster with decrypted PATs so the Go
    # binary can stream `docker logs` from each controller. PAT is
    # plaintext because the binary has no access to the Rails
    # encryption key — by the time the bytes reach the binary they
    # need to be usable as a bearer token.
    #
    # `version` field gives us a hand-rolled compat fence: bumping
    # it lets the binary refuse to talk to an old WebUI (and vice
    # versa) without inventing a separate handshake endpoint.
    def islands
      payload = {
        version: 1,
        islands: Island.find_each.map { |island|
          # id stringified to keep the wire shape stable across the
          # Ruby/Go boundary — AR primary keys are integers, but the
          # Go binary uses the id as a path component
          # (`storage/logs/<id>/...`) where a string is natural. The
          # Go decoder's `Island.ID string` field would explode on a
          # number otherwise.
          {
            id:       island.id.to_s,
            key:      island.key,
            endpoint: island.endpoint,
            pat:      island.pat
          }
        }
      }

      render json: payload
    end

    private

    # authenticate_internal_token! — constant-time check against the
    # shared token in `ENV["LOG_POLLER_TOKEN"]`. When the env
    # var is unset OR doesn't match the request header, returns 401.
    # Fail-closed: a misconfigured deploy (env var missing) never
    # accidentally opens the endpoint.
    def authenticate_internal_token!
      expected = ENV["LOG_POLLER_TOKEN"].to_s
      provided = request.headers["X-Voodu-Internal-Token"].to_s

      if expected.blank? || provided.blank? ||
         !ActiveSupport::SecurityUtils.secure_compare(expected, provided)
        head :unauthorized
      end
    end

    # enforce_loopback_or_private! — refuses any request whose
    # remote_ip is neither loopback (127.0.0.1, ::1) nor inside an
    # RFC1918 private block (10/8, 172.16/12, 192.168/16). The Go
    # binary always runs on the same host as Rails (loopback) or on
    # the same private LAN; a public-internet hit here means
    # something is wrong with the reverse proxy and the right answer
    # is 403, not "leak the PAT roster".
    #
    # We use `request.remote_ip` (not raw REMOTE_ADDR) so X-Forwarded-
    # For from a trusted proxy still resolves correctly; Rails
    # already filters spoofed values through its trusted_proxies
    # config.
    def enforce_loopback_or_private!
      ip = IPAddr.new(request.remote_ip)

      return if ip.loopback?
      return if ip.private?

      head :forbidden
    rescue IPAddr::InvalidAddressError
      head :forbidden
    end
  end
end
