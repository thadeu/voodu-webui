# frozen_string_literal: true

# Filters + table + pager, extracted because it renders in two places: inside
# the page on a full navigation, and alone inside the polling frame. One
# component is what stops the two drifting.
class Components::Deploys::DeploymentsBody < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    div(class: "flex flex-col gap-3") do
      render Components::Deploys::DeploymentFilterBar.new(
        data: @data, frame: DeploysController::FRAME
      )
      render Components::Deploys::DeploymentTable.new(data: @data)
      pagination
    end
  end

  private

  def pagination
    render Components::UI::CursorPagination.new(
      newest_href: (deploys_deployments_path(filters) unless @data.first_page?),
      prev_href: (page_href(before: @data.newest_cursor) if @data.has_newer?),
      next_href: (page_href(after: @data.oldest_cursor) if @data.has_older?),
      frame: DeploysController::FRAME,
      label: "deployments"
    )
  end

  # The cursor changes; every filter rides along. Losing what you were looking
  # at by clicking "older" is the classic pagination bug, and it comes from
  # building the URL out of the cursor alone.
  def page_href(**cursor)
    deploys_deployments_path(filters.merge(cursor))
  end

  def filters
    out = {}
    out[:status] = @data.statuses if @data.statuses.any?
    out[:repo] = @data.repos_filter if @data.repos_filter.any?
    out[:q] = @data.query if @data.query.present?
    out[:range] = @data.range_key if @data.range_key != DeploymentsData::DEFAULT_RANGE

    if @data.custom_range?
      out[:from] = @data.window&.first&.iso8601
      out[:until] = @data.window&.last&.iso8601
    end

    out.compact
  end
end
