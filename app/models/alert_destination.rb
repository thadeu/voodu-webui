# frozen_string_literal: true

# AlertDestination — a shared, ORG-scoped notification target (M3) that alert
# rules fire requests to when they transition firing/resolved. One webhook is
# reusable by every rule in the org, targeting any of its servers.
#
# One generic kind: a webhook. We POST to an operator-supplied URL
# with an OPTIONAL custom auth header and an OPTIONAL custom JSON body
# template. That covers any provider — Slack, Telegram, PagerDuty,
# Zapier, custom endpoints — without hardcoding provider-specific
# config (the form's body-template popover ships starter templates).
#
# Column mapping:
#   endpoint (encrypted)        — the POST URL (may carry a token,
#                                 e.g. a Slack webhook or a Telegram
#                                 bot URL), so it's encrypted at rest.
#   secret_header / secret      — optional auth header: name (plain,
#                                 shown on edit) + value (encrypted).
#   body_template               — optional JSON body with {{tokens}};
#                                 blank → default structured payload.
#
# Two kinds: webhook, and email (cloud only, see Mailing). An email
# destination tells org members, picked by user id in recipient_ids; it has
# no endpoint. `kind` is deliberately NOT `type`, which Rails reserves for
# STI.
class AlertDestination < ApplicationRecord
  # org-level (M3): a webhook is a shared notification target across the org's
  # servers, not tied to one — so it belongs to the org, and any rule in the org
  # (targeting any server) can wire to it.
  belongs_to :org
  has_many :alert_rule_destinations, dependent: :destroy
  has_many :alert_rules, through: :alert_rule_destinations

  KINDS = %w[webhook email].freeze
  TRANSITIONS = %w[firing resolved].freeze

  encrypts :endpoint_ciphertext
  encrypts :secret_ciphertext
  alias_attribute :endpoint, :endpoint_ciphertext
  alias_attribute :secret, :secret_ciphertext

  serialize :recipient_ids, coder: JSON, type: Array

  validates :name, presence: true, length: {maximum: 64},
    uniqueness: {scope: :org_id}
  validates :kind, inclusion: {in: KINDS}
  validates :endpoint, presence: true, if: :webhook?
  validate :endpoint_is_http_url, if: :webhook?
  validate :at_least_one_trigger
  validate :body_template_is_json, if: :webhook?
  validate :recipients_are_members, if: :email?

  scope :enabled, -> { where(enabled: true) }

  def webhook? = kind == "webhook"

  def email? = kind == "email"

  # The addresses of the picked people who are still active members of the org.
  # Someone who left stops getting mail without anyone editing the destination.
  def recipients
    org.memberships.active.where(user_id: recipient_ids).includes(:user).map { |membership| membership.user.email }.sort
  end

  # What the destinations table shows in place of the URL.
  def target_summary
    return endpoint_masked if webhook?

    count = recipients.size

    "Email · #{count} #{"person".pluralize(count)}"
  end

  # Does this destination want to be told about `transition`?
  def notifies?(transition)
    case transition.to_s
    when "firing" then on_firing?
    when "resolved" then on_resolved?
    else false
    end
  end

  # True when a custom JSON body template should render instead of the
  # default structured payload.
  def custom_body?
    body_template.present?
  end

  # Optional auth header to send with the POST, or {} when not
  # configured (both name and value are required).
  def auth_header
    return {} if secret_header.blank? || secret.blank?

    {secret_header => secret}
  end

  # Endpoint with the path/token blanked for display — never render
  # the full secret URL in a table.
  def endpoint_masked
    uri = URI.parse(endpoint.to_s)
    host = uri.host
    return "—" if host.blank?

    "#{uri.scheme}://#{host}/…"
  rescue URI::InvalidURIError
    "—"
  end

  private

  # http or https — operators legitimately target a local/internal API
  # (a box on their own network, a dev endpoint).
  def endpoint_is_http_url
    return if endpoint.blank?
    return if endpoint.to_s.match?(%r{\Ahttps?://[^/]+})

    errors.add(:endpoint, "must be an http(s) URL")
  end

  def recipients_are_members
    self.recipient_ids = Array(recipient_ids).compact_blank.map(&:to_s).uniq & org.memberships.active.pluck(:user_id).map(&:to_s)

    errors.add(:recipient_ids, "pick at least one person") if recipient_ids.empty?
  end

  def at_least_one_trigger
    return if on_firing? || on_resolved?

    errors.add(:base, "pick at least one of firing / resolved")
  end

  # A custom body must be valid JSON (we parse + re-marshal it at
  # delivery so token values are escaped safely).
  def body_template_is_json
    return if body_template.blank?

    JSON.parse(body_template)
  rescue JSON::ParserError
    errors.add(:body_template, "must be valid JSON")
  end
end
