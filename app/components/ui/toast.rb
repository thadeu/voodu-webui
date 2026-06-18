# frozen_string_literal: true

# Components::UI::Toast — single floating notification.
#
# Three variants map to Rails' flash keys: notice → success, alert →
# danger, anything else → neutral. Self-dismisses after 4s via
# toast_controller; clicking the × closes it immediately.
class Components::UI::Toast < Components::Base
  VARIANTS = {
    success: {bg: "bg-voodu-green-dim", border: "border-voodu-green/40", text: "text-voodu-green"},
    danger: {bg: "bg-voodu-red-dim", border: "border-voodu-red/40", text: "text-voodu-red"},
    info: {bg: "bg-voodu-accent-dim", border: "border-voodu-accent-line", text: "text-voodu-accent-2"},
    neutral: {bg: "bg-voodu-surface", border: "border-voodu-border", text: "text-voodu-text-2"}
  }.freeze

  def initialize(message:, variant: :info)
    @variant = variant
    @message = message
  end

  def view_template
    s = VARIANTS.fetch(@variant, VARIANTS[:neutral])

    div(
      class: tokens(
        "pointer-events-auto flex items-center gap-3 px-3 py-2 rounded-voodu-md border",
        "shadow-lg backdrop-blur",
        s[:bg], s[:border]
      ),
      data: {controller: "toast", toast_timeout_value: 4000},
      role: "status"
    ) do
      span(class: tokens("text-sm", s[:text])) { @message }
      button(
        type: "button",
        class: "ml-2 text-voodu-muted hover:text-voodu-text",
        data: {action: "click->toast#dismiss"},
        aria: {label: "Dismiss"}
      ) { plain "×" }
    end
  end
end
