# frozen_string_literal: true

# Views::LogsAnalytics::MoreRows — the Turbo Frame response for a "Load
# more" click (page ≥ 2). Renders only the page-N batch wrapped in its
# la-page-N frame; no chrome (layout: false in the controller).
class Views::LogsAnalytics::MoreRows < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    render Components::LogAnalytics::MoreRows.new(data: @data)
  end
end
