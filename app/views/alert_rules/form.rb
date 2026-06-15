# frozen_string_literal: true

# Views::AlertRules::Form — the New/Edit alert rule modal, rendered
# over the dashboard chrome (same shell as Views::Islands::New).
#
# The target is ONE select — "Host (entire server)" plus the
# workloads from the state-sync snapshot grouped by scope — encoded
# as `host` / `pod|<scope>|<name>`. Host-vs-pod is a single
# mutually-exclusive choice to the operator; splitting it into two
# controls would just invent an invalid in-between state.
#
# The alert-rule-form Stimulus controller keeps metric ↔ target
# combinations honest as the operator types (disk = host-only,
# req/s = deployments-only) and swaps the unit suffix. Server-side
# model validations remain the real guard.
class Views::AlertRules::Form < Views::Base
  def initialize(current_path:, rule:, targets: [], destinations: [], islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @rule           = rule
    @targets        = targets
    @destinations   = destinations
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
    @rule.persisted?
  end

  def modal
    Components::UI::Modal.new(
      title:    persisted? ? "Edit alert rule" : "New alert rule",
      subtitle: "Fires when the metric holds past the threshold for the whole window",
      icon:     :BellOutline,
      size:     :md,
      close_to: alerts_path
    ).with_footer { footer_actions }
  end

  def form_body
    form(
      action: persisted? ? alert_rule_path(@rule) : alert_rules_path,
      method: "post",
      data:   { turbo: false, controller: "alert-rule-form" },
      id:     "alert-rule-form",
      class:  "flex flex-col gap-4 px-5 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if persisted?

      field(label: "Name", error: @rule.errors[:name].first) do
        text_input(name: "alert_rule[name]", value: @rule.name, placeholder: "Host CPU ≥ 90%")
      end

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
        field(label: "Metric", error: @rule.errors[:metric_kind].first) do
          metric_select
        end

        field(label: "Target", error: target_error) do
          target_select
        end
      end

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
        field(
          label: "Condition",
          hint:  "Direction + threshold the metric is compared against.",
          error: @rule.errors[:threshold].first
        ) do
          condition_inputs
        end

        field(
          label: "Sustained for",
          hint:  "Every sample in this window must breach before it fires.",
          error: @rule.errors[:duration_seconds].first
        ) do
          duration_select
        end
      end

      destinations_field

      input(type: "submit", class: "hidden", "aria-hidden": "true")
    end
  end

  # Which destinations this rule notifies. Empty = all (server-side
  # default). Rendered as an inline scrollable checkbox list — NOT an
  # absolute dropdown — because inside the modal an absolute menu gets
  # clipped by the modal/footer edge. When no destinations exist yet,
  # point the operator at the Destinations tab instead of an empty box.
  def destinations_field
    field(label: "Notify destinations", hint: "Leave empty to notify all destinations.") do
      if @destinations.empty?
        div(class: "text-[12px] text-voodu-muted") do
          plain "No destinations configured. "
          a(href: alerts_path(tab: "destinations"), class: "text-voodu-link hover:underline") { "Add one" }
          plain " to send alerts to Slack, Telegram or a webhook."
        end
      else
        destinations_list
      end
    end
  end

  def destinations_list
    selected = @rule.alert_destination_ids

    div(class: "border border-voodu-border bg-voodu-surface max-h-[150px] overflow-y-auto") do
      # Empty sentinel so an all-unchecked submit clears the
      # association (a checkbox group with nothing checked otherwise
      # omits the key and would leave it unchanged on update).
      input(type: "hidden", name: "alert_rule[alert_destination_ids][]", value: "")

      @destinations.each { |dest| destination_row(dest, selected.include?(dest.id)) }
    end
  end

  def destination_row(dest, checked)
    label(class: "flex items-center gap-2.5 w-full px-3 py-2 cursor-pointer hover:bg-voodu-surface-2 " \
                 "text-[12.5px] text-voodu-text-2 border-b border-voodu-border-2 last:border-b-0") do
      input(
        type: "checkbox", name: "alert_rule[alert_destination_ids][]", value: dest.id,
        checked: checked, class: "w-3.5 h-3.5 accent-voodu-accent"
      )
      span(class: "truncate") { dest.name }
      span(class: "text-[10px] uppercase tracking-[0.05em] text-voodu-muted-2 ml-auto shrink-0") { dest.kind }
    end
  end

  def metric_select
    select_input(name: "alert_rule[metric_kind]", data: { alert_rule_form_target: "metric", action: "change->alert-rule-form#metricChanged" }) do
      metric_options.each do |value, label|
        option(value: value, selected: (@rule.metric_kind == value) || nil) { label }
      end
    end
  end

  def metric_options
    [
      ["cpu",    "CPU usage (%)"],
      ["memory", "Memory usage (%)"],
      ["disk",   "Disk usage (%)"],
      ["req_s",  "Requests per second"]
    ]
  end

  def target_select
    select_input(name: "alert_rule[target]", data: { alert_rule_form_target: "target" }) do
      option(
        value:    "host",
        selected: @rule.host_target? || nil,
        data:     { kind: "host" }
      ) { "Host (entire server)" }

      grouped_targets.each do |scope, entries|
        optgroup(label: scope) do
          entries.each do |entry|
            value = encode_target(entry[:scope], entry[:name])
            option(
              value:    value,
              selected: (current_target_value == value) || nil,
              data:     { kind: entry[:kind] }
            ) { entry[:name] }
          end
        end
      end

      orphaned_target_option
    end
  end

  # An edited rule may point at a workload that has since left the
  # snapshot (scaled away, renamed). Keep it selectable — silently
  # retargeting the rule on edit would be worse than showing the
  # truth — but label it as gone.
  def orphaned_target_option
    return if @rule.host_target?
    return if current_target_value.blank?
    return if @targets.any? { |t| encode_target(t[:scope], t[:name]) == current_target_value }

    option(value: current_target_value, selected: true, data: { kind: "deployment" }) do
      "#{@rule.target_scope}/#{@rule.target_name} (not running)"
    end
  end

  def grouped_targets
    @targets.group_by { |t| t[:scope] }.sort
  end

  def encode_target(scope, name)
    "pod|#{scope}|#{name}"
  end

  def current_target_value
    return "host" if @rule.host_target?
    return nil if @rule.target_scope.blank?

    encode_target(@rule.target_scope, @rule.target_name)
  end

  def target_error
    @rule.errors[:target_kind].first ||
      @rule.errors[:target_scope].first ||
      @rule.errors[:target_name].first
  end

  def condition_inputs
    div(class: "flex items-stretch gap-2") do
      div(class: "w-20 shrink-0") do
        select_input(name: "alert_rule[comparator]") do
          option(value: "gte", selected: (@rule.comparator != "lte") || nil) { "≥" }
          option(value: "lte", selected: (@rule.comparator == "lte") || nil) { "≤" }
        end
      end

      div(class: "relative flex-1") do
        input(
          type: "number", name: "alert_rule[threshold]", value: threshold_value,
          step: "0.1", min: "0.1", inputmode: "decimal",
          class: tokens(input_classes, "pr-14 font-voodu-mono text-[12.5px]")
        )
        span(
          class: "absolute right-3 top-1/2 -translate-y-1/2 text-[11px] text-voodu-muted pointer-events-none",
          data:  { alert_rule_form_target: "unit" }
        ) { @rule.unit }
      end
    end
  end

  def threshold_value
    return nil if @rule.threshold.nil?

    @rule.threshold % 1 == 0 ? @rule.threshold.to_i : @rule.threshold
  end

  def duration_select
    select_input(name: "alert_rule[duration_seconds]") do
      AlertRule::DURATIONS.each do |secs|
        option(value: secs, selected: (@rule.duration_seconds == secs) || nil) do
          secs >= 60 ? "#{secs / 60} minute#{secs >= 120 ? 's' : ''}" : "#{secs} seconds"
        end
      end
    end
  end

  # ---- shared field plumbing (same look as Views::Islands::New) ----

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

  def text_input(name:, value: nil, placeholder: nil)
    input(
      type: "text", name: name, value: value, placeholder: placeholder,
      autocomplete: "off",
      class: tokens(input_classes, "text-[13px]")
    )
  end

  def select_input(name:, extra_class: nil, data: nil)
    select(
      name:  name,
      data:  data,
      class: tokens(input_classes, "text-[13px] appearance-none cursor-pointer", extra_class)
    ) { yield }
  end

  def input_classes
    "w-full px-3 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none " \
      "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line placeholder:text-voodu-muted-2"
  end

  def footer_actions
    span(class: "text-[11.5px] text-voodu-muted hidden vmd:inline") do
      plain "Evaluated every 30s against the local warehouse."
    end

    div(class: "flex-1")

    a(
      href: alerts_path,
      class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { "Cancel" }

    button(
      type: "submit",
      form: "alert-rule-form",
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12.5px] font-medium hover:bg-voodu-accent-2"
    ) do
      render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
      span { persisted? ? "Save changes" : "Create rule" }
    end
  end
end
