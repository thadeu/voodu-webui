# frozen_string_literal: true

module Internal
  # Internal::PollerDigestController — entry point for the Go binary's
  # "I dropped a digest folder, please process it" notifications.
  #
  # Wire shape:
  #
  #   POST /internal/poller/digest
  #     Headers: X-Voodu-Internal-Token: <POLLER_TOKEN>
  #     Body (JSON):
  #       {
  #         "type":       "metrics" | "state",
  #         "tenant_id":  42,
  #         "sync_hash":  "0123456789abcdef",  # 16-hex xxhash64
  #         "ts":         1716922000000,        # epoch ms
  #         "size":       12345                  # folder bytes
  #       }
  #
  # Response:
  #   - 202 { status: "queued",    sync_hash: "..." } — fresh row, job enqueued
  #   - 200 { status: "duplicate", sync_hash: "..." } — already seen (idempotent)
  #   - 400 { error: "..." }                         — bad params
  #   - 401                                           — bad / missing token
  #   - 403                                           — request from public IP
  #
  # Auth + IP guards come from `InternalEndpointAuth` — same wiring as
  # `PollerController` (the GET /internal/poller/islands sibling).
  # Both must stay in lockstep; the operator configures ONE
  # POLLER_TOKEN and the Go binary uses it for every internal call.
  #
  # Idempotency:
  #
  #   The PK on poller_digests is `sync_hash` (16-hex xxhash64 from
  #   the Go side). A re-delivery of the same hash either due to
  #   transient WebUI 5xx, in-flight POST retried by Go, or operator
  #   replay finds the existing row and returns 200 without
  #   enqueueing. That keeps the Go retry loop dumb (just POST
  #   forever until 2xx).
  class PollerDigestController < ActionController::API
    include InternalEndpointAuth

    HASH_FORMAT = /\A[0-9a-f]{16}\z/

    def create
      type = params[:type].to_s
      tenant_id = params[:tenant_id]
      sync_hash = params[:sync_hash].to_s

      unless PollerDigest::TYPES.include?(type)
        return render json: {error: "invalid type"}, status: :bad_request
      end

      if tenant_id.blank?
        return render json: {error: "tenant_id required"}, status: :bad_request
      end

      unless sync_hash.match?(HASH_FORMAT)
        return render json: {error: "sync_hash must be 16 lowercase hex chars"},
          status: :bad_request
      end

      # Idempotent re-delivery short-circuit — no enqueue, no row
      # mutation, just acknowledge the original receipt. The PK
      # conflict path (a TOCTOU race between this check and the
      # insert below) would also be safe via RecordNotUnique, but
      # the existence check keeps the common-case wire latency
      # one round-trip instead of two.
      if PollerDigest.exists?(sync_hash: sync_hash)
        return render json: {status: "duplicate", sync_hash: sync_hash}, status: :ok
      end

      PollerDigest.create!(
        sync_hash: sync_hash,
        type: type,
        tenant_id: tenant_id.to_i,
        status: "queued"
      )

      PollerDigestJob.perform_later(sync_hash)

      render json: {status: "queued", sync_hash: sync_hash}, status: :accepted
    rescue ActiveRecord::RecordNotUnique
      # Lost the race with a near-simultaneous duplicate POST —
      # collapse to the same idempotent "already had it" response.
      render json: {status: "duplicate", sync_hash: sync_hash}, status: :ok
    rescue ActiveRecord::RecordInvalid => e
      render json: {error: e.record.errors.full_messages.join(", ")},
        status: :bad_request
    end
  end
end
