import { Controller } from "@hotwired/stimulus"

// LogsColumnsController — column resize + visibility for the /logs
// viewport. Rides the same root element as log-stream (they don't
// share targets, just the DOM container).
//
// State (persisted to localStorage under `storageKeyValue`):
//   {
//     hidden: ["level"],          // column keys the operator turned off
//     widths: { ts: 90, pod: 130 } // px widths for columns the operator dragged
//   }
//
// Columns the operator hasn't touched stay `auto` (sized to content).
// `body` is always last + always `minmax(0, 1fr)` so the payload
// column eats whatever's left. PAYLOAD can't be hidden — the popover
// renders it as a disabled checkbox; the controller also guards
// programmatically.
//
// Resize semantics:
//   - mousedown on a `.log-col-resize` handle → record startX +
//     current cell width (via getBoundingClientRect, so "auto"
//     columns get pinned to their resolved px on first drag).
//   - mousemove (document-scoped) → newWidth = startWidth + Δx,
//     clamped to MIN_COL_WIDTH. Re-apply grid template inline.
//   - mouseup (document-scoped) → persist + cleanup listeners.
//
// Popover open/close:
//   - togglePopover flips the [hidden] attribute on the popover
//     element + ARIA-expanded on the trigger.
//   - Outside-click listener (added only while open) closes when
//     a click lands outside the popover/trigger.
//   - Scroll on the viewport scroll container also closes — popover
//     is anchored to the viewport edge and scrolling makes its
//     position visually weird otherwise.

const COLUMNS = ["ts", "level", "pod", "body"]
const MIN_COL_WIDTH = 40       // px — keep handles draggable + text readable
const MAX_COL_WIDTH = 800      // px — sanity cap, prevents an accidental drag
                               //       from pinning body to zero width

const HIDE_CLASS_PREFIX = "cols-hide-"

export default class extends Controller {
  static values = {
    storageKey: { type: String, default: "voodu:logs-columns:v1" },
    // Which columns this surface has, in order. Default = the live tail's
    // full set; /logs/analytics passes a subset (no LVL). `body` must stay
    // last (it's the 1fr payload). Backward-compatible: callers that don't
    // set it get the live-tail columns unchanged.
    columns: { type: Array, default: COLUMNS },
    // Per-column starting width (px) before the operator drags. Analytics
    // sets fixed widths so the grid skips the (expensive over thousands of
    // rows) `auto` content-measure pass. Unset → `auto` (live-tail default).
    defaultWidths: { type: Object, default: {} }
  }

  static targets = ["popover", "settingsButton", "visibilityToggle"]

  connect() {
    this.state = this.loadState()

    // The grid container lives inside the log-stream controller's
    // markup. We don't have a Stimulus target on it (the log-stream
    // controller owns `list`) — query directly under our root.
    this.listEl = this.element.querySelector(".log-list")
    if (!this.listEl) return

    // Bound document handlers — references held so we can detach
    // them cleanly on disconnect / drag-end / popover-close.
    this.onMouseMove = this.onMouseMove.bind(this)
    this.onMouseUp   = this.onMouseUp.bind(this)
    this.onDocClick  = this.onDocClick.bind(this)
    this.onDocScroll = this.onDocScroll.bind(this)

    this.applyState()
    this.syncCheckboxes()

    // Mark the layout as applied so a surface can reveal itself only now —
    // before this, a saved resize would visibly snap from the CSS default
    // width. The CSS that reacts is analytics-scoped (`.la-list`); the live
    // tail has no pre-paint default to hide, so it's unaffected.
    this.listEl.classList.add("cols-ready")
  }

  disconnect() {
    this.stopResize()
    this.closePopover()
  }

  // ── Resize ────────────────────────────────────────────────────────

  startResize(event) {
    const handle = event.currentTarget
    const key    = handle.dataset.columnKey
    if (!key) return

    event.preventDefault()
    event.stopPropagation()

    const cell = handle.closest(".log-hcell")
    if (!cell) return

    // Pin the current resolved width as the starting point. For an
    // `auto` column this captures whatever the content sized it to;
    // for a previously-resized column it captures the stored px.
    const rect = cell.getBoundingClientRect()

    this.resize = {
      key:        key,
      startX:     event.clientX,
      startWidth: rect.width,
      handle:     handle
    }

    handle.classList.add("is-dragging")
    document.body.classList.add("log-cols-resizing")
    document.addEventListener("mousemove", this.onMouseMove)
    document.addEventListener("mouseup",   this.onMouseUp)
  }

  onMouseMove(event) {
    if (!this.resize) return

    const delta    = event.clientX - this.resize.startX
    const newWidth = Math.max(MIN_COL_WIDTH, Math.min(MAX_COL_WIDTH, this.resize.startWidth + delta))

    // Apply transiently — we don't persist until mouseup so an
    // operator who drags wildly + releases off the viewport doesn't
    // litter localStorage with intermediate values.
    this.state.widths[this.resize.key] = Math.round(newWidth)
    this.applyTemplate()
  }

  onMouseUp() {
    if (!this.resize) return

    this.resize.handle.classList.remove("is-dragging")
    this.stopResize()
    this.saveState()
  }

