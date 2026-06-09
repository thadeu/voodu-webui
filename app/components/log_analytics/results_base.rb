# frozen_string_literal: true

# Components::LogAnalytics::ResultsBase — shared row-list + "Load more"
# rendering for the analytics results, inherited by:
#
#   Results  — the initial page-1 frame (summary + table + first batch).
#   MoreRows — the page-N append fragment fetched by Load more.
#
# Pagination is the canonical Turbo append pattern: each batch ends with
# a uniquely-id'd <turbo-frame id="la-page-N"> wrapping the Load more
# link. Clicking it navigates THAT frame to ?page=N, whose response is
# wrapped in the same id — Turbo swaps the link out for the next batch +
# the next trigger, so older rows accumulate below without re-rendering
# the ones already on screen. Frame ids are unique per page (a shared id
# would collide once nested).
#
# Subclassing Components::Base (via this) rather than a mixin keeps Icon
# / route helpers / tokens resolvable inside these shared methods.
class Components::LogAnalytics::ResultsBase < Components::Base
  protected

  def render_rows(data)
    data.rows.each do |row|
      render Components::LogAnalytics::Row.new(row: row, surroundable: true)
    end
  end

  # render_load_more — the next-page trigger, or nothing on the last
  # page. The link lives INSIDE its target frame so the response (also
  # wrapped in that id) replaces it in place.
  def render_load_more(data)
    return unless data.has_more?

    frame_id = "la-page-#{data.next_page}"

    turbo_frame_tag(frame_id, class: "block border-t border-voodu-border") do
      div(class: "p-2") do
        a(
          href: load_more_path(data, data.next_page),
          data: { turbo_frame: frame_id },
          class: "flex items-center justify-center gap-1.5 w-full px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
        ) do
          render Icon::ArrowDownOutline.new(class: "w-3.5 h-3.5")
          span { load_more_label(data) }
        end
      end
    end
  end

  # load_more_path — the next page, with the window FROZEN to this
  # query's resolved from/until (UTC). Freezing matters because presets
  # resolve `until` to "now" each request; without it, a later Load more
  # would shift the window by the elapsed seconds and dupe/skip rows at
  # the page boundary. Passing explicit from/until reads as a custom
  # range server-side (identical window across all pages).
  def load_more_path(data, page)
    logs_analytics_path(
      q:     data.search.presence,
      regex: (data.regex? ? "1" : nil),
      pods:  data.pods.presence,
      from:  data.from_iso,
      until: data.until_iso,
      page:  page
    )
  end

  def load_more_label(data)
    size = [data.remaining, LogSearchData::PAGE_SIZE].min
    suffix = data.truncated? ? "+" : ""
    "Load #{ActiveSupport::NumberHelper.number_to_delimited(size)}#{suffix} older lines"
  end
end
