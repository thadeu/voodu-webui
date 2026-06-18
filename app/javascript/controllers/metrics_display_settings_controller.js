import { Controller } from "@hotwired/stimulus"
import Sortable        from "sortablejs"

// MetricsDisplaySettingsController — drives the Settings drawer body.
//
// Two card types, all uniform height in the grid:
//
//   SINGLE — click toggles hidden
//   GROUP  — click opens a floating popover (position: fixed, wider
//            than the card) with sub-metric checkboxes. The popover
//            has its own SortableJS instance so percentiles can be
//            reordered within the group.
//
// Group popover lifecycle:
//   - Open:  compute card's getBoundingClientRect, position the panel
//            below it via position:fixed (escapes the drawer's
//            overflow-auto so it never gets clipped). Bind outside-
//            click / ESC / scroll handlers.
//   - Close: hide panel, unbind handlers. Reset inline position so
//            the next open recomputes cleanly.
//
// Only ONE group can be open at a time (clicking another group
// closes the previous one).
//
// Storage shape:
//   sessionStorage["voodu:metrics:display"] =
//     {
//       "deployment": {
//         "hidden": ["latency_p90_ms", "req_3xx", ...],
//         "order":  ["cpu_percent", "latency_p95_ms", "latency_p99_ms", ...],
//         "cols":   2
//       }
//     }
//
// First-run derives hidden from data-default-visible="false" tags.
export default class extends Controller {
  static targets = ["grid", "card", "updateBtn", "colsPicker", "colsBtn"]
  static values  = { kind: String }

  connect() {
    this.subSortables = []
    this.openCard     = null

    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    this.handleEscape       = this.handleEscape.bind(this)

    this.loadState()
    this.initSortable()
    this.initGroupSortables()
  }

  disconnect() {
    this.closeGroupPanel()
    this.sortable?.destroy()
    this.subSortables.forEach(s => s.destroy())
  }

  // initSortable — outer grid: reorders top-level tiles. Each tile's
  // first drag-handle is the grip in card_header_row. Sub-metric
  // rows inside a group panel use a distinct data-role="sub-handle"
  // (different name) so they're never matched as outer handles.
  initSortable() {
    if (!this.hasGridTarget) return

    this.sortable = new Sortable(this.gridTarget, {
      animation:     150,
      handle:        "[data-role='drag-handle']",
      ghostClass:    "opacity-30",
      chosenClass:   "ring-2",
      forceFallback: true,
      fallbackClass: "shadow-lg"
    })
  }

  // initGroupSortables — one Sortable per group popover. Initialized
  // at connect even though the popover is hidden, so by the time the
  // operator opens it the drag behaviour is wired.
  initGroupSortables() {
    this.cardTargets.forEach(card => {
      if (card.dataset.cardType !== "group") return

      const panel = card.querySelector("[data-role='group-panel']")
      if (!panel) return

      const sortable = new Sortable(panel, {
        animation:     150,
        handle:        "[data-role='sub-handle']",
        ghostClass:    "opacity-30",
        chosenClass:   "ring-1",
        forceFallback: true,
        fallbackClass: "shadow-lg"
      })

      this.subSortables.push(sortable)
    })
  }

  loadState() {
    const cfg = this.readConfig()

    this.applyHidden(cfg.hidden)
    this.applyOrder(cfg.order)
    this.selectedCols = cfg.cols
    this.applyColsPicker(cfg.cols)
  }

  applyHidden(hiddenList) {
    const hidden = new Set(hiddenList)

    this.cardTargets.forEach(card => {
      if (card.dataset.cardType === "group") {
        card.querySelectorAll("[data-role='sub-metric']").forEach(row => {
          this.applySubMetricState(row, !hidden.has(row.dataset.metric))
        })

        this.updateGroupCount(card)
      } else {
        this.applyCardState(card, hidden.has(card.dataset.metric))
      }
    })
  }

