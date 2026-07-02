# frozen_string_literal: true

# Components::Hep3::CallFlow — the SIP call-flow LADDER (sequence diagram)
# for one call. Vertical lifelines (the parties, by IP) and one horizontal
# arrow per message in ts order, coloured by class (request / 1xx / 2xx /
# 3xx / 4xx-5xx). A left ts gutter times each step.
#
# Fed by Hep3::CallFlowData. Server-rendered as a COMPLETE SVG so the flow
# reads without JS (same idiom as Components::Metrics::Chart); the
# call_flow_controller only adds arrow selection → raw-SIP panel. Each
# arrow is a clickable <g> carrying its message index; a per-row hit rect
# spans the full width so the whole row is a target, and a rowbg rect
# behind it is what the controller tints on selection.
#
# Pan/zoom canvas (Figma-style): the drawable (lifeline lines + arrows +
# media) lives in a transformable <g data-call-flow-target="canvas"> that
# call_flow_controller pans (drag/scroll) and zooms (⌘/ctrl+scroll) via a
# matrix — SVG stays crisp at any scale. The lifeline IP headers are an HTML
# overlay (data-call-flow-target="headerBar") pinned to the top and kept at a
# fixed, readable size (so they don't shrink to nothing when zoomed out to fit
# many SBC columns); the controller repositions them to x = tx + col_x*k.
#
# The SVG fills its container; the controller sets the viewBox to the
# container's pixel size so 1 user unit == 1 CSS px (header math lines up).
# The modal is JS-injected, so there's no no-JS path to preserve.
class Components::Hep3::CallFlow < Components::Base
  GUTTER = 60      # left band for ts labels
  MARGIN = 46      # gutter/edge → first/last lifeline
  HEADER_H = 46    # top band for lifeline headers
  ROW_H = 46       # per-message vertical step
  TOP = 6
  BOTTOM = 20

  # Arrow colour by class (sngrep convention, operator-tuned): a request is
  # NEUTRAL (blue — neither ok nor error), EXCEPT BYE (call teardown) which is
  # flagged red; responses read by code — 1xx/2xx (100–299) green, 3xx amber,
  # 4xx+ red.
  KIND_COLOR = {
    request: "var(--voodu-blue)",
    terminate: "var(--voodu-red)",
    provisional: "var(--voodu-green)",
    success: "var(--voodu-green)",
    redirect: "var(--voodu-amber)",
    error: "var(--voodu-red)"
  }.freeze

  def initialize(data:)
    @data = data
  end

  def view_template
    svg(
      class: "block w-full h-full",
      viewBox: "0 0 #{width} #{height}",
      preserveAspectRatio: "xMinYMin meet",
      data: {call_flow_target: "svg", cf_width: width, cf_height: height},
      xmlns: "http://www.w3.org/2000/svg"
    ) do |s|
      s.g(data: {call_flow_target: "canvas"}) do |canvas|
        render_lifelines(canvas)
        messages.each { |m| render_message(canvas, m) }
        inline_media.each_with_index { |stream, i| render_media_row(canvas, stream, messages.size + i) }
      end
    end
  end

  private

  MONO = "var(--voodu-font-mono, ui-monospace, monospace)"

  def lifelines = @data.lifelines

  def messages = @data.messages

  # inline_media — RTP streams whose endpoints ARE lifelines, drawn as extra
  # rows after the SIP messages (sngrep-style). Off-lifeline media ("gap")
  # goes to the modal's footer, not here.
  def inline_media = @data.inline_media

  def row_count = messages.size + inline_media.size

  def width
    n = lifelines.size
    GUTTER + (MARGIN * 2) + ((n > 1) ? (n - 1) * col_gap : 60)
  end

  def height
    HEADER_H + TOP + (row_count * ROW_H) + BOTTOM
  end

  # col_gap — spread the lifelines across a comfortable width, clamped so
  # two parties don't sprawl and six don't crush together.
  def col_gap
    n = lifelines.size
    return 0 if n < 2

    (760 / (n - 1)).clamp(150, 300)
  end

  def col_x(index)
    GUTTER + MARGIN + (index * col_gap)
  end

  def row_y(index)
    HEADER_H + TOP + (index * ROW_H) + (ROW_H * 0.6)
  end

  # render_lifelines — the vertical party lines + their IP header boxes, drawn
  # INSIDE the transformed canvas group so they pan AND scale with the flow
  # (same size as the diagram at any zoom — no fixed-size overlay).
  def render_lifelines(s)
    lifelines.each_with_index do |ip, i|
      x = col_x(i)

      s.line(
        x1: x, x2: x, y1: HEADER_H, y2: height - BOTTOM,
        stroke: "var(--voodu-border)", "stroke-width": "1"
      )

      s.rect(
        x: x - (col_gap.positive? ? [col_gap / 2 - 6, 70].min : 70), y: 8,
        width: (col_gap.positive? ? [col_gap - 12, 140].min : 140), height: 24,
        rx: "3", fill: "var(--voodu-surface-2)", stroke: "var(--voodu-border)", "stroke-width": "1"
      )

      s.text(
        x: x, y: 24, "text-anchor": "middle",
        "font-size": "11", "font-family": MONO, fill: "var(--voodu-text)"
      ) { ip }
    end
  end

  # render_message — one arrow row: a rowbg (selection tint) + a full-width
  # hit rect (whole-row click) + the ts label + the arrow (line + head +
  # label). Wrapped in a targeted <g> so the controller can select it.
  def render_message(s, m)
    y = row_y(m[:index])
    color = KIND_COLOR.fetch(m[:kind], "var(--voodu-text-2)")

    s.g(
      class: "call-flow-arrow",
      style: "cursor: pointer;",
      data: {call_flow_target: "arrow", index: m[:index], cf_y: y.round, action: "click->call-flow#select"}
    ) do |g|
      g.rect(
        x: 0, y: y - (ROW_H * 0.6), width: width, height: ROW_H,
        fill: "transparent", data: {role: "rowbg"}
      )

      g.text(
        x: GUTTER - 10, y: y + 3, "text-anchor": "end",
        "font-size": "9.5", "font-family": "var(--voodu-font-mono, ui-monospace, monospace)",
        fill: "var(--voodu-muted-2)"
      ) { ts_label(m[:ts]) }

      render_arrow(g, m, y, color)
    end
  end

  def render_arrow(g, m, y, color)
    from = @data.column_index(m[:src])
    to = @data.column_index(m[:dst])

    return render_orphan(g, m, y, color) if from.nil? || to.nil?
    return render_self(g, m, y, color, from) if from == to

    x1 = col_x(from)
    x2 = col_x(to)
    dir = (x2 > x1) ? 1 : -1

    g.line(
      x1: x1, x2: x2 - (dir * 6), y1: y, y2: y,
      stroke: color, "stroke-width": "1.5"
    )
    arrowhead(g, x2, y, dir, color)
    arrow_label(g, m, (x1 + x2) / 2.0, y, color)
  end

  # render_self — src == dst (a message a node sends to itself, e.g. an
  # internal hop). Draw a small right-side loop off the lifeline.
  def render_self(g, m, y, color, col)
    x = col_x(col)

    g.path(
      d: "M #{x} #{y - 7} h 26 v 14 h -26",
      fill: "none", stroke: color, "stroke-width": "1.5"
    )
    arrowhead(g, x, y + 7, -1, color)
    g.text(
      x: x + 32, y: y - 1, "text-anchor": "start",
      "font-size": "10.5", "font-family": "var(--voodu-font-mono, ui-monospace, monospace)",
      fill: color
    ) { m[:label] }
  end

  # render_orphan — a message whose src/dst isn't among the resolved
  # lifelines (shouldn't happen, but never drop a message silently): show
  # the label at the left so it's still auditable.
  def render_orphan(g, m, y, color)
    g.text(
      x: GUTTER + 4, y: y + 3, "text-anchor": "start",
      "font-size": "10.5", "font-family": "var(--voodu-font-mono, ui-monospace, monospace)",
      fill: color
    ) { "#{m[:label]}  (#{m[:src]} → #{m[:dst]})" }
  end

  # render_media_row — a derived RTP stream as an extra ladder row: a DASHED
  # cyan line between the two media lifelines (both heads for sendrecv, one for
  # send/recvonly), labelled "RTP <codec>". Distinct dash + colour so it never
  # reads as a real SIP message.
  def render_media_row(s, stream, row_index)
    y = row_y(row_index)
    color = "var(--voodu-cyan)"
    x1 = col_x(stream[:from_col])
    x2 = col_x(stream[:to_col])
    lo, hi = [x1, x2].minmax

    s.g(class: "call-flow-media") do |g|
      g.text(
        x: GUTTER - 10, y: y + 3, "text-anchor": "end",
        "font-size": "9", "font-family": MONO, fill: "var(--voodu-muted-2)"
      ) { "rtp" }

      if lo == hi
        g.text(x: lo + 10, y: y - 1, "text-anchor": "start", "font-size": "10.5", "font-family": MONO, fill: color) { media_label(stream) }
      else
        g.line(x1: lo + 6, x2: hi - 6, y1: y, y2: y, stroke: color, "stroke-width": "1.5", "stroke-dasharray": "5 3")
        arrowhead(g, hi, y, 1, color)
        arrowhead(g, lo, y, -1, color) if stream[:direction] == "sendrecv"

        g.text(
          x: (x1 + x2) / 2.0, y: y - 7, "text-anchor": "middle",
          "font-size": "10.5", "font-family": MONO, fill: color
        ) { media_label(stream) }
      end
    end
  end

  # media_label — "RTP <codec>" (codec name without the clock rate).
  def media_label(stream)
    codec = stream[:codecs].first.to_s.split("/").first

    ["RTP", codec.presence].compact.join(" ")
  end

  def arrowhead(g, x, y, dir, color)
    base = x - (dir * 7)

    g.path(d: "M #{base} #{y - 4} L #{x} #{y} L #{base} #{y + 4} Z", fill: color)
  end

  def arrow_label(g, m, cx, y, color)
    g.text(
      x: cx, y: y - 7, "text-anchor": "middle",
      "font-size": "10.5", "font-family": "var(--voodu-font-mono, ui-monospace, monospace)",
      fill: color
    ) { m[:label] }
  end

  def ts_label(iso)
    time = Time.zone.parse(iso.to_s)
    return "" unless time

    WebTime.strftime(time, "%H:%M:%S") || ""
  rescue ArgumentError, TypeError
    ""
  end
end
