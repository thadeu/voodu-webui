# frozen_string_literal: true

# Views::LogsAnalytics::Index — full page for /logs/analytics. Renders
# the Dashboard chrome + the LogAnalytics::Page (filter bar + results
# table inline). The results table is wrapped in a Turbo Frame so the
# filter bar can re-query it in place; see LogsAnalyticsController#index.
class Views::LogsAnalytics::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, updated_at: nil, pods: [], data: nil)
    @current_path = current_path
    @islands = islands
    @current_island = current_island
    @updated_at = updated_at
    @pods = pods
    @data = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands,
      current_island: @current_island, updated_at: @updated_at,
      breadcrumb: @current_island && overview_crumbs(
        {label: "Logs", href: logs_analytics_path(tenant_key: @current_island.key)},
        {label: "Analytics"}
      )
    ) do
      if @current_island.nil? || @data.nil?
        render Components::UI::NoIslandState.new
      else
        render Components::LogAnalytics::Page.new(data: @data, pods: @pods)

        # Call-flow overlay host — the Logs→HEP3 bridge. Rendered once at the
        # page level (sibling of the log-analytics root) so the per-row chip's
        # `callflow` row-action has a host to inject the SIP ladder into. Same
        # placement + gating as Metrics; only when the island runs voodu-hep3
        # (else the chip never renders and this listener is dead weight).
        if @current_island.plugin_installed?("hep3")
          render Components::Hep3::CallFlowHost.new(
            call_url: metrics_hep3_call_path(tenant_key: @current_island.key)
          )
        end
      end
    end
  end
end
