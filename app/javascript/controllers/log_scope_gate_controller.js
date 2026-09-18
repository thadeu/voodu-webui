import { Controller } from "@hotwired/stimulus"

// LogScopeGateController — the pod-scope gate on /logs/analytics
// (Components::LogAnalytics::ScopeGate). Owns ONLY the gate's own state:
//
//   1. "All pods" and the pod cards are mutually exclusive.
//   2. Apply stays disabled until a scope exists.
//   3. With nothing applied yet, the last applied scope (remembered per
//      server) is PRE-SELECTED — or "All pods" on a first visit, so Apply is
//      always one click away. Never auto-run: a scan starts only when the
//      operator asks for it. An applied scope arrives checked from the server.
//   4. Apply dispatches `log-scope-gate:apply`; the log-analytics controller
//      copies the choice into the filter form and submits it.
//
// The selected look of a card is pure CSS (has-[:checked]), so there is no
// repaint step here.
export default class extends Controller {
  static targets = ["all", "allCard", "pod", "card", "search", "noMatch", "clear", "count", "apply", "query"]

  static values = { storageKey: String }

  connect() {
    this.restore()
    this.refresh()
  }

  toggleAll() {
    if (this.allTarget.checked) this.podTargets.forEach((cb) => { cb.checked = false })

    this.refresh()
  }

  togglePod() {
    if (this.hasAllTarget) this.allTarget.checked = false

    this.refresh()
  }

  clear() {
    if (this.hasAllTarget) this.allTarget.checked = false

    this.podTargets.forEach((cb) => { cb.checked = false })
    this.refresh()
  }

  // filterCards — hide the cards that don't match the search. A hidden card
  // keeps its checked state, so a search never drops a selection.
  filterCards() {
    const needle = this.searchTarget.value.trim().toLowerCase()
    let visible = 0

    this.cardTargets.forEach((card) => {
      const match = needle === "" || card.dataset.search.includes(needle)

      card.hidden = !match

      if (match) visible += 1
    })

    if (this.hasAllCardTarget) this.allCardTarget.hidden = needle !== ""
    if (this.hasNoMatchTarget) this.noMatchTarget.hidden = visible > 0 || needle === ""
  }

  keydown(event) {
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return

    event.preventDefault()
    this.apply()
  }

  apply() {
    const pods = this.selectedPods()
    const all = this.hasAllTarget && this.allTarget.checked

    if (!all && pods.length === 0) return
    if (this.element.querySelector(".voodu-code--invalid")) return

    this.remember({ all, pods })
    this.applyTarget.disabled = true

    this.dispatch("apply", {
      detail: { all, pods, query: this.hasQueryTarget ? this.queryTarget.value.trim() : "" }
    })
  }

  refresh() {
    const count = this.selectedPods().length
    const all = this.hasAllTarget && this.allTarget.checked
    const chosen = all || count > 0

    if (this.hasApplyTarget) this.applyTarget.disabled = !chosen
    if (this.hasClearTarget) this.clearTarget.hidden = !chosen
    if (!this.hasCountTarget) return

    if (all) {
      this.countTarget.textContent = "All pods selected"
    } else if (count === 0) {
      this.countTarget.textContent = "No pod selected"
    } else {
      this.countTarget.textContent = `${count} ${count === 1 ? "pod" : "pods"} selected`
    }
  }

  selectedPods() {
    return this.podTargets.filter((cb) => cb.checked).map((cb) => cb.value)
  }

  // restore — pre-select when the server applied nothing: the remembered
  // pods, else "All pods". Remembered pods that no longer exist find no card;
  // if none survive, it falls back to All pods too.
  restore() {
    // An applied scope is the server's to paint — even when its pods left the
    // list (no card to check), it must not be silently widened to All pods.
    if (this.element.dataset.required !== "true") return
    if (this.allTarget.checked || this.selectedPods().length > 0) return

    const wanted = new Set(this.recall()?.pods || [])

    this.podTargets.forEach((cb) => { cb.checked = wanted.has(cb.value) })

    if (this.selectedPods().length === 0) this.allTarget.checked = true
  }

  recall() {
    try {
      return JSON.parse(localStorage.getItem(this.storageKeyValue) || "null")
    } catch (_e) {
      return null
    }
  }

  remember(scope) {
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(scope))
    } catch (_e) {
      // localStorage disabled — the gate just opens empty next time.
    }
  }
}
