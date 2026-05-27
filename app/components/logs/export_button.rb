# frozen_string_literal: true

# Components::Logs::ExportButton — toolbar button on the /logs page
# that opens the export drawer.
#
# Wraps Components::UI::Drawer with the right configuration:
#   - title: "Export logs"
#   - src: GET /exports/new (returns ExportDrawer body)
#   - width: 36vw default (form-heavy, narrower than logs drawer)
#   - max_width: 60vw (operator can drag wider if needed)
#   - storage_key: dedicated so the operator's logs-drawer width
#     pref doesn't get inherited (form needs less width than logs)
#
# Carries the operator's `current_pod` through as a query param
# so the form pre-checks the right pod row in the picker.
class Components::Logs::ExportButton < Components::Base
  def initialize(current_pod: nil)
    @current_pod = current_pod
  end

  def view_template
    render(Components::UI::Drawer.new(
      title:               "Export logs",
      src:                 drawer_src,
      open_url:            drawer_src,
      width:               "36vw",
      max_width:           "60vw",
      show_full_page_link: false,
      storage_key:         "voodu:drawer-width:export",
      trigger_attrs: {
        class: "inline-flex items-center gap-1.5 px-3 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      }
    )) do
      render Icon::ArrowDownTrayOutline.new(class: "w-3.5 h-3.5")
      span { "Export" }
    end
  end

  private

  def drawer_src
    params = { embed: 1 }
    params[:pod] = @current_pod if @current_pod.present?
    "#{new_export_path}?#{params.to_query}"
  end
end
