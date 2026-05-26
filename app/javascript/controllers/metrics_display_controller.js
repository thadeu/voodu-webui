import { Controller } from "@hotwired/stimulus"

// MetricsDisplayController — wraps the chart-grid content inside the
// metrics-charts turbo-frame. Two responsibilities:
//
//   1. Hide cards whose metric key is in the operator's hidden set
//   2. Reorder cards to match the operator's saved order
//
// Both states live in sessionStorage keyed by `kindValue` and are
// written by MetricsDisplaySettingsController when the operator
// hits Update in the Settings drawer.
//
// Targets:
//   card — each chart card (carries data-metric-key="cpu_percent")
//
// Values:
//   kind — "deployment" | "statefulset" | "host" | "pod"
//          Namespaces the sessionStorage read.
//
// Lifecycle:
//   connect()    — applyState() on initial mount AND after every
//                  turbo-frame swap (this controller lives INSIDE
//                  the frame, so reconnects on broadcast tick)
//   disconnect() — removes the window event listener
//
// Re-apply triggers:
//   - Turbo-frame swap (broadcast tick) → reconnect → applyState
//   - metrics-display:changed event (fired by display-settings
//     drawer on Update) → applyState without reload
//
// Default-visible principle: hidden is an EXPLICIT list, not a
// visible list. New metrics added in a release land visible by
// default and at the end of the order. Operator never loses
// awareness of a new metric just because they configured the page
// once.
export default class extends Controller {
  static targets = ["card"]
  static values  = { kind: String }

  connect() {
    this.applyState()

    this.handleChanged = this.applyState.bind(this)
    window.addEventListener("metrics-display:changed", this.handleChanged)
  }

  disconnect() {
    window.removeEventListener("metrics-display:changed", this.handleChanged)
  }

  applyState() {
    const cfg = this.readConfig()

    this.applyHidden(cfg.hidden)
    this.applyOrder(cfg.order)
  }

  applyHidden(hiddenList) {
    const hidden = new Set(hiddenList)

    this.cardTargets.forEach(card => {
      card.hidden = hidden.has(card.dataset.metricKey)
    })
  }

  // applyOrder — move chart cards into the saved DOM order. The
  // first card target's parent is the grid container — we reorder
  // by appending in sequence. Cards not in the saved order keep
  // their server position (appended after the ordered set).
  applyOrder(orderList) {
    if (!orderList || orderList.length === 0) return
    if (this.cardTargets.length === 0) return

    const grid = this.cardTargets[0].parentElement
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

  // readConfig — same normalisation logic as the settings controller.
  // Tolerates the older shape (resource_hidden + http_hidden) so a
  // tab opened before the order feature shipped doesn't lose the
  // hidden preferences on first load.
  readConfig() {
    const store = this.readStore()
    const raw   = store[this.kindValue] || {}

    if ("resource_hidden" in raw || "http_hidden" in raw) {
      return {
        hidden: [...(raw.resource_hidden || []), ...(raw.http_hidden || [])],
        order:  raw.order || []
      }
    }

    return {
      hidden: raw.hidden || [],
      order:  raw.order  || []
    }
  }

  readStore() {
    try {
      return JSON.parse(sessionStorage.getItem("voodu:metrics:display") || "{}")
    } catch (_) {
      return {}
    }
  }
}
