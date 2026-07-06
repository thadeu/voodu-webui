# frozen_string_literal: true

# Views::Metrics::Frame — the turbo-frame body returned when Turbo
# refetches the `metrics-charts` frame (broadcast tick over
# ActionCable, or manual frame.reload()).
#
# Renders ChartCards with data fetched server-side. Server-side
# fetch + Rails.cache (60s TTL) keeps the cold cost bounded; the
# warm path (1s after a tick) is sub-100ms.
#
# `Views::Metrics::Index#chart_grid` renders the SAME structure on
# initial pageload — keeping them lockstep means the broadcast
# swap doesn't visually flicker (same DOM in, same DOM out).
#
# Resource + HTTP cards share ONE grid (no divider). Each HTTP card
# carries an inline [http] badge inside its header so the visual
# cue remains without breaking the grid.
class Views::Metrics::Frame < Views::Base
  def initialize(data: nil)
    @data = data
  end

  def view_template
    turbo_frame_tag("metrics-charts") do
      next if @data.nil?

      # Mirrors Views::Metrics::Index#chart_grid — same multi/section vs
      # single grid structure so the broadcast-tick swap is DOM-stable.
      if multi_mode?
        div(class: "flex flex-col gap-5 vmd:gap-6") do
          @data.sections.each { |sec| dashboard_section(sec) }
        end
      elsif dashboard_mode?
        dashboard_section(@data)
      else
        grid_for(@data)
      end
    end
  end

  private

  def multi_mode?
    @data.respond_to?(:multi?) && @data.multi?
  end

  def dashboard_mode?
    @data.respond_to?(:dashboard?) && @data.dashboard?
  end

  # Mirrors Index#dashboard_section EXACTLY — the collapse toggle + settings
  # button + the metrics-section wrapper must survive the broadcast-tick frame
  # swap (else they flash in on pageload then vanish on the first reload).
  def dashboard_section(sec)
    dash = sec.dashboard

    div(
      class: "flex flex-col gap-3",
      data: {controller: "metrics-section", metrics_section_id_value: dash&.uuid.to_s}
    ) do
      div(class: "flex items-center gap-2.5") do
        render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0")
        span(class: "text-[13px] font-semibold text-voodu-text") { dash&.name }
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "#{dash&.panels_count} #{(dash&.panels_count == 1) ? "panel" : "panels"}"
        end
        span(class: "flex-1 h-px bg-voodu-border-2 ml-1")

        collapse_toggle
        edit_dashboard_link(dash)

        render Components::Metrics::DisplaySettingsButton.new(
          kind: sec.display_kind,
          scope_kind: "host",
          display_settings_url: metrics_display_settings_path,
          dashboard_id: dash&.uuid,
          compact: true
        )
      end

      div(data: {metrics_section_target: "body"}) do
        grid_for(sec)
      end
    end
  end

  def collapse_toggle
    button(
      type: "button",
      "aria-label": "Collapse or expand this group",
      data: {action: "click->metrics-section#toggle", tooltip: "Collapse group"},
      class: "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 transition-colors shrink-0"
    ) do
      span(data: {role: "eye-open"}) { render Icon::EyeOutline.new(class: "w-3.5 h-3.5") }
      span(data: {role: "eye-closed"}, class: "hidden") { render Icon::EyeSlashOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  # edit_dashboard_link — mirrors Index#edit_dashboard_link so the quick-edit
  # pencil survives the broadcast-tick frame swap.
  def edit_dashboard_link(dash)
    return unless dash

    a(
      href: metric_dashboards_path(edit: dash.uuid),
      data: {turbo_frame: "_top", tooltip: "Edit dashboard"},
      "aria-label": "Edit dashboard",
      class: "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 transition-colors shrink-0"
    ) { render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5") }
  end

  def grid_for(data)
    div(
      class: "flex flex-col gap-4 vmd:gap-5",
      data: {
        controller: "metrics-display",
        metrics_display_kind_value: data.display_kind
      }
    ) do
      all_charts = data.charts + (data.ingress_eligible? ? data.http_charts : [])
      render_grid(all_charts, data)
    end
  end

  def render_grid(charts, data)
    div(
      class: "grid grid-cols-1 vmd:grid-cols-2 gap-3",
      data: {metrics_display_target: "grid"}
    ) do
      charts.each do |c|
        if c[:kind] == :number
          render_number_card(c)
        elsif c[:kind] == :table
          render_table_card(c)
        elsif c[:missing]
          render_missing_card(c)
        else
          render Components::Metrics::ChartCard.new(
            label: c[:label],
            color: c[:color],
            unit: c[:unit],
            points: c[:points],
            range_ms: data.range_ms,
            current: c[:current],
            expand_url: expand_url_for(c, data),
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
    end
  end

  # render_number_card — mirrors Views::Metrics::Index#render_number_card so
  # a log-count tile renders identically on initial load and after a
  # broadcast-tick frame swap. Drift = the count flickers shape on refresh.
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
      range_ms: c[:range_ms],
      sub: c[:meta],
      default_visible: c.fetch(:default_visible, true)
    )
  end

  # render_table_card — mirrors Views::Metrics::Index#render_table_card so a
  # Table panel renders the same shell after a broadcast-tick frame swap.
  # The card is turbo-permanent, so its live client state (rows, scroll,
  # pause) survives the swap; this keeps the no-JS / first-paint shell in
  # lockstep.
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

  # table_window — mirrors Views::Metrics::Index#table_window so a Table panel
  # keeps honouring the page's time window after a broadcast-tick frame swap.
  def table_window
    custom = @data.respond_to?(:custom?) && @data.custom?

    {
      range: custom ? "custom" : (@data&.range || "1h"),
      window_from: (custom ? request.query_parameters[:from] : nil),
      window_until: (custom ? request.query_parameters[:until] : nil)
    }
  end

  # render_missing_card — mirrors Views::Metrics::Index#render_missing_card
  # so a dashboard panel with no running replica renders the same dashed
  # placeholder after a broadcast-tick frame swap.
  def render_missing_card(c)
    div(class: "bg-voodu-surface border border-voodu-border border-dashed p-3.5 flex flex-col gap-2 min-w-0") do
      span(
        class: "text-[11.5px] font-semibold uppercase tracking-[0.05em]",
        style: "color: #{c[:color]};"
      ) { c[:label] }

      div(class: "flex items-center justify-center w-full h-[120px] text-[12px] text-voodu-muted text-center px-3") do
        plain "no running replica for #{c[:source_label]}"
      end
    end
  end

  # expand_url_for — mirrors Views::Metrics::Index#expand_url_for.
  # Drift between the two = the maximize button breaks after the
  # first broadcast tick swap.
  def expand_url_for(chart, data)
    return hep3_expand_url(chart, data) if chart[:source] == "hep3"

    sk = chart[:scope_kind] || (data.respond_to?(:scope_kind) ? data.scope_kind : nil)
    sid = chart[:scope_id] || (data.respond_to?(:scope_id) ? data.scope_id : nil)

    qp = {
      scope_kind: sk || "host",
      scope_id: sid,
      range: data.range || "1h",
      # Match Views::Metrics::Index#expand_url_for — omit `interval`
      # when `auto` so URLs stay clean on the default path.
      interval: (data.interval && data.interval != "auto") ? data.interval : nil,
      metric: chart[:metric],
      scale: chart[:scale],
      label: chart[:label],
      color: chart[:color],
      unit: chart[:unit],
      # server_id → drill into the panel's own server (cross-server dashboards).
      server_id: chart[:server_id],
      # Carry the panel's chart type so the expand modal renders the same
      # shape (a gauge stays a gauge). Omitted for the default area.
      chart_type: ((chart[:chart_type].to_s == "area") ? nil : chart[:chart_type])
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end

  # hep3_expand_url — mirrors Views::Metrics::Index#hep3_expand_url.
  def hep3_expand_url(chart, data)
    qp = {
      source: "hep3", scope: chart[:scope], name: chart[:name], view: chart[:view],
      filter_query: chart[:filter_query].presence,
      chart_type: chart[:chart_type], percent: (chart[:percent] ? "true" : nil),
      label: chart[:label], color: chart[:color],
      server_id: chart[:server_id],
      range: data.range || "1h",
      interval: (data.interval && data.interval != "auto") ? data.interval : nil
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end
end
