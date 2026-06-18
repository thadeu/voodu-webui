import { Controller } from "@hotwired/stimulus"

// MetricsDisplayController — wraps the chart-grid content inside the
// metrics-charts turbo-frame. Three responsibilities:
//
//   1. Hide cards whose metric key is in the operator's hidden set
//   2. Reorder cards to match the operator's saved order
//   3. Pick an effective grid column count based on visible card
//      count + the operator's cols preference
//
// Smart layout rules (3rd responsibility):
//
//   visible == 1 → 1 col (full width, regardless of saved cols)
//   visible == 2 → 2 cols
//   visible >= 3 → operator's saved cols (default 2; 2 | 3 | 4)
//
// On viewport below vmd (1100px) — always 1 col, matchMedia gates
// the override so mobile stays stacked.
//
// Targets:
//   card — each chart card (data-metric-key="cpu_percent")
//   grid — the grid container whose grid-template-columns we mutate
//
// Values:
//   kind — sessionStorage namespace
//
// Lifecycle:
//   connect()    — applyState() on mount + after each turbo-frame swap
//   disconnect() — removes window/media listeners
//
// Re-apply triggers:
//   - Turbo-frame swap → reconnect → applyState
//   - metrics-display:changed event (Update in drawer) → applyState
//   - matchMedia('(min-width: 1100px)') change → applyLayout
//
// Default-visible principle: hidden is an EXPLICIT list. New metrics
// added in a future release land visible at the end of the order.

// BASE_COLS — the resize canvas is a fine 60-track grid. The operator's
// "columns" preference (2|3|4) picks the DEFAULT span (60/cols → 30|20|15), so
// a 2-up layout looks identical (the inter-track gaps absorb into each card),
// but the boundary resizes in 1/60 steps — fine enough to follow the cursor
// smoothly instead of snapping in coarse column chunks. 60 is the safe ceiling
// for gap-3 (59 gaps must still fit the narrowest vmd+ grid). Per-card spans
// persist in sixtieths under v3 (v2 was twelfths — bumped so old values don't
// render tiny on the finer grid).
const BASE_COLS = 60
const SIZES_KEY = "voodu:metrics:sizes:v3"

export default class extends Controller {
  static targets = ["card", "grid"]
  static values  = { kind: String }

  connect() {
    this.handleChanged = this.applyState.bind(this)
    this.handleResize  = this.applyLayout.bind(this)
    this.onResizeMove  = this.onResizeMove.bind(this)
    this.onResizeEnd   = this.onResizeEnd.bind(this)

    this.mediaQuery = window.matchMedia("(min-width: 1100px)")
    this.mediaQuery.addEventListener("change", this.handleResize)

    window.addEventListener("metrics-display:changed", this.handleChanged)

    this.applyState()
  }

  disconnect() {
    window.removeEventListener("metrics-display:changed", this.handleChanged)
    this.mediaQuery?.removeEventListener("change", this.handleResize)
    this.onResizeEnd()
  }

  applyState() {
    const cfg = this.readConfig()

    this.applyHidden(cfg.hidden)
    this.applyOrder(cfg.order)
    this.applyLayout(cfg.cols)
  }

  applyHidden(hiddenList) {
    const hidden = new Set(hiddenList)

    this.cardTargets.forEach(card => {
      card.hidden = hidden.has(card.dataset.metricKey)
    })
  }

  applyOrder(orderList) {
    if (!orderList || orderList.length === 0) return
    if (this.cardTargets.length === 0) return

    const grid = this.hasGridTarget
      ? this.gridTarget
      : this.cardTargets[0].parentElement

    if (!grid) return

    const byMetric = new Map(this.cardTargets.map(c => [c.dataset.metricKey, c]))

    orderList.forEach(metric => {
      const card = byMetric.get(metric)

      if (card) grid.appendChild(card)
    })

    this.cardTargets.forEach(card => {
      if (!orderList.includes(card.dataset.metricKey)) {
        grid.appendChild(card)
      }
    })
  }

