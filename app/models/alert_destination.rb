# frozen_string_literal: true

# AlertDestination — a shared, island-scoped notification target that
# alert rules fire requests to when they transition firing/resolved.
#
# Three kinds:
#   slack    → an incoming-webhook URL (POST { text: ... })
#   webhook  → a generic URL we POST a JSON payload to (Zapier
#              catch-hooks, custom endpoints, …) with an OPTIONAL
#              custom auth header.
#   telegram → a bot token + chat_id; we derive the Bot API
#              sendMessage URL and POST { chat_id, text }.
#
# Column mapping per kind (`secret_ciphertext`, aliased `secret`, is
# the one encrypted credential — its meaning is kind-specific):
#   slack    → endpoint = webhook URL
#   webhook  → endpoint = URL; secret_header + secret = auth header
#   telegram → secret = bot token; chat_id = chat; endpoint derived
#
# The webhook auth header is free-form so any scheme works:
#   Authorization : Bearer <token>   /   Authorization : Token token="…"
#   x-api-key     : <key>            /   x-zapier-key  : <key>
# The header NAME (`secret_header`) and `chat_id` are not sensitive —
# plain columns shown back on edit. `kind` is a plain string column —
# deliberately NOT `type`, which Rails reserves for STI.
class AlertDestination < ApplicationRecord
  belongs_to :island
  has_many :alert_rule_destinations, dependent: :destroy
  has_many :alert_rules, through: :alert_rule_destinations

  KINDS       = %w[slack webhook telegram].freeze
  TRANSITIONS = %w[firing resolved].freeze
  TELEGRAM_API = "https://api.telegram.org"

  encrypts :endpoint_ciphertext
  encrypts :secret_ciphertext
  alias_attribute :endpoint, :endpoint_ciphertext
  alias_attribute :secret,   :secret_ciphertext

  before_validation :derive_telegram_endpoint

  validates :name, presence: true, length: { maximum: 64 },
                   uniqueness: { scope: :island_id }
  validates :kind, inclusion: { in: KINDS }
  validates :endpoint, presence: true
  validate  :endpoint_is_http_url
  validate  :slack_endpoint_host
  validate  :at_least_one_trigger
  validates :secret,  presence: true, if: :telegram?
  validates :chat_id, presence: true, if: :telegram?
  validate  :body_template_is_json

  scope :enabled, -> { where(enabled: true) }

  def webhook?
    kind == "webhook"
  end

  # True when this webhook has a custom JSON body template to render
  # instead of the default structured payload.
  def custom_body?
    webhook? && body_template.present?
  end

  # Does this destination want to be told about `transition`?
  def notifies?(transition)
    case transition.to_s
    when "firing"   then on_firing?
    when "resolved" then on_resolved?
    else false
    end
  end

  def slack?
    kind == "slack"
  end

  def telegram?
    kind == "telegram"
  end

  # The URL we actually POST to. Telegram derives it from the bot
  # token; the others post to the configured endpoint.
  def delivery_url
    telegram? ? "#{TELEGRAM_API}/bot#{secret}/sendMessage" : endpoint
  end

  # The custom auth header to send with a webhook POST, or {} when not
  # configured (or incomplete — both name and value are required).
  # Telegram authenticates via the URL, so never has one.
  def auth_header
    return {} if telegram? || secret_header.blank? || secret.blank?

    { secret_header => secret }
  end

  # Endpoint with the path/token blanked for display — never render
  # the full secret URL in a table.
  def endpoint_masked
    return "api.telegram.org · chat #{chat_id}" if telegram?

    uri = URI.parse(endpoint.to_s)
    host = uri.host
    return "—" if host.blank?

    "#{uri.scheme}://#{host}/…"
  rescue URI::InvalidURIError
    "—"
  end

  private

  # Telegram has no operator-entered endpoint — set the API base so
  # the NOT NULL + https validations pass; delivery_url builds the
  # real bot URL from the token. Forced (ignores any stale submitted
  # value left over from switching kinds in the form).
  def derive_telegram_endpoint
    self.endpoint = TELEGRAM_API if telegram?
  end

  # Generic webhooks may be http — operators legitimately target a
  # local/internal API (a box on their own network, a dev endpoint).
  # Slack is always https (enforced separately below).
  def endpoint_is_http_url
    return if endpoint.blank?
    return if endpoint.to_s.match?(%r{\Ahttps?://[^/]+})

    errors.add(:endpoint, "must be an http(s) URL")
  end

  def slack_endpoint_host
    return unless slack?
    return if endpoint.blank?
    return if endpoint.to_s.match?(%r{\Ahttps://hooks\.slack\.com/})

    errors.add(:endpoint, "must be a https://hooks.slack.com/… incoming webhook URL")
  end

  def at_least_one_trigger
    return if on_firing? || on_resolved?

    errors.add(:base, "pick at least one of firing / resolved")
  end

  # A custom body only applies to the webhook kind, and must be valid
  # JSON (we parse + re-marshal it at delivery so token values are
  # escaped safely).
  def body_template_is_json
    return if body_template.blank? || !webhook?

    JSON.parse(body_template)
  rescue JSON::ParserError
    errors.add(:body_template, "must be valid JSON")
  end
end
