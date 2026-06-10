# frozen_string_literal: true

# AlertPayload — builds the JSON body sent to a destination for a
# fire/resolve transition. The shape depends on the destination kind:
#
#   slack    → { text: "..." } (Slack incoming-webhook render)
#   telegram → { chat_id:, text: } (Bot API sendMessage)
#   webhook  → a flat structured object for generic consumers
#              (Zapier, custom endpoints).
#
# Alert facts are read from the AlertEvent snapshot (rule name,
# target, metric, threshold) so the payload is truthful even if the
# rule was edited after firing. Destination config (chat_id) comes
# from the destination. The deep link is included only when
# APP_BASE_URL is set (jobs have no request host for absolute URLs).
class AlertPayload
  def self.for(event, transition, destination)
    new(event, transition, destination).build
  end

  def initialize(event, transition, destination)
    @event       = event
    @transition  = transition.to_s
    @destination = destination
  end

  def build
    case @destination.kind
    when "slack"    then slack
    when "telegram" then telegram
    else webhook
    end
  end

  def slack
    emoji = firing? ? ":rotating_light:" : ":white_check_mark:"
    line  = "#{emoji} *#{@event.rule_name}* #{state_word} — `#{@event.target_label}` " \
            "at #{value} (threshold #{@event.format_value(@event.threshold)})"
    line += "\n<#{link}|Open alerts>" if link

    { text: line }
  end

  def telegram
    { chat_id: @destination.chat_id, text: telegram_text }
  end

  # A custom body template (operator JSON with {{tokens}}) renders to
  # a verbatim string the client sends as-is; otherwise the default
  # structured object (a Hash the client marshals).
  def webhook
    return WebhookTemplate.render(@destination.body_template, template_tokens) if @destination.custom_body?

    {
      event:        @transition,
      state:        state_word,
      island:       @event.island&.name,
      rule:         @event.rule_name,
      target:       @event.target_label,
      metric:       @event.metric_kind,
      threshold:    @event.threshold,
      value:        @event.last_value,
      peak:         @event.peak_value,
      started_at:   @event.started_at&.utc&.iso8601,
      resolved_at:  @event.resolved_at&.utc&.iso8601,
      url:          link
    }.compact
  end

  # Tokens available to a webhook body template — formatted for human
  # messages: numbers rounded (no float noise; pair with {{unit}} for
  # "90%"), timestamps humanised in the operator's timezone. The
  # default structured payload (above) keeps raw values + ISO for
  # machine consumers.
  def template_tokens
    {
      "rule"        => @event.rule_name,
      "state"       => state_word,
      "event"       => @transition,
      "target"      => @event.target_label,
      "metric"      => @event.metric_kind,
      "unit"        => @event.unit,
      "value"       => AlertRule.format_metric_number(@event.last_value),
      "threshold"   => AlertRule.format_metric_number(@event.threshold),
      "peak"        => AlertRule.format_metric_number(@event.peak_value),
      "island"      => @event.island&.name,
      "started_at"  => human_time(@event.started_at),
      "resolved_at" => human_time(@event.resolved_at),
      "url"         => link
    }
  end

  # Operator-timezone, human-readable timestamp (e.g. "Jun 10, 12:58").
  # Blank for a missing time (resolved_at on a firing event).
  def human_time(time)
    WebTime.strftime(time, "%b %-d, %H:%M") || ""
  end

  private

  def firing?
    @transition == "firing"
  end

  def state_word
    firing? ? "firing" : "resolved"
  end

  def value
    @event.format_value(@event.last_value)
  end

  # Plain text (no parse_mode) so rule names with Markdown specials
  # (_, *, [) don't need escaping and can't break the message.
  def telegram_text
    emoji = firing? ? "🚨" : "✅"
    base  = "#{emoji} #{@event.rule_name} #{state_word} — #{@event.target_label} " \
            "at #{value} (threshold #{@event.format_value(@event.threshold)})"
    link ? "#{base}\n#{link}" : base
  end

  # Absolute /alerts URL, only when APP_BASE_URL is set (jobs can't
  # build *_url without a host). Returns nil otherwise.
  def link
    base = ENV["APP_BASE_URL"].presence
    return nil if base.nil? || @event.island.nil?

    "#{base.chomp('/')}/#{@event.island.key}/alerts"
  end
end
