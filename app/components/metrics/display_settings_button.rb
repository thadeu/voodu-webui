# frozen_string_literal: true

# Components::Metrics::DisplaySettingsButton — toolbar icon button
# that opens the "Settings" Drawer on /metrics.
#
# The drawer lets the operator toggle which chart cards are visible.
# Settings are persisted in sessionStorage keyed by kind — toggling
# on a deployment scope never bleeds into host or statefulset views.
# Title is "Settings" (not "Display settings") because other
# page-level settings may live here in the future.
#
# Usage:
#
#   render Components::Metrics::DisplaySettingsButton.new(
#     kind:                 @data.display_kind,
#     scope_kind:           @data.scope_kind,
#     display_settings_url: metrics_display_settings_path
#   )
class Components::Metrics::DisplaySettingsButton < Components::Base
  def initialize(kind:, scope_kind:, display_settings_url:, dashboard_id: nil)
    @kind                 = kind
    @scope_kind           = scope_kind
    @display_settings_url = display_settings_url
    @dashboard_id         = dashboard_id
  end

  def view_template
    src = "#{@display_settings_url}?kind=#{@kind}&scope_kind=#{@scope_kind}"
    # In dashboard mode the drawer lists the active dashboard's panels
    # (instead of the scope's fixed metric set) — the endpoint keys off
    # this param.
    src += "&pid=#{@dashboard_id}" if @dashboard_id

    render(Components::UI::Drawer.new(
      title:               "Settings",
      src:                 src,
      open_url:            src,
      width:               "30vw",
      min_width:           "280px",
      resizable:           true,
      show_full_page_link: false,
      # Dedicated storage key — settings drawer is compact card grid,
      # shouldn't inherit the wide width an operator set for the Logs
      # or Pod content drawers.
      storage_key:         "voodu:drawer-width:metrics-settings",
      trigger_attrs: {
        title:        "Settings",
        "aria-label": "Settings",
        class:        btn_class
      }
    )) do
      render Icon::AdjustmentsHorizontalOutline.new(class: "w-3.5 h-3.5")
    end
  end

  private

  def btn_class
    "inline-flex items-center justify-center w-9 h-9 " \
      "border border-voodu-border bg-voodu-surface " \
      "text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 " \
      "transition-colors"
  end
end
