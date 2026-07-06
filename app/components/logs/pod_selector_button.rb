# frozen_string_literal: true

# Components::Logs::PodSelectorButton — multi-select pod filter for
# /logs.
#
# Replaces the older Components::Logs::PodPicker dropdown (single-
# select navigation to /logs/:name). Operator now toggles which
# resource_names stream into the live tail via a drawer of
# checkboxes; selection persists in localStorage per server and
# the log-stream controller filters rows accordingly.
#
# Trigger button:
#   - icon + "all pods" / "N pods" label
#   - same h-9 height + min-w-180 as the original ScopePicker
#     trigger so the toolbar rhythm stays consistent
#   - opens the right-side drawer fetching /logs/pods_picker
class Components::Logs::PodSelectorButton < Components::Base
  def initialize(pods: [])
    @pods = Array(pods)
  end

  def view_template
    render(Components::UI::Drawer.new(
      title: "Pods",
      src: pods_picker_logs_path,
      open_url: pods_picker_logs_path,
      width: "32vw",
      min_width: "300px",
      resizable: true,
      show_full_page_link: false,
      storage_key: "voodu:drawer-width:logs-pods",
      trigger_attrs: {
        title: "Pick which pods stream into the live tail",
        "aria-label": "Pick visible pods",
        class: trigger_classes
      }
    )) do
      render Icon::Squares2x2Outline.new(class: "w-3 h-3")
      span(class: "min-w-0 truncate font-voodu-mono text-voodu-text") { label }
      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  private

  def trigger_classes
    "inline-flex items-center gap-2 px-2.5 h-9 min-w-[180px] " \
      "border border-voodu-border bg-voodu-surface text-voodu-text " \
      "text-[12.5px] hover:bg-voodu-surface-2"
  end

  # label — the trigger's visible label. We can't read localStorage
  # server-side so the initial paint always shows "all pods". Once
  # the page hydrates, the operator's saved selection takes effect
  # on the stream filter; the trigger label stays "all pods" until
  # the operator opens the drawer again. Acceptable trade-off
  # vs. hydrating the label via JS just to keep it accurate at
  # rest — the actual filter behaviour IS accurate.
  def label
    n = unique_resource_names.size
    n.zero? ? "no pods" : "all pods"
  end

  def unique_resource_names
    @pods.filter_map { |p| (p[:resource_name] || p["resource_name"]).to_s.presence }.uniq
  end
end
