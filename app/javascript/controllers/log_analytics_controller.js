import { Controller } from "@hotwired/stimulus"

// LogAnalyticsController — drives the /logs/analytics surface:
//
//   1. Preset chips set the hidden `range` field and re-query (the form
//      targets the results Turbo Frame, so only the table swaps).
//   2. The "Custom" chip reveals two datetime-local inputs instead of
//      submitting, pre-filled with a sensible window so they're never
//      blank/incomplete (a date-only datetime-local serialises as "").
//   3. normalizeDates converts the from/until inputs local→UTC on submit
//      (the server's Time.zone.parse assumes UTC, so an unconverted
//      local value lands hours off).
//   4. On connect, a custom-range page fills the inputs from the
//      resolved UTC window converted to the BROWSER's local zone — so
//      the round-trip is timezone-correct even when the server's zone
//      differs from the operator's.
//   5. copyLine copies a row's raw line; openSurrounding fetches the
//      Surrounding Logs modal and injects it as an overlay;
//      closeSurrounding tears it down on `modal:close`.

const CHIP_ACTIVE = ["border-voodu-accent-line", "bg-voodu-accent-dim", "text-voodu-accent-2"]
const CHIP_INACTIVE = [
  "border-voodu-border",
  "bg-voodu-surface",
  "text-voodu-text-2",
  "hover:bg-voodu-surface-2",
  "hover:text-voodu-text"
]

// Preset key → window duration (ms). A preset is a shortcut that fills
// the date-range button + pickers with [now - Δ, now]. Keep the keys in
// lockstep with LogSearchData::RANGES.
const RANGE_MS = {
  "5m": 5 * 60 * 1000,
  "30m": 30 * 60 * 1000,
  "1h": 60 * 60 * 1000,
  "3h": 3 * 60 * 60 * 1000,
  "12h": 12 * 60 * 60 * 1000,
  "24h": 24 * 60 * 60 * 1000
}

// Persisted width of the filter drawer (its own key — a query editor wants a
// different width than the logs/pod content drawers). Min width + the
// viewport breathing room mirror drawer_controller.
const FILTER_WIDTH_KEY = "voodu:logs-filter-drawer-width"
const FILTER_MIN_WIDTH = 360

export default class extends Controller {
  static targets = [
    "form",
    "range",
    "preset",
    "customRange",
    "fromInput",
    "untilInput",
    "fromHidden",
    "untilHidden",
    "customLabel",
    "podCheckbox",
    "podLabel",
    "selectAllLabel",
    "scroller",
    "summary",
    "surroundingHost",
    "wrapToggle",
    "loadMore",
    "filterPanel"
  ]

  static WRAP_KEY = "voodu:logs-analytics-wrap:v1"

  static values = {
    surroundingUrl: String,
    range: String,
    from: String,
    until: String
  }

  connect() {
    if (this.rangeValue === "custom") {
      this.fillCustomInputsFromWindow()
    } else {
      this.fillFromPreset(this.rangeValue)
    }
    this.updateCustomLabel()
    this.refreshPodScope()

    // Filter drawer dismiss + resize. Document-level listeners (so ESC +
    // outside-click work no matter where focus is), guarded by filterOpen()
    // while closed — same lifecycle as drawer_controller. The resize move/end
    // handlers attach only during a drag.
    this.onFilterKey        = this.onFilterKey.bind(this)
    this.onFilterDocPointer = this.onFilterDocPointer.bind(this)
    this.onFilterResizeMove = this.onFilterResizeMove.bind(this)
    this.onFilterResizeEnd  = this.onFilterResizeEnd.bind(this)
    document.addEventListener("keydown", this.onFilterKey)
    document.addEventListener("pointerdown", this.onFilterDocPointer)

    if (this.hasFilterPanelTarget) {
      try {
        const saved = localStorage.getItem(FILTER_WIDTH_KEY)
        if (saved) this.filterPanelTarget.style.width = saved
      } catch (_e) {
        // localStorage disabled — fall back to the CSS default width.
      }
    }
  }

