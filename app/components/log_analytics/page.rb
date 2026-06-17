# frozen_string_literal: true

# Components::LogAnalytics::Page — the /logs/analytics surface chrome.
# Sibling to Components::Logs::Page (live tail); the shared Logs::Header at
# the top (label + Analytics/Follow switcher on one row) lets the operator
# flip between Follow (live) and Analytics (historical search) without
# hunting in the sidebar.
#
# Structure: header (label + tabs) → filter bar → results frame. The
# root carries `data-controller="log-analytics"`, which owns the preset
# chips, custom-range toggle, date normalisation, row copy, and the
# Surrounding Logs overlay (fetched into #surroundingHost on demand).
class Components::LogAnalytics::Page < Components::Base
  def initialize(data:, pods: [])
    @data = data
    @pods = Array(pods)
  end

  def view_template
    div(
      class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 h-full",
      data: {
        controller: "log-analytics",
        action:     "modal:close->log-analytics#closeSurrounding",
        log_analytics_surrounding_url_value: logs_analytics_surrounding_path,
        # Resolved window as UTC ISO + the active range. On connect the
        # controller fills the custom datetime-local inputs from these,
        # converted to the browser's local zone (timezone-correct).
        log_analytics_range_value: @data.range,
        log_analytics_from_value:  @data.from_iso,
        log_analytics_until_value: @data.until_iso
      }
    ) do
      render Components::Logs::Header.new(active: :analytics)
      render Components::LogAnalytics::FilterBar.new(data: @data, pods: @pods)
      render Components::LogAnalytics::Results.new(data: @data)

      surrounding_host
    end
  end

  private

  # surrounding_host — empty mount point the controller injects the
  # Surrounding Logs modal into. Lives at page root so the fixed-position
  # backdrop/dialog overlay the whole viewport, not just the table.
  def surrounding_host
    div(data: { log_analytics_target: "surroundingHost" })
  end
end
