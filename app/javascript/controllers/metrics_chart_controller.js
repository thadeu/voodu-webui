import { Controller } from "@hotwired/stimulus"

// MetricsChartController — owns the responsive layout + hover
// crosshair/tooltip for Components::Metrics::Chart.
//
// Responsive (Option B):
//   The server renders the chart at viewBox=widthValue×heightValue
//   (default 600×200) as a no-JS fallback. On connect + on resize
//   this controller MEASURES the actual container width in CSS
//   pixels, rewrites the viewBox to `0 0 W heightValue`, and
//   reprojects every x-coordinate (path, axis ticks, spanning
//   lines, clip + overlay rects). After takeover, 1 SVG unit ==
//   1 CSS pixel, so `font-size="10"` paints at 10px no matter how
//   wide the container is — text never squishes, chart fills the
//   full available width.
//
//   `segmentsValue` is the gap-detected step-after path emitted
//   by the server with each point's x stored as a 0-1 ratio of
//   the inner chart area. We rebuild the line + area `d` attrs
//   on every resize by mapping `padLeft + xNorm * innerW`.
//
//   Y coordinates and Y-axis labels DON'T move on resize: the
//   chart's height is fixed (not container-relative), and the
//   left gutter stays at padLeft regardless of width.
//
// Hover:
//   move() walks the projected points to find the nearest x to
//   the cursor, then paints a dashed crosshair line + outlined
//   dot at that point and positions a dark mono tooltip. All
//   coordinates are in viewBox units (which equal CSS pixels
//   post-resize), so the hover lookup stays accurate as the
//   container reflows.
export default class extends Controller {
  static targets = [
    "svg",        // the inner <svg> (set programmatically too)
    "overlay",    // hover rect catching mouse events
    "line",       // <path> for the stroked curve
    "area",       // <path> for the gradient fill
    "clipRect",   // <rect> inside <clipPath>
    "hLine",      // gridlines + frame baseline (span padLeft → W-padRight)
    "xTick"       // X-axis tick labels (use data-x-tick-ratio)
  ]
  static values  = {
    points:     { type: Array,   default: [] },   // { ts, value, formatted, x, x_norm, y }
    segments:   { type: Array,   default: [] },   // [[[xNorm, y], ...], ...]
    color:      { type: String,  default: "#34d399" },
    unit:       { type: String,  default: "" },
    label:      { type: String,  default: "" },
    width:      { type: Number,  default: 600 },  // initial viewBox W, updated on resize
    height:     { type: Number,  default: 200 },
    padLeft:    { type: Number,  default: 44 },
    padRight:   { type: Number,  default: 12 },
    padTop:     { type: Number,  default: 14 },
    padBottom:  { type: Number,  default: 22 },
    baselineY:  { type: Number,  default: 178 },  // height - padBottom; precomputed server-side
    responsive: { type: Boolean, default: false },
    // IANA name of the operator's chosen display timezone, threaded
    // through from WebTime.zone_name server-side. Defaults to UTC
    // when callers don't set it (legacy + tests). The tooltip's
    // formatTs uses Intl.DateTimeFormat with this value so the
    // timestamp line reflects Settings → Display preferences.
    timezone:   { type: String,  default: "UTC" }
  }

  connect() {
    this.svg       = this.hasSvgTarget ? this.svgTarget : this.element.querySelector("svg")
    this.crosshair = null
    this.dot       = null
    this.tooltip   = null
    this.points    = this.pointsValue.map((p) => ({ ...p }))   // working copy with mutable x

    if (!this.responsiveValue) return

    // Use ResizeObserver so we react to ANY container width change
    // (drawer open/close, 1col↔2col flip, devtools opening, etc.)
    // — not just window resize.
    this.resizeObserver = new ResizeObserver(() => this.scheduleResize())
    this.resizeObserver.observe(this.element)

    // Initial fit. ResizeObserver fires once on observe in modern
    // browsers anyway, but explicit call keeps the first-paint
    // path predictable.
    this.resize()
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    if (this.resizeRaf) cancelAnimationFrame(this.resizeRaf)
    this.clearHover()
    this.tooltip?.remove()
    this.tooltip = null
  }

  // ── Resize pipeline ──────────────────────────────────────────

  // scheduleResize — coalesce multiple ResizeObserver callbacks
  // within one frame into a single resize(). Cheap; avoids
  // double-work when the browser fires entries in rapid succession.
  scheduleResize() {
    if (this.resizeRaf) return

    this.resizeRaf = requestAnimationFrame(() => {
      this.resizeRaf = null
      this.resize()
    })
  }

