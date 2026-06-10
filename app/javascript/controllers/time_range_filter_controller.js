import { Controller } from "@hotwired/stimulus"

// TimeRangeFilterController — generic preset + custom date/hour range
// picker, extracted from the logs-analytics filter so any surface
// (alerts history, …) gets the same timezone-correct behaviour:
//
//   1. Preset chips set the hidden `range` field and re-submit (the
//      form targets its own frame, so only that region swaps).
//   2. The "Custom" chip reveals two datetime-local inputs pre-filled
//      with a sensible window, instead of submitting.
//   3. normalizeDates converts the visible local pickers → UTC into
//      hidden companions on submit (the server's Time.zone.parse reads
//      UTC; an unconverted local value would land hours off).
//   4. On connect a custom-range page fills the inputs from the
//      resolved UTC window in the browser's local zone, so the
//      round-trip is correct even when server and operator zones differ.
//
// Preset durations are parsed from the key itself ("24h", "7d", "30m")
// so the controller is agnostic to which presets a surface offers.

const CHIP_ACTIVE = ["border-voodu-accent-line", "bg-voodu-accent-dim", "text-voodu-accent-2"]
const CHIP_INACTIVE = [
  "border-voodu-border",
  "bg-voodu-surface",
  "text-voodu-text-2",
  "hover:bg-voodu-surface-2",
  "hover:text-voodu-text"
]

const UNIT_MS = { m: 60 * 1000, h: 60 * 60 * 1000, d: 24 * 60 * 60 * 1000 }

export default class extends Controller {
  static targets = [
    "form",
    "range",
    "preset",
    "fromInput",
    "untilInput",
    "fromHidden",
    "untilHidden",
    "customLabel"
  ]

  static values = { range: String, from: String, until: String }

  connect() {
    if (this.rangeValue === "custom") {
      this.fillCustomInputsFromWindow()
    } else {
      this.fillFromPreset(this.rangeValue)
    }
    this.updateCustomLabel()
  }

  fillCustomInputsFromWindow() {
    if (this.hasFromInputTarget && this.fromValue) {
      this.fromInputTarget.value = utcToLocalInput(this.fromValue)
    }

    if (this.hasUntilInputTarget && this.untilValue) {
      this.untilInputTarget.value = utcToLocalInput(this.untilValue)
    }
  }

  selectRange(event) {
    event.preventDefault()
    const value = event.currentTarget.dataset.range
    if (!value) return

    this.rangeTarget.value = value
    this.repaintPresets(value)
    this.fillFromPreset(value)
    this.formTarget.requestSubmit()
  }

  openCustom() {
    if (this.rangeTarget.value !== "custom") this.fillFromPreset(this.rangeTarget.value)
  }

  applyCustom() {
    this.rangeTarget.value = "custom"
    this.repaintPresets("custom")
    this.updateCustomLabel()
    this.formTarget.requestSubmit()
  }

  fillFromPreset(range) {
    const ms = parseRangeMs(range)
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

  // normalizeDates — on submit, write the UTC equivalent of the visible
  // local pickers into the hidden companions (custom only). For a preset
  // the pickers are display-only, so clear the hidden fields and let
  // range=<preset> drive the relative window server-side.
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
}

// parseRangeMs — "24h" / "7d" / "30m" → milliseconds. Returns 0 for
// unknown keys (e.g. "custom"), so callers no-op cleanly.
function parseRangeMs(key) {
  const m = String(key).match(/^(\d+)(m|h|d)$/)
  if (!m) return 0

  return parseInt(m[1], 10) * UNIT_MS[m[2]]
}

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

function utcToLocalInput(iso) {
  const d = new Date(iso)
  if (isNaN(d.getTime())) return ""

  return formatLocal(d)
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

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
