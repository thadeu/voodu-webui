# frozen_string_literal: true

# Views::Metrics::CardRenderer — the single-card render shared by the dashboard
# grid (Index + Frame) and the builder's panel preview. Given ONE chart envelope
# (from MetricDashboardData#chart_for) it picks the right card component, keeping
# the render paths (number / table / group / chart, + missing) in ONE place so
# the three surfaces never drift.
#
# The host view must `include Views::Metrics::ExpandUrl` (for expand_url_for) and
# set @data (for table_window's custom-window forwarding).
module Views
  module Metrics
    module CardRenderer
      # render_one_card — one envelope → its card. `expandable:` adds the maximize
      # URL (the grid wants it; the preview has nothing to maximize).
      def render_one_card(c, data, expandable: true)
        if c[:kind] == :number
          render_number_card(c)
        elsif c[:kind] == :table
          render_table_card(c)
        elsif c[:kind] == :group_table || c[:kind] == :group_bar
          render_group_card(c)
        elsif c[:missing]
          render_missing_card(c)
        else
          render Components::Metrics::ChartCard.new(
            label: c[:label],
            color: c[:color],
            unit: c[:unit],
            points: c[:points],
            series: c[:series],
            range_ms: data.range_ms,
            current: c[:current],
            expand_url: expandable ? expand_url_for(c, data) : nil,
            # data-metric-key the Settings/Order drawer matches on (panel_key in
            # dashboard mode; the metric name in scope mode).
            metric: c[:panel_key] || c[:metric],
            section: c[:section],
            default_visible: c.fetch(:default_visible, true),
            capacity_label: c[:capacity_label],
            capacity_pct: c[:capacity_pct],
            chart_type: c[:chart_type],
            percent: c.fetch(:percent, true)
          )
        end
      end

      # render_number_card — log/hep3/http count tile.
      def render_number_card(c)
        render Components::Metrics::NumberCard.new(
          label: c[:label],
          color: c[:color],
          formatted: c[:formatted],
          range: c[:range],
          metric: c[:panel_key],
          truncated: c[:truncated],
          clamped: c[:clamped],
          series: c[:series] || [],
          numbers: c[:numbers],
          range_ms: c[:range_ms],
          sub: c[:meta],
          default_visible: c.fetch(:default_visible, true)
        )
      end

      # render_table_card — DataSource-backed Table panel (scope_kind "table").
      # The card fetches its rows client-side from rows_url, scoped to table_window.
      def render_table_card(c)
        render Components::Metrics::TableCard.new(
          label: c[:label],
          color: c[:color],
          source: c[:source],
          scope: c[:scope],
          name: c[:name],
          view: c[:view],
          fields: c[:fields] || [],
          default_fields: c[:default_fields] || [],
          filter_query: c[:filter_query],
          rows_url: metrics_datatable_rows_path(source: c[:source]),
          metric: c[:panel_key],
          default_visible: c.fetch(:default_visible, true),
          row_action: c[:row_action],
          dashboard_uuid: c[:dashboard_uuid],
          server_id: c[:server_id],
          **table_window
        )
      end

      # render_group_card — a HEP3 group-by snapshot (`… | count() by <field>`)
      # rendered as a Table (rows) or Bar (horizontal bars) per group.
      def render_group_card(c)
        render Components::Metrics::GroupCard.new(
          label: c[:label], color: c[:color], field: c[:field], groups: c[:groups] || [],
          style: (c[:kind] == :group_bar) ? :bars : :table,
          metric: c[:panel_key], default_visible: c.fetch(:default_visible, true)
        )
      end

      # render_missing_card — placeholder for a panel whose workload has no running
      # replica right now (scaled to zero, deleted, mid-redeploy). Dashed border so
      # it reads as intentionally empty, not broken.
      def render_missing_card(c)
        div(
          class: "bg-voodu-surface border border-voodu-border border-dashed p-3.5 flex flex-col gap-2 min-w-0",
          data: c[:panel_key] ? {metrics_display_target: "card", metric_key: c[:panel_key]} : {}
        ) do
          span(
            class: "text-[11.5px] font-semibold uppercase tracking-[0.05em]",
            style: "color: #{c[:color]};"
          ) { c[:label] }

          div(class: "flex items-center justify-center w-full h-[120px] text-[12px] text-voodu-muted text-center px-3") do
            plain "no running replica for #{c[:source_label]}"
          end
        end
      end

      # table_window — the page's time picker forwarded to a Table panel so its
      # rows scope to the same window as the charts.
      def table_window
        custom = @data.respond_to?(:custom?) && @data.custom?

        {
          range: custom ? "custom" : (@data&.range || "1h"),
          window_from: (custom ? request.query_parameters[:from] : nil),
          window_until: (custom ? request.query_parameters[:until] : nil)
        }
      end
    end
  end
end
