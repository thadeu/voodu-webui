# frozen_string_literal: true

# Deployment — the record of one push arriving, and what became of it.
#
# Created by the webhook before any work starts, so it is also the dedupe: a
# retried delivery collides on the unique index instead of running twice. See
# `record_delivery`, which is the only way one should be created from a
# webhook.
class Deployment < ApplicationRecord
  belongs_to :org
  belongs_to :server
  belongs_to :integration, class_name: "Integration::Record", optional: true

  # optional, and it stays optional forever: receipts expire on a retention
  # job and a deployment outlives the comprovante that produced it. See the
  # migration for why there is no foreign key constraint either.
  belongs_to :webhook_receipt, class_name: "Webhook::Receipt", optional: true

  STATUSES = %w[queued running succeeded failed skipped].freeze

  # `applied` and `skipped_reason` are written by the queue; the rest by the
  # webhook. All in one blob because they are read together, by one screen,
  # and giving each a column would mean a migration every time GitHub's
  # payload or the executor's answer grows a field.
  store_accessor :details, :commit_message, :commit_author, :pusher,
    :manifests, :resources, :applied, :skipped_reason,
    # Who caused the push, and where to see what it changed. See
    # Integration::Github::Push for why there is no email among them.
    :sender, :sender_avatar, :sender_url, :commit_url, :compare_url, :changed_files

  validates :repo, presence: true
  validates :status, presence: true, inclusion: {in: STATUSES}

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }

  # Cursor scopes on (created_at, id), the same shape ActivityAction uses.
  #
  # The id is not decoration: two deployments created in the same second are
  # ordinary — one push fanning out to two servers writes both rows inside the
  # same request — and a cursor on the timestamp alone would either skip one or
  # loop on it forever.
  scope :older_than, ->(ts, id) {
    where("created_at < :ts OR (created_at = :ts AND id < :id)", ts: ts, id: id.to_i)
  }

  scope :newer_than, ->(ts, id) {
    where("created_at > :ts OR (created_at = :ts AND id > :id)", ts: ts, id: id.to_i)
  }

  scope :matching, ->(text) {
    needle = "%#{sanitize_sql_like(text.to_s.strip)}%"

    where("repo LIKE :q OR sha LIKE :q OR error LIKE :q OR details LIKE :q", q: needle)
  }
  scope :pending, -> { where(status: %w[queued running]) }
  scope :running, -> { where(status: "running") }

  # SERIALISATION KEY: one deploy in flight per server + repository.
  #
  # The ticket asked for (tenant, server, scope), and scope is the one part we
  # do not hold: it lives in the manifest, which only the box has read. Server
  # plus repository is the key we actually have, and it is a superset of the
  # intended one for the shape that matters — two pushes to the same repository
  # landing on the same box.
  #
  # What it does NOT cover, said out loud: two DIFFERENT repositories declaring
  # the same scope on one box would still apply in parallel. That is a
  # configuration where two repositories fight over one namespace, which has a
  # worse problem than this one.
  def serialization_key = "deploy:#{server_id}:#{repo}"

  # superseded_by — a newer deployment for the same key that has not run yet.
  #
  # What matters is the LAST SHA, not the order of arrival. Three pushes while
  # the first is applying should end at the third, not walk through all three —
  # each intermediate apply restarts containers to reach a state nobody asked
  # to stay in.
  def superseded_by
    self.class
      .where(server_id: server_id, repo: repo, status: "queued")
      .where("created_at > ?", created_at)
      .order(created_at: :desc)
      .first
  end

  # record_delivery — the webhook's write, and the whole dedupe.
  #
  # Returns nil when this delivery already landed on this server. Rescuing the
  # uniqueness violation rather than asking `exists?` first is deliberate:
  # GitHub retries in parallel with the attempt it gave up on, so two requests
  # can pass the same check and both insert. The index is the only thing that
  # cannot be raced.
  def self.record_delivery(target:, delivery_id:, ref:, sha:, receipt: nil, details: {})
    create!(
      org: target.integration.org,
      webhook_receipt_id: receipt&.id,
      server: target.server,
      integration: target.integration,
      repo: target.repo,
      trigger_id: target.trigger_id,
      delivery_id: delivery_id,
      ref: ref,
      sha: sha,
      status: "queued",
      details: details.compact
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # cursor — how a row names itself in a URL.
  #
  # Microseconds, because two rows written in the same request differ only
  # there; truncating to the second would make the pair ambiguous and the
  # `id` tiebreaker would then be doing all the work on every page boundary.
  def cursor = "#{created_at.to_f}:#{id}"

  # parse_cursor — nil for anything that is not one, so a hand-edited URL
  # falls back to the newest page instead of raising.
  def self.parse_cursor(raw)
    ts, id = raw.to_s.split(":")

    return nil if ts.blank? || id.blank?

    [Time.zone.at(ts.to_f), id.to_i]
  end

  def queued? = status == "queued"

  def running? = status == "running"

  def start!
    update!(status: "running", started_at: Time.current, error: nil)
  end

  def succeed!(remote_job_id: nil, applied: nil, skipped: nil, resources: nil)
    update!(
      status: "succeeded", finished_at: Time.current, remote_job_id: remote_job_id,
      details: details.merge(
        "applied" => applied, "skipped" => skipped, "resources" => resources.presence
      ).compact
    )
  end

  def fail!(message)
    update!(status: "failed", finished_at: Time.current, error: message.to_s.truncate(1000))
  end

  # skip! — finished without deploying, and that is not a failure.
  #
  # Two things land here: a push superseded by a newer one, and a push the box
  # read and decided nothing matched (wrong branch, no watched path). Neither
  # is an error, and colouring them red would train operators to ignore red.
  def skip!(reason)
    update!(status: "skipped", finished_at: Time.current,
      details: details.merge("skipped_reason" => reason.to_s))
  end

  def finished? = %w[succeeded failed skipped].include?(status)

  # The short SHA every screen shows. Seven characters is what GitHub prints,
  # and matching it means an operator can compare the two by eye.
  def short_sha = sha.to_s[0, 7]

  # The branch, without the `refs/heads/` GitHub sends.
  def branch = ref.to_s.delete_prefix("refs/heads/")

  # Resource — one thing this deploy put on the box.
  #
  # (scope, name) is the pair every path on the box is keyed by, which is what
  # lets a deployment link straight to a pod without a lookup table.
  Resource = Struct.new(:kind, :scope, :name) do
    def label = scope.present? ? "#{scope}/#{name}" : name
  end

  def deployed_resources
    Array(resources).map { |row| Resource.new(row["kind"], row["scope"], row["name"]) }
  end

  # pods_for — the containers currently running one deployed resource.
  #
  # A resource is a DECLARATION and a pod is a running container, so this is
  # one-to-many: three replicas of `runa/web` are three rows. Read live rather
  # than stored on the deployment, because the pods a resource has now are not
  # the pods it had when it deployed — a replica restarted an hour later has a
  # new container name, and a link recorded at deploy time would 404.
  #
  # Empty is a real answer and the screen says so: a resource deployed last
  # week whose containers are gone is exactly the thing somebody opens this
  # page to find out about.
  def pods_for(resource)
    server.pods.where(scope: resource.scope.to_s, resource_name: resource.name.to_s)
      .order(:container_name)
  end

  # for_pod — the deploys that touched one pod, newest first.
  #
  # TWO STEPS, and the second is what makes it correct. The LIKE narrows to
  # rows whose blob mentions the name at all; the Ruby filter then matches
  # (scope, name) against the PARSED structs.
  #
  # A single SQL match would have to assume the key order inside the JSON
  # (`"scope":…,"name":…`), which is set by Go's struct field order and by
  # `omitempty` on an unscoped resource. That is a match that keeps working
  # until somebody reorders a struct, and then silently returns nothing —
  # the worst failure shape for a link that is supposed to say "this pod came
  # from that deploy".
  #
  # The LIKE does not use an index. Bounded to one server, on a page nobody
  # opens in a loop, and `LIMIT` keeps the parsed set small. A join table would
  # be a second place the truth lives, which is what the blob avoids.
  def self.for_pod(server:, scope:, name:, limit: 10)
    candidates = where(server_id: server.id, status: "succeeded")
      .where("details LIKE ?", "%#{sanitize_sql_like(name.to_s)}%")
      .recent
      .limit(limit * 5)

    candidates.select do |deployment|
      deployment.deployed_resources.any? do |resource|
        resource.name.to_s == name.to_s && resource.scope.to_s == scope.to_s
      end
    end.first(limit)
  end
end
