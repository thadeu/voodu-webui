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
    "podInput",
    "podLabel",
    "scroller",
    "surroundingHost"
  ]

  static values = {
    surroundingUrl: String,
    range: String,
    from: String,
    until: String
  }

  connect() {
    if (this.rangeValue === "custom") this.fillCustomInputsFromWindow()
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

  // selectRange — a preset chip was clicked. Repaint the active chip,
  // write the hidden range field, then either reveal the custom-range
  // inputs (no submit) or re-query immediately.
  selectRange(event) {
    event.preventDefault()
    const value = event.currentTarget.dataset.range
    if (!value) return

    this.rangeTarget.value = value
    this.repaintPresets(value)

    if (value === "custom") {
      this.customRangeTarget.classList.remove("hidden")
      this.prefillCustomDefaults()
      if (this.hasFromInputTarget) this.fromInputTarget.focus()

      return
    }

    this.customRangeTarget.classList.add("hidden")
    this.clearCustomInputs()
    this.formTarget.requestSubmit()
  }

  repaintPresets(activeValue) {
    this.presetTargets.forEach((chip) => {
      const active = chip.dataset.range === activeValue
      chip.classList.remove(...(active ? CHIP_INACTIVE : CHIP_ACTIVE))
      chip.classList.add(...(active ? CHIP_ACTIVE : CHIP_INACTIVE))
    })
  }

  // prefillCustomDefaults — seed empty custom inputs with a last-30m
  // window so they always hold a complete, submittable value.
  prefillCustomDefaults() {
    const now = new Date()

    if (this.hasFromInputTarget && !this.fromInputTarget.value) {
      this.fromInputTarget.value = formatLocal(new Date(now.getTime() - 30 * 60 * 1000))
    }

    if (this.hasUntilInputTarget && !this.untilInputTarget.value) {
      this.untilInputTarget.value = formatLocal(now)
    }
  }

  // selectPod — a row in the DS pod dropdown was clicked. Write the
  // hidden pods[] value, update the trigger label, and re-run the query
  // (preserving the rest of the form). The dropdown closes via its own
  // action on the same button.
  selectPod(event) {
    const btn = event.currentTarget
    const value = btn.dataset.pod || ""
    const label = btn.dataset.label || "All pods"

    if (this.hasPodInputTarget) this.podInputTarget.value = value
    if (this.hasPodLabelTarget) this.podLabelTarget.textContent = label

    this.formTarget.requestSubmit()
  }

  clearCustomInputs() {
    if (this.hasFromInputTarget) this.fromInputTarget.value = ""
    if (this.hasUntilInputTarget) this.untilInputTarget.value = ""
    if (this.hasFromHiddenTarget) this.fromHiddenTarget.value = ""
    if (this.hasUntilHiddenTarget) this.untilHiddenTarget.value = ""
  }

  // normalizeDates — runs on submit (before Turbo serialises the form).
  // Reads the VISIBLE local datetime-local inputs and writes their UTC
  // equivalent into the HIDDEN companions (which carry name=from/until).
  // We never write the "…Z" string back into the datetime-local itself —
  // the browser would reject it and blank the visible value.
  normalizeDates() {
    this.syncHidden(this.hasFromInputTarget && this.fromInputTarget, this.hasFromHiddenTarget && this.fromHiddenTarget)
    this.syncHidden(this.hasUntilInputTarget && this.untilInputTarget, this.hasUntilHiddenTarget && this.untilHiddenTarget)
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

  // jumpTop / jumpBottom — leap to either end of the results scroll
  // container. Instant (not smooth) so a 20k-row list doesn't animate
  // through everything; the scroller target re-binds after frame swaps.
  jumpTop() {
    if (this.hasScrollerTarget) this.scrollerTarget.scrollTop = 0
  }

  jumpBottom() {
    if (this.hasScrollerTarget) this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight
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
    if (!ts) return

    const params = new URLSearchParams({ ts, pod, all_pods: allPods ? "1" : "0" })

    try {
      const resp = await fetch(`${this.surroundingUrlValue}?${params.toString()}`, {
        headers: { Accept: "text/html" }
      })
      if (!resp.ok) return

      const html = await resp.text()
      this.surroundingHostTarget.innerHTML = html

      const anchor = this.surroundingHostTarget.querySelector("[data-surrounding-anchor]")
      if (anchor) anchor.scrollIntoView({ block: "center" })
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
