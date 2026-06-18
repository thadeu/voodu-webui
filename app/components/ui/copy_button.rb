# frozen_string_literal: true

# Components::UI::CopyButton — 22×22 square button that copies a value
# to the clipboard. Bound to the `clipboard` Stimulus controller:
# click flips the icon to a check for 1.2s, then resets.
#
# Use inline next to long opaque values (container ids, hashes, env
# var values). The button itself stays unobtrusive (muted color) until
# hover.
class Components::UI::CopyButton < Components::Base
  def initialize(value:, label: "Copy")
    @value = value.to_s
    @label = label
  end

  def view_template
    button(
      type: "button",
      class: "w-[22px] h-[22px] inline-flex items-center justify-center border border-voodu-border bg-voodu-surface-2 text-voodu-muted hover:text-voodu-text-2 transition-colors shrink-0",
      data: {
        controller: "clipboard",
        clipboard_value_value: @value,
        action: "click->clipboard#copy"
      },
      aria: {label: "#{@label}: #{@value}"},
      title: @label
    ) do
      # Default icon — flipped to check by JS when copy succeeds.
      span(data: {clipboard_target: "idle"}) do
        render Icon::DocumentDuplicateOutline.new(class: "w-3 h-3")
      end
      span(data: {clipboard_target: "done"}, hidden: true) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5 text-voodu-green")
      end
    end
  end
end
