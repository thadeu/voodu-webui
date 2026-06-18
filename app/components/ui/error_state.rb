# frozen_string_literal: true

# Components::UI::ErrorState — the screen-level "something went wrong
# talking to the controller" panel. Used by every operational screen
# when Voodu::Client raises (timeout, auth, controller 5xx).
#
# Surfaces the error class + message verbatim so the operator gets
# enough info to act (rotate PAT, check the controller, etc.) without
# making them read logs.
class Components::UI::ErrorState < Components::Base
  def initialize(error:)
    @error = error
  end

  def view_template
    div(class: "mx-auto max-w-md py-16 flex flex-col items-center gap-3 text-center") do
      div(class: "h-10 w-10 rounded-voodu-md bg-voodu-red-dim", aria: {hidden: "true"})
      h2(class: "text-lg font-semibold text-voodu-text") { "Couldn't reach the controller" }
      p(class: "text-voodu-text-2 text-sm") { @error.class.name.demodulize }
      p(class: "font-voodu-mono text-xs text-voodu-muted") { @error.message }
    end
  end
end
