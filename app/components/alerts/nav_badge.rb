# frozen_string_literal: true

# Components::Alerts::NavBadge — the red firing-count bubble on the
# sidebar's Alerts nav item, extracted into a component so the
# evaluator can broadcast a re-render into the id-bearing wrappers
# without rebuilding the whole sidebar.
#
# Two variants because the sidebar renders the count twice:
#
#   :dot  — tiny bubble pinned top-right of the bell icon; only
#           visible when the sidebar is collapsed.
#   :pill — inline right-aligned pill next to the label; hidden
#           when collapsed (the dot takes over).
#
# Renders NOTHING at count 0 — a Turbo `update` with this empty body
# is exactly how a resolved last-alert clears the badge.
class Components::Alerts::NavBadge < Components::Base
  def initialize(count:, variant: :pill)
    @count   = count.to_i
    @variant = variant
  end

  def view_template
    return unless @count.positive?

    if @variant == :dot
      span(
        class: "hidden vmd:group-data-[collapsed]:inline-flex absolute -top-1 -right-1 " \
               "items-center justify-center min-w-[12px] h-[12px] px-1 text-[9px] " \
               "font-medium font-voodu-mono bg-voodu-red-dim text-voodu-red " \
               "rounded-full leading-none",
        aria:  { label: "#{@count} alerts firing" }
      ) { @count.to_s }
    else
      span(
        class: "inline-flex items-center justify-center min-w-[18px] h-[18px] px-1.5 " \
               "text-[10px] font-medium font-voodu-mono bg-voodu-red-dim text-voodu-red"
      ) { @count.to_s }
    end
  end
end