  // applyOrder — outer grid uses tile-level ordering; sub-metrics
  // inside group panels use their own ordering (driven by the
  // popover's SortableJS). On load we reorder both layers.
  applyOrder(orderList) {
    if (!orderList || orderList.length === 0 || !this.hasGridTarget) return

    const byMetric = new Map()

    this.cardTargets.forEach(card => {
      if (card.dataset.cardType === "group") {
        card.dataset.subMetrics.split(",").forEach(m => byMetric.set(m, card))
      } else {
        byMetric.set(card.dataset.metric, card)
      }
    })

    // 1. Outer order: walk metrics in saved order, move the
    //    containing tile to the end as we encounter each.
    const seen = new Set()

    orderList.forEach(metric => {
      const card = byMetric.get(metric)
      if (card && !seen.has(card)) {
        this.gridTarget.appendChild(card)
        seen.add(card)
      }
    })

    this.cardTargets.forEach(card => {
      if (!seen.has(card)) this.gridTarget.appendChild(card)
    })

    // 2. Sub-metric order within each group: walk orderList and
    //    move matching sub-metric rows to the end of their panel.
    this.cardTargets.forEach(card => {
      if (card.dataset.cardType !== "group") return

      const panel = card.querySelector("[data-role='group-panel']")
      if (!panel) return

      const subSet = new Set(card.dataset.subMetrics.split(","))

      orderList.forEach(metric => {
        if (!subSet.has(metric)) return

        const row = panel.querySelector(`[data-role='sub-metric'][data-metric='${metric}']`)
        if (row) panel.appendChild(row)
      })
    })
  }

  applyColsPicker(cols) {
    this.colsBtnTargets.forEach(btn => {
      const active = parseInt(btn.dataset.cols, 10) === cols

      btn.classList.toggle("bg-voodu-accent-dim",   active)
      btn.classList.toggle("text-voodu-accent-2",   active)
      btn.classList.toggle("border-voodu-accent-2", active)
      btn.classList.toggle("border-voodu-border",   !active)
      btn.classList.toggle("text-voodu-text-2",     !active)
    })
  }

  selectCols(event) {
    const cols = parseInt(event.currentTarget.dataset.cols, 10)

    this.selectedCols = cols
    this.applyColsPicker(cols)
    // Choosing a column count is an explicit "lay these out N per row" — drop
    // this kind's per-card drag-resize widths so the preset takes cleanly
    // (otherwise stale spans win and e.g. "2" still renders 4-up). Applied on
    // Update; metrics-display re-reads the cleared sizes then. Same key as
    // metrics_display_controller's SIZES_KEY ("voodu:metrics:sizes:v3").
    this.clearCardWidths()
  }

  // clearCardWidths — wipe the resize-drag widths for this kind so the column
  // preset lays out a uniform N-up. Resize is a fine-tune ON TOP afterwards.
  clearCardWidths() {
    try {
      const sizes = JSON.parse(sessionStorage.getItem("voodu:metrics:sizes:v3") || "{}")
      delete sizes[this.kindValue]
      sessionStorage.setItem("voodu:metrics:sizes:v3", JSON.stringify(sizes))
    } catch (_) {
      // sessionStorage disabled — nothing persisted to clear.
    }
  }

  // toggle — entry point for clicking a card. Routes by type and
  // skips drag-handle / sub-metric clicks (those have their own
  // handlers and shouldn't trigger toggle).
  toggle(event) {
    if (event.target.closest("[data-role='drag-handle']")) return
    if (event.target.closest("[data-role='sub-metric']")) return
    if (event.target.closest("[data-role='group-panel']")) return

    const card = event.currentTarget

    if (card.dataset.cardType === "group") {
      this.openGroupPanel(card)
      return
    }

    const isHidden = card.dataset.hiddenState === "true"

    this.applyCardState(card, !isHidden)
  }

