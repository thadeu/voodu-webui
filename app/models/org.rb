# frozen_string_literal: true

# Org — the tenant/grouping layer above servers (islands). One Org groups
# N servers; from M1 on, Metrics + Alerts become org-level (a panel/alert
# can target any server in the org). Today there's no login — the Org IS
# the future tenant boundary, so the SaaS upgrade (subdomain + user↔org)
# stays additive, no remodel.
#
# Identity: a UUIDv7 string PK (HasUuidV7) for global uniqueness + time
# ordering, plus a `short_id` (8-char base62) as the opaque URL handle used
# from M1 on. A server always belongs to exactly one Org (Island belongs_to
# :org, org_id null:false) — no orphan servers, no default org.
class Org < ApplicationRecord
  include HasUuidV7

  # 8-char base62 handle for URLs (M1). Same rationale as Island::KEY —
  # base62 is URL-clean + hand-typeable; 8 chars (~48 bits) so it's
  # non-guessable at SaaS scale.
  SHORT_ID_ALPHABET = (("0".."9").to_a + ("A".."Z").to_a + ("a".."z").to_a).freeze
  SHORT_ID_LENGTH = 8

  # restrict_with_error: deleting an Org that still owns servers is blocked
  # with a friendly error (mirrors the DB FK restrict) — the operator moves
  # or removes the servers first, so no server is left orphaned.
  has_many :islands, dependent: :restrict_with_error

  # Metric dashboards live at the org level (M2) — a dashboard's panels can
  # pull from any of the org's servers. Reaped with the org.
  has_many :metric_dashboards, dependent: :destroy

  # Alerts are org-level (M3): a rule targets any server in the org, events fire
  # against those servers, and destinations (webhooks) are shared org-wide.
  # Reaped with the org (which is itself blocked while it still owns servers).
  has_many :alert_rules, dependent: :destroy
  has_many :alert_events, dependent: :destroy
  has_many :alert_destinations, dependent: :destroy

  before_validation :ensure_short_id, on: :create

  validates :name, presence: true, uniqueness: true, length: {maximum: 64}
  validates :short_id, presence: true, uniqueness: true, format: {with: /\A[a-zA-Z0-9]{8}\z/}

  # generate_unique_short_id — random 8-char base62 not already taken. The
  # unique index is the real guard; this loop just avoids RecordNotUnique at
  # save (collision odds are negligible even at scale).
  def self.generate_unique_short_id
    loop do
      candidate = Array.new(SHORT_ID_LENGTH) { SHORT_ID_ALPHABET.sample }.join
      break candidate unless exists?(short_id: candidate)
    end
  end

  # to_param — URLs use the opaque short_id (shorter than the uuid, still
  # non-guessable). The route constraint (M1) matches the 8-char shape.
  def to_param
    short_id
  end

  private

  # ensure_short_id — populate on first save so the validation passes.
  # Idempotent; never overwrites (short_id lands in URLs/bookmarks).
  def ensure_short_id
    self.short_id ||= self.class.generate_unique_short_id
  end
end
