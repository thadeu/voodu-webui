import { Controller } from "@hotwired/stimulus"

// SecretRevealController — masks env values until the operator
// explicitly opts in.
//
// Per-row: each row holds a `mask` span (visible by default) +
// a `value` span (hidden). Clicking the row's eye toggles which is
// shown. Closest-ancestor lookup keeps the controller in one
// scope without per-row instances.
//
// Global: header eye toggles ALL rows at once. First reveal (going
// hide → show) opens a small inline confirm popover anchored
// below the eye button — guards against accidental click in a
// shoulder-surfing scenario. Subsequent hide → show after the
// initial confirm in the same session does NOT re-prompt
// (operator already committed).
//
// We DON'T persist the revealed state across reloads — every
// fresh page load resets to masked. "Show secrets" is a per-view
// intent, never a stored preference.
export default class extends Controller {
  static targets = [
    "row",        // <div> wrapping a single env row (one per kv-row)
    "globalBtn",  // header eye button
    "globalIcon", // <svg> inside header eye (swapped on toggle)
    "confirm"     // inline confirm popover (hidden until needed)
  ]

  static values = {
    confirmed: { type: Boolean, default: false }  // session-wide "they said yes once"
  }

  connect() {
    this.allShown = false
    this.onDocClick = this.onDocClick.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
  }

  // toggleOne — eye button on a single row. Walk to the row, swap
  // its mask + value spans. No confirm — operator already on the
  // pod page and revealing one value is low-stakes.
  toggleOne(event) {
    event.preventDefault()
    event.stopPropagation()  // don't bubble to onDocClick
    const row  = event.currentTarget.closest('[data-secret-reveal-target="row"]')
    if (!row) return
    const mask = row.querySelector('[data-secret-mask]')
    const val  = row.querySelector('[data-secret-value]')
    const eye  = row.querySelector('[data-secret-eye]')
    const slash = row.querySelector('[data-secret-eye-slash]')
    if (!mask || !val) return

    const reveal = !mask.hidden  // currently masked → reveal
    mask.hidden = reveal
    val.hidden  = !reveal
    if (eye)   eye.hidden   = reveal
    if (slash) slash.hidden = !reveal
  }

  // toggleAll — header eye. First reveal in this view opens the
  // inline confirm; subsequent reveals (after the operator
  // committed) flip directly. Hide direction is always immediate.
  toggleAll(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.allShown) {
      this.applyAll(false)
      return
    }

    if (this.confirmedValue) {
      this.applyAll(true)
      return
    }

    this.openConfirm()
  }

  // confirmReveal — Confirm button inside the popover. Marks
  // committed + flips all to shown + closes popover. Operator
  // doesn't get re-asked for the rest of the page lifetime.
  confirmReveal(event) {
    event.preventDefault()
    event.stopPropagation()
    this.confirmedValue = true
    this.applyAll(true)
    this.closeConfirm()
  }

  cancelReveal(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this.closeConfirm()
  }

  // ── internals ──────────────────────────────────────────────────

  applyAll(reveal) {
    this.rowTargets.forEach(row => {
      const mask  = row.querySelector('[data-secret-mask]')
      const val   = row.querySelector('[data-secret-value]')
      const eye   = row.querySelector('[data-secret-eye]')
      const slash = row.querySelector('[data-secret-eye-slash]')
      if (mask) mask.hidden = reveal
      if (val)  val.hidden  = !reveal
      if (eye)   eye.hidden   = reveal
      if (slash) slash.hidden = !reveal
    })
    this.allShown = reveal
    this.swapGlobalIcon(reveal)
  }

  swapGlobalIcon(reveal) {
    if (!this.hasGlobalBtnTarget) return
    const eye   = this.globalBtnTarget.querySelector('[data-secret-eye]')
    const slash = this.globalBtnTarget.querySelector('[data-secret-eye-slash]')
    if (eye)   eye.hidden   = reveal
    if (slash) slash.hidden = !reveal
    this.globalBtnTarget.setAttribute("title", reveal ? "Hide all values" : "Show all values")
    this.globalBtnTarget.setAttribute("aria-label", reveal ? "Hide all values" : "Show all values")
  }

  openConfirm() {
    if (!this.hasConfirmTarget) {
      // No popover wired — degrade to silent reveal (still requires
      // explicit click, just no extra confirmation).
      this.applyAll(true)
      return
    }
    this.confirmTarget.hidden = false
    // Bind document click to dismiss when clicking outside the popover.
    setTimeout(() => document.addEventListener("click", this.onDocClick), 0)
  }

  closeConfirm() {
    if (!this.hasConfirmTarget) return
    this.confirmTarget.hidden = true
    document.removeEventListener("click", this.onDocClick)
  }

  onDocClick(event) {
    if (!this.hasConfirmTarget) return
    if (this.confirmTarget.contains(event.target)) return
    if (this.hasGlobalBtnTarget && this.globalBtnTarget.contains(event.target)) return
    this.closeConfirm()
  }
}
