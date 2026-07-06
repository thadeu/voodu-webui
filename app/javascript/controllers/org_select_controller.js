import { Controller } from "@hotwired/stimulus"

// org-select — turns the org dropdown menu into a form field. A picked row sets
// the hidden input (submitted as server[org_id]) + the trigger label. It also
// keeps the field honest as OrgsController mutates #org-options via
// turbo_stream:
//
//   - create → a new row is appended → auto-select it (the operator just made
//     it to use it) + hide the empty-state.
//   - delete → the row is removed → if it was the selected one, fall back to
//     the placeholder; show the empty-state again when the last row goes.
export default class extends Controller {
  static targets = ["input", "label", "empty"]

  connect() {
    this.menu = this.element.querySelector("#org-options")
    this.refreshEmpty()

    if (this.menu) {
      this.observer = new MutationObserver((mutations) => this.onMutations(mutations))
      this.observer.observe(this.menu, { childList: true })
    }
  }

  disconnect() {
    this.observer?.disconnect()
  }

  pick(event) {
    const row = event.currentTarget.closest("[data-org-id]")

    if (row) this.select(row.dataset.orgId, row.dataset.orgName)
  }

  select(id, name) {
    if (this.hasInputTarget) this.inputTarget.value = id || ""

    if (this.hasLabelTarget) {
      this.labelTarget.textContent = name || "Select an org…"
      this.labelTarget.classList.toggle("text-voodu-muted-2", !id)
      this.labelTarget.classList.toggle("text-voodu-text", Boolean(id))
    }

    this.markActive(id)
  }

  markActive(id) {
    this.rows().forEach((r) => { r.dataset.active = String(r.dataset.orgId === id) })
  }

  rows() {
    return this.menu ? Array.from(this.menu.querySelectorAll("[data-org-id]")) : []
  }

  // onMutations — a newly-appended org (create) auto-selects; any add/remove
  // re-evaluates the empty-state + clears a now-deleted selection.
  onMutations(mutations) {
    const added = mutations
      .flatMap((m) => Array.from(m.addedNodes))
      .filter((n) => n.nodeType === 1 && n.dataset && n.dataset.orgId)

    if (added.length) {
      const last = added[added.length - 1]

      this.select(last.dataset.orgId, last.dataset.orgName)
    }

    this.refreshEmpty()
    this.clearIfSelectionGone()
  }

  refreshEmpty() {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.rows().length > 0
  }

  clearIfSelectionGone() {
    const current = this.hasInputTarget ? this.inputTarget.value : ""

    if (current && !this.rows().some((r) => r.dataset.orgId === current)) this.select("", "")
  }
}
