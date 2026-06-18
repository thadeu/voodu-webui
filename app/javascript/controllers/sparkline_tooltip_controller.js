import { Controller } from "@hotwired/stimulus"

// SparklineTooltipController — hover affordance for the area chart
// rendered by Components::UI::Sparkline. Pattern ported from
// clowk's chart_tooltip_controller (Phlex SVG + invisible rect
// overlays + fixed-position tooltip div), simplified for our case:
//
//   - single series (sparkline is one line — no stacking)
//   - dark theme (voodu surface palette, not clowk's light card)
//   - "active point" marker (small dot + dashed vertical line at
//     the hovered x — orient operator's eye)
//
// Markup pattern (rendered by the Sparkline component):
//
//   <svg data-controller="sparkline-tooltip" style="--voodu-spark-color: ...">
//     ... path / area / always-on tail dot (data-sparkline-tooltip-target="tailDot")
//     <rect data-sparkline-tooltip-target="strip"
//           data-action="mouseenter->sparkline-tooltip#show mouseleave->sparkline-tooltip#hide"
//           data-ts="2026-05-24T09:00:00Z"
//           data-value="12.4"
//           data-formatted="12.4%"
//           data-point-x="120" data-point-y="34" />
//     ...
//   </svg>
//
// The tooltip is appended to <body> so its `position: fixed`
// coordinates work regardless of any ancestor's overflow / transform.
// Connect lazily — the element is built on first hover and
// disposed on disconnect.
export default class extends Controller {
  static targets = ["strip", "tailDot"]

  connect() {
    this.tooltip = null
    this.activeDot = null
    this.activeLine = null
  }

  disconnect() {
    this.tooltip?.remove()
    this.activeDot?.remove()
    this.activeLine?.remove()
  }

  show(event) {
    const strip = event.currentTarget

    this.ensureTooltip()

    const formatted = strip.dataset.formatted || strip.dataset.value || ""
    const ts        = strip.dataset.ts || ""
    // tz follows the same data-attribute path as ts — the Phlex
    // Sparkline component stamps both at render time. Falls back
    // to "UTC" when missing so older renders keep working.
    const tz        = strip.dataset.tz || this.element.dataset.tz || "UTC"

    this.tooltip.innerHTML = renderContent(formatted, ts, this.accentColor, tz)
    this.tooltip.style.opacity = "1"

    this.drawActiveMarker(
      parseFloat(strip.dataset.pointX),
      parseFloat(strip.dataset.pointY)
    )

    this.positionTooltip(strip)

    // Hide the always-on tail dot while hovering — its sibling
    // active dot at the hovered point is the visual focus now.
    this.tailDotTargets.forEach((d) => d.setAttribute("opacity", "0"))
  }

  hide() {
    if (this.tooltip) this.tooltip.style.opacity = "0"

    this.removeActiveMarker()

    // Restore the tail dot's original opacity (halo=0.18, core=1).
    this.tailDotTargets.forEach((d, i) => {
      d.setAttribute("opacity", i === 0 ? "0.18" : "1")
    })
  }

  // ── internals ───────────────────────────────────────────────────

  get accentColor() {
    // Read the sparkline's color from the inline CSS variable the
    // Phlex component sets on the <svg>. Fallback to a sensible
    // muted accent so the tooltip dot is visible even if the
    // variable is missing.
    const raw = this.element.style.getPropertyValue("--voodu-spark-color").trim()

    return raw || "#34d399"
  }

  ensureTooltip() {
    if (this.tooltip) return

    this.tooltip = document.createElement("div")

    Object.assign(this.tooltip.style, {
      position: "fixed",
      pointerEvents: "none",
      opacity: "0",
      transition: "opacity 0.12s ease",
      zIndex: "60",
      background: "var(--voodu-surface-2, #161c27)",
      color: "var(--voodu-text, #e6ebf2)",
      border: "1px solid var(--voodu-border, #1d2435)",
      borderRadius: "4px",
      padding: "5px 8px",
      fontSize: "11px",
      lineHeight: "1.5",
      fontFamily: "var(--voodu-font-mono, ui-monospace, SFMono-Regular, Menlo, monospace)",
      boxShadow: "0 8px 20px rgba(0,0,0,0.4), 0 2px 4px rgba(0,0,0,0.3)",
      whiteSpace: "nowrap"
    })

    document.body.appendChild(this.tooltip)
  }

