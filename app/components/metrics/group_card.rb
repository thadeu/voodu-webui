# frozen_string_literal: true

# Components::Metrics::GroupCard — renders a group-by aggregation SNAPSHOT
# (`… | count()/count(distinct X) by <field>`): one entry per group value,
# already sorted + capped by the query's sort/limit. Two styles:
#
#   :table → a two-column [<field> | count] list
#   :bars  → horizontal bars (width ∝ count) for a quick top-N read
#
# Both scroll vertically, so "see ALL N groups" works even for hundreds of rows
# (the operator caps with `| sort desc | limit N` when they want fewer). Mirrors
# the other metric cards' chrome (label header + range-agnostic count badge) so
# it sits in the same metrics-display grid and the Settings/Order drawer can
# show/hide/reorder/resize it via data-metric-key.
module Components
  module Metrics
    class GroupCard < Components::Base
      def initialize(label:, color:, field:, groups:, style: :table, metric: nil, default_visible: true)
        @label = label
        @color = color
        @field = field.to_s
        @groups = Array(groups)
        @style = style.to_sym
        @metric = metric
        @default_visible = default_visible
      end

      def view_template
        root_data = {}

        if @metric
          root_data[:metrics_display_target] = "card"
          root_data[:metric_key] = @metric
        end

        root_data[:default_visible] = "false" unless @default_visible

        div(
          class: "relative bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0",
          data: root_data
        ) do
          card_header

          if @groups.empty?
            empty_state
          elsif @style == :bars
            bars_body
          else
            table_body
          end

          if @metric
            resize_handle("left")
            resize_handle("right")
          end
        end
      end

      private

      def card_header
        div(class: "flex items-start justify-between gap-2") do
          span(
            class: "text-[11.5px] font-semibold uppercase tracking-[0.05em] min-w-0 truncate",
            style: "color: #{@color};"
          ) { @label }

          span(
            class: "inline-flex items-center px-1.5 h-[18px] text-[10.5px] font-medium rounded-voodu-sm " \
                   "border border-voodu-border text-voodu-muted shrink-0 font-voodu-mono"
          ) { "#{@groups.size} #{@field}" }
        end
      end

      def empty_state
        div(class: "flex items-center justify-center h-[120px] text-[12px] text-voodu-muted") { "no data" }
      end

      # table_body — [<field> | count], newest-strongest first (already sorted).
      # The value column is right-aligned mono so digits line up.
      def table_body
        div(class: "min-w-0 overflow-y-auto max-h-[240px]") do
          table(class: "w-full text-[12px] border-collapse") do
            tbody do
              @groups.each do |g|
                tr(class: "border-b border-voodu-border-2 last:border-0") do
                  td(class: "py-1 pr-2 font-voodu-mono text-voodu-text truncate max-w-0 w-full") { g[:group].to_s }
                  td(class: "py-1 pl-2 text-right font-voodu-mono text-voodu-text-2 tabular-nums whitespace-nowrap") do
                    MetricFormat.number(g[:value])
                  end
                end
              end
            end
          end
        end
      end

      # bars_body — one horizontal bar per group, width proportional to the
      # largest value (a quick "who's biggest" read). Value trails the bar.
      def bars_body
        max = @groups.map { |g| g[:value].to_i }.max.to_i
        max = 1 if max <= 0

        div(class: "min-w-0 overflow-y-auto max-h-[240px] flex flex-col gap-1.5") do
          @groups.each do |g|
            pct = ((g[:value].to_f / max) * 100).clamp(0, 100).round(1)

            div(class: "flex items-center gap-2 min-w-0") do
              span(class: "font-voodu-mono text-[11px] text-voodu-text truncate w-[42%] shrink-0") { g[:group].to_s }

              div(class: "flex-1 min-w-0 h-3 bg-voodu-surface-2 rounded-voodu-sm overflow-hidden") do
                div(class: "h-full rounded-voodu-sm", style: "width: #{pct}%; background: #{@color};")
              end

              span(class: "font-voodu-mono text-[11px] text-voodu-text-2 tabular-nums shrink-0 w-10 text-right") do
                MetricFormat.number(g[:value])
              end
            end
          end
        end
      end

      # resize_handle — mirrors the other cards so a group card column-resizes in
      # the metrics-display grid.
      def resize_handle(edge)
        div(
          data: {action: "pointerdown->metrics-display#startResize", resize_edge: edge},
          aria: {hidden: "true"},
          title: "Drag to resize",
          class: tokens(
            "absolute top-0 bottom-0 w-1.5 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-10 touch-none",
            (edge == "left") ? "left-0" : "right-0"
          )
        )
      end
    end
  end
end
