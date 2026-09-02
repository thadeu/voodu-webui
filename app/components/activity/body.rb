# frozen_string_literal: true

# Components::Activity::Body — filter bar, table, pagination.
#
# Extracted so Views::Activity::Index and ::Frame render the identical subtree.
# Two copies of this markup is how a live-reloading frame starts flickering:
# the first paint and every refetch have to produce the same DOM.
class Components::Activity::Body < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    # data-controller lives INSIDE the frame on purpose: Turbo replaces the
    # frame's contents on every reload, so this element is torn down and
    # rebuilt, and the controller's connect() becomes the after-render hook
    # that reopens the rows the operator had expanded.
    #
    # Keyed by server so two tabs on two boxes do not restore each other's
    # rows.
    div(
      class: "flex flex-col gap-4",
      data: {
        controller: "activity-rows",
        activity_rows_key_value: @data.server.id
      }
    ) do
      render Components::Activity::FilterBar.new(data: @data, frame: ActivityController::FRAME)
      render Components::Activity::Table.new(data: @data)
      pagination
    end
  end

  private

  # The hrefs keep every other query parameter — losing your filters by
  # clicking "next" is the classic pagination bug, and it comes from building
  # the URL out of the position alone.
  #
  # Cursor and not offset because this list grows at the top while you read it:
  # the poller inserts every thirty seconds and the frame reloads itself, so an
  # offset page two would re-show rows already seen on page one.
  def pagination
    render Components::UI::CursorPagination.new(
      newest_href: @data.first_page? ? nil : page_href({}),
      prev_href: @data.has_newer? ? page_href(before: @data.newest_cursor) : nil,
      next_href: @data.has_older? ? page_href(after: @data.oldest_cursor) : nil,
      frame: ActivityController::FRAME,
      label: "actions",
      showing: @data.rows.size
    )
  end

  # Both cursors are dropped before the new one is applied: they are two names
  # for the same position, and carrying a stale one alongside would make the
  # page depend on which the reader happened to check first.
  def page_href(cursor)
    activity_path(request.query_parameters.except("before", "after", "page").merge(cursor))
  end
end