  // applyLayout — pick the effective column count and write it
  // directly to grid-template-columns. Mobile (<vmd) always defers
  // to the Tailwind grid-cols-1 class by clearing the inline style.
  //
  // cols argument is optional; when omitted, the value is re-read
  // from sessionStorage (used by the matchMedia change handler).
  applyLayout(cols) {
    if (!this.hasGridTarget) return

    if (cols == null || typeof cols === "object") {
      cols = this.readConfig().cols
    }

    const visibleCount = this.cardTargets.filter(c => !c.hidden).length

    // perRow → the DEFAULT cards-per-row; the default span is BASE_COLS/perRow.
    let perRow

    if (visibleCount <= 1)       perRow = 1
    else if (visibleCount === 2) perRow = 2
    else                         perRow = cols || 2

    if (this.mediaQuery.matches) {
      this.gridTarget.style.gridTemplateColumns = `repeat(${BASE_COLS}, minmax(0, 1fr))`
      this.baseCols    = BASE_COLS
      this.defaultSpan = Math.max(1, Math.round(BASE_COLS / perRow))
    } else {
      this.gridTarget.style.gridTemplateColumns = ""
      this.baseCols    = 1
      this.defaultSpan = 1
    }

    // Per-card spans ride on top — re-applied whenever the layout changes.
    this.applySizes()
  }

  // ── per-card width (column span) ───────────────────────────────────────────
  // A card's width = how many of the N grid columns it spans (1..N). Stored
  // per metric key in its own sessionStorage slice so it never clobbers the
  // Settings drawer's {hidden, order, cols} blob.

  applySizes(sizes) {
    if (!this.hasGridTarget) return

    const map  = sizes || this.readSizes()
    const base = this.baseCols || 1
    const def  = this.defaultSpan || 1

    this.cardTargets.forEach(card => {
      // Mobile (single track) — let the Tailwind grid-cols-1 win.
      if (base <= 1) {
        card.style.gridColumn = ""

        return
      }

      // Custom width (sixtieths) if the operator resized this card, else the
      // default span derived from the columns preference.
      const span = Math.min(base, Math.max(1, map[card.dataset.metricKey] || def))

      card.style.gridColumn = `span ${span}`
    })

    // Non-card grid items (the "no running replica" placeholders) aren't
    // resizable, but still need the default span or they collapse to 1/12.
    const cards = new Set(this.cardTargets)

    Array.from(this.gridTarget.children).forEach(child => {
      if (cards.has(child)) return

      child.style.gridColumn = base <= 1 ? "" : `span ${def}`
    })

    this.fillRows()
  }

  // fillRows — stretch the LAST item of every row to the row end so a row is
  // always full (flex-1 last). Rows are derived by walking the items in DOM
  // order and summing spans against the 12-track base — the same order CSS
  // grid auto-flow packs them, so the math matches the layout. A no-op once
  // spans already fill (a resized row stays full because pairs preserve their
  // total); it's what closes the default gap (e.g. 3 cards × span 3 = 9/12).
  fillRows() {
    if (!this.hasGridTarget) return

    const base = this.baseCols || 1

    if (base <= 1) return

    const items = Array.from(this.gridTarget.children).filter(el => !el.hidden)
    let rowSpan = 0 // span already placed on the current row, before this item

    items.forEach((item, i) => {
      const span = this.spanOf(item)

      if (rowSpan + span > base) rowSpan = 0 // this item wraps to a fresh row

      const next     = items[i + 1]
      const nextSpan = next ? this.spanOf(next) : Infinity
      const lastOfRow = !next || (rowSpan + span + nextSpan > base)

      if (lastOfRow) {
        item.style.gridColumn = `span ${base - rowSpan}` // fill to the row end
        rowSpan = 0
      } else {
        rowSpan += span
      }
    })
  }

  // startResize — pointer-down on a card edge handle. SPLIT-PANE model: the
  // handle moves the BOUNDARY between this card and its same-row neighbour on
  // that side. The pair's total span is held constant, so this card grows by
  // exactly what the neighbour gives up (and vice versa) — nothing else on the
  // page reflows. No same-row neighbour on that side → no-op (a card at the
  // row edge has nothing to trade with). No-op on mobile (single column).
  startResize(event) {
    if (!this.mediaQuery.matches || !this.hasGridTarget) return

    const handle = event.currentTarget
    const card   = handle.closest("[data-metrics-display-target='card']")

    if (!card) return

    // Move the boundary with the same-row neighbour on this edge: their
    // combined span is held constant, so only the boundary slides — nothing
    // else reflows. No neighbour on that side (row edge) → no-op; the last
    // card of a row is the flex filler (fillRows), so its outer edge has
    // nothing to trade with.
    const neighbor = this.rowNeighbor(card, handle.dataset.resizeEdge)

    if (!neighbor) return

    event.preventDefault()
    this.resizeCard      = card
    this.resizeNeighbor  = neighbor
    this.resizeEdge      = handle.dataset.resizeEdge
    this.resizeStartX    = event.clientX
    this.resizeStartSelf = this.spanOf(card)
    this.resizePairTotal = this.resizeStartSelf + this.spanOf(neighbor)

    const gridWidth = this.gridTarget.clientWidth
    const gap       = parseFloat(getComputedStyle(this.gridTarget).columnGap) || 0

    this.resizeStep = (gridWidth + gap) / (this.baseCols || 1)

    document.addEventListener("pointermove", this.onResizeMove)
    document.addEventListener("pointerup", this.onResizeEnd)
    document.addEventListener("pointercancel", this.onResizeEnd)
    document.body.style.cursor     = "col-resize"
    document.body.style.userSelect = "none"
  }

