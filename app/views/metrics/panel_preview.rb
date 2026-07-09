# frozen_string_literal: true

# Views::Metrics::PanelPreview — the builder's live preview of ONE in-progress
# panel, rendered as its real dashboard card (via the shared CardRenderer). The
# controller builds a synthetic one-panel dashboard → chart_for → this. No
# maximize (nothing to expand yet); a panel that can't build yet → a placeholder.
class Views::Metrics::PanelPreview < Views::Base
  include Views::Metrics::ExpandUrl
  include Views::Metrics::CardRenderer

  def initialize(chart:, data:)
    @chart = chart
    @data = data
  end

  def view_template
    if @chart.nil?
      placeholder
    else
      div(class: "grid grid-cols-1 gap-3", data: {metrics_display_target: "grid"}) do
        render_one_card(@chart, @data, expandable: false)
      end
    end
  end

  private

  def placeholder
    div(class: "flex items-center justify-center h-[160px] border border-voodu-border border-dashed rounded-voodu text-[12px] text-voodu-muted text-center px-4") do
      plain "Pick a source and render to preview the panel"
    end
  end
end
