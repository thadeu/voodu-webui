# frozen_string_literal: true

# Components::UI::Kbd — monospace keyboard-shortcut chip.
#
# Sized 16×18 to sit inline with 13px body text without overflowing
# the line-height. Used in the topbar search ("⌘ K") and in shortcut
# hints around the UI.
class Components::UI::Kbd < Components::Base
  def initialize(**attrs)
    @attrs = attrs
  end

  def view_template(&)
    kbd(
      class: tokens(
        "inline-flex items-center justify-center font-voodu-mono",
        "px-1.5 min-w-[16px] h-[18px] text-[10.5px] font-medium",
        "bg-voodu-surface-3 text-voodu-text-2 border border-voodu-border",
        @attrs[:class]
      ),
      style: "box-shadow: 0 1px 0 rgba(0,0,0,0.5);",
      **@attrs.except(:class)
    ) { yield if block_given? }
  end
end
