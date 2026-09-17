# frozen_string_literal: true

# Webhook::Receipt — one delivery that arrived, and what became of it.
#
# NAMESPACED so the surface has room: a future outbound webhook is
# `Webhook::Endpoint` or `Webhook::Delivery` beside this, rather than a second
# top-level name competing for the word.
#
# A RECEIPT AND NOT A WEBHOOK. What this row holds is the comprovante — that
# something arrived, when, and what we decided. The webhook is the thing the
# provider sent; this is our record of receiving it.
class Webhook::Receipt < ApplicationRecord
  self.table_name = "webhook_receipts"

  PROVIDERS = %w[github stripe].freeze

  # The outcomes, and the value is that they are SEPARATE. "It did not work" is
  # not a diagnosis: `refused_signature` and `no_target` send an operator to
  # opposite ends of the problem — one is a secret that does not match, the
  # other is a repository nobody pointed at a server.
  STATUSES = {
    "accepted" => "Produced work",
    "no_target" => "No server listed it",
    "skipped" => "Nothing to do",
    "ignored" => "Event we do not handle",
    "duplicate" => "Already seen",
    "refused_signature" => "Signature did not verify",
    "failed" => "Errored while processing"
  }.freeze

  # The ones an operator is usually hunting for. Everything else is noise on a
  # working installation.
  TROUBLE = %w[refused_signature failed no_target].freeze

  validates :provider, presence: true
  validates :event, presence: true
  validates :status, presence: true, inclusion: {in: STATUSES.keys}

  scope :recent, -> { order(received_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(received_at: :asc, id: :asc) }
  scope :trouble, -> { where(status: TROUBLE) }

  # Cursor scopes on (received_at, id), the shape Activity and Deployment use.
  # The id is not decoration: a provider can deliver twice inside one second.
  scope :older_than, ->(ts, id) {
    where("received_at < :ts OR (received_at = :ts AND id < :id)", ts: ts, id: id.to_i)
  }

  scope :newer_than, ->(ts, id) {
    where("received_at > :ts OR (received_at = :ts AND id > :id)", ts: ts, id: id.to_i)
  }

  scope :matching, ->(text) {
    needle = "%#{sanitize_sql_like(text.to_s.strip)}%"

    where("reference LIKE :q OR event LIKE :q OR external_id LIKE :q OR CAST(details AS TEXT) LIKE :q", q: needle)
  }

  # record — the only writer, and it is the dedupe.
  #
  # Rescuing the uniqueness violation rather than asking `exists?` first: a
  # provider retries in parallel with the attempt it gave up on, so two
  # requests can pass the same check and both insert. The index is the only
  # thing that cannot be raced.
  #
  # Returns [receipt, fresh?] — `false` means this delivery was already seen,
  # which is what tells the caller to do nothing rather than work twice.
  def self.record(provider:, event:, status:, external_id: nil, **attrs)
    receipt = create!(
      provider: provider, event: event, status: status, external_id: external_id.presence,
      received_at: Time.current, **attrs
    )

    [receipt, true]
  rescue ActiveRecord::RecordNotUnique
    [find_by(provider: provider, external_id: external_id), false]
  end

  # THE PAYLOAD IS NEVER TRUSTED AS INSTRUCTIONS. It is written by whoever
  # could reach the endpoint, and it is stored as evidence of what arrived —
  # not as a source of behavior. Everything the app acts on is re-derived
  # from our own records after the signature verified.
  def payload_hash = payload.is_a?(Hash) ? payload : {}

  def status_label = STATUSES.fetch(status, status)

  def trouble? = TROUBLE.include?(status)

  store_accessor :details, :sender, :sender_avatar, :sender_url,
    :commit_message, :commit_url, :compare_url, :changed_files, :reason

  def short_id = external_id.to_s[0, 8]

  # How a row names itself in a URL. Microseconds, because two deliveries
  # written in the same request differ only there.
  def cursor = "#{received_at.to_f}:#{id}"

  # What this delivery produced, asked of the children. See the migration for
  # why the arrow points this way.
  def deployments = Deployment.where(webhook_receipt_id: id)
end
