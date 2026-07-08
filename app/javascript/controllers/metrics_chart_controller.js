import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { panelPref } from "../lib/panel_prefs"

// HIDDEN_SERIES_BY_CHART — legend hide/show selections that must OUTLIVE a
// realtime Turbo Stream refresh. Each refresh replaces the chart element, so the
// controller disconnects + a fresh one connects with in-memory state wiped. This
// module-level map bridges instances: stable chart id → Set of hidden series
// LABELS (labels survive a data refresh; array indices could shift). Cleared
// only on a full page reload — exactly the lifetime the operator expects.
const HIDDEN_SERIES_BY_CHART = new Map()

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
    "svg",        
    "overlay",    
    "line",       
    "area",       
    "clipRect",   
    "hLine",      
    "xTick",
    "bar",
    "dot",
    "legendItem"
  ]

  static values  = {
    points:     { type: Array,   default: [] },   
    segments:   { type: Array,   default: [] },   
    color:      { type: String,  default: "#34d399" },
    unit:       { type: String,  default: "" },
    label:      { type: String,  default: "" },
    width:      { type: Number,  default: 600 },  
    height:     { type: Number,  default: 200 },
    padLeft:    { type: Number,  default: 44 },
    padRight:   { type: Number,  default: 12 },
    padTop:     { type: Number,  default: 14 },
    padBottom:  { type: Number,  default: 22 },
    baselineY:  { type: Number,  default: 178 },  
    responsive: { type: Boolean, default: false },
    // IANA name of the operator's chosen display timezone, threaded
    // through from WebTime.zone_name server-side. Defaults to UTC
    // when callers don't set it (legacy + tests). The tooltip's
    // formatTs uses Intl.DateTimeFormat with this value so the
    // timestamp line reflects Settings → Display preferences.
    timezone:   { type: String,  default: "UTC" },
    // Path interpolation for the resize rebuild — "step" (area) or "linear"
    // (Line style, straight point-to-point). Keeps the rebuilt path matching
    // the server-rendered one.
    interp:     { type: String,  default: "step" },
    // Multi-series (pilot: Line). When true, `series` drives N lines instead of
    // the single `points`/`segments`. Each series: {label, color, points:[{ts,
    // value, formatted, x_norm, y}]} sharing the axes.
    multi:      { type: Boolean, default: false },
    series:     { type: Array,   default: [] },
    // Stable per-chart id (panel_key). Keys the persisted hidden-series set so a
    // stream refresh restores which lines the operator hid.
    key:        { type: String,  default: "" },
    // Set ONLY when the chart is rendered inside the expand modal — the
    // /metrics/chart endpoint URL (carrying this chart's metric/scope/
    // server params). Its presence flips applyZoom from a full-page
    // Turbo.visit (grid) to an in-modal turbo-stream re-fetch that keeps
    // the modal open.
    zoomUrl:    { type: String,  default: "" }
  }

  // Minimum drag width (fraction of the plot) to treat as a zoom rather than a
  // click — below this, a mousedown+up is just a hover, not a range select.
  MIN_BRUSH = 0.015

  connect() {
    this.svg       = this.hasSvgTarget ? this.svgTarget : this.element.querySelector("svg")
    this.crosshair = null
    this.dot       = null
    this.tooltip   = null
    this.points    = this.pointsValue.map((p) => ({ ...p }))

    if (this.multiValue) {
      this.setupMulti()
      // Re-apply any hidden lines restored from a prior instance (stream refresh)
      // so the reconnected chart paints them hidden on first frame.
      this.applySeriesStyles(null)
    }

    // "Show dots" per-panel pref (options menu). Restore it on connect — incl.
    // after a stream refresh — and react live to the menu's toggle event.
    this.applyShowDots(panelPref(this.keyValue, "dots", true))

    this.onPanelOptions = (e) => {
      if (e.detail?.key === this.keyValue) this.applyShowDots(e.detail.dots)
    }

    window.addEventListener("panel-options:change", this.onPanelOptions)

    // Brush-to-zoom state. onBrush* are document-level so a drag keeps
    // tracking even when the cursor leaves the chart mid-select.
    this.brushing    = false
    this.brushRect   = null
    this.onBrushMove = this.brushMove.bind(this)
    this.onBrushEnd  = this.brushEnd.bind(this)

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
    this.endBrushListeners()
    if (this.onPanelOptions) window.removeEventListener("panel-options:change", this.onPanelOptions)
    this.clearBrush()
    this.clearHover()
    this.tooltip?.remove()
    this.tooltip = null
  }

  // applyShowDots — the options-menu "Show dots" toggle. Uses `display` (not
  // opacity) so it composes cleanly with the per-series opacity from
  // applySeriesStyles: dots-off hides every dot regardless of series state, and
  // dots-on hands control back to the series visibility. The dynamic hover
  // marker isn't a dot target, so hovering still shows a point either way.
  applyShowDots(show) {
    this.dotTargets.forEach((d) => { d.style.display = show ? "" : "none" })
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

    // Multi-series: one line per series, rebuilt from seriesValue. Its dots
    // ride the shared dotTargets loop below (each carries data-x-norm).
    if (this.multiValue) this.rebuildMultiPaths(innerW)

    // Reposition bars (bars mode has no path to rebuild): each rect carries
    // its normalized x + width, so it tracks the new inner width instead of
    // staying in the server's original coordinate space (which clipped/hid
    // them on resize).
    this.barTargets.forEach((bar) => {
      const xn = parseFloat(bar.dataset.xNorm)
      const wn = parseFloat(bar.dataset.wNorm)

      if (Number.isFinite(xn)) bar.setAttribute("x", this.padLeftValue + xn * innerW)
      if (Number.isFinite(wn)) bar.setAttribute("width", Math.max(0.8, wn * innerW))
    })

    // Line-style dots: cx tracks the new inner width via each dot's normalized
    // x. cy is value-based, so it doesn't move when only the width changes.
    this.dotTargets.forEach((dot) => {
      const xn = parseFloat(dot.dataset.xNorm)

      if (Number.isFinite(xn)) dot.setAttribute("cx", this.padLeftValue + xn * innerW)
    })

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

    const buildLine = this.interpValue === "linear" ? linearPath : segmentPath

    const lineD = lineSegs
      .map((seg) => buildLine(seg))
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
    if (this.brushing) return
    if (this.multiValue) return this.moveMulti(event)
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

    // Step styles (bars + area) draw each value as a block that STARTS at the
    // point's x — so the raw point sits at the block's LEFT edge, and hovering
    // there reads as "in the gap / on the corner". Anchor the hover to the
    // block CENTER instead (both the nearest-point match AND the drawn marker),
    // so it lands mid-bar. Line is linear — its point is a vertex, no nudge.
    const off = this.interpValue === "step" ? this.bucketHalfNorm() : 0

    let nearest = this.points[0]
    let best    = Infinity

    for (const p of this.points) {
      const xn = (Number.isFinite(p.x_norm) ? p.x_norm : 0) + off
      const d  = Math.abs(xn - t)

      if (d < best) {
        best    = d
        nearest = p
      }
    }

    // Crosshair x in CURRENT viewBox units — recomputed from x_norm + the live
    // inner width, never the stale cached p.x.
    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const x = this.padLeftValue + ((Number.isFinite(nearest.x_norm) ? nearest.x_norm : 0) + off) * innerVbW

    this.drawCrosshair(x, nearest.y)
    this.positionTooltip({ ...nearest, x }, rect)
  }

  // bucketHalfNorm — half the typical point spacing (in x_norm units), i.e. how
  // far right of a point its bucket's center sits. Median-based so a lone
  // appended "latest" point doesn't skew it; cached (x_norm is width-independent
  // so it never changes after connect).
  bucketHalfNorm() {
    if (this._bucketHalf != null) return this._bucketHalf

    const xs = (this.pointsValue || [])
      .map((p) => p.x_norm)
      .filter(Number.isFinite)
      .sort((a, b) => a - b)

    const diffs = []

    for (let i = 1; i < xs.length; i++) diffs.push(xs[i] - xs[i - 1])

    if (diffs.length === 0) return (this._bucketHalf = 0)

    diffs.sort((a, b) => a - b)

    return (this._bucketHalf = diffs[Math.floor(diffs.length / 2)] / 2)
  }

  leave() {
    this.clearHover()
    if (this.tooltip) this.tooltip.style.opacity = "0"
  }

  // ── Multi-series (pilot: Line) ─────────────────────────────────────────────

  setupMulti() {
    this.multiSeries = (this.seriesValue || []).map((s) => ({
      label: s.label,
      color: s.color,
      points: (s.points || []).map((p) => ({ ...p }))
    }))

    // Series indices the operator hid (legend toggle). Empty = all visible.
    // Seeded from the module store so a hidden line stays hidden across a stream
    // refresh; matched by LABEL since a refresh can't be trusted to keep indices.
    const persisted = HIDDEN_SERIES_BY_CHART.get(this.chartKey())

    this.hiddenSeries = new Set()

    if (persisted) {
      this.multiSeries.forEach((s, idx) => { if (persisted.has(s.label)) this.hiddenSeries.add(idx) })
    }

    // Union of buckets by ts, sorted by x_norm — the hover's nearest-x index.
    const byTs = new Map()

    for (const s of this.multiSeries) {
      for (const p of s.points) {
        if (!byTs.has(p.ts)) byTs.set(p.ts, { ts: p.ts, x_norm: p.x_norm })
      }
    }

    this.multiIndex = [...byTs.values()].sort((a, b) => a.x_norm - b.x_norm)
  }

  // ── Legend interaction (hover-spotlight + click-toggle) ────────────────────

  // highlightSeries — legend hover: spotlight the hovered line by dimming every
  // OTHER visible line (+ its dots + legend entry). Hidden lines stay hidden.
  highlightSeries(event) {
    if (!this.multiValue) return

    const idx = parseInt(event.currentTarget.dataset.seriesIndex, 10)

    if (!Number.isInteger(idx)) return

    this.applySeriesStyles(idx)
  }

  // unhighlightSeries — legend mouseleave: restore every visible line to full
  // opacity (hidden ones stay hidden).
  unhighlightSeries() {
    if (!this.multiValue) return

    this.applySeriesStyles(null)
  }

  // toggleSeries — legend click: hide/show this line (+ its dots). The cursor is
  // still on the entry, so re-showing spotlights it; hiding clears the highlight
  // and drops it from the hover tooltip.
  toggleSeries(event) {
    if (!this.multiValue) return

    const idx = parseInt(event.currentTarget.dataset.seriesIndex, 10)

    if (!Number.isInteger(idx)) return

    if (this.hiddenSeries.has(idx)) this.hiddenSeries.delete(idx)
    else this.hiddenSeries.add(idx)

    this.persistHidden()

    const nowHidden = this.hiddenSeries.has(idx)

    event.currentTarget.setAttribute("aria-pressed", nowHidden ? "false" : "true")
    this.applySeriesStyles(nowHidden ? null : idx)
    this.clearHover()
  }

  // chartKey — the stable id the hidden-series set is stored under. The panel_key
  // (keyValue) on a dashboard; otherwise the label + the series-label set, which
  // is stable across a pure data refresh of the same panel.
  chartKey() {
    if (this.hasKeyValue && this.keyValue) return this.keyValue

    return `${this.labelValue}::${(this.seriesValue || []).map((s) => s.label).join(",")}`
  }

  // persistHidden — mirror the current hidden set (as LABELS) into the module
  // store so the next instance (post stream-refresh) restores it. Drops the entry
  // when nothing is hidden so the map doesn't grow unbounded.
  persistHidden() {
    const labels = new Set()

    this.multiSeries.forEach((s, idx) => { if (this.hiddenSeries.has(idx)) labels.add(s.label) })

    if (labels.size) HIDDEN_SERIES_BY_CHART.set(this.chartKey(), labels)
    else HIDDEN_SERIES_BY_CHART.delete(this.chartKey())
  }

  // applySeriesStyles — single source of truth for per-series opacity. A hidden
  // series is invisible; with a highlight set, non-highlighted VISIBLE series dim
  // to a faint ghost; otherwise everything visible is full-strength. The legend
  // entry mirrors the state (dim + strike-through when hidden).
  applySeriesStyles(highlightIdx = null) {
    if (!this.multiSeries) return

    this.multiSeries.forEach((s, idx) => {
      const hidden = this.hiddenSeries.has(idx)
      const dimmed = !hidden && highlightIdx != null && highlightIdx !== idx
      const markOpacity = hidden ? "0" : (dimmed ? "0.15" : "1")

      const line = this.lineForIndex(idx)

      if (line) line.style.opacity = markOpacity

      this.dotsForIndex(idx).forEach((d) => { d.style.opacity = markOpacity })
      // Area multi: the fill dims/hides in lockstep with its line.
      this.areasForIndex(idx).forEach((a) => { a.style.opacity = markOpacity })

      const item = this.legendForIndex(idx)

      if (!item) return

      item.style.opacity = (hidden || dimmed) ? "0.4" : "1"
      // Keep aria-pressed truthful on every apply — including a restore after a
      // stream refresh, where the server re-rendered the button as pressed.
      item.setAttribute("aria-pressed", hidden ? "false" : "true")

      const label = item.querySelector("[data-legend-label]")

      if (label) label.style.textDecoration = hidden ? "line-through" : "none"
    })
  }

  lineForIndex(idx) {
    return this.lineTargets.find((p) => parseInt(p.dataset.seriesIndex, 10) === idx)
  }

  dotsForIndex(idx) {
    return this.dotTargets.filter((d) => parseInt(d.dataset.seriesIndex, 10) === idx)
  }

  legendForIndex(idx) {
    return this.legendItemTargets.find((el) => parseInt(el.dataset.seriesIndex, 10) === idx)
  }

  areasForIndex(idx) {
    return this.areaTargets.filter((a) => parseInt(a.dataset.seriesIndex, 10) === idx)
  }

  moveMulti(event) {
    if (!this.multiIndex || this.multiIndex.length === 0) return

    const overlay = event.currentTarget
    const rect    = overlay.getBoundingClientRect()

    if (rect.width <= 0) return

    const t = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))

    let nearest = this.multiIndex[0]
    let best    = Infinity

    for (const e of this.multiIndex) {
      const d = Math.abs(e.x_norm - t)

      if (d < best) {
        best    = d
        nearest = e
      }
    }

    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const x = this.padLeftValue + nearest.x_norm * innerVbW

    const dots = []
    const rows = []

    this.multiSeries.forEach((s, idx) => {
      // A legend-hidden line drops out of the crosshair + tooltip entirely.
      if (this.hiddenSeries.has(idx)) return

      const p = s.points.find((pp) => pp.ts === nearest.ts)

      if (!p) return

      dots.push({ x, y: p.y, color: s.color })
      rows.push({ label: s.label, color: s.color, formatted: (p.formatted != null) ? p.formatted : this.formatRaw(p.value) })
    })

    this.drawCrosshairMulti(x, dots)
    this.positionTooltipMulti(x, dots[0] ? dots[0].y : this.padTopValue, nearest.ts, rows, rect)
  }

  drawCrosshairMulti(x, dots) {
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
    this.svg.appendChild(line)
    this.crosshair = line

    this.hoverDots = dots.map((d) => {
      const dot = document.createElementNS(ns, "circle")

      dot.setAttribute("cx", d.x)
      dot.setAttribute("cy", d.y)
      dot.setAttribute("r", "3.5")
      dot.setAttribute("fill", "var(--voodu-bg-2)")
      dot.setAttribute("stroke", d.color)
      dot.setAttribute("stroke-width", "2")
      dot.setAttribute("pointer-events", "none")
      this.svg.appendChild(dot)

      return dot
    })
  }

  positionTooltipMulti(x, y, ts, rows, overlayRect) {
    this.ensureTooltip()

    const rowsHtml = rows.map((r) => `
      <div style="color: ${escapeAttr(r.color)}; font-weight: 600; margin-top: 2px;">
        ${escapeHtml(r.label)}:
        <span style="font-variant-numeric: tabular-nums;">${escapeHtml(r.formatted)}</span>
      </div>`).join("")

    this.tooltip.innerHTML = `
      <div style="color: var(--voodu-muted-2, #6c7790); font-size: 10.5px;">${escapeHtml(this.formatTs(ts))}</div>
      ${rowsHtml}
    `

    this.placeTooltip(x, y, overlayRect)
  }

  // rebuildMultiPaths — one line (+ Area fill) per series, d rebuilt from
  // seriesValue on resize (each path carries data-series-index). Dots ride
  // dotTargets.
  rebuildMultiPaths(innerW) {
    const padL      = this.padLeftValue

    const ptsFor    = (idx) => {
      const s = this.seriesValue[idx]

      return s ? (s.points || []).map((p) => [padL + p.x_norm * innerW, p.y]) : null
    }

    this.lineTargets.forEach((path) => {
      const pts = ptsFor(parseInt(path.dataset.seriesIndex, 10))

      if (pts) path.setAttribute("d", linearPath(pts))
    })

    this.areaTargets.forEach((path) => {
      const pts = ptsFor(parseInt(path.dataset.seriesIndex, 10))

      if (pts) path.setAttribute("d", linearAreaPath(pts, this.baselineYValue))
    })
  }

  // timeBoundsMs — [firstMs, lastMs] across the data (single or multi), for
  // brush-to-zoom's from/until. null when there aren't 2 distinct timestamps.
  timeBoundsMs() {
    const iso = this.multiValue
      ? (this.seriesValue || []).flatMap((s) => (s.points || []).map((p) => p.ts))
      : (this.pointsValue || []).map((p) => p.ts)

    const times = iso.map((ts) => Date.parse(ts)).filter(Number.isFinite)

    if (times.length < 2) return null

    const first = Math.min(...times)
    const last  = Math.max(...times)

    return last > first ? [first, last] : null
  }

  // ── Brush-to-zoom (area/line only; wired from chart.rb) ─────
  // Drag horizontally to pick a time range; on release, reload the page at
  // range=custom&from&until for that slice. A click / micro-drag is ignored so
  // the overlay stays a hover surface.
  brushStart(event) {
    if (event.button !== 0) return

    const n = this.multiValue ? (this.multiIndex?.length || 0) : (this.points?.length || 0)

    if (n < 2) return

    event.preventDefault()
    this.clearHover()
    if (this.tooltip) this.tooltip.style.opacity = "0"

    this.brushing    = true
    this.brushOverlay = event.currentTarget
    this.brushStartT  = this.ratioAt(event)
    this.drawBrush(this.brushStartT, this.brushStartT)

    document.addEventListener("mousemove", this.onBrushMove)
    document.addEventListener("mouseup", this.onBrushEnd)
  }

  brushMove(event) {
    if (!this.brushing) return

    this.drawBrush(this.brushStartT, this.ratioAt(event))
  }

  brushEnd(event) {
    if (!this.brushing) return

    this.endBrushListeners()
    this.brushing = false

    const endT = this.ratioAt(event)
    const lo   = Math.min(this.brushStartT, endT)
    const hi   = Math.max(this.brushStartT, endT)

    this.clearBrush()

    if (hi - lo < this.MIN_BRUSH) return

    this.applyZoom(lo, hi)
  }

  endBrushListeners() {
    document.removeEventListener("mousemove", this.onBrushMove)
    document.removeEventListener("mouseup", this.onBrushEnd)
  }

  // ratioAt — cursor x as a clamped 0..1 across the overlay's plot area (same
  // basis as the hover `t`).
  ratioAt(event) {
    const rect = this.brushOverlay.getBoundingClientRect()

    if (rect.width <= 0) return 0

    return Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))
  }

  drawBrush(t1, t2) {
    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const lo = Math.min(t1, t2)
    const hi = Math.max(t1, t2)

    if (!this.brushRect) {
      const ns = "http://www.w3.org/2000/svg"

      this.brushRect = document.createElementNS(ns, "rect")
      this.brushRect.setAttribute("y", this.padTopValue)
      this.brushRect.setAttribute("height", this.heightValue - this.padTopValue - this.padBottomValue)
      this.brushRect.setAttribute("fill", this.colorValue)
      this.brushRect.setAttribute("fill-opacity", "0.15")
      this.brushRect.setAttribute("stroke", this.colorValue)
      this.brushRect.setAttribute("stroke-opacity", "0.5")
      this.brushRect.setAttribute("stroke-width", "1")
      this.brushRect.setAttribute("pointer-events", "none")
      this.svg.appendChild(this.brushRect)
    }

    this.brushRect.setAttribute("x", this.padLeftValue + lo * innerVbW)
    this.brushRect.setAttribute("width", Math.max(0, (hi - lo) * innerVbW))
  }

  clearBrush() {
    this.brushRect?.remove()
    this.brushRect = null
  }

  // applyZoom — map the [lo, hi] ratio to a UTC [from, until] from the points'
  // own timestamps and reload at range=custom (which freezes live polling on
  // the frozen window). metrics reads from/until off the query string.
  //
  // Two targets:
  //   - In the expand modal (zoomUrlValue set): re-fetch the modal body at
  //     the brushed window as a turbo-stream and render it in place, so the
  //     modal stays open (a full-page visit would tear it down).
  //   - On the grid (no zoomUrlValue): navigate the whole /metrics page.
  applyZoom(lo, hi) {
    const bounds = this.timeBoundsMs()

    if (!bounds) return

    const [first, last] = bounds
    const span  = last - first
    const from  = new Date(first + lo * span).toISOString()
    const until = new Date(first + hi * span).toISOString()

    if (this.zoomUrlValue) {
      this.zoomInModal(from, until)

      return
    }

    const url = new URL(window.location.href)

    url.searchParams.set("range", "custom")
    url.searchParams.set("from", from)
    url.searchParams.set("until", until)

    Turbo.visit(url.toString())
  }

  // zoomInModal — re-fetch /metrics/chart (zoomUrlValue) at range=custom for
  // the brushed [from, until] and let Turbo apply the returned stream. The
  // endpoint replaces #chart-modal-body (and re-opens the already-open modal
  // idempotently), so the modal survives the zoom.
  async zoomInModal(from, until) {
    const url = new URL(this.zoomUrlValue, window.location.origin)

    url.searchParams.set("range", "custom")
    url.searchParams.set("from", from)
    url.searchParams.set("until", until)

    const res = await fetch(url.toString(), {
      headers:     { Accept: "text/vnd.turbo-stream.html" },
      credentials: "same-origin"
    })

    if (!res.ok) return

    const html = await res.text()

    Turbo.renderStreamMessage(html)
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

    if (this.hoverDots) {
      this.hoverDots.forEach((d) => d.remove())
      this.hoverDots = null
    }
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

    this.placeTooltip(point.x, point.y, overlayRect)
  }

  // placeTooltip — convert a viewBox (vbX, vbY) into CSS px relative to the
  // chart container and position the (already-filled) tooltip near it, flipping
  // left when it would overflow the right edge. Shared by single + multi.
  placeTooltip(vbX, vbY, overlayRect) {
    const innerVbW = this.widthValue - this.padLeftValue - this.padRightValue
    const innerVbH = this.heightValue - this.padTopValue - this.padBottomValue
    const scaleX   = overlayRect.width  / innerVbW
    const scaleY   = overlayRect.height / innerVbH

    const containerRect = this.element.getBoundingClientRect()
    const pxX = (overlayRect.left - containerRect.left) + (vbX - this.padLeftValue) * scaleX
    const pxY = (overlayRect.top  - containerRect.top)  + (vbY - this.padTopValue)  * scaleY

    this.tooltip.style.opacity = "1"
    this.tooltip.style.left = "0px"
    this.tooltip.style.top  = "0px"
    const ttRect = this.tooltip.getBoundingClientRect()

    let left = pxX + 12
    const top  = Math.max(8, pxY - 30)

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

// linearPath — straight diagonal point-to-point ("raio"), the Line style's
// look. Mirrors Chart#linear_segment_path so a resize rebuild matches the
// server-rendered stroke.
function linearPath(seg) {
  if (seg.length < 2) return ""

  return "M " + seg.map(([x, y]) => `${x} ${y}`).join(" L ")
}

// linearAreaPath — the Area multi fill: the raio stroke closed down to the
// baseline. Mirrors Chart#linear_area_path so a resize rebuild matches paint.
function linearAreaPath(seg, baselineY) {
  if (seg.length < 2) return ""

  return `${linearPath(seg)} L ${seg[seg.length - 1][0]} ${baselineY} L ${seg[0][0]} ${baselineY} Z`
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
