# frozen_string_literal: true

# Views::AlertRules::Form — the New/Edit alert rule modal, rendered
# over the dashboard chrome (same shell as Views::Servers::New).
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
  def initialize(current_path:, rule:, targets: [], servers: [], destinations: [], current_server: nil, return_to: nil)
    @current_path = current_path
    @current_server = current_server
    @rule = rule
    @targets = targets
    # servers — the org's servers (M3): feeds BOTH the layout sidebar list and
    # the Target select (a Host per server + that server's pods). A rule targets
    # exactly one (server, host|pod). (Pre-rename this was two params — servers
    # for the layout + servers for the picker — but they carry the same data.)
    @servers = servers
    @destinations = destinations
    # return_to — the path cancel/close/save go back to (a full route, already
    # validated by the controller). Carried through the form as a hidden field so
    # the POST preserves it. Defaults to /alerts when the caller had no origin.
    @return_to = return_to || alerts_path
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, current_server: @current_server,
      breadcrumb: overview_crumbs({label: "Alerts"})
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
      title: persisted? ? "Edit alert rule" : "New alert rule",
      subtitle: "Fires when the metric holds past the threshold for the whole window",
      icon: :BellOutline,
      size: :md,
      close_to: @return_to
    ).with_footer { footer_actions }
  end

  def form_body
    form(
      action: persisted? ? alert_rule_path(@rule) : alert_rules_path,
      method: "post",
      data: {turbo: false, controller: "alert-rule-form"},
      id: "alert-rule-form",
      class: "flex flex-col gap-4 px-5 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if persisted?
      input(type: "hidden", name: "return_to", value: @return_to)

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
          hint: "Direction + threshold the metric is compared against.",
          error: @rule.errors[:threshold].first
        ) do
          condition_inputs
        end

        field(
          label: "Sustained for",
          hint: "Every sample in this window must breach before it fires.",
          error: @rule.errors[:duration_seconds].first
        ) do
          duration_select
        end
      end

      destinations_field

      input(type: "submit", class: "hidden", "aria-hidden": "true")
    end
  end

  # Which destinations this rule notifies. Empty selection = DON'T SEND (the
  # honest default — the rule fires but notifies nowhere); "Select all" opts
  # into every destination. A DS multi-select dropdown backed by real checkboxes
  # (same submit shape as a plain checkbox group). When no destinations exist
  # yet, point the operator at the Destinations tab instead of an empty box.
  def destinations_field
    field(label: "Notify destinations", hint: "Leave empty to send nowhere; “Select all” notifies every destination.") do
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
    selected = @rule.alert_destination_ids & @destinations.map(&:id)

    div(class: "relative", data: {controller: "dropdown ds-multiselect", ds_multiselect_empty_label_value: "Don't send", ds_multiselect_all_label_value: "All destinations"}) do
      button(
        type: "button", data: {action: "click->dropdown#toggle"},
        class: tokens(input_classes, "flex items-center gap-2 text-[13px] cursor-pointer")
      ) do
        span(data: {ds_multiselect_target: "label"}, class: "flex-1 min-w-0 truncate text-left") { destinations_trigger_label(selected) }
        render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
      end

      div(hidden: true, data: {dropdown_target: "menu"}, class: target_menu_classes) do
        # Empty sentinel so an all-unchecked submit CLEARS the association (a
        # checkbox group with nothing checked otherwise omits the key entirely,
        # leaving it unchanged on update).
        input(type: "hidden", name: "alert_rule[alert_destination_ids][]", value: "")

        button(
          type: "button", data: {action: "ds-multiselect#toggleAll"},
          class: "flex items-center justify-between gap-2 w-full px-3 py-2 border-b border-voodu-border-2 text-left text-[11.5px] text-voodu-text-2 hover:bg-voodu-surface-2 sticky top-0 bg-voodu-surface"
        ) do
          span(class: "uppercase tracking-[0.05em] text-voodu-muted-2") { "Destinations" }
          span(data: {ds_multiselect_target: "selectAllLabel"}, class: "text-voodu-link") { "Select all" }
        end

        @destinations.each { |dest| destination_row(dest, selected.include?(dest.id)) }
      end
    end
  end

  # destinations_trigger_label — server-rendered so there's no flash before
  # ds-multiselect#connect recomputes it: "Don't send" (none picked = the
  # default, notifies nowhere), "All destinations" (every one picked), the
  # single name, or "N selected".
  def destinations_trigger_label(selected)
    return "Don't send" if selected.empty?
    return "All destinations" if selected.size == @destinations.size
    return @destinations.find { |d| d.id == selected.first }&.name.to_s if selected.size == 1

    "#{selected.size} selected"
  end

  def destination_row(dest, checked)
    label(class: "flex items-center gap-2.5 w-full px-3 py-2 cursor-pointer hover:bg-voodu-surface-2 " \
                 "text-[12.5px] text-voodu-text-2 border-b border-voodu-border-2 last:border-b-0") do
      input(
        type: "checkbox", name: "alert_rule[alert_destination_ids][]", value: dest.id, checked: checked,
        data: {ds_multiselect_target: "option", label: dest.name, action: "change->ds-multiselect#sync"},
        class: "w-3.5 h-3.5 accent-voodu-accent"
      )
      span(class: "truncate") { dest.name }
      span(class: "text-[10px] uppercase tracking-[0.05em] text-voodu-muted-2 ml-auto shrink-0") { dest.kind }
    end
  end

  def metric_select
    ds_select(
      name: "alert_rule[metric_kind]", selected: @rule.metric_kind, options: metric_options,
      # Metric drives the target constraint + unit — its pick dispatches change,
      # which alert-rule-form listens for on the hidden input.
      input_data: {alert_rule_form_target: "metric", action: "change->alert-rule-form#metricChanged"}
    )
  end

  def metric_options
    [
      ["cpu", "CPU usage (%)"],
      ["memory", "Memory usage (%)"],
      ["disk", "Disk usage (%)"],
      ["req_s", "Requests per second"]
    ]
  end

  # target_select — the DS custom dropdown (trigger + hidden input + filterable
  # menu), NOT a native <select>. One flat, server-prefixed list of targets
  # across the org (M3): a Host per server + that server's pods. The hidden
  # input carries the encoded value (`host|<server_id>` / `pod|<id>|<scope>|
  # <name>`); alert_rule_form#pickTarget syncs it + the trigger label + the
  # metric↔kind constraint. Org-wide pod lists get an in-menu search box.
  def target_select
    rows = target_rows

    div(class: "relative", data: {controller: "dropdown"}) do
      input(type: "hidden", name: "alert_rule[target]", value: current_target_value,
        data: {alert_rule_form_target: "target"})

      button(
        type: "button", data: {action: "click->dropdown#toggle"},
        class: tokens(input_classes, "flex items-center gap-2 text-[13px] cursor-pointer")
      ) do
        span(data: {alert_rule_form_target: "targetLabel"}, class: "flex-1 min-w-0 truncate text-left") { current_target_label(rows) }
        render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
      end

      div(hidden: true, data: {dropdown_target: "menu"}, class: target_menu_classes) do
        dropdown_filter("Filter servers + pods…") if rows.size > 6
        rows.each { |row| target_option(row) }
        dropdown_empty
      end
    end
  end

  # target_rows — flat [{value, kind, label}] across the org: a Host per server
  # + its pods, each label server-prefixed when the org has >1 server (matches
  # the metrics builder). A gone-but-saved target (edited rule) is appended.
  def target_rows
    @target_rows ||= begin
      rows = servers_for_select.flat_map do |server|
        host = {value: "host|#{server.id}", kind: "host", label: target_label_for(server, "Host (entire server)")}
        pods = targets_for(server).map do |t|
          {value: encode_target(t[:server_id], t[:scope], t[:name]), kind: t[:kind],
           label: target_label_for(server, "#{t[:scope]}/#{t[:name]}")}
        end
        [host, *pods]
      end
      orphan = orphaned_target_row
      orphan ? rows + [orphan] : rows
    end
  end

  def multi_server?
    servers_for_select.size > 1
  end

  def target_label_for(server, base)
    multi_server? ? "#{server.name} · #{base}" : base
  end

  # target_option — a menu row. data-value/kind feed pickTarget + the metric↔kind
  # constraint; data-dropdown-target="option" makes it filterable; data-active
  # rings the current pick, data-disabled dims an incompatible kind.
  def target_option(row)
    active = row[:value] == current_target_value

    button(
      type: "button",
      data: {
        action: "click->alert-rule-form#pickTarget click->dropdown#close",
        dropdown_target: "option", alert_rule_form_target: "option",
        value: row[:value], kind: row[:kind], label: row[:label], active: active.to_s
      },
      class: "flex items-center gap-2 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] text-voodu-text " \
             "hover:bg-voodu-hover data-[active=true]:text-voodu-accent-2 " \
             "data-[disabled=true]:opacity-40 data-[disabled=true]:pointer-events-none"
    ) do
      span(class: "w-3.5 shrink-0 text-voodu-accent-2", data: {alert_rule_form_target: "optionCheck"}) { active ? "✓" : "" }
      span(class: "truncate") { row[:label] }
    end
  end

  # servers_for_select — the org's servers; falls back to the current server so
  # the menu is never empty (a lone-server org / pre-servers state).
  def servers_for_select
    @servers.presence || [@current_server].compact
  end

  # targets_for — a server's pod targets (workloads), sorted by scope+name.
  def targets_for(server)
    @targets.select { |t| t[:server_id] == server.id }.sort_by { |t| [t[:scope], t[:name]] }
  end

  # An edited rule may point at a workload that has since left the snapshot
  # (scaled away, renamed). Keep it selectable — silently retargeting the rule on
  # edit would be worse than showing the truth — but label it as gone.
  def orphaned_target_row
    return if @rule.host_target?
    return if current_target_value.blank?
    return if @targets.any? { |t| encode_target(t[:server_id], t[:scope], t[:name]) == current_target_value }

    {value: current_target_value, kind: "deployment", label: "#{@rule.target_scope}/#{@rule.target_name} (not running)"}
  end

  def current_target_label(rows)
    rows.find { |r| r[:value] == current_target_value }&.dig(:label) || "Select a target"
  end

  def target_menu_classes
    "absolute left-0 top-[calc(100%+4px)] z-30 min-w-full w-max max-w-[320px] max-h-[300px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
  end

  # dropdown_filter / dropdown_empty — the shared in-menu search box (sticky top)
  # + "no matches" row the dropdown controller drives (same as the metrics
  # builder's source pickers).
  def dropdown_filter(placeholder)
    div(class: "sticky top-0 z-10 bg-voodu-surface border-b border-voodu-border-2 p-1.5") do
      input(
        type: "text", placeholder: placeholder, autocomplete: "off", spellcheck: "false",
        data: {dropdown_target: "filter", action: "input->dropdown#filterInput keydown->dropdown#onFilterKey"},
        class: "w-full h-8 px-2.5 bg-voodu-surface-2 border border-voodu-border text-voodu-text text-[12px] " \
               "placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
    end
  end

  def dropdown_empty
    div(hidden: true, data: {dropdown_target: "empty"}, class: "px-3 py-3 text-[12px] text-voodu-muted text-center") { "No matches" }
  end

  def encode_target(server_id, scope, name)
    "pod|#{server_id}|#{scope}|#{name}"
  end

  def current_target_value
    return "host|#{@rule.server_id}" if @rule.host_target?
    return nil if @rule.target_scope.blank?

    encode_target(@rule.server_id, @rule.target_scope, @rule.target_name)
  end

  def target_error
    @rule.errors[:target_kind].first ||
      @rule.errors[:target_scope].first ||
      @rule.errors[:target_name].first
  end

  def condition_inputs
    div(class: "flex items-stretch gap-2") do
      div(class: "w-20 shrink-0") do
        ds_select(
          name: "alert_rule[comparator]",
          selected: (@rule.comparator == "lte") ? "lte" : "gte",
          options: [["gte", "≥"], ["lte", "≤"]]
        )
      end

      div(class: "relative flex-1") do
        input(
          type: "number", name: "alert_rule[threshold]", value: threshold_value,
          step: "0.1", min: "0.1", inputmode: "decimal",
          class: tokens(input_classes, "pr-14 font-voodu-mono text-[12.5px]")
        )
        span(
          class: "absolute right-3 top-1/2 -translate-y-1/2 text-[11px] text-voodu-muted pointer-events-none",
          data: {alert_rule_form_target: "unit"}
        ) { @rule.unit }
      end
    end
  end

  def threshold_value
    return nil if @rule.threshold.nil?

    (@rule.threshold % 1 == 0) ? @rule.threshold.to_i : @rule.threshold
  end

  def duration_select
    ds_select(
      name: "alert_rule[duration_seconds]",
      selected: @rule.duration_seconds,
      options: AlertRule::DURATIONS.map { |secs| [secs, duration_option_label(secs)] }
    )
  end

  def duration_option_label(secs)
    (secs >= 60) ? "#{secs / 60} minute#{"s" if secs >= 120}" : "#{secs} seconds"
  end

  # ds_select — a DS single-select dropdown (trigger + hidden input + menu),
  # replacing a native <select> so every picker in the form matches the design
  # system. `dropdown` handles open/close (+ the shared filter once options pass
  # the threshold); `ds-select` syncs the pick → hidden input + label + ✓ and
  # dispatches `change` (so metric's constraint hook still fires). `selected` is
  # compared to each option value with `==`, so integer values (durations) work.
  def ds_select(name:, selected:, options:, input_data: {})
    current = options.find { |value, _| value == selected }

    div(class: "relative", data: {controller: "dropdown ds-select"}) do
      input(type: "hidden", name: name, value: selected, data: {ds_select_target: "input"}.merge(input_data))

      button(
        type: "button", data: {action: "click->dropdown#toggle"},
        class: tokens(input_classes, "flex items-center gap-2 text-[13px] cursor-pointer")
      ) do
        span(data: {ds_select_target: "label"}, class: "flex-1 min-w-0 truncate text-left") { current ? current[1] : "Select…" }
        render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
      end

      div(hidden: true, data: {dropdown_target: "menu"}, class: target_menu_classes) do
        dropdown_filter("Filter…") if options.size > 6
        options.each { |value, text| ds_option(value, text, value == selected) }
        dropdown_empty if options.size > 6
      end
    end
  end

  def ds_option(value, text, active)
    button(
      type: "button",
      data: {
        action: "click->ds-select#pick click->dropdown#close",
        dropdown_target: "option", ds_select_target: "option",
        value: value, label: text, active: active.to_s
      },
      class: "group flex items-center gap-2 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] " \
             "text-voodu-text hover:bg-voodu-hover data-[active=true]:text-voodu-accent-2"
    ) do
      span(class: "w-3.5 shrink-0 text-voodu-accent-2 opacity-0 group-data-[active=true]:opacity-100") { "✓" }
      span(class: "truncate") { text }
    end
  end

  # field + input_classes live in Views::Base (shared by every modal form).

  def text_input(name:, value: nil, placeholder: nil)
    input(
      type: "text", name: name, value: value, placeholder: placeholder,
      autocomplete: "off",
      class: tokens(input_classes, "text-[13px]")
    )
  end

  def footer_actions
    span(class: "text-[11.5px] text-voodu-muted hidden vmd:inline") do
      plain "Evaluated every 30s against the local warehouse."
    end

    div(class: "flex-1")

    a(
      href: @return_to,
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
