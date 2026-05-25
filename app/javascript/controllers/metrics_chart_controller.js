import { Controller } from "@hotwired/stimulus"

// MetricsChartController — hover crosshair + tooltip for the big
// chart on /metrics. Ported 1:1 from design-webui-inspiration/
// pages-metrics.jsx MetricChart's onMove/onLeave + the
// absolutely-positioned tooltip JSX (lines 221-331).
//
// Pre-projected points (with x/y already painted by the SVG)
// come in via data-metrics-chart-points-value; this controller
// only does:
//
//   1. find nearest point by x-distance from mouse
//   2. draw a dashed vertical line + outline circle at the point
//   3. position a dark mono tooltip near the point
//
// All visuals scoped to the chart container — multiple charts on
// the page are independent (each has its own controller instance).
//
// Why pre-projected coords (not re-derived in JS):
//   - The bezier math + nice-ceil + axis padding already lives in
//     the Phlex component; duplicating it in JS would create two
//     sources of truth for "where does point i land in viewBox?"
//     and they'd inevitably drift. Pre-computing on Rails-side
//     and passing the px coords through data-* keeps both sides
//     reading the same numbers.
export default class extends Controller {
  static targets = ["overlay"]
  static values  = {
    points:    { type: Array,  default: [] },
    color:     { type: String, default: "#7c5cff" },
    unit:      { type: String, default: "" },
    label:     { type: String, default: "" },
    width:     { type: Number, default: 600 },
    height:    { type: Number, default: 200 },
    padLeft:   { type: Number, default: 44 },
    padRight:  { type: Number, default: 12 },
    padTop:    { type: Number, default: 14 },
    padBottom: { type: Number, default: 22 }
  }

  connect() {
    this.svg = this.element.querySelector("svg")
    this.crosshair = null
    this.dot = null
    this.tooltip = null
  }

  disconnect() {
    this.clearHover()
    this.tooltip?.remove()
    this.tooltip = null
  }

  // move — mouse moved over the overlay rect. Translate the page
  // x to viewBox x (the SVG is `width: 100%` so they're not equal),
  // walk the points to find the nearest, paint crosshair + dot,
  // position tooltip.
  move(event) {
    if (!this.pointsValue || this.pointsValue.length === 0) return

    const overlay = event.currentTarget
    const rect = overlay.getBoundingClientRect()
    const mouseX = event.clientX - rect.left

    // Map mouseX (in CSS pixels relative to overlay) → viewBox X.
    // overlay starts at `padLeft` in viewBox space; its rendered
    // width is `rect.width` and represents `width - padLeft - padRight`
    // viewBox units.
    const innerVbW   = this.widthValue - this.padLeftValue - this.padRightValue
    const vbMouseX   = this.padLeftValue + (mouseX / rect.width) * innerVbW

    // Find nearest point in viewBox space.
    let nearest = this.pointsValue[0]
    let bestDx  = Infinity

    for (const p of this.pointsValue) {
      const dx = Math.abs(p.x - vbMouseX)
      if (dx < bestDx) {
        bestDx = dx
        nearest = p
      }
    }

    this.drawCrosshair(nearest.x, nearest.y)
    this.positionTooltip(nearest, rect)
  }

  leave() {
    this.clearHover()
    if (this.tooltip) this.tooltip.style.opacity = "0"
  }

  // drawCrosshair — vertical line through the hovered point +
  // outlined circle at the point. Both painted as direct SVG
  // children (above the area/line which are siblings).
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

    // Hover marker: <ellipse> with X/Y radii compensated for the
    // SVG's non-uniform scaling. The chart's SVG declares
    // preserveAspectRatio="none" + width=100% so it stretches in
    // both axes to fill its container. A plain <circle r="3.5">
    // would render as a horizontal ellipse on a wide modal
    // (~1100px wide, 480px tall ≈ 1.83× horizontal stretch). We
    // measure the actual rendered scale and inverse-scale the
    // viewBox radii so the visible dot lands as a perfect circle.
    //
    // Same correction for the stroke width (otherwise the outline
    // also stretches and looks like a fat oval).
    const svgRect = this.svg.getBoundingClientRect()
    const scaleX  = (svgRect.width  / this.widthValue)  || 1
    const scaleY  = (svgRect.height / this.heightValue) || 1
    const targetRadiusPx = 3.5
    const targetStrokePx = 2

    const dot = document.createElementNS(ns, "ellipse")
    dot.setAttribute("cx", x)
    dot.setAttribute("cy", y)
    dot.setAttribute("rx", targetRadiusPx / scaleX)
    dot.setAttribute("ry", targetRadiusPx / scaleY)
    dot.setAttribute("fill", "var(--voodu-bg-2)")
    dot.setAttribute("stroke", this.colorValue)
    dot.setAttribute("stroke-width", targetStrokePx / Math.min(scaleX, scaleY))
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

  // positionTooltip — absolutely-positioned div inside the chart
  // container (NOT body) so it inherits the page's z-stack but
  // stays anchored to the chart's coordinate system. Mirrors the
  // inspiration's `position: absolute, left/top relative to chart`.
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
    // container. overlayRect is the overlay's bounding rect;
    // overlay starts at viewBox padLeft and ends at width-padRight.
    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const innerVbH = this.heightValue - this.padTopValue - this.padBottomValue
    const scaleX   = overlayRect.width  / innerVbW
    const scaleY   = overlayRect.height / innerVbH

    // overlayRect is relative to viewport; we want coords relative
    // to the chart container (this.element) which IS the
    // tooltip's offsetParent (position: relative on the root div).
    const containerRect = this.element.getBoundingClientRect()
    const pxX = (overlayRect.left - containerRect.left) + (point.x - this.padLeftValue) * scaleX
    const pxY = (overlayRect.top  - containerRect.top)  + (point.y - this.padTopValue)  * scaleY

    // Tooltip dimensions only known after content is set.
    this.tooltip.style.opacity = "1"
    this.tooltip.style.left = "0px"
    this.tooltip.style.top  = "0px"
    const ttRect = this.tooltip.getBoundingClientRect()

    let left = pxX + 12
    let top  = Math.max(8, pxY - 30)

    // Flip horizontally if the tooltip would clip the right edge.
    const containerW = containerRect.width
    if (left + ttRect.width > containerW - 4) {
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

  // formatTs — RFC3339 → "YYYY-MM-DD HH:MM:SS UTC". Matches the
  // inspiration's window.formatDateTime fallback (a known-good
  // operator-readable shape).
  formatTs(iso) {
    if (!iso) return ""

    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return iso

    const pad = (n) => String(n).padStart(2, "0")
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ` +
           `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())} UTC`
  }

  formatRaw(v) {
    return `${Number(v).toFixed(1)}${this.unitValue}`
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]))
}

function escapeAttr(s) {
  return String(s).replace(/"/g, "&quot;")
}
