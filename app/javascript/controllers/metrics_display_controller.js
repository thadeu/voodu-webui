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
export default class extends Controller {
  static targets = ["card", "grid"]
  static values  = { kind: String }

  connect() {
    this.handleChanged = this.applyState.bind(this)
    this.handleResize  = this.applyLayout.bind(this)

    this.mediaQuery = window.matchMedia("(min-width: 1100px)")
    this.mediaQuery.addEventListener("change", this.handleResize)

    window.addEventListener("metrics-display:changed", this.handleChanged)

    this.applyState()
  }

  disconnect() {
    window.removeEventListener("metrics-display:changed", this.handleChanged)
    this.mediaQuery?.removeEventListener("change", this.handleResize)
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

    let effective
    if (visibleCount <= 1)      effective = 1
    else if (visibleCount === 2) effective = 2
    else                         effective = cols || 2

    if (this.mediaQuery.matches) {
      this.gridTarget.style.gridTemplateColumns = `repeat(${effective}, minmax(0, 1fr))`
    } else {
      this.gridTarget.style.gridTemplateColumns = ""
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
