# frozen_string_literal: true

# Components::Form::Input — single-line text input.
#
# Dark fill, voodu-border default, focus ring uses the accent purple
# at low alpha. `mono: true` flips to Geist Mono for code/token fields
# (URLs, PATs, IDs).
class Components::Form::Input < Components::Base
  def initialize(mono: false, error: false, **attrs)
    @mono  = mono
    @error = error
    @attrs = attrs
  end

  def view_template
    input(
      class: tokens(
        "w-full px-3 py-2 text-sm text-voodu-text rounded-voodu-md border transition-colors",
        "bg-voodu-bg-2 placeholder:text-voodu-muted-2",
        "focus:outline-none focus:ring-2 focus:ring-voodu-accent-line focus:border-voodu-accent",
        @error ? "border-voodu-red bg-voodu-red-dim" : "border-voodu-border",
        ("font-voodu-mono text-xs" if @mono),
        @attrs[:class]
      ),
      **@attrs.except(:class)
    )
  end
end
