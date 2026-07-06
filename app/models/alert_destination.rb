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
# `kind` stays a column (single value today) so re-introducing
# first-class kinds later is additive. It is deliberately NOT `type`,
# which Rails reserves for STI.
class AlertDestination < ApplicationRecord
  # org-level (M3): a webhook is a shared notification target across the org's
  # servers, not tied to one — so it belongs to the org, and any rule in the org
  # (targeting any server) can wire to it.
  belongs_to :org
  has_many :alert_rule_destinations, dependent: :destroy
  has_many :alert_rules, through: :alert_rule_destinations

  KINDS = %w[webhook].freeze
  TRANSITIONS = %w[firing resolved].freeze

  encrypts :endpoint_ciphertext
  encrypts :secret_ciphertext
  alias_attribute :endpoint, :endpoint_ciphertext
  alias_attribute :secret, :secret_ciphertext

  validates :name, presence: true, length: {maximum: 64},
    uniqueness: {scope: :org_id}
  validates :kind, inclusion: {in: KINDS}
  validates :endpoint, presence: true
  validate :endpoint_is_http_url
  validate :at_least_one_trigger
  validate :body_template_is_json

  scope :enabled, -> { where(enabled: true) }

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