  // fillCustomInputsFromWindow — populate the datetime-local inputs from
  // the resolved UTC window (data values), converted to local. Runs on a
  // full-page load of a custom-range URL so the inputs reflect the query.
  fillCustomInputsFromWindow() {
    if (this.hasFromInputTarget && this.fromValue) {
      this.fromInputTarget.value = utcToLocalInput(this.fromValue)
    }

    if (this.hasUntilInputTarget && this.untilValue) {
      this.untilInputTarget.value = utcToLocalInput(this.untilValue)
    }
  }

  // selectRange — a preset is a SHORTCUT, not a separate mode: it fills
  // the date-range button + pickers with [now - Δ, now] so the button
  // always shows the active window, then re-queries (range=<preset>).
  selectRange(event) {
    event.preventDefault()
    const value = event.currentTarget.dataset.range
    if (!value) return

    this.rangeTarget.value = value
    this.repaintPresets(value)
    this.fillFromPreset(value)
    this.formTarget.requestSubmit()
  }

  // openCustom — the date-range button's popover opened. For a preset,
  // refresh the pickers to the live [now - Δ, now] so the popover shows
  // the current span; for an already-custom window, leave the operator's
  // values intact. Opening does NOT switch to custom — only Apply does.
  openCustom() {
    if (this.rangeTarget.value !== "custom") this.fillFromPreset(this.rangeTarget.value)
  }

  // applyCustom — Apply clicked in the popover. Commit an explicit custom
  // window and re-query (normalizeDates syncs the hidden UTC fields on
  // submit). The button keeps showing the chosen span.
  applyCustom() {
    this.rangeTarget.value = "custom"
    this.repaintPresets("custom")
    this.updateCustomLabel()
    this.formTarget.requestSubmit()
  }

  // fillFromPreset — set the pickers (and thus the date-button label) to
  // the [now - Δ, now] window for a preset key. No-op for unknown keys.
  fillFromPreset(range) {
    const ms = RANGE_MS[range]
    if (!ms) return

    const now = new Date()
    if (this.hasFromInputTarget) this.fromInputTarget.value = formatLocal(new Date(now.getTime() - ms))
    if (this.hasUntilInputTarget) this.untilInputTarget.value = formatLocal(now)
    this.updateCustomLabel()
  }

  repaintPresets(activeValue) {
    this.presetTargets.forEach((chip) => {
      const active = chip.dataset.range === activeValue
      chip.classList.remove(...(active ? CHIP_INACTIVE : CHIP_ACTIVE))
      chip.classList.add(...(active ? CHIP_ACTIVE : CHIP_INACTIVE))
    })
  }

  // updateCustomLabel — what the date button shows:
  //   - preset  → a RELATIVE label ("5m → now"). The query resolves the
  //     window at run time (range=<preset>), so a frozen timestamp would
  //     lie — it'd look fixed while the results are actually dynamic.
  //   - custom  → the FIXED absolute window the operator picked
  //     ("Jun 9, 19:12 – 19:17").
  updateCustomLabel() {
    if (!this.hasCustomLabelTarget) return

    const range = this.rangeTarget.value
    if (range !== "custom") {
      this.customLabelTarget.textContent = `${range} → now`

      return
    }

    const from = this.hasFromInputTarget ? this.fromInputTarget.value : ""
    const until = this.hasUntilInputTarget ? this.untilInputTarget.value : ""
    this.customLabelTarget.textContent = from && until ? formatRangeLabel(from, until) : "Custom"
  }

  // togglePod — a pod checkbox flipped. Reflect it (box + check + label).
  // No submit until Apply.
  togglePod() {
    this.refreshPodScope()
  }

  // toggleAllPods — the header toggle: check every pod, or clear them all if
  // they're already all checked. No submit until Apply (mirrors togglePod).
  toggleAllPods() {
    const boxes = this.hasPodCheckboxTarget ? this.podCheckboxTargets : []
    const allOn = boxes.length > 0 && boxes.every((cb) => cb.checked)
    boxes.forEach((cb) => { cb.checked = !allOn })
    this.refreshPodScope()
  }

  // applyPods — Apply the chosen pod scope (the checked pods[] checkboxes
  // serialise with the form). Dropdown closes via its own action.
  applyPods() {
    this.formTarget.requestSubmit()
  }

