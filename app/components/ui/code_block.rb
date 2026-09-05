# frozen_string_literal: true

# Components::UI::CodeBlock — a `<pre>` with a copy button that surfaces on
# hover.
#
# The content comes from the block, so a caller can hand it plain text or
# highlighted spans; this owns the container, the scrolling and the button.
#
# THE BUTTON IS OVER THE BLOCK AND APPEARS ON HOVER. Always visible puts a
# control on top of the first line of every block on the page; hidden entirely
# is a feature nobody finds. `focus-within` keeps it reachable by keyboard,
# where "hover" does not exist.
#
# `copy_value` is passed separately rather than read from the rendered markup,
# and that is the point: what you copy is the SOURCE, not what is on screen.
# The screen may be highlighted, truncated, or wrapped — the clipboard gets the
# bytes.
class Components::UI::CodeBlock < Components::Base
  # Tall blocks scroll rather than growing. A webhook payload is a few hundred
  # lines, and a card that runs three screens pushes everything after it off
  # the page.
  def initialize(copy_value:, label: "Copy", max_height: nil)
    @copy_value = copy_value
    @label = label
    @max_height = max_height
  end

  def view_template(&block)
    div(class: "relative group") do
      copy_button

      pre(class: tokens(
        "m-0 p-3 overflow-x-auto font-voodu-mono text-[12px] leading-[1.6] text-voodu-text-2",
        @max_height && "#{@max_height} overflow-y-auto"
      )) do
        code(&block)
      end
    end
  end

  private

  def copy_button
    div(class: "absolute top-1.5 right-1.5 z-10 opacity-0 group-hover:opacity-100 " \
               "focus-within:opacity-100 transition-opacity") do
      render Components::UI::CopyButton.new(
        value: @copy_value, label: @label, announce_value: false
      )
    end
  end
end
