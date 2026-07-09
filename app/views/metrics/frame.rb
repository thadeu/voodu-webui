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
  # Same maximize-button URL logic as Views::Metrics::Index — shared so a poll
  # re-render of the grid can't drift from first paint (it used to: the modal
  # dropped the brushed window after the first tick).
  include Views::Metrics::ExpandUrl
  include Views::Metrics::CardRenderer

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
      charts.each { |c| render_one_card(c, data) }
    end
  end
end
