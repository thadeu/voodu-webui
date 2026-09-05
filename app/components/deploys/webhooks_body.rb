# frozen_string_literal: true

# Filters + table + pager, extracted because it renders in two places: inside
# the page on a full navigation, and alone inside the polling frame.
class Components::Deploys::WebhooksBody < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    div(class: "flex flex-col gap-3") do
      render Components::Deploys::WebhookFilterBar.new(
        data: @data, frame: DeploysController::WEBHOOKS_FRAME
      )
      render Components::Deploys::WebhookTable.new(data: @data)
      pagination
    end
  end

  private

  def pagination
    render Components::UI::CursorPagination.new(
      newest_href: (deploys_webhooks_path(filters) unless @data.first_page?),
      prev_href: (page_href(before: @data.newest_cursor) if @data.has_newer?),
      next_href: (page_href(after: @data.oldest_cursor) if @data.has_older?),
      frame: DeploysController::WEBHOOKS_FRAME,
      label: "deliveries"
    )
  end

  def page_href(**cursor)
    deploys_webhooks_path(filters.merge(cursor))
  end

  # The cursor changes; every filter rides along. Losing what you were looking
  # at by clicking "older" comes from building the URL out of the cursor alone.
  def filters
    out = {}
    out[:status] = @data.statuses if @data.statuses.any?
    out[:reference] = @data.references if @data.references.any?
    out[:q] = @data.query if @data.query.present?
    out[:range] = @data.range_key if @data.range_key != WebhookReceiptsData::DEFAULT_RANGE

    if @data.custom_range?
      out[:from] = @data.window&.first&.iso8601
      out[:until] = @data.window&.last&.iso8601
    end

    out.compact
  end
end
