# frozen_string_literal: true

# Views::AlertDestinations::Form — New/Edit destination modal, same
# shell as Views::AlertRules::Form. The `destination-form` Stimulus
# controller shows the right fields per kind (slack = one URL;
# webhook = URL + optional secret).
#
# On edit, secret fields render empty (we never echo a stored
# credential) with a hint that leaving them blank keeps the current
# value — same UX as the island PAT edit.
class Views::AlertDestinations::Form < Views::Base
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
      subtitle: "Send a request to this target when an alert fires or resolves",
      icon:     :PaperAirplaneOutline,
      size:     :md,
      close_to: alerts_path(tab: "destinations")
    ).with_footer { footer_actions }
  end

  def form_body
    form(
      action: persisted? ? alert_destination_path(@destination) : alert_destinations_path,
      method: "post",
      data:   { turbo: false, controller: "destination-form" },
      id:     "destination-form",
      class:  "flex flex-col gap-4 px-5 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if persisted?

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
        field(label: "Name", error: @destination.errors[:name].first) do
          text_input(name: "alert_destination[name]", value: @destination.name, placeholder: "Slack #ops")
        end

        field(label: "Type", error: @destination.errors[:kind].first) do
          kind_select
        end
      end

      endpoint_field
      telegram_field
      secret_field
      body_template_field

      triggers_field
    end
  end

  def kind_select
    select_input(
      name: "alert_destination[kind]",
      data: { destination_form_target: "kind", action: "change->destination-form#kindChanged" }
    ) do
      option(value: "slack",    selected: (@destination.kind == "slack") || nil)    { "Slack" }
      option(value: "webhook",  selected: (@destination.kind == "webhook") || nil)  { "Generic webhook" }
      option(value: "telegram", selected: (@destination.kind == "telegram") || nil) { "Telegram" }
    end
  end

  # slack / webhook — the destination URL. Hidden + disabled for
  # telegram (its URL is derived from the bot token).
  def endpoint_field
    div(data: { destination_form_target: "urlWrap" }) do
      field(
        label: "Webhook URL",
        hint:  endpoint_hint,
        error: @destination.errors[:endpoint].first
      ) do
        text_input(
          name: "alert_destination[endpoint]",
          value: nil,
          placeholder: persisted? ? "•••••• (unchanged)" : "https://hooks.slack.com/services/…",
          mono: true
        )
      end
    end
  end

  # telegram — bot token (encrypted, blank-keeps) + chat_id (plain,
  # shown). Hidden + disabled for the other kinds.
  def telegram_field
    div(hidden: true, data: { destination_form_target: "telegramWrap" }, class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
      field(label: "Bot token", hint: telegram_token_hint, error: @destination.errors[:secret].first) do
        text_input(
          name: "alert_destination[secret]", value: nil,
          placeholder: persisted? ? "•••••• (unchanged)" : "123456789:AAH…", mono: true
        )
      end
      field(label: "Chat ID", hint: "Where to send — see /getUpdates.", error: @destination.errors[:chat_id].first) do
        text_input(name: "alert_destination[chat_id]", value: @destination.chat_id, placeholder: "987654321", mono: true)
      end
    end
  end

  def telegram_token_hint
    persisted? ? "Leave blank to keep the current token." : "From @BotFather (123456:AA…)."
  end

  # Generic webhook only — an optional custom auth header. Free-form
  # name + value so any scheme works (Authorization: Bearer …,
  # x-api-key: …, Authorization: Token token="…"). The name is shown
  # on edit; the value is masked and kept-if-blank.
  def secret_field
    div(hidden: true, data: { destination_form_target: "authWrap" }, class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { "Auth header (optional)" }

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-2") do
        text_input(
          name: "alert_destination[secret_header]", value: @destination.secret_header,
          placeholder: "Authorization / x-api-key", mono: true
        )
        text_input(
          name: "alert_destination[secret]", value: nil,
          placeholder: persisted? ? "•••••• (unchanged)" : "Bearer … / your-key", mono: true
        )
      end

      if (err = @destination.errors[:secret].first || @destination.errors[:secret_header].first)
        div(class: "text-[11.5px] text-voodu-red inline-flex items-center gap-1.5") do
          span(class: "inline-block w-[5px] h-[5px] rounded-full bg-voodu-red", "aria-hidden": "true")
          span { err }
        end
      else
        div(class: "text-[11.5px] text-voodu-muted") do
          "Header name + value. Leave blank for no auth; leave value blank on edit to keep it."
        end
      end
    end
  end

  # Generic webhook only — an optional custom JSON body with {{token}}
  # placeholders. Blank → the default structured payload. Hidden +
  # disabled for the other kinds.
  TEMPLATE_TOKENS = %w[
    {{rule}} {{state}} {{target}} {{metric}} {{value}} {{threshold}}
    {{peak}} {{unit}} {{island}} {{started_at}} {{resolved_at}} {{url}}
  ].freeze

  def body_template_field
    div(hidden: true, data: { destination_form_target: "bodyWrap" }, class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { "Body template (optional)" }

      textarea(
        name: "alert_destination[body_template]",
        rows: 6, spellcheck: "false", autocapitalize: "off", autocomplete: "off",
        placeholder: %({\n  "text": "{{rule}} is {{state}} on {{target}} ({{value}}{{unit}})"\n}),
        class: tokens(input_classes, "font-voodu-mono text-[12px] leading-relaxed py-2 h-auto resize-y")
      ) { @destination.body_template }

      if (err = @destination.errors[:body_template].first)
        div(class: "text-[11.5px] text-voodu-red inline-flex items-center gap-1.5") do
          span(class: "inline-block w-[5px] h-[5px] rounded-full bg-voodu-red", "aria-hidden": "true")
          span { err }
        end
      else
        div(class: "text-[11.5px] text-voodu-muted") do
          plain "Valid JSON, sent as-is (blank = default payload). Tokens: "
          span(class: "font-voodu-mono text-voodu-text-2") { TEMPLATE_TOKENS.join(" ") }
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
      input(type: "checkbox", name: name, value: "1", checked: checked,
            class: "w-3.5 h-3.5 accent-voodu-accent")
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

  def endpoint_hint
    # On edit the hint is static ("blank keeps current") — don't wire
    # the Stimulus target so the controller leaves it alone. On new,
    # attach the target so kindChanged tailors it per type.
    return span { "Leave blank to keep the current URL." } if persisted?

    span(data: { destination_form_target: "endpointHint" }) { "The incoming-webhook URL (https)." }
  end

  # ---- shared field plumbing (same look as Views::AlertRules::Form) ----

  def field(label:, hint: nil, error: nil)
    div(class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { label }

      yield

      if error
        div(class: "text-[11.5px] text-voodu-red inline-flex items-center gap-1.5") do
          span(class: "inline-block w-[5px] h-[5px] rounded-full bg-voodu-red", "aria-hidden": "true")
          span { error }
        end
      elsif hint
        div(class: "text-[11.5px] text-voodu-muted") { hint }
      end
    end
  end

  def text_input(name:, value: nil, placeholder: nil, mono: false)
    input(
      type: "text", name: name, value: value, placeholder: placeholder,
      autocomplete: "off", spellcheck: "false",
      class: tokens(input_classes, mono ? "font-voodu-mono text-[12.5px]" : "text-[13px]")
    )
  end

  def select_input(name:, data: nil)
    select(
      name:  name,
      data:  data,
      class: tokens(input_classes, "text-[13px] appearance-none cursor-pointer")
    ) { yield }
  end

  def input_classes
    "w-full px-3 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none " \
      "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line placeholder:text-voodu-muted-2"
  end

  def footer_actions
    span(class: "text-[11.5px] text-voodu-muted hidden vmd:inline") do
      plain "Delivered asynchronously, with retries."
    end

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
end