  stopResize() {
    if (!this.resize) {
      document.body.classList.remove("log-cols-resizing")
      return
    }

    this.resize = null
    document.body.classList.remove("log-cols-resizing")
    document.removeEventListener("mousemove", this.onMouseMove)
    document.removeEventListener("mouseup",   this.onMouseUp)
  }

  // ── Visibility popover ────────────────────────────────────────────

  togglePopover(event) {
    event.preventDefault()
    event.stopPropagation()

    if (!this.hasPopoverTarget) return

    if (this.popoverTarget.hidden) {
      this.openPopover()
    } else {
      this.closePopover()
    }
  }

  openPopover() {
    this.popoverTarget.hidden = false
    if (this.hasSettingsButtonTarget) {
      this.settingsButtonTarget.setAttribute("aria-expanded", "true")
    }

    // Wait a tick so the click that OPENED the popover doesn't
    // immediately close it via the outside-click handler — that
    // mousedown is still bubbling when this runs synchronously.
    requestAnimationFrame(() => {
      document.addEventListener("click", this.onDocClick)
      // The viewport scroller is the closest interactive ancestor.
      // Scrolling there pulls the header out from under the popover
      // visually — close instead of trying to follow.
      const scroller = this.element.querySelector('[data-log-stream-target="viewport"]')
      if (scroller) {
        scroller.addEventListener("scroll", this.onDocScroll, { passive: true })
        this.popoverScroller = scroller
      }
    })
  }

  closePopover() {
    if (!this.hasPopoverTarget) return
    if (this.popoverTarget.hidden) return

    this.popoverTarget.hidden = true
    if (this.hasSettingsButtonTarget) {
      this.settingsButtonTarget.setAttribute("aria-expanded", "false")
    }
    document.removeEventListener("click", this.onDocClick)
    if (this.popoverScroller) {
      this.popoverScroller.removeEventListener("scroll", this.onDocScroll)
      this.popoverScroller = null
    }
  }

  onDocClick(event) {
    if (!this.hasPopoverTarget) return
    if (this.popoverTarget.contains(event.target)) return
    if (this.hasSettingsButtonTarget && this.settingsButtonTarget.contains(event.target)) return
    this.closePopover()
  }

  onDocScroll() {
    this.closePopover()
  }

  toggleVisibility(event) {
    const input = event.currentTarget
    const key   = input.dataset.columnKey
    if (!key) return

    // PAYLOAD can never be hidden — the checkbox is `disabled` in
    // the markup but we belt-and-suspender it in JS too in case a
    // future call site forgets the disabled flag.
    if (input.dataset.required === "true") {
      input.checked = true
      return
    }

    if (input.checked) {
      this.state.hidden = this.state.hidden.filter((k) => k !== key)
    } else if (!this.state.hidden.includes(key)) {
      this.state.hidden.push(key)
    }

    this.applyState()
    this.saveState()
  }

  // ── State persistence + application ───────────────────────────────

  loadState() {
    const empty = { hidden: [], widths: {} }
    try {
      const raw = localStorage.getItem(this.storageKeyValue)
      if (!raw) return empty
      const parsed = JSON.parse(raw)
      return {
        hidden: Array.isArray(parsed.hidden) ? parsed.hidden.filter((k) => this.columnsValue.includes(k) && k !== "body") : [],
        widths: (parsed.widths && typeof parsed.widths === "object") ? parsed.widths : {}
      }
    } catch (e) {
      console.warn("[voodu] logs-columns: localStorage load failed:", e)
      return empty
    }
  }

  saveState() {
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(this.state))
    } catch (e) {
      console.warn("[voodu] logs-columns: localStorage save failed:", e)
    }
  }

  applyState() {
    this.applyHidden()
    this.applyTemplate()
  }

  applyHidden() {
    for (const col of this.columnsValue) {
      if (col === "body") continue
      const cls = `${HIDE_CLASS_PREFIX}${col}`
      this.listEl.classList.toggle(cls, this.state.hidden.includes(col))
    }
  }

  // applyTemplate — rebuild grid-template-columns from the current
  // visibility + width state. Hidden columns drop out of the
  // template entirely (their cells are display:none so they're not
  // grid items anyway). `body` is always last + always 1fr.
  applyTemplate() {
    const tracks = []

    for (const col of this.columnsValue) {
      if (col === "body") {
        tracks.push("minmax(0, 1fr)")
        continue
      }

      if (this.state.hidden.includes(col)) continue
      const w = this.state.widths[col] || this.defaultWidthsValue[col]
      tracks.push(w ? `${w}px` : "auto")
    }

    this.listEl.style.gridTemplateColumns = tracks.join(" ")
  }

  syncCheckboxes() {
    if (!this.hasVisibilityToggleTarget) return

    for (const input of this.visibilityToggleTargets) {
      const key = input.dataset.columnKey
      
      if (!key) continue

      if (input.dataset.required === "true") {
        input.checked = true
        continue
      }
      
      input.checked = !this.state.hidden.includes(key)
    }
  }
}