  // refresh — re-run the current query. For a preset, normalizeDates clears
  // the hidden from/until so the server re-resolves the window to "now" →
  // fresh data; a custom window re-runs as-is.
  refresh() {
    if (this.hasFormTarget) this.formTarget.requestSubmit()
  }

  // refreshPodScope — mirror metric-multiselect#refresh: paint each row's
  // checkbox box + check from its native checkbox, then sync the trigger
  // label and the header select-all/clear toggle.
  refreshPodScope() {
    const boxes = this.hasPodCheckboxTarget ? this.podCheckboxTargets : []
    let count = 0
    let single = ""

    boxes.forEach((cb) => {
      const on = cb.checked
      if (on) {
        count += 1
        single = cb.dataset.label || cb.value
      }

      const row = cb.closest("label")
      const box = row && row.querySelector("[data-role='checkbox']")
      const check = row && row.querySelector("[data-role='check']")

      if (box) {
        box.classList.toggle("border-voodu-accent-line", on)
        box.classList.toggle("bg-voodu-accent-dim", on)
        box.classList.toggle("border-voodu-border", !on)
      }

      if (check) check.classList.toggle("hidden", !on)
    })

    if (this.hasPodLabelTarget) {
      this.podLabelTarget.textContent = count === 0 ? "All pods" : count === 1 ? single : `${count} pods`
    }

    // Header toggle reads "Clear" once everything is selected, "Select all"
    // otherwise — so one button covers both directions.
    if (this.hasSelectAllLabelTarget) {
      this.selectAllLabelTarget.textContent = boxes.length > 0 && count === boxes.length ? "Clear" : "Select all"
    }
  }

  // normalizeDates — runs on submit (before Turbo serialises the form).
  // Only a custom window submits explicit from/until: we write the UTC
  // equivalent of the VISIBLE local pickers into the HIDDEN companions
  // (never the "…Z" string back into the datetime-local — the browser
  // would reject it and blank the field). For a preset, the visible
  // pickers are display-only, so we clear the hidden fields and let
  // range=<preset> drive the (relative) window server-side.
  normalizeDates() {
    if (this.rangeTarget.value === "custom") {
      this.syncHidden(this.hasFromInputTarget && this.fromInputTarget, this.hasFromHiddenTarget && this.fromHiddenTarget)
      this.syncHidden(this.hasUntilInputTarget && this.untilInputTarget, this.hasUntilHiddenTarget && this.untilHiddenTarget)
    } else {
      if (this.hasFromHiddenTarget) this.fromHiddenTarget.value = ""
      if (this.hasUntilHiddenTarget) this.untilHiddenTarget.value = ""
    }
  }

  syncHidden(localInput, hidden) {
    if (!localInput || !hidden) return

    const raw = localInput.value
    if (!raw) {
      hidden.value = ""

      return
    }

    const d = new Date(raw)
    hidden.value = isNaN(d.getTime()) ? "" : d.toISOString()
  }

  // clear — wipe the current results buffer (rows + summary) so the
  // operator can tweak the filter and Run fresh. Client-side only; the
  // filter inputs are left intact, and the next Run re-renders the
  // frame from the server.
  clear(event) {
    event.preventDefault()
    if (this.hasScrollerTarget) this.scrollerTarget.innerHTML = ""
    if (this.hasSummaryTarget) this.summaryTarget.textContent = "Cleared — Run to search again."
  }

  // jumpTop / jumpBottom — leap to either end of the results scroll
  // container. Instant (not smooth) so a 20k-row list doesn't animate
  // through everything; the scroller target re-binds after frame swaps.
  jumpTop() {
    if (this.hasScrollerTarget) this.scrollerTarget.scrollTop = 0
  }

  jumpBottom() {
    if (this.hasScrollerTarget) this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight
  }

  // ── filter drawer ────────────────────────────────────────────────────────
  // The query editor + pod scope live in a right-side slide-in panel. The
  // trigger sits in the results-frame toolbar (re-rendered each query); this
  // controller is the page root that spans BOTH the trigger and the panel
  // (which lives in the filter <form>, outside the frame), so it owns open
  // state. No backdrop — the results stay visible/usable behind the panel,
  // so the operator iterates on the query and watches the table update live.

