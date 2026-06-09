# frozen_string_literal: true

# Views::LogsAnalytics::Results — the Turbo Frame response for a re-query
# (filter-bar submit). Renders ONLY the results frame so Turbo swaps the
# table in place without touching the page chrome. The same component is
# rendered inline by LogAnalytics::Page on the initial full-page load, so
# the markup matches and Turbo's frame match succeeds.
class Views::LogsAnalytics::Results < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    render Components::LogAnalytics::Results.new(data: @data)
  end
end
