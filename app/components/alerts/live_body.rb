# frozen_string_literal: true

# Components::Alerts::LiveBody — everything inside the `alerts-live`
# turbo-frame: the tab bar (Active / Rules / History with live
# counts) plus the ONE active tab's panel. Rendered by both
# Views::Alerts::Index (initial load) and Views::Alerts::Frame
# (alerts_tick reload) so the broadcast swap is DOM-stable.
#
# Tabs are server-driven (?tab=…): only the active panel's rows are
# loaded, so a 5,000-row history never costs anything until the
# operator opens that tab. The tab bar lives inside the frame so the
# counts refresh on every fire/resolve broadcast.
class Components::Alerts::LiveBody < Components::Base
  TABS = [
    {id: :active, label: "Active"},
    {id: :rules, label: "Rules"},
    {id: :destinations, label: "Destinations"},
    {id: :history, label: "History"}
  ].freeze

  def initialize(data:, active_tab: :active)
    @data = data
    @active_tab = active_tab
  end

  def view_template
    # Show the tabbed UI once anything exists — rules OR destinations.
    # Destinations are configured independently of rules, so a fresh
    # island with a Slack target but no rules yet still reaches the
    # Destinations tab instead of the rules-onboarding empty state.
    if @data.rules? || @data.destinations_count.positive?
      tab_bar
      active_panel
    else
      empty_state
    end
  end

  private

  def tab_bar
    nav(
      class: "flex items-center gap-1 overflow-x-auto -mx-3.5 px-3.5 vmd:mx-0 vmd:px-0 " \
             "vmd:overflow-visible border-b border-voodu-border-2",
      aria: {label: "Alerts view"}
    ) do
      TABS.each { |tab| tab_link(tab) }
    end
  end

  def tab_link(tab)
    active = tab[:id] == @active_tab
    count = tab_count(tab[:id])
    danger = tab[:id] == :active && count.positive?

    a(
      href: alerts_path(tab: tab[:id]),
      "aria-current": (active ? "page" : nil),
      class: tokens(
        "inline-flex items-center gap-2 px-1 pb-2.5 -mb-px text-[13px] border-b-2 transition-colors shrink-0",
        active ? "border-voodu-accent text-voodu-text font-medium" : "border-transparent text-voodu-text-2 hover:text-voodu-text"
      )
    ) do
      span { tab[:label] }
      count_badge(count, danger: danger)
    end
  end

  def count_badge(count, danger:)
    span(
      class: tokens(
        "inline-flex items-center justify-center min-w-[18px] h-[16px] px-1 text-[10.5px] font-voodu-mono leading-none",
        danger ? "bg-voodu-red-dim text-voodu-red" : "bg-voodu-surface-2 text-voodu-muted"
      )
    ) { count.to_s }
  end

  def tab_count(id)
    case id
    when :active then @data.firing_count
    when :rules then @data.rules_count
    when :destinations then @data.destinations_count
    when :history then @data.history_count
    end
  end

  def active_panel
    div(class: "pt-4") do
      case @active_tab
      when :active then active_tab_panel
      when :rules then render Components::Alerts::RulesTable.new(rules: @data.rules)
      when :destinations then render Components::Alerts::DestinationsTable.new(destinations: @data.destinations)
      when :history then history_panel
      end
    end
  end

  # History tab: the date/hour range filter (reused generic component,
  # frame-scoped so a range change swaps just the alerts-live frame and
  # advances the URL) above the day-grouped timeline.
  def history_panel
    div(class: "flex flex-col gap-3.5") do
      div(class: "flex justify-end") do
        render Components::UI::TimeRangeFilter.new(
          form_action: alerts_path,
          frame: "alerts-live",
          active_range: @data.history_filter.range,
          ranges: AlertHistoryFilter::RANGES.keys,
          from_iso: @data.history_filter.from_iso,
          until_iso: @data.history_filter.until_iso,
          extra_params: {tab: "history"}
        )
      end

      render Components::Alerts::HistoryList.new(
        events: @data.history,
        total: @data.history_window_count,
        truncated: @data.history_truncated?
      )
    end
  end

  def active_tab_panel
    if @data.firing_events.any?
      div(class: "flex flex-col gap-2.5") do
        @data.firing_events.each do |event|
          render Components::Alerts::FiringCard.new(event: event)
        end
      end
    else
      all_clear_strip
    end
  end

  def all_clear_strip
    div(class: "flex items-center gap-2.5 px-3.5 py-3 border border-voodu-border bg-voodu-surface") do
      render Icon::CheckCircleOutline.new(class: "w-4 h-4 shrink-0", style: "color: var(--voodu-green);")
      span(class: "text-[12.5px] text-voodu-text-2") { "All clear — no rule is above its threshold." }
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
    form(action: defaults_alert_rules_path, method: "post", data: {turbo: false}) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      render Components::UI::Button.new(variant: :secondary, size: :md, type: :submit, class: "w-full vmd:w-auto") do
        render Icon::SparklesOutline.new(class: "w-3.5 h-3.5")
        span { "Create default rules" }
      end
    end
  end
end
