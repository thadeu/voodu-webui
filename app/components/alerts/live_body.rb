# frozen_string_literal: true

# Components::Alerts::LiveBody — everything inside the `alerts-live`
# turbo-frame: firing cards, rules table, resolved history. ONE
# component rendered by both Views::Alerts::Index (initial load) and
# Views::Alerts::Frame (alerts_tick reload) so the broadcast swap is
# DOM-stable — same trick Views::Metrics::Index#chart_grid plays
# with Views::Metrics::Frame.
class Components::Alerts::LiveBody < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    if @data.rules?
      firing_block
      rules_block
      history_block
    else
      empty_state
    end
  end

  private

  def firing_block
    div(class: "flex flex-col gap-2.5") do
      section_head("Firing", count: @data.firing_count, danger: @data.firing_count.positive?)

      if @data.firing_events.any?
        @data.firing_events.each do |event|
          render Components::Alerts::FiringCard.new(event: event)
        end
      else
        all_clear_strip
      end
    end
  end

  def all_clear_strip
    div(class: "flex items-center gap-2.5 px-3.5 py-3 border border-voodu-border bg-voodu-surface") do
      render Icon::CheckCircleOutline.new(class: "w-4 h-4 shrink-0", style: "color: var(--voodu-green);")
      span(class: "text-[12.5px] text-voodu-text-2") { "All clear — no rule is above its threshold." }
    end
  end

  def rules_block
    div(class: "flex flex-col gap-2.5") do
      section_head("Rules", count: @data.rules.size)
      render Components::Alerts::RulesTable.new(rules: @data.rules)
    end
  end

  def history_block
    div(class: "flex flex-col gap-2.5") do
      section_head("History", count: @data.history.size)
      render Components::Alerts::HistoryList.new(events: @data.history)
    end
  end

  # Short uppercase label + a rule fading right — the same section
  # divider the pod show page uses for its HTTP block.
  def section_head(label, count: nil, danger: false)
    div(class: "flex items-center gap-2") do
      span(
        class: tokens(
          "text-[11px] font-semibold uppercase tracking-[0.08em]",
          danger ? "text-voodu-red" : "text-voodu-muted"
        )
      ) { label }
      if count
        span(class: "text-[11px] font-voodu-mono text-voodu-muted-2") { count.to_s }
      end
      span(class: "flex-1 h-px bg-voodu-border-2")
    end
  end

  def empty_state
    div(class: "flex flex-col items-center justify-center gap-3 px-6 py-14 border border-voodu-border border-dashed bg-voodu-surface text-center") do
      render Icon::BellOutline.new(class: "w-7 h-7 text-voodu-muted-2")
      div(class: "text-[14px] font-semibold text-voodu-text") { "No alert rules yet" }
      div(class: "text-[12.5px] text-voodu-muted max-w-[44ch]") do
        plain "Watch disk, CPU, memory and request rate from the metrics "
        plain "warehouse — a rule fires when its threshold holds for the "
        plain "sustained-for window."
      end

      div(class: "flex flex-col vmd:flex-row items-stretch vmd:items-center gap-2 mt-1") do
        defaults_button
        render Components::UI::Button.new(variant: :primary, size: :md, tag: :a, href: new_alert_rule_path) do
          render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
          span { "New rule" }
        end
      end
    end
  end

  # "Create default rules" posts the host-level starter pack
  # (disk 85% / cpu 90% / mem 90%). Idempotent server-side, so a
  # double-click can't duplicate anything.
  def defaults_button
    form(action: defaults_alert_rules_path, method: "post", data: { turbo: false }) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      render Components::UI::Button.new(variant: :secondary, size: :md, type: :submit, class: "w-full vmd:w-auto") do
        render Icon::SparklesOutline.new(class: "w-3.5 h-3.5")
        span { "Create default rules" }
      end
    end
  end
end
