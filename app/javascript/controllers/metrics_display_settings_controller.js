import { Controller } from "@hotwired/stimulus"
import Sortable        from "sortablejs"

// MetricsDisplaySettingsController — drives the Settings drawer body
// (Views::Metrics::DisplaySettings). Two operator actions:
//
//   1. Click a card → toggle its hidden mark (preview only, not saved)
//   2. Drag a card's grip → reorder cards (preview only, not saved)
//   3. Click Update → commit hidden set + current order to sessionStorage
//      and fire metrics-display:changed so the chart grid re-applies
//
// Targets:
//   grid      — the cards container (SortableJS root)
//   card      — each metric tile
//   updateBtn — the single "Update" button
//
// Values:
//   kind — "deployment" | "statefulset" | "host" | "pod"
//          sessionStorage namespace so settings are per kind
//
// Storage shape (forward-compatible with SQLite JSONB migration):
//
//   sessionStorage["voodu:metrics:display"] =
//     {
//       "deployment": {
//         "hidden": ["net_rx_delta_bytes"],
//         "order":  ["cpu_percent", "req_count", "mem_usage_bytes", ...]
//       }
//     }
//
// Cards NOT in `order` render after the ordered set in their default
// server order — so a metric added in a future release lands at the
// end of the operator's grid without disturbing the existing layout.
//
// Backward-compat: older shape with resource_hidden/http_hidden is
// normalised on read so previously-saved preferences keep applying.
export default class extends Controller {
  static targets = ["grid", "card", "updateBtn"]
  static values  = { kind: String }

  connect() {
    this.loadState()
    this.initSortable()
  }

  disconnect() {
    this.sortable?.destroy()
  }

  // initSortable — handle is the grip icon (data-role="drag-handle")
  // so the rest of the card stays click-toggleable. ghostClass +
  // chosenClass give the operator visual feedback during drag.
  initSortable() {
    if (!this.hasGridTarget) return

    this.sortable = new Sortable(this.gridTarget, {
      animation:   150,
      handle:      "[data-role='drag-handle']",
      ghostClass:  "opacity-30",
      chosenClass: "ring-2",
      forceFallback: true,
      fallbackClass: "shadow-lg"
    })
  }

  // loadState — reads sessionStorage and:
  //   (a) marks cards hidden/visible per the saved hidden list
  //   (b) reorders cards in the grid per the saved order list
  loadState() {
    const cfg = this.readConfig()

    this.applyHidden(cfg.hidden)
    this.applyOrder(cfg.order)
  }

  applyHidden(hiddenList) {
    const hidden = new Set(hiddenList)

    this.cardTargets.forEach(card => {
      this.applyCardState(card, hidden.has(card.dataset.metric))
    })
  }

  // applyOrder — move cards into the saved order. Metrics NOT in
  // the saved order keep their server-side position relative to
  // each other (appended after the ordered set).
  applyOrder(orderList) {
    if (!orderList || orderList.length === 0 || !this.hasGridTarget) return

    const byMetric = new Map(this.cardTargets.map(c => [c.dataset.metric, c]))

    orderList.forEach(metric => {
      const card = byMetric.get(metric)
      if (card) this.gridTarget.appendChild(card)
    })

    // Append any cards NOT in the saved order at the end (new
    // metrics added in a release after the operator's last save).
    this.cardTargets.forEach(card => {
      if (!orderList.includes(card.dataset.metric)) {
        this.gridTarget.appendChild(card)
      }
    })
  }

  // toggle — flip a card's hidden mark visually. Returns early if
  // the click landed inside the drag handle so dragging never
  // toggles as a side-effect.
  toggle(event) {
    if (event.target.closest("[data-role='drag-handle']")) return

    const card     = event.currentTarget
    const isHidden = card.dataset.hiddenState === "true"

    this.applyCardState(card, !isHidden)
  }

  // save — collect current hidden + order state from the DOM and
  // commit to sessionStorage. Fires metrics-display:changed so the
  // chart grid re-filters and re-orders without a page reload.
  save(event) {
    const hidden = this.cardTargets
      .filter(c => c.dataset.hiddenState === "true")
      .map(c => c.dataset.metric)

    // Order = DOM order at save time. SortableJS has already moved
    // the cards in place; reading children in document order gives
    // us the operator's final layout.
    const order = this.hasGridTarget
      ? Array.from(this.gridTarget.querySelectorAll("[data-metrics-display-settings-target='card']"))
          .map(c => c.dataset.metric)
      : []

    const store = this.readStore()

    store[this.kindValue] = { hidden, order }

    try {
      sessionStorage.setItem("voodu:metrics:display", JSON.stringify(store))
    } catch (_) {
      // Private mode / quota exceeded — in-memory state still applies.
    }

    window.dispatchEvent(new CustomEvent("metrics-display:changed", {
      detail: { kind: this.kindValue }
    }))

    // "Saved!" flash on the Update button.
    const btn  = event.currentTarget
    const orig = btn.textContent.trim()

    btn.textContent = "Saved!"
    btn.disabled    = true

    setTimeout(() => {
      btn.textContent = orig
      btn.disabled    = false
    }, 1200)
  }

  // ── Private helpers ───────────────────────────────────────────

  applyCardState(card, isHidden) {
    card.dataset.hiddenState = isHidden ? "true" : "false"

    card.classList.toggle("opacity-40",         isHidden)
    card.classList.toggle("border-dashed",       isHidden)
    card.classList.toggle("border-voodu-muted",  isHidden)
    card.classList.toggle("border-voodu-border", !isHidden)

    const dot = card.querySelector("[data-role='dot']")

    if (dot) {
      dot.style.opacity = isHidden ? "0.25" : "1"
    }

    const check = card.querySelector("[data-role='check']")

    if (check) {
      check.classList.toggle("hidden", isHidden)
      check.classList.toggle("flex",   !isHidden)
    }
  }

  // readConfig — normalised view of the saved settings for this kind.
  // Returns { hidden: [], order: [] }. Migrates the older shape
  // ({ resource_hidden, http_hidden }) transparently so previously-
  // saved preferences keep applying.
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
