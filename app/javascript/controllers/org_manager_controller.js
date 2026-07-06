import { Controller } from "@hotwired/stimulus"

// org-manager — opens / closes the org manager overlay from the "New org"
// trigger in the server-registration form.
//
// The overlay is a fixed, full-viewport backdrop + card. But the add-server
// modal it lives in is CSS-`transform`ed (centering translate), which traps
// `position: fixed` descendants inside the modal box. So on open we PORTAL
// the overlay to <body> (escaping the transform); on close we hand it back.
//
// Once portaled the overlay leaves this controller's subtree, so `data-action`
// bindings on it would stop resolving — close is wired via a delegated click
// listener (backdrop / [data-org-close]) + Escape instead. The CRUD <form>s
// still work: Turbo intercepts submits globally and its turbo_stream responses
// target #org-manager-panel / #org-options by id, wherever they sit.
export default class extends Controller {
  static targets = ["overlay"]

  connect() {
    this.overlay = this.hasOverlayTarget ? this.overlayTarget : null
    this.onOverlayClick = this.onOverlayClick.bind(this)
    this.onKey = this.onKey.bind(this)
  }

  disconnect() {
    this.teardown()
    this.restore()
  }

  open() {
    if (!this.overlay) return

    document.body.appendChild(this.overlay)
    this.overlay.hidden = false
    this.overlay.addEventListener("click", this.onOverlayClick)
    document.addEventListener("keydown", this.onKey, true)

    requestAnimationFrame(() => {
      // Focus the visible pane's name field — openAndEdit flips to an edit pane
      // synchronously after open(), so the first (New) input may be hidden.
      const pane = this.panes().find((p) => !p.hidden)

      pane?.querySelector("input[name='org[name]']")?.focus()
    })
  }

  // openAndEdit — the dropdown's per-row pencil: open the overlay + select that
  // org's edit pane. The pencil lives in the field (still in this controller's
  // subtree, so data-action resolves); the rail rows are inside the portaled
  // overlay and ride onOverlayClick.
  openAndEdit(event) {
    const id = event.currentTarget.dataset.editOrgId

    this.open()
    this.selectOrg(id)
  }

  close() {
    this.teardown()
    this.restore()
  }

  onOverlayClick(event) {
    if (event.target.closest("[data-org-close]") || event.target.hasAttribute("data-org-backdrop")) {
      this.close()

      return
    }

    const rail = event.target.closest("[data-org-select]")

    if (rail) {
      this.selectOrg(rail.dataset.orgSelect)

      return
    }

    if (event.target.closest("[data-org-new]")) this.showNew()
  }

  // selectOrg / showNew — master-detail: reveal one detail pane (an org's edit
  // form, or the New-org form) and hide the rest, syncing the rail's active
  // highlight. Scoped to the overlay so it works portaled or not.
  selectOrg(id) {
    this.showPane(id)
    this.railItems().forEach((r) => { r.dataset.active = String(r.dataset.orgSelect === id) })
  }

  showNew() {
    this.showPane("new")
    this.railItems().forEach((r) => { r.dataset.active = "false" })
  }

  showPane(key) {
    let focus = null

    this.panes().forEach((p) => {
      const on = p.dataset.orgPane === key

      p.hidden = !on
      if (on) focus = p
    })

    focus?.querySelector("input[name='org[name]']")?.focus()
  }

  panes() {
    return Array.from((this.overlay || this.element).querySelectorAll("[data-org-pane]"))
  }

  railItems() {
    return Array.from((this.overlay || this.element).querySelectorAll("[data-org-select]"))
  }

  onKey(event) {
    if (event.key !== "Escape") return

    event.stopPropagation()
    this.close()
  }

  teardown() {
    if (!this.overlay) return

    this.overlay.removeEventListener("click", this.onOverlayClick)
    document.removeEventListener("keydown", this.onKey, true)
  }

  // restore — hide + hand the overlay back to the controller element so it
  // survives re-open (and isn't orphaned in <body> if the form re-renders).
  restore() {
    if (!this.overlay) return

    this.overlay.hidden = true

    if (this.overlay.parentElement !== this.element) this.element.appendChild(this.overlay)
  }
}
