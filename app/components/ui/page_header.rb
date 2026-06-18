# frozen_string_literal: true

# Components::UI::PageHeader — shared header pattern for every
# operational page (Metrics, Logs, future Alerts, etc.). Two-column
# flex with the title block on the left + actions cluster on the
# right; both sides wrap when the viewport's tight.
#
# Layout:
#
#   ┌──────────────────────────────────────────────────────────────┐
#   │ Title                                  [action] [action] ... │
#   │ subtitle text · meta · meta                                  │
#   └──────────────────────────────────────────────────────────────┘
#
# Slots:
#
#   .with_subtitle { ... }  — block rendered under the H1
#   .with_actions  { ... }  — block rendered in the right-side cluster
#
# Both are optional. With neither, the component degrades to a
# bare H1 — useful as a placeholder for pages still under construction.
#
# Usage
#
#   render(
#     Components::UI::PageHeader.new(title: "Metrics")
#       .with_subtitle { page_sub }
#       .with_actions do
#         pod_actions if pod_scope?
#         refresh_btn
#       end
#   )
class Components::UI::PageHeader < Components::Base
  def initialize(title:)
    @title = title
    @subtitle_block = nil
    @actions_block = nil
  end

  def with_subtitle(&block)
    @subtitle_block = block
    self
  end

  def with_actions(&block)
    @actions_block = block
    self
  end

  def view_template
    div(class: "flex flex-wrap items-end justify-between gap-3 vmd:gap-4") do
      div(class: "min-w-0") do
        h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") { @title }
        @subtitle_block&.call
      end

      if @actions_block
        div(class: "flex items-center gap-2 shrink-0 flex-wrap") do
          @actions_block.call
        end
      end
    end
  end
end