  // openGroupPanel — show the group's sub-metric popover. The panel
  // uses position: absolute relative to the card (which is
  // position: relative) — much simpler than fixed-positioning + JS
  // coords, AND robust against the drawer's CSS transform (which
  // would break position: fixed by becoming its containing block).
  //
  // anchorPanel runs AFTER classList.remove("hidden") so the panel's
  // offsetWidth is measurable — we need actual width to center on
  // the card.
  openGroupPanel(card) {
    if (this.openCard && this.openCard !== card) {
      this.closeGroupPanel()
    }

    if (card.dataset.expanded === "true") {
      this.closeGroupPanel()
      return
    }

    const panel = card.querySelector("[data-role='group-panel']")
    if (!panel) return

    panel.classList.remove("hidden")
    this.anchorPanel(card, panel)

    card.dataset.expanded = "true"
    this.rotateChevron(card, true)

    this.openCard = card

    setTimeout(() => {
      document.addEventListener("click", this.handleOutsideClick, true)
      document.addEventListener("keydown", this.handleEscape)
    }, 0)
  }

  closeGroupPanel() {
    if (!this.openCard) return

    const panel = this.openCard.querySelector("[data-role='group-panel']")

    if (panel) {
      panel.classList.add("hidden")
      panel.style.left  = ""
      panel.style.right = ""

      const arrow = panel.querySelector("[data-role='group-arrow']")
      if (arrow) arrow.style.left = ""
    }

    this.openCard.dataset.expanded = "false"
    this.rotateChevron(this.openCard, false)

    document.removeEventListener("click", this.handleOutsideClick, true)
    document.removeEventListener("keydown", this.handleEscape)

    this.openCard = null
  }

  // anchorPanel — center the popover horizontally on the card, then
  // clamp so it stays inside the drawer's left + right edges. The
  // arrow at the top stays aligned with the card's center even when
  // the panel was shifted by the clamp, giving the operator a
  // clear "this popover came from THIS card" visual cue.
  anchorPanel(card, panel) {
    const drawer = card.closest("[data-drawer-target='panel']")
    if (!drawer) return

    const cardRect   = card.getBoundingClientRect()
    const drawerRect = drawer.getBoundingClientRect()
    const panelWidth = panel.offsetWidth || 220
    const margin     = 8

    // Desired panel left in viewport coords — centered on card.
    let viewportLeft = cardRect.left + cardRect.width / 2 - panelWidth / 2

    // Clamp to drawer bounds with a small margin.
    const minLeft = drawerRect.left + margin
    const maxLeft = drawerRect.right - margin - panelWidth

    viewportLeft = Math.max(minLeft, Math.min(maxLeft, viewportLeft))

    // Convert viewport-relative panel left to card-relative
    // (panel's `left` is interpreted in the CARD's coord space,
    // since the card is its positioned ancestor).
    panel.style.left  = `${viewportLeft - cardRect.left}px`
    panel.style.right = "auto"

    // Arrow: position at card center within the panel. Stays
    // aligned with the card even when the panel was shifted by
    // the clamp.
    const arrow = panel.querySelector("[data-role='group-arrow']")
    if (arrow) {
      const cardCenterInPanel = (cardRect.left + cardRect.width / 2) - viewportLeft
      // Subtract half the arrow's width (10px → 5px) so the arrow's
      // center, not its left edge, aligns with the card center.
      arrow.style.left = `${cardCenterInPanel - 5}px`
    }
  }

  rotateChevron(card, expanded) {
    const chevron = card.querySelector("[data-role='chevron']")
    if (chevron) chevron.style.transform = expanded ? "rotate(180deg)" : ""
  }

  handleOutsideClick(event) {
    if (!this.openCard) return

    const panel = this.openCard.querySelector("[data-role='group-panel']")

    if (this.openCard.contains(event.target) || (panel && panel.contains(event.target))) return

    this.closeGroupPanel()
  }

  handleEscape(event) {
    if (event.key === "Escape") this.closeGroupPanel()
  }