  resize() {
    const measured = this.element.getBoundingClientRect().width
    if (measured <= 0) return

    // Round down — sub-pixel viewBox widths confuse browser snap
    // and produce a 1-pixel gap at the right edge on some zoom
    // levels.
    const W = Math.floor(measured)
    if (W === this.widthValue && this.lastAppliedW === W) return

    this.widthValue    = W
    this.lastAppliedW  = W

    this.svg.setAttribute("viewBox", `0 0 ${W} ${this.heightValue}`)

    const innerW = W - this.padLeftValue - this.padRightValue
    if (innerW <= 0) return

    // Spanning rects (clip + overlay) — width = innerW, left edge
    // stays at padLeft.
    if (this.hasClipRectTarget) {
      this.clipRectTarget.setAttribute("width", innerW)
    }

    if (this.hasOverlayTarget) {
      this.overlayTarget.setAttribute("width", innerW)
    }

    // Spanning lines (gridlines + frame baseline). x1 stays at
    // padLeft; only x2 needs to move with W.
    const rightX = W - this.padRightValue
    this.hLineTargets.forEach((line) => line.setAttribute("x2", rightX))

    // X-axis tick labels — reposition via cached t ratio.
    this.xTickTargets.forEach((tick) => {
      const t = parseFloat(tick.dataset.xTickRatio)
      if (!Number.isFinite(t)) return

      tick.setAttribute("x", this.padLeftValue + t * innerW)
    })

    // Rebuild path d-strings from normalized segments.
    this.rebuildPaths(innerW)

    // Recompute each point's absolute x for hover nearest-x
    // lookup. y is unchanged.
    this.points.forEach((p, i) => {
      const norm = this.pointsValue[i]?.x_norm
      if (Number.isFinite(norm)) {
        p.x = this.padLeftValue + norm * innerW
      }
    })

    // If the hover marker is currently visible, drop it — its
    // x coords are stale post-rescale. Next mousemove repaints.
    this.clearHover()
  }

  rebuildPaths(innerW) {
    if (!this.segmentsValue || this.segmentsValue.length === 0) return

    const padL      = this.padLeftValue
    const baselineY = this.baselineYValue

    const lineSegs = this.segmentsValue.map((seg) =>
      seg.map(([xNorm, y]) => [padL + xNorm * innerW, y])
    )

    const lineD = lineSegs
      .map((seg) => segmentPath(seg))
      .filter((s) => s)
      .join(" ")

    const areaD = lineSegs
      .map((seg) => areaPath(seg, baselineY))
      .filter((s) => s)
      .join(" ")

    if (this.hasLineTarget) this.lineTarget.setAttribute("d", lineD)
    if (this.hasAreaTarget) this.areaTarget.setAttribute("d", areaD)
  }

  // ── Hover (largely unchanged from previous version) ─────────

