import { Controller } from "@hotwired/stimulus"

// ExportFormController — small helpers for the log export form:
//
//   1. Period preset chips ("Last 1h", "Yesterday", etc.) fill the
//      from/until datetime-local inputs.
//   2. "All pods" master toggle clears + disables individual pod
//      checkboxes; unchecking flips back to manual mode.
//   3. "Select all of kind X" toggles every pod_row in that kind
//      bucket. Stays in sync with the All-pods master.
//
// All other behaviour (submit, validation, status morph) is plain
// HTML form + Turbo Stream — no JS needed for the happy path.

export default class extends Controller {
  static targets = ["fromInput", "untilInput", "podCheckbox"]

  // applyPreset — handler for the period chips. Reads
  // data-preset-id off the button, computes a [from, until] window,
  // writes both inputs.
  applyPreset(event) {
    event.preventDefault()
    const presetId = event.currentTarget.dataset.presetId
    const range = this.computeRange(presetId)
    if (!range) return

    this.fromInputTarget.value  = formatLocal(range.from)
    this.untilInputTarget.value = formatLocal(range.until)
  }

  // normalizeDates — fires on form submit (capture phase). Converts
  // the from/until inputs from browser-local strings ("YYYY-MM-
  // DDTHH:MM") to UTC ISO ("YYYY-MM-DDTHH:MM:SS.SSSZ") so the
  // server's Time.zone.parse (which assumes the input is already in
  // its own zone — UTC in our deployment) lands on the wall-clock
  // moment the operator actually meant.
  //
  // Without this, a BRT (UTC-3) operator picking "Last 1h" sends
  // local "20:30" which the server reads as 20:30 UTC, three hours
  // off from the real now. The Reader's range filter then misses
  // every line the warehouse has (timestamps are real UTC).
  //
  // Runs in capture phase via `action: "submit->#normalizeDates"`
  // so the values are updated BEFORE Turbo serialises the form.
  normalizeDates(event) {
    if (this.hasFromInputTarget)  this.toIsoUtc(this.fromInputTarget)
    if (this.hasUntilInputTarget) this.toIsoUtc(this.untilInputTarget)
  }

  toIsoUtc(input) {
    const raw = input.value
    if (!raw) return

    // `new Date("YYYY-MM-DDTHH:MM")` parses as LOCAL time (per the
    // HTML datetime-local spec). `.toISOString()` then returns the
    // equivalent UTC instant — exactly what the server needs.
    const d = new Date(raw)
    if (isNaN(d.getTime())) return  // invalid input — leave for server validation

    input.value = d.toISOString()
  }

  // toggleAll — operator clicked the "All pods" checkbox. When
  // checked, clear every pod checkbox + disable them visually
  // (operator sees "all" wins). When unchecked, re-enable them.
  toggleAll(event) {
    const allOn = event.currentTarget.checked
    this.podCheckboxTargets.forEach((cb) => {
      if (allOn) {
        cb.checked = false
      }

      cb.disabled = allOn
    })
  }

  // toggleKind — operator clicked "Select all" within one kind
  // group. Reads data-kind off the checkbox, finds matching
  // pod_row checkboxes (also tagged with data-kind), flips them
  // all to match the master state.
  toggleKind(event) {
    const checked = event.currentTarget.checked
    const kind    = event.currentTarget.dataset.kind
    if (!kind) return

    this.podCheckboxTargets
      .filter((cb) => cb.dataset.kind === kind)
      .forEach((cb) => {
        if (cb.disabled) return  // master "All pods" wins

        cb.checked = checked
      })
  }

  // computeRange — returns { from, until } for a given preset id.
  // `until` is always "now"; `from` is now minus the preset duration
  // OR a calendar-anchored boundary (today/yesterday).
  computeRange(id) {
    const now   = new Date()
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())

    switch (id) {
      case "last_15m":
        return { from: new Date(now - 15 * 60 * 1000),         until: now }
      case "last_1h":
        return { from: new Date(now - 60 * 60 * 1000),         until: now }
      case "last_24h":
        return { from: new Date(now - 24 * 60 * 60 * 1000),    until: now }
      case "last_2d":
        return { from: new Date(now - 2 * 24 * 60 * 60 * 1000), until: now }
      case "today":
        return { from: today,                                  until: now }
      case "yesterday": {
        const yStart = new Date(today.getTime() - 24 * 60 * 60 * 1000)
        const yEnd   = new Date(today.getTime() - 1)

        return { from: yStart, until: yEnd }
      }
      default:
        return null
    }
  }
}

// formatLocal — produces "YYYY-MM-DDTHH:MM" suitable for a
// <input type="datetime-local"> value. We deliberately use the
// local timezone so the operator sees the same wall-clock they
// typed; conversion to UTC happens server-side via Time.zone.parse.
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