  toggleFilter() {
    if (this.filterOpen()) this.closeFilter()
    else this.openFilter()
  }

  openFilter() {
    if (!this.hasFilterPanelTarget) return

    this.filterPanelTarget.removeAttribute("inert")
    this.filterPanelTarget.dataset.open = "true"
    // Focus the editor once the slide settles so the caret lands ready.
    const editor = this.filterPanelTarget.querySelector(".voodu-code__input")
    if (editor) requestAnimationFrame(() => editor.focus())
  }

  closeFilter() {
    if (!this.hasFilterPanelTarget) return

    delete this.filterPanelTarget.dataset.open
    this.filterPanelTarget.setAttribute("inert", "")
  }

  filterOpen() {
    return this.hasFilterPanelTarget && this.filterPanelTarget.dataset.open != null
  }

  // clearQuery — wipe the editor and re-run (the active-query chip's ✕). The
  // editor lives in the panel; repaint via an `input` event, then submit.
  clearQuery() {
    const editor = this.hasFilterPanelTarget ? this.filterPanelTarget.querySelector(".voodu-code__input") : null

    if (editor) {
      editor.value = ""
      editor.dispatchEvent(new Event("input", { bubbles: true }))
    }

    if (this.hasFormTarget) this.formTarget.requestSubmit()
  }

  // onFilterKey — ESC closes the drawer from anywhere (document-level, so it
  // works even after focus left the panel, e.g. the operator clicked a result).
  onFilterKey(event) {
    if (!this.filterOpen()) return
    if (event.key === "Escape") this.closeFilter()
  }

  // onFilterDocPointer — click-outside dismiss. Can't use `element.contains`
  // (this controller wraps the whole page), so we keep it open only for clicks
  // INSIDE the panel or on the openers (the toolbar funnel / the summary chip),
  // which toggle/open themselves. A drag past the panel edge is ignored.
  onFilterDocPointer(event) {
    if (!this.filterOpen() || this.filterResizing) return
    if (this.filterPanelTarget.contains(event.target)) return
    if (event.target.closest("[data-action*='log-analytics#toggleFilter'], [data-action*='log-analytics#openFilter']")) return

    this.closeFilter()
  }

  // startFilterResize — left-edge handle drag. Mirrors drawer_controller:
  // pin the cursor + kill text selection page-wide for the drag, compute
  // width from the pointer, persist on release.
  startFilterResize(event) {
    event.preventDefault()
    this.filterResizing = true
    this.savedCursor     = document.body.style.cursor
    this.savedUserSelect = document.body.style.userSelect
    document.body.style.cursor     = "col-resize"
    document.body.style.userSelect = "none"

    document.addEventListener("pointermove", this.onFilterResizeMove)
    document.addEventListener("pointerup", this.onFilterResizeEnd)
    document.addEventListener("pointercancel", this.onFilterResizeEnd)
  }

  onFilterResizeMove(event) {
    if (!this.filterResizing || !this.hasFilterPanelTarget) return

    const max = window.innerWidth - 80
    const width = Math.max(FILTER_MIN_WIDTH, Math.min(max, window.innerWidth - event.clientX))
    this.filterPanelTarget.style.width = `${width}px`
  }

  onFilterResizeEnd() {
    if (!this.filterResizing) return

    this.filterResizing = false
    document.body.style.cursor     = this.savedCursor ?? ""
    document.body.style.userSelect = this.savedUserSelect ?? ""
    document.removeEventListener("pointermove", this.onFilterResizeMove)
    document.removeEventListener("pointerup", this.onFilterResizeEnd)
    document.removeEventListener("pointercancel", this.onFilterResizeEnd)

    try {
      localStorage.setItem(FILTER_WIDTH_KEY, this.filterPanelTarget.style.width)
    } catch (_e) {
      // localStorage disabled — width just won't persist across visits.
    }
  }

