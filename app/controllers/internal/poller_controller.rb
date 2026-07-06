# frozen_string_literal: true

module Internal
  # Internal::PollerController — feeds the out-of-process Go log
  # poller binary the list of servers it should tail.
  #
  # Lives under /internal/ and does NOT inherit ApplicationController:
  #
  #   - No server scoping (the binary is global, sees every server).
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

    # GET /internal/poller/servers
    #
    # Returns the full server roster with decrypted PATs so the Go
    # binary can stream `docker logs` from each controller. PAT is
    # plaintext because the binary has no access to the Rails
    # encryption key — by the time the bytes reach the binary they
    # need to be usable as a bearer token.
    #
    # `version` field gives us a hand-rolled compat fence: bumping
    # it lets the binary refuse to talk to an old WebUI (and vice
    # versa) without inventing a separate handshake endpoint.
    def servers
      payload = {
        version: 1,
        servers: Server.find_each.map { |server|
          # id stringified to keep the wire shape stable across the
          # Ruby/Go boundary — AR primary keys are integers, but the
          # Go binary uses the id as a path component
          # (`storage/logs/<id>/...`) where a string is natural. The
          # Go decoder's `Server.ID string` field would explode on a
          # number otherwise.
          {
            id: server.id.to_s,
            key: server.key,
            endpoint: server.endpoint,
            pat: server.pat
          }
        }
      }

      render json: payload
    end

    # GET /internal/poller/metrics_watermark?server_id=<id>
    #
    # Returns the newest metric ts (unix seconds) the warehouse holds
    # for this server, so the Go binary can resume `/metrics/dump?since=`
    # from there on a cold start instead of now-30s. This is the SAME
    # boundary the Ruby MetricsSyncServerJob uses (MetricSample.last_ts_for),
    # bringing the Go poller to parity: a global-max `since` means the
    # controller re-delivers only strictly-newer rows — backfills the
    # offline gap with zero duplicates (the warehouse has no unique index).
    #
    # `since` is 0 when the warehouse is empty for this server (first-ever
    # sync); the binary treats 0 as "nothing to backfill" and keeps its
    # short cold-start lookback rather than pulling the controller's full
    # 7-day retention on a brand-new server.
    def metrics_watermark
      server_id = params[:server_id].presence
      return render(json: {error: "server_id required"}, status: :bad_request) unless server_id

      render json: {version: 1, since: MetricSample.last_ts_for(server_id)}
    end
  end
end
