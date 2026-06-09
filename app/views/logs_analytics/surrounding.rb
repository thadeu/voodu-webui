# frozen_string_literal: true

# Views::LogsAnalytics::Surrounding — bare modal body for the Surrounding
# Logs overlay. Fetched by the log-analytics Stimulus controller and
# injected into the page; no Dashboard chrome (layout: false in the
# controller).
class Views::LogsAnalytics::Surrounding < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    render Components::LogAnalytics::SurroundingModal.new(data: @data)
  end
end