  // toggleRowWrap — flip `.log-row-wrap` on ONE line (per-row wrap), so
  // its body switches to pre-wrap/break-all and the whole message is
  // readable inline — no expand panel. Two triggers, same handler (mirrors
  // the live tail): the per-row wrap chip (click) and a double-click on
  // the line. Double-clicks that land on a chip are skipped (the chip has
  // its own click action); a dblclick also leaves a stray word-selection,
  // so we clear it for a clean toggle.
  toggleRowWrap(event) {
    if (event.type === "dblclick" && event.target.closest(".log-copy, .log-wrap-single, .log-surrounding")) {
      return
    }

    event.preventDefault()
    event.stopPropagation()

    const node = event.currentTarget
    const row  = node.classList.contains("log-row") ? node : node.closest(".log-row")
    if (!row) return

    const wrapped = row.classList.toggle("log-row-wrap")
    const chip    = row.querySelector(".log-wrap-single")
    if (chip) chip.dataset.active = wrapped ? "true" : "false"

    if (event.type === "dblclick") {
      const sel = window.getSelection()
      if (sel && sel.removeAllRanges) sel.removeAllRanges()
    }
  }

  // toggleWrap — flip wrap on every line. The `.log-wrap` class on the
  // grid `.log-list` drives the CSS (truncate ↔ pre-wrap), shared with the
  // live tail. Persisted so a re-query (which swaps the results frame +
  // scroller) keeps the choice; scrollerTargetConnected re-applies it.
  toggleWrap() {
    const on = !this.wrapEnabled()
    this.setWrapPref(on)
    this.applyWrap(on)
  }

  // scrollerTargetConnected — fires on first render AND after each
  // re-query frame swap (Turbo replaces the scroller). Re-apply the saved
  // wrap state so it survives the swap.
  scrollerTargetConnected() {
    this.applyWrap(this.wrapEnabled())
  }

