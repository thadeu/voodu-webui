# frozen_string_literal: true

# Components::Alerts::DestinationsTable — the Destinations tab body:
# one row per shared notification target, plus a "New destination"
# affordance. Rows are flex (not <table>) so they stack cleanly at
# 360px; action labels hide on mobile.
class Components::Alerts::DestinationsTable < Components::Base
  def initialize(destinations:)
    @destinations = destinations
  end

  def view_template
    toolbar

    if @destinations.empty?
      empty_state
    else
      div(class: "border border-voodu-border bg-voodu-surface") do
        @destinations.each { |dest| destination_row(dest) }
      end
    end
  end

  private

  def toolbar
    div(class: "flex items-center justify-between gap-2 mb-2.5") do
      span(class: "text-[12px] text-voodu-muted") do
        "Where alerts are sent when a rule fires or resolves."
      end
      render Components::UI::Button.new(
        variant: :primary, size: :sm, tag: :a, href: new_alert_destination_path
      ) do
        render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "New destination" }
      end
    end
  end

  def destination_row(dest)
    div(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-4 px-3.5 py-3 " \
             "border-b border-voodu-border-2 last:border-b-0"
    ) do
      div(class: "flex items-center gap-2.5 flex-1 min-w-0") do
        render Icon::PaperAirplaneOutline.new(class: "w-4 h-4 shrink-0 text-voodu-muted-2")

        div(class: "flex flex-col gap-0.5 min-w-0") do
          div(class: "flex items-center gap-2 min-w-0") do
            span(class: "text-[12.5px] font-medium text-voodu-text truncate") { dest.name }
            paused_tag unless dest.enabled?
          end
          span(class: "text-[11px] font-voodu-mono text-voodu-muted truncate") { dest.endpoint_masked }
        end
      end

      div(class: "flex items-center gap-4 vmd:gap-5 shrink-0") do
        triggers_cell(dest)
        delivery_cell(dest)
      end

      actions_row(dest)
    end
  end

  def paused_tag
    span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted-2 border border-voodu-border-2 px-1.5 py-0.5") do
      "paused"
    end
  end

  def triggers_cell(dest)
    on = []
    on << "firing" if dest.on_firing?
    on << "resolved" if dest.on_resolved?

    div(class: "flex flex-col gap-0.5") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { "notifies" }
      span(class: "text-[12px] text-voodu-text-2 whitespace-nowrap") { on.join(" · ") }
    end
  end

  def delivery_cell(dest)
    div(class: "flex flex-col gap-0.5") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { "last delivery" }
      span(class: "text-[12px] whitespace-nowrap", style: delivery_style(dest)) { delivery_label(dest) }
    end
  end

  def delivery_label(dest)
    case dest.last_status
    when "ok" then "ok · #{ago(dest.last_delivered_at)}"
    when "failed" then "failed"
    else "—"
    end
  end

  def delivery_style(dest)
    case dest.last_status
    when "ok" then "color: var(--voodu-green);"
    when "failed" then "color: var(--voodu-red);"
    else "color: var(--voodu-muted);"
    end
  end

  def actions_row(dest)
    div(class: "flex items-center gap-1.5 shrink-0") do
      test_button(dest)

      render Components::UI::Button.new(
        variant: :ghost, size: :sm, tag: :a,
        href: edit_alert_destination_path(dest), title: "Edit destination"
      ) do
        render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Edit" }
      end

      delete_button(dest)
    end
  end

  # Sends a one-off probe payload. Plain POST; the controller flashes
  # the ✓/✗ result. title carries the failure reason when present.
  def test_button(dest)
    form(action: test_alert_destination_path(dest), method: "post", data: {turbo: false}) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      render Components::UI::Button.new(
        variant: :ghost, size: :sm, type: :submit,
        title: dest.last_error.presence || "Send a test payload"
      ) do
        render Icon::PaperAirplaneOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Test" }
      end
    end
  end

  def delete_button(dest)
    render Components::UI::Confirmable.new(
      title: "Remove destination",
      message: "Stop sending alerts to \"#{dest.name}\"? Rules notifying only this destination will fall back to all.",
      confirm_label: "Remove",
      danger: true,
      icon: :TrashOutline,
      form: {action: alert_destination_path(dest), method: :delete},
      trigger: {
        class: "inline-flex items-center gap-2 px-3 py-1.5 text-xs rounded-voodu-md " \
               "text-voodu-muted hover:text-voodu-red hover:bg-voodu-red-dim transition-colors",
        title: "Remove destination",
        "aria-label": "Remove #{dest.name}"
      }
    ) do
      render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Remove" }
    end
  end

  def empty_state
    div(class: "flex flex-col items-center justify-center gap-3 px-6 py-14 border border-voodu-border border-dashed bg-voodu-surface text-center") do
      render Icon::PaperAirplaneOutline.new(class: "w-7 h-7 text-voodu-muted-2")
      div(class: "text-[14px] font-semibold text-voodu-text") { "No destinations yet" }
      div(class: "text-[12.5px] text-voodu-muted max-w-[46ch]") do
        plain "Add a webhook (Slack, Telegram, PagerDuty, Zapier or any "
        plain "endpoint) and your rules POST there on fire/resolve. Rules "
        plain "notify all destinations unless you narrow them per rule."
      end
      render Components::UI::Button.new(variant: :primary, size: :md, tag: :a, href: new_alert_destination_path) do
        render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
        span { "New destination" }
      end
    end
  end

  def ago(time)
    return "—" if time.nil?

    secs = (Time.current - time).to_i.abs

    case secs
    when 0..59 then "#{secs}s ago"
    when 60..3599 then "#{secs / 60}m ago"
    when 3600..86_399 then "#{secs / 3600}h ago"
    else "#{secs / 86_400}d ago"
    end
  end
end
