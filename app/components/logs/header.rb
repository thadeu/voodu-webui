# frozen_string_literal: true

# Components::Logs::Header — the compact one-row header shared by both logs
# surfaces (Analytics search + Follow live tail). Collapses what used to be
# two stacked rows — a standalone ModeTabs strip ABOVE a tall PageHeader —
# into a single line: the "Logs" label sits inline with the Analytics/Follow
# switcher. So the tab strip stays put when the operator flips surfaces (no
# layout jump), and the reclaimed vertical space goes to the result rows.
#
# Slots (both optional):
#   .with_subtitle { ... } — a thin line under the row (Follow's live stats)
#   .with_actions  { ... } — right-aligned cluster (Follow's pod picker, etc.)
#
# tabs: false suppresses the switcher (drawer/embed mode — no room to flip
# surfaces there, and ModeTabs was already hidden in that case).
#
#   render Components::Logs::Header.new(active: :analytics)
class Components::Logs::Header < Components::Base
  def initialize(active:, tabs: true)
    @active = active
    @tabs = tabs
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
    div(class: "flex flex-col gap-1") do
      div(class: "flex flex-wrap items-center justify-between gap-x-4 gap-y-2") do
        title_cluster
        actions_cluster if @actions_block
      end

      @subtitle_block&.call
    end
  end

  private

  # title_cluster — "Logs" + the tab switcher, inline. The h1 matches the
  # 22px hero the shared PageHeader uses on Metrics et al., so the title
  # rhythm is identical across pages; the tabs sit beside it on the same row.
  def title_cluster
    div(class: "flex items-center gap-3 min-w-0") do
      h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight shrink-0") { "Logs" }
      render Components::Logs::ModeTabs.new(active: @active) if @tabs
    end
  end

  def actions_cluster
    div(class: "flex items-center gap-2 shrink-0 flex-wrap") do
      @actions_block.call
    end
  end
end