  move(event) {
    if (!this.points || this.points.length === 0) return

    const overlay = event.currentTarget
    const rect    = overlay.getBoundingClientRect()
    if (rect.width <= 0) return

    // Cursor position within the inner chart area, 0..1. We match on `x_norm`
    // (width-independent) instead of the cached per-point pixel `x`: a resize
    // (card drag, column flip) can leave `p.x` lagging behind the new width
    // while x_norm is always right — that lag made wide cards' hover snap to
    // the wrong point and never reach the rightmost peak.
    const t = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))

    let nearest = this.points[0]
    let best    = Infinity

    for (const p of this.points) {
      const xn = Number.isFinite(p.x_norm) ? p.x_norm : 0
      const d  = Math.abs(xn - t)
      
      if (d < best) {
        best    = d
        nearest = p
      }
    }

    // Crosshair x in CURRENT viewBox units — recomputed from x_norm + the live
    // inner width, never the stale cached p.x.
    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const x = this.padLeftValue + (Number.isFinite(nearest.x_norm) ? nearest.x_norm : 0) * innerVbW

    this.drawCrosshair(x, nearest.y)
    this.positionTooltip({ ...nearest, x }, rect)
  }

  leave() {
    this.clearHover()
    if (this.tooltip) this.tooltip.style.opacity = "0"
  }

  drawCrosshair(x, y) {
    this.clearHover()

    const ns = "http://www.w3.org/2000/svg"

    const line = document.createElementNS(ns, "line")
    line.setAttribute("x1", x)
    line.setAttribute("x2", x)
    line.setAttribute("y1", this.padTopValue)
    line.setAttribute("y2", this.heightValue - this.padBottomValue)
    line.setAttribute("stroke", "var(--voodu-text-2)")
    line.setAttribute("stroke-opacity", "0.35")
    line.setAttribute("stroke-width", "1")
    line.setAttribute("pointer-events", "none")

    // Hover dot. With responsive Option B, scaleX == scaleY at
    // all times (viewBox is rewritten to match container px so
    // 1 SVG unit = 1 CSS pixel), so a plain <circle> renders as
    // a true circle — no inverse-scale compensation needed.
    const dot = document.createElementNS(ns, "circle")
    dot.setAttribute("cx", x)
    dot.setAttribute("cy", y)
    dot.setAttribute("r", "3.5")
    dot.setAttribute("fill", "var(--voodu-bg-2)")
    dot.setAttribute("stroke", this.colorValue)
    dot.setAttribute("stroke-width", "2")
    dot.setAttribute("pointer-events", "none")

    this.svg.appendChild(line)
    this.svg.appendChild(dot)

    this.crosshair = line
    this.dot       = dot
  }

  clearHover() {
    this.crosshair?.remove()
    this.dot?.remove()
    this.crosshair = null
    this.dot = null
  }

  positionTooltip(point, overlayRect) {
    this.ensureTooltip()

    const formatted = point.formatted || this.formatRaw(point.value)
    const tsLabel   = this.formatTs(point.ts)

    this.tooltip.innerHTML = `
      <div style="color: var(--voodu-muted-2, #6c7790); font-size: 10.5px;">${escapeHtml(tsLabel)}</div>
      <div style="color: ${escapeAttr(this.colorValue)}; font-weight: 600; margin-top: 2px;">
        ${escapeHtml(this.labelValue)}:
        <span style="font-variant-numeric: tabular-nums;">${escapeHtml(formatted)}</span>
      </div>
    `

    // Convert viewBox point.x/y → CSS px relative to the chart
    // container. With responsive takeover, viewBox W ≈ overlayRect.width,
    // so scale collapses to ≈1 — but compute it explicitly so the
    // pre-takeover snapshot also positions correctly.
    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const innerVbH = this.heightValue - this.padTopValue - this.padBottomValue
    const scaleX   = overlayRect.width  / innerVbW
    const scaleY   = overlayRect.height / innerVbH

    const containerRect = this.element.getBoundingClientRect()
    const pxX = (overlayRect.left - containerRect.left) + (point.x - this.padLeftValue) * scaleX
    const pxY = (overlayRect.top  - containerRect.top)  + (point.y - this.padTopValue)  * scaleY

    this.tooltip.style.opacity = "1"
    this.tooltip.style.left = "0px"
    this.tooltip.style.top  = "0px"
    const ttRect = this.tooltip.getBoundingClientRect()

    let left = pxX + 12
    let top  = Math.max(8, pxY - 30)

    if (left + ttRect.width > containerRect.width - 4) {
      left = pxX - ttRect.width - 12
    }

    this.tooltip.style.left = `${left}px`
    this.tooltip.style.top  = `${top}px`
  }

  ensureTooltip() {
    if (this.tooltip) return

    this.tooltip = document.createElement("div")

    Object.assign(this.tooltip.style, {
      position: "absolute",
      pointerEvents: "none",
      opacity: "0",
      transition: "opacity 0.12s ease",
      zIndex: "10",
      background: "var(--voodu-surface-3, #1c2330)",
      border: "1px solid var(--voodu-border-2, #1d2435)",
      padding: "6px 10px",
      fontFamily: "var(--voodu-font-mono, ui-monospace, SFMono-Regular, Menlo, monospace)",
      fontSize: "11.5px",
      lineHeight: "1.4",
      minWidth: "160px",
      boxShadow: "0 4px 12px rgba(0,0,0,0.5)",
      color: "var(--voodu-text, #e6ebf2)",
      whiteSpace: "nowrap"
    })

    this.element.appendChild(this.tooltip)
  }

  formatTs(iso) {
    if (!iso) return ""

    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return iso

    // Render in the operator's preferred timezone (Settings →
    // Display preferences). The TZ name comes through the
    // `timezoneValue` Stimulus value, populated server-side from
    // WebTime.zone_name. Falls back to "UTC" when the value is
    // missing (legacy callers / no operator preference set).
    const tz = this.hasTimezoneValue && this.timezoneValue ? this.timezoneValue : "UTC"
    try {
      const fmt = new Intl.DateTimeFormat("en-CA", {
        year:   "numeric",
        month:  "2-digit",
        day:    "2-digit",
        hour:   "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
        timeZone: tz,
        timeZoneName: "short"
      })
      // en-CA gives YYYY-MM-DD; the formatter returns parts like
      // "2026-05-27, 14:38:15 BRT". Reshape with a parts walker so
      // we get the exact "YYYY-MM-DD HH:MM:SS TZ" layout the
      // operator's been seeing.
      const parts = fmt.formatToParts(d).reduce((acc, p) => (acc[p.type] = p.value, acc), {})
      return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second} ${parts.timeZoneName || tz}`
    } catch (_e) {
      // Invalid IANA name → fall back to UTC rendering so the
      // tooltip still shows something coherent.
      const pad = (n) => String(n).padStart(2, "0")
      return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ` +
             `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())} UTC`
    }
  }

  formatRaw(v) {
    return `${Number(v).toFixed(1)}${this.unitValue}`
  }
}

// ── Path builders — mirror Components::Metrics::Chart#segment_path
// and #area_path_for so resize paths look identical to first paint.

function segmentPath(seg) {
  if (seg.length < 2) return ""

  let d = `M ${seg[0][0]} ${seg[0][1]}`

  for (let i = 1; i < seg.length; i++) {
    const prevY = seg[i - 1][1]
    const currX = seg[i][0]
    const currY = seg[i][1]
    d += ` L ${currX} ${prevY} L ${currX} ${currY}`
  }

  return d
}

function areaPath(seg, baselineY) {
  if (seg.length < 2) return ""

  return `${segmentPath(seg)} L ${seg[seg.length - 1][0]} ${baselineY} L ${seg[0][0]} ${baselineY} Z`
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]))
}

function escapeAttr(s) {
  return String(s).replace(/"/g, "&quot;")
}
