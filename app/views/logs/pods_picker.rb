# frozen_string_literal: true

# Views::Logs::PodsPicker — drawer body for the multi-select pods
# picker on /logs.
#
# Rendered when the operator clicks the "N pods" trigger in the
# logs page header. Lists one card per UNIQUE RESOURCE_NAME (not
# per replica) grouped by scope — selecting "controller" picks
# every replica of controller automatically. Same operator mental
# model as the metrics scope picker but with a checkbox per row
# instead of single-select navigation.
#
# State machinery (all client-side):
#   - localStorage key  `voodu:logs-pods:v1:<server_key>` →
#                       JSON array of resource_names (empty = all)
#   - Stimulus ctrl     `logs-pods-selector` (drawer body root)
#                       — loads selection, toggles checkboxes,
#                       dispatches `logs-pods:changed` DOM event
#                       on the window when operator hits Update.
#   - log-stream ctrl   listens for the event + reapplies its
#                       row visibility filter
#
# No POST endpoint. The drawer is purely a UI surface; persistence
# is localStorage so it survives navigation but doesn't burden the
# Settings table with per-server junk that's better treated as
# ephemeral display state.
class Views::Logs::PodsPicker < Views::Base
  def initialize(server_key:, pods: [])
    @server_key = server_key
    @pods = Array(pods)
  end

  def view_template
    # @container marks the root as a container-query context so the
    # cards grid responds to DRAWER width (operator-resizable, 300px–
    # ~50vw) instead of the viewport. Cards reflow:
    #   <  380px  → 1 column   (narrow drawer)
    #   ≥ 380px  → 2 columns   (default ~32vw on desktop)
    #   ≥ 620px  → 3 columns   (operator dragged the drawer wide)
    div(
      class: "p-4 flex flex-col gap-3.5 @container",
      data: {
        controller: "logs-pods-selector",
        logs_pods_selector_storage_key_value: "voodu:logs-pods:v1:#{@server_key}"
      }
    ) do
      header_row
      hint_row
      bulk_actions
      groups
    end
  end

  private

  def header_row
    div(class: "flex items-center gap-2.5") do
      span(
        class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted shrink-0"
      ) { "Pods" }
      span(class: "flex-1 h-px bg-voodu-border")
      span(
        class: "text-[11px] font-voodu-mono text-voodu-text-2",
        data: {logs_pods_selector_target: "counter"}
      ) { "" }
    end
  end

  def hint_row
    p(class: "text-[11px] text-voodu-muted-2 leading-relaxed") do
      plain "Pick which pods stream into the live tail. Selecting a "
      span(class: "text-voodu-text-2") { "name" }
      plain " includes all of its replicas. Leave everything checked for the "
      span(class: "text-voodu-text-2") { "all pods" }
      plain " default."
    end
  end

  def bulk_actions
    div(class: "flex items-center gap-2") do
      bulk_button("Select all", action: "selectAll")
      bulk_button("Clear", action: "clearAll")
      div(class: "flex-1")
      span(
        class: "text-[11px] text-voodu-muted-2",
        data: {logs_pods_selector_target: "dirtyHint"}
      ) { "" }
    end
  end

  def bulk_button(label, action:)
    button(
      type: "button",
      data: {action: "click->logs-pods-selector##{action}"},
      class: "inline-flex items-center px-2.5 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11.5px] hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { label }
  end

  # groups — one section per scope, each with a checkbox row per
  # unique resource_name in that scope. Sorting:
  #   - scopes: alpha
  #   - resource_names within a scope: alpha
  # Stable order so operators get the same layout between visits.
  def groups
    grouped = group_by_scope(@pods)
    return empty_state if grouped.empty?

    div(class: "flex flex-col gap-3") do
      grouped.each do |scope_name, resources|
        section(scope_name, resources)
      end
    end
  end

  def section(scope_name, resources)
    div(class: "flex flex-col gap-2") do
      div(
        class: "px-1 py-0.5 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted"
      ) { scope_name }

      # Container-query grid: 1 col on narrow drawer (<380px),
      # 2 on default 32vw, 3 if operator drags wider. `gap-2` keeps
      # the cards close enough to read as a grid + breathing-room
      # enough to click each checkbox independently.
      div(class: "grid grid-cols-1 @[380px]:grid-cols-2 @[620px]:grid-cols-3 gap-2") do
        resources.each { |r| pod_card(r) }
      end
    end
  end

  # pod_card — compact card with checkbox + name + meta. Tightened
  # from a full-width row to a square-ish tile so the operator can
  # scan many pods at once. Active state (default: checked) gets a
  # subtle accent border-left + bg tint to signal "this one
  # streams into the tail."
  #
  # data-resource-name is the identity key used by the Stimulus
  # controller; data-containers carries the comma-separated full
  # container names so the log-stream filter (which sees container-
  # level [pod-name] prefixes) can resolve "is this row from a
  # selected resource?" without a second lookup.
  def pod_card(resource)
    label(
      class: "group flex items-start gap-2 p-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[12px] cursor-pointer hover:bg-voodu-surface-2 hover:border-voodu-border-2 transition-colors min-w-0"
    ) do
      input(
        type: "checkbox",
        checked: true,
        data: {
          logs_pods_selector_target: "toggle",
          action: "change->logs-pods-selector#onToggle",
          resource_name: resource[:resource_name],
          scope: resource[:scope],
          containers: resource[:containers].join(",")
        },
        class: "accent-voodu-accent shrink-0 mt-0.5"
      )
      div(class: "min-w-0 flex flex-col flex-1") do
        span(class: "font-voodu-mono text-voodu-text truncate text-[12.5px] font-medium") { resource[:resource_name] }
        span(class: "text-[10.5px] text-voodu-muted font-voodu-mono truncate") do
          plain replica_summary(resource[:containers])
        end
        if resource[:image].present?
          span(class: "text-[10px] text-voodu-muted-2 font-voodu-mono truncate") { resource[:image] }
        end
      end
    end
  end

  def replica_summary(containers)
    n = containers.size
    (n == 1) ? "1 replica" : "#{n} replicas"
  end

  def empty_state
    div(class: "p-4 text-center text-voodu-muted text-[12px]") do
      "No pods reported by this server."
    end
  end

  # group_by_scope — collapse the compact pod list (which has one
  # entry per replica) into a per-scope hash of unique resource
  # entries. Each entry carries its container_name list so the JS
  # filter can resolve resource_name → container_name set at filter
  # time without re-querying.
  def group_by_scope(pods)
    by_scope = {}

    pods.each do |p|
      scope = (p[:scope] || p["scope"] || "(default)").to_s
      resource = (p[:resource_name] || p["resource_name"]).to_s
      next if resource.empty?

      container = (p[:name] || p["name"]).to_s
      image = (p[:image] || p["image"]).to_s

      by_scope[scope] ||= {}
      key = resource
      by_scope[scope][key] ||= {resource_name: resource, scope: scope, image: image, containers: []}
      by_scope[scope][key][:containers] << container if container.present?
    end

    by_scope
      .sort_by { |scope, _| scope }
      .map { |scope, by_resource| [scope, by_resource.values.sort_by { |r| r[:resource_name] }] }
  end
end
