# frozen_string_literal: true

# Components::LogAnalytics::MoreRows — one appended page of results,
# fetched by the "Load more" link. Wrapped in the same <turbo-frame
# id="la-page-N"> the link targeted, so Turbo swaps the link out for
# this batch (rows + the next page's trigger). See ResultsBase for the
# pagination pattern.
class Components::LogAnalytics::MoreRows < Components::LogAnalytics::ResultsBase
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag("la-page-#{@data.page}") do
      render_rows(@data)
      render_load_more(@data)
    end
  end
end
