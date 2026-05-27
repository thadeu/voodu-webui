# frozen_string_literal: true

# LogExport — one operator-requested log download.
#
# Lifecycle:
#
#   create! (status: :queued)                            ← controller
#       │
#       ▼
#   LogExportJob.perform_later(id) → status: :running    ← job picks up
#       │
#       ▼
#   write file → status: :ready, ready_at, expires_at    ← happy path
#       OR
#   status: :failed, error                               ← sad path
#       │
#       ▼
#   LogExportCleanupJob: when expires_at < now,          ← reaper
#     delete file + destroy row
#
# The `params` column is a JSON blob (text) carrying the operator's
# choices from the export drawer form. Parsed lazily via #params_hash
# so callers don't need to handle JSON themselves.
#
# Why text + JSON instead of separate columns?
#   - The shape evolves (e.g. adding a `levels:` filter in the future
#     is one Ruby change, not a migration).
#   - Mirrors the JSON-in-text idiom already used by Pod.payload and
#     MetricSample.payload — consistent across the app.
class LogExport < ApplicationRecord
  belongs_to :island

  STATUSES = %w[queued running ready failed].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :ready,    -> { where(status: "ready") }
  scope :expired,  -> { where("expires_at < ?", Time.current) }
  scope :recent,   -> { order(created_at: :desc) }

  # params_hash — lazy-parses the JSON blob into a plain Hash.
  # Memoised per instance; the inverse setter writes back through
  # #params= so callers can mutate without re-encoding manually.
  def params_hash
    @params_hash ||= begin
      raw = self[:params]
      raw.blank? ? {} : (JSON.parse(raw) || {})
    rescue JSON::ParserError, EncodingError
      {}
    end
  end

  def params_hash=(hash)
    @params_hash  = hash || {}
    self[:params] = JSON.generate(@params_hash)
  end

  # filter params accessors — typed getters that work against
  # the params_hash, so views/jobs don't repeat the lookup logic.

  def from_time
    parse_time(params_hash["from"])
  end

  def until_time
    parse_time(params_hash["until"])
  end

  def pods
    Array(params_hash["pods"])
  end

  def all_pods?
    params_hash["pods"].nil? || pods.empty?
  end

  def content_search
    params_hash["content_search"].to_s
  end

  def content_regex?
    params_hash["regex"] == true
  end

  def group_by_pod?
    params_hash["group_by_pod"] == true
  end

  def format
    params_hash["format"].presence || "ndjson"
  end

  # State predicates — terse for view/controller use.
  def queued?  = status == "queued"
  def running? = status == "running"
  def ready?   = status == "ready"
  def failed?  = status == "failed"

  # absolute_file_path — joins the stored relative path with the
  # Rails root. Stored as relative so a deployment moving the
  # storage volume doesn't invalidate old rows.
  def absolute_file_path
    return nil if file_path.blank?

    Rails.root.join(file_path)
  end

  # destroy callback — wipes the on-disk file when the row dies.
  # Keeps disk + DB in lockstep without a separate sweep.
  before_destroy :delete_file_from_disk

  private

  def delete_file_from_disk
    path = absolute_file_path
    return if path.nil?
    return unless File.exist?(path)

    File.delete(path)
  rescue Errno::ENOENT
    # raced with another cleanup — fine.
  rescue StandardError => e
    Rails.logger.warn("log-export #{id} file delete failed: #{e.class}: #{e.message}")
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