  // drawActiveMarker — adds a small filled dot + a dashed vertical
  // line at the hovered point. Both are children of the <svg> so
  // they share the same coordinate system as the path; appended
  // last so they render above everything.
  drawActiveMarker(px, py) {
    this.removeActiveMarker()

    const svg = this.element
    const ns = "http://www.w3.org/2000/svg"
    const color = this.accentColor

    const line = document.createElementNS(ns, "line")

    line.setAttribute("x1", px)
    line.setAttribute("y1", 0)
    line.setAttribute("x2", px)
    line.setAttribute("y2", svg.viewBox.baseVal.height || 56)
    line.setAttribute("stroke", color)
    line.setAttribute("stroke-width", "1")
    line.setAttribute("stroke-dasharray", "2,2")
    line.setAttribute("opacity", "0.65")
    line.setAttribute("pointer-events", "none")

    // Halo behind the dot — same trick as the always-on tail dot,
    // gives the active point a glow so it pops against the curve
    // even when the value matches the line's color near it.
    const halo = document.createElementNS(ns, "circle")

    halo.setAttribute("cx", px)
    halo.setAttribute("cy", py)
    halo.setAttribute("r", "6")
    halo.setAttribute("fill", color)
    halo.setAttribute("opacity", "0.25")
    halo.setAttribute("pointer-events", "none")

    const dot = document.createElementNS(ns, "circle")

    dot.setAttribute("cx", px)
    dot.setAttribute("cy", py)
    dot.setAttribute("r", "3.5")
    dot.setAttribute("fill", color)
    dot.setAttribute("stroke", "var(--voodu-bg, #0a0d14)")
    dot.setAttribute("stroke-width", "1.5")
    dot.setAttribute("pointer-events", "none")

    svg.appendChild(line)
    svg.appendChild(halo)
    svg.appendChild(dot)

    this.activeLine = line
    this.activeDot = dot
    this.activeHalo = halo
  }

  removeActiveMarker() {
    this.activeDot?.remove()
    this.activeHalo?.remove()
    this.activeLine?.remove()
    this.activeDot = null
    this.activeHalo = null
    this.activeLine = null
  }

  // positionTooltip — places the tooltip above the hovered point.
  // Anchor is the strip's mid-x converted from SVG viewBox units
  // to page pixels (the SVG is `width: 100%` with preserveAspectRatio
  // none, so the horizontal scale != 1 in general).
  //
  // Clamps to the viewport so a strip at the right edge doesn't
  // clip the tooltip. If there's no room ABOVE (sparkline near
  // the top of the screen), flip to BELOW.
  positionTooltip(strip) {
    const svgRect = this.element.getBoundingClientRect()
    const stripX  = parseFloat(strip.getAttribute("x"))
    const stripW  = parseFloat(strip.getAttribute("width"))
    const vbW     = this.element.viewBox.baseVal.width || svgRect.width

    const scaleX  = svgRect.width / vbW
    const centerX = svgRect.left + (stripX + stripW / 2) * scaleX

    // Force a layout to learn the tooltip's measured size.
    this.tooltip.style.left = "0px"
    this.tooltip.style.top  = "0px"

    const tRect = this.tooltip.getBoundingClientRect()
    const gap   = 6

    let x = centerX - tRect.width / 2
    let y = svgRect.top - tRect.height - gap

    if (x < 4) x = 4
    if (x + tRect.width > window.innerWidth - 4) x = window.innerWidth - tRect.width - 4
    if (y < 4) y = svgRect.bottom + gap

    this.tooltip.style.left = `${x}px`
    this.tooltip.style.top  = `${y}px`
  }
}

// renderContent — inline HTML for the tooltip body. Two lines:
//   1) accent-colored dot + the formatted value (big)
//   2) timestamp in HH:MM:SS (muted), only when ts is present
//
// Inline styles instead of CSS classes so the tooltip doesn't
// depend on a stylesheet load order — works even when grafted into
// <body> outside the component's scope.
function renderContent(formatted, ts, color, tz) {
  const tsLine = ts
    ? `<div style="color: var(--voodu-muted-2, #6c7790); font-size: 10px; margin-top: 2px;">${formatTs(ts, tz)}</div>`
    : ""

  return `
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style="display: inline-block; width: 6px; height: 6px; border-radius: 9999px; background: ${color};"></span>
      <span style="font-weight: 600; color: var(--voodu-text, #e6ebf2); font-variant-numeric: tabular-nums;">${escapeHtml(formatted)}</span>
    </div>
    ${tsLine}
  `
}

// formatTs — ISO → HH:MM:SS in the operator's CHOSEN timezone,
// not the browser's. The TZ name comes via the strip element's
// `data-tz` attribute (populated by Components::UI::Sparkline
// from WebTime.zone_name); falls back to UTC when missing so
// orphan tooltips still produce a sensible string.
//
// Why explicit timeZone rather than `toLocaleTimeString(undefined)`?
// Operators can remote-desktop / SSH from one TZ to a browser in
// another (or just prefer a different display TZ than the OS
// reports). The Settings → Display preferences is the source of
// truth across the whole app — sparkline tooltips honour it too.
function formatTs(iso, tz) {
  const d = new Date(iso)

  if (Number.isNaN(d.getTime())) return iso

  const zone = tz || "UTC"

  try {
    return new Intl.DateTimeFormat("en-GB", {
      hour:     "2-digit",
      minute:   "2-digit",
      second:   "2-digit",
      hour12:   false,
      timeZone: zone
    }).format(d)
  } catch (_e) {
    return d.toISOString().substring(11, 19)
  }
}

// escapeHtml — minimal guard for the `formatted` string. MetricsData
// emits its own (controlled) format, but defense-in-depth keeps a
// future caller from shipping a raw user-supplied string straight
// into innerHTML.
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]))
}
