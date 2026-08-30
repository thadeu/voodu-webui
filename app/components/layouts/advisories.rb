# frozen_string_literal: true

# PerimeterBanner — the one thing anonymous mode must never let you forget.
#
# With CLOWK_ENABLED off the app asks for no credentials on purpose: something
# in front of it authenticates. Whoever reaches the port is the operator, and
# the operator can reveal a PAT — which is the controller itself, not a chart.
# So if a request arrives from a public address, either the perimeter is missing
# or it forwards real client IPs, and the operator needs to know which.
#
# Deliberately NOT dismissable. A banner you can close is a banner that gets
# closed, and the condition it describes does not go away when you stop looking
# at it. The way to silence it is to fix the exposure, or to state that the
# perimeter is trusted (VOODU_TRUSTED_PERIMETER=1).
class Components::Layouts::PerimeterBanner < Components::Base
  def view_template
    return unless perimeter_warning?

    div(
      role: "alert",
      class: "flex flex-col vmd:flex-row vmd:items-center gap-1.5 vmd:gap-3 px-4 py-2.5 " \
             "border-b border-voodu-red/40 bg-voodu-red/10"
    ) do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::ExclamationTriangleOutline.new(class: "w-4 h-4 shrink-0 text-voodu-red")
        span(class: "text-[12.5px] font-semibold text-voodu-red shrink-0") { "No sign-in required" }
      end

      span(class: "text-[12px] text-voodu-text-2 min-w-0") do
        plain "This request came from a public address. Anyone who reaches this port is an " \
              "operator and can read every server's access token. Put a VPN or an access proxy " \
              "in front of it, or set "
        code(class: "font-voodu-mono text-[11.5px] text-voodu-text") { "VOODU_TRUSTED_PERIMETER=1" }
        plain " if one is already there."
      end
    end
  end
end
