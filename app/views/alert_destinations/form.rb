# frozen_string_literal: true

# Views::AlertDestinations::Form — New/Edit destination modal. One
# generic kind (webhook): a URL + optional auth header + optional JSON
# body template with {{tokens}}. The body-template popover ships
# starter templates for Slack / Telegram / PagerDuty / Zapier so any
# provider is a copy-and-tweak away — no hardcoded provider config.
#
# The URL is encrypted at rest; on edit it's pre-filled (masked) with
# an eye toggle so the operator can verify it. The auth header value
# stays blank-keeps (more sensitive; not pre-filled).
class Views::AlertDestinations::Form < Views::Base
  # Token list shown under the body field.
  TOKENS = %w[
    {{rule}} {{state}} {{target}} {{metric}} {{value}} {{threshold}}
    {{peak}} {{unit}} {{island}} {{started_at}} {{resolved_at}} {{url}}
    {{event_action}} {{dedup_key}}
  ].freeze

  def initialize(current_path:, destination:, islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @destination    = destination
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      render(modal) { form_body }
    end
  end

  private

  def persisted?
    @destination.persisted?
  end

  def modal
    Components::UI::Modal.new(
      title:    persisted? ? "Edit destination" : "New destination",
      subtitle: "POST a request to this target when an alert fires or resolves",
      icon:     :PaperAirplaneOutline,
      size:     :lg,
      close_to: alerts_path(tab: "destinations")
    ).with_footer { footer_actions }
  end

  # Two columns at vmd+ (the connection on the left, the payload on the
  # right where the tall body editor has room); stacks on narrow.
  def form_body
    form(
      action: persisted? ? alert_destination_path(@destination) : alert_destinations_path,
      method: "post",
      data:   { turbo: false },
      id:     "destination-form",
      class:  "px-5 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if persisted?
      input(type: "hidden", name: "alert_destination[kind]", value: "webhook")

      div(class: "flex flex-col vmd:flex-row gap-4 vmd:gap-5") do
        div(class: "flex flex-col gap-4 vmd:flex-1 min-w-0") do
          field(label: "Name", error: @destination.errors[:name].first) do
            text_input(name: "alert_destination[name]", value: @destination.name, placeholder: "Slack #ops")
          end
          field(label: "Type") { type_static }
          url_field
          auth_header_field
        end

        div(class: "flex flex-col gap-4 vmd:flex-1 min-w-0") do
          body_template_field
          triggers_field
        end
      end
    end
  end

  # Single kind — render it as a static, read-only field (matches the
  # form's other inputs visually) plus the hidden kind above.
  def type_static
    div(class: tokens(input_classes, "text-[13px] flex items-center text-voodu-muted cursor-default")) do
      "Generic webhook"
    end
  end

  def url_field
    field(label: "Webhook URL", hint: url_hint, error: @destination.errors[:endpoint].first) do
      div(class: "relative", data: { controller: "reveal" }) do
        input(
          # New: visible while pasting. Edit: pre-filled + masked, eye reveals.
          type:  persisted? ? "password" : "text",
          name:  "alert_destination[endpoint]",
          value: persisted? ? @destination.endpoint : nil,
          placeholder: "https://hooks.slack.com/… · https://api.telegram.org/bot…/sendMessage",
          autocomplete: "off", spellcheck: "false",
          data: { reveal_target: "input" },
          class: tokens(input_classes, "pr-10 font-voodu-mono text-[12.5px]")
        )
        button(
          type: "button",
          title: "Show / hide URL",
          data: { action: "click->reveal#toggle" },
          class: "absolute right-[1px] top-[1px] bottom-[1px] px-2.5 text-voodu-muted hover:text-voodu-text border-l border-voodu-border bg-voodu-surface inline-flex items-center"
        ) { render Icon::EyeOutline.new(class: "w-3.5 h-3.5") }
      end
    end
  end

  def url_hint
    persisted? ? "Leave blank to keep the current URL." : "http(s) endpoint we POST to. The eye reveals it."
  end

  # Optional custom auth header — free-form name + value so any scheme
  # works (Authorization: Bearer …, x-api-key: …, etc.).
  def auth_header_field
    div(class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { "Auth header (optional)" }

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-2") do
        text_input(name: "alert_destination[secret_header]", value: @destination.secret_header,
                   placeholder: "Authorization / x-api-key", mono: true)
        text_input(name: "alert_destination[secret]", value: nil,
                   placeholder: persisted? ? "•••••• (unchanged)" : "Bearer … / your-key", mono: true)
      end

      hint_or_error(:secret, "Header name + value. Blank = no auth; value blank on edit keeps it.")
    end
  end

  # Optional JSON body template with {{tokens}}. A popover offers
  # starter templates per provider (fills the textarea).
  def body_template_field
    div(class: "flex flex-col gap-1.5 vmd:flex-1 vmd:min-h-0", data: { controller: "template-picker" }) do
      div(class: "flex items-center justify-between") do
        span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { "Body template (optional)" }
        templates_popover
      end

      textarea(
        name: "alert_destination[body_template]",
        rows: 12, spellcheck: "false", autocapitalize: "off", autocomplete: "off",
        placeholder: %({\n  "text": "{{rule}} is {{state}} on {{target}} ({{value}}{{unit}})"\n}),
        data:  { template_picker_target: "textarea" },
        class: tokens(input_classes, "font-voodu-mono text-[12px] leading-relaxed py-2 h-auto min-h-[220px] resize-y vmd:flex-1")
      ) { @destination.body_template }

      if (err = @destination.errors[:body_template].first)
        error_line(err)
      else
        div(class: "flex flex-col gap-1 text-[11.5px] text-voodu-muted") do
          div do
            plain "Valid JSON, sent as-is (blank = default payload). Tokens: "
            span(class: "font-voodu-mono text-voodu-text-2") { TOKENS.join(" ") }
          end
          div do
            plain "Filters (Liquid-style): "
            span(class: "font-voodu-mono text-voodu-text-2") { "{{dedup_key | slice: 0, 6}}" }
            plain " · slice · truncate · upcase · downcase · strip · default"
          end
        end
      end
    end
  end

  def templates_popover
    div(class: "relative", data: { controller: "dropdown" }) do
      button(
        type: "button",
        title: "Insert a starter template",
        data: { action: "click->dropdown#toggle" },
        class: "inline-flex items-center gap-1 px-2 h-6 text-[11px] text-voodu-text-2 border border-voodu-border bg-voodu-surface hover:bg-voodu-surface-2 transition-colors"
      ) do
        render Icon::DocumentDuplicateOutline.new(class: "w-3 h-3 shrink-0")
        span { "Templates" }
        render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 opacity-70")
      end

      div(
        hidden: true,
        data:  { dropdown_target: "menu" },
        class: "absolute right-0 top-[calc(100%+4px)] z-40 w-[200px] border border-voodu-border-2 bg-voodu-surface shadow-2xl py-1"
      ) do
        PROVIDER_TEMPLATES.each do |label, json|
          button(
            type: "button",
            data: { template: json, action: "click->template-picker#fill click->dropdown#close" },
            class: "flex items-center gap-2 w-full px-3 py-2 text-left text-[12.5px] text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"
          ) do
            render Icon::DocumentDuplicateOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted")
            span { label }
          end
        end
      end
    end
  end

  def triggers_field
    field(label: "Notify on", error: @destination.errors[:base].first) do
      div(class: "flex flex-col gap-2") do
        checkbox_row("alert_destination[on_firing]", "Firing", @destination.on_firing != false)
        checkbox_row("alert_destination[on_resolved]", "Resolved", @destination.on_resolved != false)
        enabled_row
      end
    end
  end

  def checkbox_row(name, label, checked)
    label(class: "inline-flex items-center gap-2 text-[12.5px] text-voodu-text-2 cursor-pointer select-none") do
      input(type: "hidden", name: name, value: "0")
      input(type: "checkbox", name: name, value: "1", checked: checked, class: "w-3.5 h-3.5 accent-voodu-accent")
      span { label }
    end
  end

  def enabled_row
    label(class: "inline-flex items-center gap-2 text-[12.5px] text-voodu-text-2 cursor-pointer select-none mt-1 pt-2 border-t border-voodu-border-2") do
      input(type: "hidden", name: "alert_destination[enabled]", value: "0")
      input(type: "checkbox", name: "alert_destination[enabled]", value: "1",
            checked: @destination.enabled != false, class: "w-3.5 h-3.5 accent-voodu-accent")
      span { "Enabled" }
    end
  end

  # ---- shared field plumbing ----

  def field(label:, hint: nil, error: nil)
    div(class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { label }

      yield

      if error
        error_line(error)
      elsif hint
        div(class: "text-[11.5px] text-voodu-muted") { hint }
      end
    end
  end

  def hint_or_error(field, hint)
    err = @destination.errors[field].first
    err ? error_line(err) : div(class: "text-[11.5px] text-voodu-muted") { hint }
  end

  def error_line(message)
    div(class: "text-[11.5px] text-voodu-red inline-flex items-center gap-1.5") do
      span(class: "inline-block w-[5px] h-[5px] rounded-full bg-voodu-red", "aria-hidden": "true")
      span { message }
    end
  end

  def text_input(name:, value: nil, placeholder: nil, mono: false)
    input(
      type: "text", name: name, value: value, placeholder: placeholder,
      autocomplete: "off", spellcheck: "false",
      class: tokens(input_classes, mono ? "font-voodu-mono text-[12.5px]" : "text-[13px]")
    )
  end

  def input_classes
    "w-full px-3 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none " \
      "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line placeholder:text-voodu-muted-2"
  end

  def footer_actions
    span(class: "text-[11.5px] text-voodu-muted hidden vmd:inline") { "Delivered asynchronously, with retries." }

    div(class: "flex-1")

    a(
      href: alerts_path(tab: "destinations"),
      class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { "Cancel" }

    button(
      type: "submit",
      form: "destination-form",
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12.5px] font-medium hover:bg-voodu-accent-2"
    ) do
      render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
      span { persisted? ? "Save changes" : "Create destination" }
    end
  end

  # Starter body templates per provider. The operator fills the URL
  # (and provider-specific bits like chat_id / routing_key) separately.
  PROVIDER_TEMPLATES = {
    "Slack" => <<~JSON.strip,
      {
        "text": "🚨 *{{rule}}* — {{state}}\\n`{{target}}` at {{value}}{{unit}} (threshold {{threshold}}{{unit}})"
      }
    JSON
    "Telegram" => <<~JSON.strip,
      {
        "chat_id": "YOUR_CHAT_ID",
        "parse_mode": "HTML",
        "disable_web_page_preview": true,
        "text": "🚨 <b>{{rule}}</b>\\n<i>{{state}}</i>\\n\\n📦 <code>{{target}}</code>\\n📊 {{metric}}: {{value}}{{unit}} (limite {{threshold}}{{unit}})\\n🕐 {{started_at}}"
      }
    JSON
    "PagerDuty" => <<~JSON.strip,
      {
        "routing_key": "YOUR_ROUTING_KEY",
        "event_action": "{{event_action}}",
        "dedup_key": "{{dedup_key}}",
        "payload": {
          "summary": "{{rule}} {{state}} — {{target}} at {{value}}{{unit}}",
          "severity": "critical",
          "source": "{{island}}",
          "custom_details": { "metric": "{{metric}}", "value": "{{value}}{{unit}}", "threshold": "{{threshold}}{{unit}}" }
        }
      }
    JSON
    "Zapier" => <<~JSON.strip
      {
        "event": "{{state}}",
        "rule": "{{rule}}",
        "target": "{{target}}",
        "metric": "{{metric}}",
        "value": "{{value}}",
        "unit": "{{unit}}",
        "threshold": "{{threshold}}",
        "island": "{{island}}",
        "started_at": "{{started_at}}"
      }
    JSON
  }.freeze
end
