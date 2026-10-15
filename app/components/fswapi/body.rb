# frozen_string_literal: true

# Components::Fswapi::Body — everything on the FreeSWITCH page that refreshes:
# the status line, the count cards and the live table of the chosen tab.
#
# Rendered by the full page AND by the polling frame, so the two can never
# drift. The tabs are links inside the frame: a click swaps only the frame,
# and `turbo_action: advance` keeps the URL (and so the polling src) on the
# tab the operator chose.
class Components::Fswapi::Body < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    div(class: "flex flex-col gap-4 vmd:gap-5") do
      error_callout if @data.error
      status_line
      cards
      live_section
    end
  end

  private

  # The plugin's own message: a wrong ESL password names the
  # `vd config:set` command that fixes it, so it is shown verbatim.
  def error_callout
    render Components::UI::Callout.new(tone: :danger, title: "FreeSWITCH did not answer") do
      span(class: "font-voodu-mono text-[12px] break-words") { @data.error }
    end
  end

  # Each fact explains itself on hover (or tap): what it means, then where the
  # value comes from in FreeSWITCH's `status` reply. The page is opened rarely
  # enough that "what was idle CPU again?" is the normal question.
  #
  # A tip is {title:, lines:, source:} and renders as a title, one line per
  # idea, and the source in mono — a paragraph run together was unreadable.
  def status_line
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-1.5 vmd:gap-4 text-[12.5px] text-voodu-text-2") do
      explained(UP_TIP) do
        tone = @data.up? ? "var(--voodu-green)" : "var(--voodu-red)"

        span(class: "inline-block w-2 h-2 rounded-full", style: "background: #{tone};")
        span(class: "font-medium text-voodu-text") { @data.up? ? "Up" : "Unavailable" }
      end

      fact("Version", @data.version, VERSION_TIP)
      fact("Uptime", @data.uptime, UPTIME_TIP)
      fact("Idle CPU", @data.idle_cpu, idle_cpu_tip)
    end
  end

  UP_TIP = {
    title: "Status",
    lines: [
      "Up: FreeSWITCH answered on its event socket (ESL) just now.",
      "Unavailable: the plugin could not reach ESL, or the password was refused."
    ],
    source: "ESL `status`, read live"
  }.freeze

  VERSION_TIP = {
    title: "Version",
    lines: ["The FreeSWITCH build running on this server."],
    source: "`status` → FreeSWITCH (Version …) is ready"
  }.freeze

  UPTIME_TIP = {
    title: "Uptime",
    lines: ["Time since FreeSWITCH started.", "Back to zero on every FreeSWITCH restart."],
    source: "`status` → UP … days, hours, minutes"
  }.freeze

  def idle_cpu_tip
    idle = @data.idle_cpu_percent
    floor = @data.idle_cpu_floor

    lines = ["Free CPU on the whole host, as FreeSWITCH measures it."]
    lines << "#{pct(idle)} idle ≈ #{pct(100 - idle)} in use." if idle

    if floor
      guard = floor.zero? ? "0 (off)" : pct(floor)
      lines << "Guard (min-idle-cpu): #{guard}. Below this much free CPU, FreeSWITCH refuses new calls."
    end

    {title: "Idle CPU", lines: lines, source: "`status` → min idle cpu <guard>/<idle>"}
  end

  def pct(value) = "#{Kernel.format("%.1f", value)}%"

  def fact(label, value, tip)
    return if value.blank?

    explained(tip) do
      span(class: "text-voodu-muted") { "#{label} " }
      span(class: "font-voodu-mono text-[12px] text-voodu-text") { value }
    end
  end

  # explained — the fact itself, focusable (a tap opens the tip on touch), with
  # the explanation in a tooltip BELOW it: above, the page's top cuts it. The
  # tooltip is aria-hidden, so the same text rides along as sr-only for screen
  # readers.
  def explained(tip, &)
    span(tabindex: "0", class: "relative group/fact inline-flex items-center gap-1.5 self-start cursor-help outline-none border-b border-dotted border-voodu-border-2 focus-visible:border-voodu-accent") do
      yield

      span(class: "sr-only") { [tip[:title], *tip[:lines], "Source: #{tip[:source]}"].join(". ") }

      render Components::UI::Tooltip.new(group: "fact", side: :bottom_start) do
        tip_body(tip)
      end
    end
  end

  def tip_body(tip)
    span(class: "flex flex-col gap-1.5 w-[280px] whitespace-normal leading-snug py-0.5") do
      span(class: "font-medium text-voodu-text") { tip[:title] }

      tip[:lines].each do |line|
        span(class: "text-voodu-text-2") { line }
      end

      span(class: "pt-1.5 mt-0.5 border-t border-voodu-border-2 font-voodu-mono text-[11px] text-voodu-muted") do
        tip[:source]
      end
    end
  end

  def cards
    div(class: "grid grid-cols-1 vmd:grid-cols-3 gap-3") do
      @data.cards.each do |card|
        render Components::Overview::StatCard.new(**card, period: "1h")
      end
    end
  end

  def live_section
    div(class: "flex flex-col gap-3") do
      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2.5") do
        tabs
        filter_form
      end

      summary_line
      render Components::Fswapi::LiveTable.new(view: @data.view, rows: @data.rows)
    end
  end

  # filter_form — a GET inside the frame: Enter (or the search field's own
  # clear button) re-renders just the frame, and `advance` keeps `q` in the URL
  # so the polling tick refetches the same filtered list.
  #
  # The input is turbo-permanent (stable id): the frame re-renders every 15s,
  # and without it a tick would wipe whatever the operator is typing.
  def filter_form
    form(
      action: fswapi_path, method: "get",
      data: {turbo_action: "advance", controller: "auto-submit"},
      class: "w-full vmd:w-auto vmd:ml-auto"
    ) do
      input(type: "hidden", name: "view", value: @data.view)

      label(class: "flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface w-full vmd:w-[320px] text-voodu-muted") do
        render Icon::FunnelOutline.new(class: "w-3 h-3 shrink-0")
        input(
          id: "fswapi-filter", type: "search", name: "q", value: @data.q,
          placeholder: "number, destination, channel… ⏎",
          autocomplete: "off", spellcheck: "false", "aria-label": "Filter the list",
          data: {turbo_permanent: true, action: "search->auto-submit#submit"},
          class: "flex-1 min-w-0 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2"
        )
      end
    end
  end

  # summary_line — what the table holds: on Channels the legs and the calls
  # they make up (plus how many transcode); everywhere, how many match the
  # filter and whether the list was cut at MAX_SHOWN.
  def summary_line
    parts = []

    parts << channels_summary if @data.view == "channels" && @data.all_rows.any?
    parts << match_summary if @data.filtered?
    parts << cap_summary if @data.capped?

    return if parts.empty?

    p(class: "flex flex-wrap items-center gap-x-1.5 text-[12px] text-voodu-muted") do
      parts.each_with_index do |part, i|
        span(aria: {hidden: "true"}) { "·" } if i.positive?
        span { part.call }
      end
    end
  end

  # "314 legs in 157 calls · 157 transcoding" — read off the same live list as
  # the table, so it always matches it.
  def channels_summary
    -> {
      legs = @data.all_rows.size
      calls = @data.call_count
      transcoding = @data.transcoding_count

      num(legs)
      plain " #{"leg".pluralize(legs)} in "
      num(calls)
      plain " #{"call".pluralize(calls)}"

      if transcoding.positive?
        plain " · "
        span(class: "text-voodu-amber") do
          num(transcoding)
          plain " transcoding"
        end
      end
    }
  end

  def match_summary
    -> {
      num(@data.matched_units)
      plain " of "
      num(@data.total_units)
      plain " #{unit_word(@data.total_units)} match “#{@data.q}”"
    }
  end

  def cap_summary
    -> {
      plain "showing the first "
      num(FswapiPageData::MAX_SHOWN)
      plain " — filter to find the rest"
    }
  end

  def unit_word(count)
    (@data.view == "channels") ? "call".pluralize(count) : "row".pluralize(count)
  end

  def num(value)
    span(class: "font-voodu-mono text-voodu-text") { value.to_s }
  end

  def tabs
    nav(class: "flex items-center gap-1 overflow-x-auto -mx-3.5 px-3.5 vmd:mx-0 vmd:px-0", aria: {label: "FreeSWITCH lists"}) do
      @data.views.each { |v| tab_link(v) }
    end
  end

  def tab_link(view)
    active = view[:key] == @data.view

    a(
      href: fswapi_path(view: view[:key], q: @data.q.presence),
      data: {turbo_action: "advance"},
      aria: {current: (active ? "page" : nil)},
      class: tokens(
        "inline-flex items-center gap-2 px-2.5 h-7 text-[12px] rounded-voodu-sm border transition-colors shrink-0",
        active ? "border-voodu-border bg-voodu-surface text-voodu-text" : "border-transparent text-voodu-text-2 hover:bg-voodu-surface hover:text-voodu-text"
      )
    ) do
      span { view[:label] }

      if (count = @data.count_for(view[:key]))
        span(class: "font-voodu-mono text-[10.5px] text-voodu-muted") { count.to_s }
      end
    end
  end
end