  // loadMoreTargetConnected — auto-fire the Load more trigger as it nears
  // the viewport, so the operator scrolls continuously instead of clicking.
  // Only ONE trigger exists at a time (the next page's), so this paginates
  // ON DEMAND — the table never renders everything up front. Clicking swaps
  // the trigger out; the next page's trigger re-observes when it connects.
  loadMoreTargetConnected(el) {
    this.loadMoreObserver?.disconnect()
    this.loadMoreObserver = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return

      this.loadMoreObserver.disconnect()
      el.click()
    }, {
      root:       this.hasScrollerTarget ? this.scrollerTarget : null,
      rootMargin: "600px 0px"
    })
    this.loadMoreObserver.observe(el)
  }

  loadMoreTargetDisconnected() {
    this.loadMoreObserver?.disconnect()
  }

  disconnect() {
    this.loadMoreObserver?.disconnect()
    document.removeEventListener("keydown", this.onFilterKey)
    document.removeEventListener("pointerdown", this.onFilterDocPointer)
    this.onFilterResizeEnd?.()
  }

  applyWrap(on) {
    // Wrap rides the same `.log-wrap` class + `.log-body` rules as the
    // live tail (theme.css), toggled on the grid `.log-list`.
    const list = this.hasScrollerTarget ? this.scrollerTarget.querySelector(".log-list") : null
    if (list) list.classList.toggle("log-wrap", on)

    if (this.hasWrapToggleTarget) {
      this.wrapToggleTarget.dataset.active = on ? "true" : "false"
      this.wrapToggleTarget.setAttribute("aria-pressed", on ? "true" : "false")
    }
  }

  wrapEnabled() {
    try {
      return localStorage.getItem(this.constructor.WRAP_KEY) === "1"
    } catch (_e) {
      return false
    }
  }

  setWrapPref(on) {
    try {
      localStorage.setItem(this.constructor.WRAP_KEY, on ? "1" : "0")
    } catch (_e) {
      // private mode / quota — wrap still toggles for this view, just
      // won't survive the next frame swap.
    }
  }

  // copyExport — fetch the export endpoint for the current query (same
  // URL the Download items link to) and put the body on the clipboard.
  // So "Copy" and "Download" return identical content for a given format.
  async copyExport(event) {
    const btn = event.currentTarget
    const url = btn.dataset.exportUrl
    if (!url) return

    try {
      const resp = await fetch(url, { headers: { Accept: "text/plain" } })
      if (!resp.ok) return

      await navigator.clipboard.writeText(await resp.text())
      const prev = btn.getAttribute("title")
      btn.setAttribute("title", "Copied")
      setTimeout(() => btn.setAttribute("title", prev || ""), 1200)
    } catch (_e) {
      // Network/clipboard denied — no-op; the Download item still works.
    }
  }

  // copyLine — copy a row's raw payload. Brief title flip is the only
  // feedback; the clipboard write is the function.
  copyLine(event) {
    const btn = event.currentTarget
    const raw = btn.dataset.raw
    if (!raw) return

    navigator.clipboard.writeText(raw).then(() => {
      const prev = btn.getAttribute("title")
      btn.setAttribute("title", "Copied")
      setTimeout(() => btn.setAttribute("title", prev || ""), 1200)
    })
  }

  // openSurrounding — fetch the Surrounding Logs modal for one anchor
  // (ts + pod, optional all-pods widening) and inject it. The injected
  // markup carries its own data-controller="modal", so Stimulus connects
  // it automatically (scroll-lock, ESC, backdrop).
  async openSurrounding(event) {
    event.preventDefault()
    const btn = event.currentTarget
    const ts = btn.dataset.ts || ""
    const pod = btn.dataset.pod || ""
    const allPods = btn.dataset.allPods === "1"
    const expand = btn.dataset.expand || "0"
    if (!ts) return

    const params = new URLSearchParams({ ts, pod, all_pods: allPods ? "1" : "0", expand })

    try {
      const resp = await fetch(`${this.surroundingUrlValue}?${params.toString()}`, {
        headers: { Accept: "text/html" }
      })
      if (!resp.ok) return

      const html = await resp.text()
      this.surroundingHostTarget.innerHTML = html

      // Centre the clicked line. The anchor row is `.log-row` (display:
      // contents → no box), so scrollIntoView on it is a no-op; scroll one
      // of its cells (a real grid item) instead. rAF lets the grid lay out
      // first so the centring lands on the right offset.
      requestAnimationFrame(() => {
        const anchor = this.surroundingHostTarget.querySelector("[data-surrounding-anchor]")
        if (!anchor) return

        const box = anchor.querySelector(".log-ts") || anchor.firstElementChild || anchor
        box.scrollIntoView({ block: "center" })
      })
    } catch (_e) {
      // Network/teardown — leave the host untouched; the operator can retry.
    }
  }

  closeSurrounding() {
    if (this.hasSurroundingHostTarget) this.surroundingHostTarget.innerHTML = ""
  }
}

// formatLocal — "YYYY-MM-DDTHH:MM" for a datetime-local value, in the
// browser's local zone (the input shows the operator's wall clock).
function formatLocal(date) {
  const pad = (n) => String(n).padStart(2, "0")

  return (
    date.getFullYear() +
    "-" + pad(date.getMonth() + 1) +
    "-" + pad(date.getDate()) +
    "T" + pad(date.getHours()) +
    ":" + pad(date.getMinutes())
  )
}

// utcToLocalInput — UTC ISO string → local datetime-local value.
function utcToLocalInput(iso) {
  const d = new Date(iso)
  if (isNaN(d.getTime())) return ""

  return formatLocal(d)
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// formatRangeLabel — two datetime-local values → a compact chip label,
// e.g. "Jun 9, 14:23 – 14:53" (same day) or "Jun 9 14:23 – Jun 10 09:00".
function formatRangeLabel(fromVal, untilVal) {
  const f = new Date(fromVal)
  const u = new Date(untilVal)
  if (isNaN(f.getTime()) || isNaN(u.getTime())) return "Custom"

  const pad = (n) => String(n).padStart(2, "0")
  const day = (d) => `${MONTHS[d.getMonth()]} ${d.getDate()}`
  const time = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`

  return f.toDateString() === u.toDateString()
    ? `${day(f)}, ${time(f)} – ${time(u)}`
    : `${day(f)} ${time(f)} – ${day(u)} ${time(u)}`
}
