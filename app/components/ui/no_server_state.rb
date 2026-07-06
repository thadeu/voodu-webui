# frozen_string_literal: true

# Components::UI::NoServerState — drop-in empty state shown by every
# operational screen (Pods / Logs / Metrics) when there's no server
# registered yet OR the operator hasn't selected one.
#
# Single source of truth for the "add an server first" message — so
# the wording stays consistent across screens.
class Components::UI::NoServerState < Components::Base
  def view_template
    div(class: "mx-auto max-w-md py-16 flex flex-col items-center gap-3 text-center") do
      div(class: "h-10 w-10 rounded-voodu-md bg-voodu-accent-dim", aria: {hidden: "true"})
      h2(class: "text-lg font-semibold text-voodu-text") { "No server selected" }
      p(class: "text-voodu-text-2 text-sm") do
        "Register a voodu controller to start monitoring its pods, " \
        "metrics, and logs."
      end
      div(class: "pt-2") do
        render(Components::UI::Button.new(tag: :a, variant: :primary, href: new_server_path)) { "Add server" }
      end
    end
  end
end
