# frozen_string_literal: true

module Internal
  # Internal::PollerController — feeds the out-of-process Go log
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
  #      `ENV["POLLER_TOKEN"]` (constant-time compare via
  #      SecurityUtils.secure_compare).
  #   3. JSON-only response, narrow shape — no opportunity to leak
  #      adjacent data even if a guard slips.
  #
  # ## Token setup
  #
  # The operator sets `POLLER_TOKEN` as an environment
  # variable. Generate once per environment:
  #
  #   POLLER_TOKEN=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
  #
  # Then export it the same way you set RAILS_ENV / DATABASE_URL —
  # kamal secrets, docker `-e`, .env file, systemd Environment=, etc.
  # Both Rails and the Go binary read the same env var.
  #
  # When the env var is unset, every request 401s (fail-closed —
  # never accidentally open the endpoint in a misconfigured deploy).
  #
  # Auth + IP guards live in `InternalEndpointAuth` so sibling
  # controllers under `/internal/` (e.g. PollerDigestController) share
  # the exact same fail-closed wiring without duplication.
  class PollerController < ActionController::API
    include InternalEndpointAuth

    # GET /internal/poller/islands
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
  end
end
