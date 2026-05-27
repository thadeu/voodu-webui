import { Controller } from "@hotwired/stimulus"

// LogsPodsSelectorController — drawer body for the multi-select
// pod picker on /logs.
//
// Owns:
//   - The checkbox state in the drawer
//   - Persistence of the selection to localStorage (one key per
//     island so switching servers doesn't smear filters across them)
//   - The `logs-pods:changed` window-level event that tells the
//     log-stream controller "rebuild your row-visibility filter
//     from this new selection"
//
// Storage shape (localStorage):
//   key: voodu:logs-pods:v1:<island_key>
//   value:
//     null / missing     → no saved selection → show all pods (default)
//     []                 → intentional empty selection → show no pods
//     ["foo", "bar"]     → show only pods whose resource_name matches
//
// Why resource_name (not full container name)?
//   Operator-facing identity is the deploy/service name, not the
//   `.67ad`-suffixed replica id which changes on every rollout.
//   Selecting "controller" means "I want logs from controller no
//   matter how many replicas roll out under it" — exactly what the
//   operator said in the request.
//
// Event contract:
//   window.dispatchEvent(new CustomEvent("logs-pods:changed", {
//     detail: { resources: ["controller", "events"] | null }
//   }))
//
//   detail.resources = null     → reset to default (show all)
//   detail.resources = []       → hide all
//   detail.resources = [...]    → filter

export default class extends Controller {
  static values  = { storageKey: String }
  static targets = ["toggle", "counter", "dirtyHint"]

  connect() {
    this.applyStateToCheckboxes(this.loadSelection())
    this.updateCounter()
  }

  // ── Toggle handlers ──────────────────────────────────────────

  onToggle(_event) {
    this.persistAndDispatch()
    this.updateCounter()
  }

  selectAll() {
    this.toggleTargets.forEach((t) => { t.checked = true })
    // Selection back to "default" — clear the saved selection so
    // future replica adds get picked up automatically.
    this.storageRemove()
    this.dispatchChange(null)
    this.updateCounter()
  }

  clearAll() {
    this.toggleTargets.forEach((t) => { t.checked = false })
    this.persistAndDispatch()
    this.updateCounter()
  }

  // ── Internals ───────────────────────────────────────────────

  // currentSelection — array of checked resource_names. Null when
  // every checkbox is checked (operator's "show all" state — same
  // as a missing localStorage key).
  currentSelection() {
    const total   = this.toggleTargets.length
    const checked = this.toggleTargets.filter((t) => t.checked)

    if (total > 0 && checked.length === total) return null

    return checked.map((t) => t.dataset.resourceName)
  }

  persistAndDispatch() {
    const sel = this.currentSelection()

    if (sel === null) {
      this.storageRemove()
    } else {
      this.storageWrite(sel)
    }

    this.dispatchChange(sel)
  }

  dispatchChange(resources) {
    window.dispatchEvent(new CustomEvent("logs-pods:changed", {
      detail: { resources: resources }
    }))
  }

  applyStateToCheckboxes(selection) {
    // null = all (everything stays checked from the markup default)
    if (selection === null) return

    const allowed = new Set(selection)
    this.toggleTargets.forEach((t) => {
      t.checked = allowed.has(t.dataset.resourceName)
    })
  }

  // updateCounter — "N of M selected" headline + "showing all" hint
  // when selection is at the default.
  updateCounter() {
    const total   = this.toggleTargets.length
    const checked = this.toggleTargets.filter((t) => t.checked).length

    if (this.hasCounterTarget) {
      this.counterTarget.textContent = checked === total
        ? `all (${total})`
        : `${checked} of ${total}`
    }

    if (this.hasDirtyHintTarget) {
      this.dirtyHintTarget.textContent = checked === total
        ? "showing all"
        : checked === 0 ? "hiding all" : "filter active"
    }
  }

  // ── localStorage ────────────────────────────────────────────

  loadSelection() {
    if (!this.storageKeyValue) return null
    try {
      const raw = localStorage.getItem(this.storageKeyValue)
      if (raw === null) return null
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : null
    } catch (_e) {
      return null
    }
  }

  storageWrite(arr) {
    if (!this.storageKeyValue) return
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(arr))
    } catch (_e) { /* quota / privacy mode — ignore */ }
  }

  storageRemove() {
    if (!this.storageKeyValue) return
    try {
      localStorage.removeItem(this.storageKeyValue)
    } catch (_e) { /* ignore */ }
  }
}
