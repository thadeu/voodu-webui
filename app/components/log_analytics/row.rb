# frozen_string_literal: true

# Components::LogAnalytics::Row — one line in the analytics results table
# (and reused inside the Surrounding Logs modal).
#
# Mirrors the live-tail row exactly: a `.log-row.la-grid-row` whose cells
# (time / pod / message) flow into the shared `.log-list` grid, with the
# payload kept as plain selectable text. There is NO expand panel — the
# "see the whole line" need is met by WRAP (per-row, via the hover chip or
# a double-click on the line), and the per-row hover chips cover the rest:
#
#   wrap (this line) · copy (raw) · surrounding logs
#
# Per-level left tint follows the chart palette rule (--voodu-red reserved
# for errors); the message text is tinted only for error/warn so the bulk
# of lines stay full-strength readable.
#
#   row:          { ts:, pod:, stream:, level:, msg:, raw:, parsed: }
#   surroundable: render the surrounding-logs chip (true in the results
#                 table; false inside the surrounding modal so it doesn't
#                 recurse).
#   anchor:       mark this row as the surrounding-modal anchor (highlight
#                 + scroll-into-view).
class Components::LogAnalytics::Row < Components::Base
  include Components::LogAnalytics::CallId

  def initialize(row:, surroundable: true, anchor: false)
    @row = row
    @surroundable = surroundable
    @anchor = anchor
  end

  def view_template
    div(
      class: tokens("log-row la-grid-row la-row group", @anchor ? "is-anchor" : nil),
      style: row_style,
      data: row_data
    ) do
      ts_cell
      pod_cell
      body_cell
    end
  end

  private

  # row_data — double-click anywhere on the line toggles its wrap (the chip
  # handler skips dblclicks that land on a chip). surrounding_anchor marks
  # the modal anchor for scroll-into-view.
  def row_data
    data = {action: "dblclick->log-analytics#toggleRowWrap"}
    data[:surrounding_anchor] = "true" if @anchor

    data
  end

  # row_style — the left stripe (--row-accent) always reflects the level
  # (neutral when there's none). The message text (--log-tone) is tinted
  # ONLY for error/warn; everything else falls back to --voodu-text via
  # theme.css (a no-level line tinted with the neutral border tone washed
  # the message into the dark background — unreadable).
  def row_style
    style = "--row-accent: #{level_color};"
    tone = message_tone
    style += " --log-tone: #{tone};" if tone

    style
  end

  def message_tone
    case @row[:level].to_s.upcase
    when "ERROR", "FATAL" then "var(--voodu-red)"
    when "WARN", "WARNING" then "var(--voodu-amber)"
    end
  end

  # ts_cell — the timestamp in the operator's configured timezone (Settings →
  # Display preferences, via WebTime), so the wall clock matches the rest of
  # the dashboard. Converting here (lazy, per RENDERED row) keeps it off the
  # full scan: only the PAGE_SIZE slice pays the per-row parse, never the
  # MATCH_SCAN_CAP collection. `datetime`/`title` carry the canonical UTC ISO —
  # the raw value stays in the DOM (copy/hover/debug), and the surrounding
  # anchor key (chip `data-ts`, still `@row[:ts]`) is untouched.
  def ts_cell
    time(class: "log-ts", datetime: @row[:ts], title: @row[:ts]) { local_ts }
  end

  # local_ts — UTC warehouse timestamp → configured zone, re-appending the
  # source's OWN fractional digits. The offset only shifts whole minutes, so
  # the sub-second part is timezone-invariant: reusing the raw fraction keeps
  # the exact nano/milli precision (useful for debug) without padding a
  # millisecond stamp out to phantom nanoseconds. Falls back to the raw string
  # for an unparseable ts so a malformed line renders as-is, never blank.
  def local_ts
    raw = @row[:ts].to_s
    zoned = WebTime.in_zone(raw)
    return raw if zoned.nil?

    frac = raw[/\.(\d+)/, 1]
    base = zoned.strftime("%Y-%m-%dT%H:%M:%S")

    frac ? "#{base}.#{frac}" : base
  end

  def pod_cell
    span(class: "log-pod") { @row[:pod] }
  end

  # body_cell — the payload + the floating hover chips. `.log-body` is the
  # positioning context (position: relative in theme.css) for the absolute
  # chips, which reveal on row hover. `.log-msg` is the selectable text.
  def body_cell
    span(class: "log-body") do
      span(class: "log-msg") { @row[:msg].presence || @row[:raw] }
      call_flow_chip if call_flow_available?
      surrounding_chip if @surroundable
      wrap_chip
      copy_chip
    end
  end

  # call_flow_available? — show the SIP-bridge chip only when this line
  # carries a Call-ID AND the island runs voodu-hep3. Both gates matter:
  # without a Call-ID there's nothing to open, and without hep3 the page
  # has no call-flow host to catch the click (a dead affordance). Cheap —
  # the island/System/plugins are all memoised, so the per-row check is free.
  def call_flow_available?
    sip_call_id.present? && current_island&.plugin_installed?("hep3")
  end

  # sip_call_id — the SIP Call-ID embedded in the raw line (FreeSWITCH prints
  # `Call-ID: <id>`), or nil. The chip hands this id to the bridge, which
  # resolves it to the captured call (folding x_cid) in the read model, so a
  # log line jumps straight to its SIP ladder without the operator copying ids.
  def sip_call_id
    return @sip_call_id if defined?(@sip_call_id)

    @sip_call_id = sip_call_id_from(@row[:raw])
  end

  # call_flow_chip — the Logs→HEP3 bridge (leftmost chip, right: 76px).
  # Carries the Call-ID; clicking dispatches a `callflow` row-action that the
  # page's hep3-call-flow host catches → fetches + injects the ladder for the
  # captured call this id folds into (same fetch→inject as the DataTable).
  def call_flow_chip
    button(
      type: "button",
      class: "log-callflow",
      title: "Open SIP call-flow",
      "aria-label": "Open the SIP call-flow for this line's Call-ID",
      data: {action: "click->log-analytics#openCallFlow", call_id: sip_call_id}
    ) do
      render Icon::ArrowsRightLeftOutline.new
    end
  end

  # copy_chip — copies the raw line. Rightmost (right: 4px).
  def copy_chip
    button(
      type: "button",
      class: "log-copy",
      title: "Copy line",
      "aria-label": "Copy log line to clipboard",
      data: {action: "click->log-analytics#copyLine", raw: @row[:raw].presence || @row[:msg]}
    ) do
      render Icon::ClipboardOutline.new
    end
  end

  # wrap_chip — toggles wrap for THIS line only (right: 28px). Stays lit
  # (data-active) while the line is wrapped so the operator can un-wrap
  # without re-hunting it.
  def wrap_chip
    button(
      type: "button",
      class: "log-wrap-single",
      title: "Toggle wrap for this line",
      "aria-label": "Toggle wrap for this log line",
      data: {action: "click->log-analytics#toggleRowWrap", active: "false"}
    ) do
      svg(
        viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
        "stroke-width": "1.5", "stroke-linecap": "round", "stroke-linejoin": "round",
        "aria-hidden": "true"
      ) do |s|
        s.line(x1: "2", y1: "4", x2: "14", y2: "4")
        s.path(d: "M2 8h10a2 2 0 0 1 0 4H7")
        s.polyline(points: "9,10 7,12 9,14")
        s.line(x1: "2", y1: "12", x2: "4", y2: "12")
      end
    end
  end

  # surrounding_chip — opens the Surrounding Logs modal anchored on this
  # line (left of the others, right: 52px). Carries ts + pod so the server
  # can locate the anchor.
  def surrounding_chip
    button(
      type: "button",
      class: "log-surrounding",
      title: "Show surrounding logs",
      "aria-label": "Show logs surrounding this line",
      data: {action: "click->log-analytics#openSurrounding", ts: @row[:ts], pod: @row[:pod]}
    ) do
      render Icon::ArrowsPointingOutOutline.new
    end
  end

  # level_color — the chart-palette tint for this row's level.
  # --voodu-red stays reserved for errors/failures (CLAUDE.md rule).
  def level_color
    case @row[:level].to_s.upcase
    when "ERROR", "FATAL" then "var(--voodu-red)"
    when "WARN", "WARNING" then "var(--voodu-amber)"
    when "INFO" then "var(--voodu-blue)"
    when "DEBUG", "TRACE" then "var(--voodu-muted)"
    else "var(--voodu-border-2)"
    end
  end
end