  // toggleSubMetric — flip a sub-metric checkbox + update parent
  // group's count badge. stopPropagation so the parent card's
  // toggle (which would re-toggle the popover) doesn't fire.
  toggleSubMetric(event) {
    event.stopPropagation()

    const row     = event.currentTarget
    const checked = row.dataset.subChecked === "true"

    this.applySubMetricState(row, !checked)

    const group = row.closest("[data-card-type='group']")
    if (group) this.updateGroupCount(group)
  }

  applySubMetricState(row, isChecked) {
    row.dataset.subChecked = isChecked ? "true" : "false"

    const check = row.querySelector("[data-role='check-icon']")
    if (check) check.classList.toggle("hidden", !isChecked)

    row.classList.toggle("opacity-40", !isChecked)
  }

  updateGroupCount(groupCard) {
    const rows  = Array.from(groupCard.querySelectorAll("[data-role='sub-metric']"))
    const total = rows.length
    const sel   = rows.filter(r => r.dataset.subChecked === "true").length

    const countEl = groupCard.querySelector("[data-role='count']")
    if (countEl) countEl.textContent = `${sel} of ${total}`

    const dimmed = sel === 0

    groupCard.classList.toggle("opacity-60",         dimmed)
    groupCard.classList.toggle("border-dashed",       dimmed)
    groupCard.classList.toggle("border-voodu-muted",  dimmed)
    groupCard.classList.toggle("border-voodu-border", !dimmed)
  }

  // save — commits hidden + order + cols to sessionStorage and
  // fires metrics-display:changed. Closes any open group popover
  // first so its state isn't dangling.
  save(event) {
    this.closeGroupPanel()

    const hidden = []

    this.cardTargets.forEach(card => {
      if (card.dataset.cardType === "group") {
        card.querySelectorAll("[data-role='sub-metric']").forEach(row => {
          if (row.dataset.subChecked !== "true") hidden.push(row.dataset.metric)
        })
      } else if (card.dataset.hiddenState === "true") {
        hidden.push(card.dataset.metric)
      }
    })

    // Order: walk the outer grid in DOM order; for group cards
    // expand to their sub-metrics in the popover's internal DOM
    // order (the operator may have reordered them inside).
    const order = []

    if (this.hasGridTarget) {
      Array.from(this.gridTarget.children).forEach(card => {
        if (card.dataset.cardType === "group") {
          card.querySelectorAll("[data-role='sub-metric']").forEach(row => {
            order.push(row.dataset.metric)
          })
        } else if (card.dataset.metric) {
          order.push(card.dataset.metric)
        }
      })
    }

    const cols = this.selectedCols || 2

    const store = this.readStore()

    store[this.kindValue] = { hidden, order, cols }

    try {
      sessionStorage.setItem("voodu:metrics:display", JSON.stringify(store))
    } catch (_) { /* in-memory state still applies */ }

    window.dispatchEvent(new CustomEvent("metrics-display:changed", {
      detail: { kind: this.kindValue }
    }))

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
    if (dot) dot.style.opacity = isHidden ? "0.25" : "1"

    const check = card.querySelector("[data-role='check']")
    if (check) {
      check.classList.toggle("hidden", isHidden)
      check.classList.toggle("flex",   !isHidden)
    }
  }

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
    const hidden = []

    this.cardTargets.forEach(card => {
      if (card.dataset.cardType === "group") {
        card.querySelectorAll("[data-role='sub-metric']").forEach(row => {
          if (row.dataset.defaultVisible === "false") hidden.push(row.dataset.metric)
        })
      } else if (card.dataset.defaultVisible === "false") {
        hidden.push(card.dataset.metric)
      }
    })

    return hidden
  }

  readStore() {
    try {
      return JSON.parse(sessionStorage.getItem("voodu:metrics:display") || "{}")
    } catch (_) {
      return {}
    }
  }
}
