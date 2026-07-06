# frozen_string_literal: true

# PollerDigest — receipt row for a folder the out-of-process Go
# binary dropped on disk under `storage/poller/<type>/<sync_hash>/`.
#
# Lifecycle:
#
#   1. Go binary fetches /pods + /system (or /metrics/dump) for one
#      server, writes the parsed bytes into the folder, computes the
#      xxhash64 of the canonical contents, POSTs `/internal/poller/
#      digest` with {type, server_id, sync_hash, ts, size}.
#   2. Rails inserts this row in status=queued + enqueues
#      `PollerDigestJob.perform_later(sync_hash)`.
#   3. The job swings to `status=processing`, dispatches to the
#      `MetricsDigestService` or `StateDigestService` based on
#      `type`, flips to `status=processed`, deletes the folder.
#      On exception → `status=failed` + the AJ retry loop kicks in.
#
# `sync_hash` IS the primary key (16-hex from xxhash64 on the Go
# side). That makes the duplicate-delivery path a free PK conflict
# instead of a separate "have I seen this hash?" lookup.
#
# No FK back to Server — soft-deleting an server still leaves the
# audit row in place. `belongs_to :server` without `optional: true`
# would otherwise raise on read if the server row was purged.
class PollerDigest < ApplicationRecord
  self.primary_key = :sync_hash

  # ActiveRecord normally treats `type` as the STI discriminator
  # column. We use it as a domain field (`metrics` | `state`), so
  # disable the STI inheritance machinery.
  self.inheritance_column = :_type_disabled

  # Marker raised by PollerDigestJob when it picks up a row that's
  # already terminal (status=processed). discarded_on at the job
  # level so reschedules of the same hash are silent no-ops, not
  # retry-burning exceptions.
  AlreadyProcessed = Class.new(StandardError)

  TYPES = %w[metrics state].freeze
  STATUSES = %w[queued processing processed failed].freeze

  # No `belongs_to :server` validation — keep the receipt intact even
  # after the server row is destroyed (forensic value > referential
  # integrity for this audit table). The column is `server_id` (the
  # poller feature's internal naming); the association still points
  # at the `servers` table because that IS the server registry.
  belongs_to :server, foreign_key: :server_id, optional: true

  validates :type, presence: true, inclusion: {in: TYPES}
  validates :sync_hash, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: {in: STATUSES}

  scope :processed, -> { where(status: "processed") }
  scope :failed, -> { where(status: "failed") }

  # stale — rows older than the cutoff. Hits the partial fan on
  # `created_at`. Default cutoff is 1 hour ago, matching the
  # operator-facing "anything older than this is dead weight"
  # assumption used by the periodic cleanup job.
  scope :stale, ->(older_than: 1.hour.ago) { where(arel_table[:created_at].lt(older_than)) }

  def processed?
    status == "processed"
  end

  def queued?
    status == "queued"
  end

  def processing?
    status == "processing"
  end

  def failed?
    status == "failed"
  end
end
