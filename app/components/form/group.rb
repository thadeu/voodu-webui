# frozen_string_literal: true

# Components::Form::Group — label + control + hint wrapper.
#
# Encapsulates the vertical stack so callers don't repeat the gap +
# label classes on every field. Hint is rendered below in muted text;
# error messages should use Components::UI::Badge variant: :danger
# slotted inside the body.
class Components::Form::Group < Components::Base
  def initialize(label: nil, hint: nil)
    @label = label
    @hint = hint
  end

  def view_template(&)
    div(class: "flex flex-col gap-1.5") do
      label(class: "text-sm font-medium text-voodu-text") { @label } if @label
      yield if block_given?
      p(class: "text-xs text-voodu-muted") { @hint } if @hint
    end
  end
end