  onResizeMove(event) {
    if (!this.resizeCard || !this.resizeStep) return

    // Pulling the LEFT edge left, or the RIGHT edge right, grows this card.
    const moved = (event.clientX - this.resizeStartX) / this.resizeStep
    const grow  = Math.round(this.resizeEdge === "left" ? -moved : moved)

    const self = Math.max(1, Math.min(this.resizePairTotal - 1, this.resizeStartSelf + grow))

    this.setSpan(this.resizeCard, self)
    this.setSpan(this.resizeNeighbor, this.resizePairTotal - self)
  }

  onResizeEnd() {
    if (!this.resizeCard) return

    this.persistSize(this.resizeCard.dataset.metricKey, this.spanOf(this.resizeCard))
    this.persistSize(this.resizeNeighbor.dataset.metricKey, this.spanOf(this.resizeNeighbor))

    this.resizeCard = null
    this.resizeNeighbor = null

    document.removeEventListener("pointermove", this.onResizeMove)
    document.removeEventListener("pointerup", this.onResizeEnd)
    document.removeEventListener("pointercancel", this.onResizeEnd)

    document.body.style.cursor     = ""
    document.body.style.userSelect = ""

    // Re-stretch the last card of each row to swallow any gap the change left.
    this.fillRows()
  }

  // rowNeighbor — the visible card immediately before (left) / after (right)
  // this one in DOM order that shares its row (same rect top). Null at a row
  // edge.
  rowNeighbor(card, edge) {
    const cards = this.cardTargets.filter(c => !c.hidden)
    const idx   = cards.indexOf(card)

    if (idx < 0) return null

    const top      = Math.round(card.getBoundingClientRect().top)
    const neighbor = edge === "left" ? cards[idx - 1] : cards[idx + 1]

    return neighbor && Math.round(neighbor.getBoundingClientRect().top) === top ? neighbor : null
  }

  setSpan(card, span) {
    card.style.gridColumn = `span ${span}`
  }

  spanOf(card) {
    const m = (card.style.gridColumn || "").match(/span\s+(\d+)/)

    return m ? parseInt(m[1], 10) : (this.defaultSpan || 1)
  }

  persistSize(metricKey, span) {
    if (!metricKey) return

    const store = this.readSizesStore()

    store[this.kindValue] ||= {}
    store[this.kindValue][metricKey] = span // sixtieths — explicit once resized

    try {
      sessionStorage.setItem(SIZES_KEY, JSON.stringify(store))
    } catch (_) {
      // sessionStorage disabled — the resize holds for this view, just won't
      // survive the next frame swap.
    }
  }

  readSizes() {
    return this.readSizesStore()[this.kindValue] || {}
  }

  readSizesStore() {
    try {
      return JSON.parse(sessionStorage.getItem(SIZES_KEY) || "{}")
    } catch (_) {
      return {}
    }
  }

  // readConfig — normalised view. First-run derives the hidden set
  // from data-default-visible="false" cards so picker-only HTTP
  // metrics (p90, p99, 3xx, 4xx) start hidden — only the canonical
  // 4 are shown until the operator enables more via the Settings
  // drawer's Latency / Errors group pickers.
  readConfig() {
    const store = this.readStore()
    const raw   = store[this.kindValue]

    if (!raw) {
      return {
        hidden: this.defaultHiddenFromDom(),
        order:  [],
        cols:   2
      }
    }

    if ("resource_hidden" in raw || "http_hidden" in raw) {
      return {
        hidden: [...(raw.resource_hidden || []), ...(raw.http_hidden || [])],
        order:  raw.order || [],
        cols:   raw.cols  || 2
      }
    }

    return {
      hidden: raw.hidden || [],
      order:  raw.order  || [],
      cols:   raw.cols   || 2
    }
  }

  defaultHiddenFromDom() {
    return this.cardTargets
      .filter(c => c.dataset.defaultVisible === "false")
      .map(c => c.dataset.metricKey)
  }

  readStore() {
    try {
      return JSON.parse(sessionStorage.getItem("voodu:metrics:display") || "{}")
    } catch (_) {
      return {}
    }
  }
}
