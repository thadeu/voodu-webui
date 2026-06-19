import { Controller } from "@hotwired/stimulus"

// ConfirmHostController — one singleton (mounted in the dashboard layout)
// that REPLACES Turbo's native window.confirm with the DS dialog for every
// `data-turbo-confirm` on the page (form submits AND data-turbo-method
// links). Registers itself as Turbo's confirm method on connect; that method
// shows the dialog and returns a Promise<boolean> Turbo awaits.
//
// Why a global override (vs the per-instance Components::UI::Confirmable):
// some triggers can't be wrapped in their own <form> (e.g. an action that
// lives inside another form — the dashboard delete/save), so the native
// confirm was the only option there. This upgrades all of them at once.
export default class extends Controller {
  static targets = ["modal", "dialog", "message"]

  connect() {
    this.onKey = this.onKey.bind(this)
    this.onTriggerClick = this.onTriggerClick.bind(this)
    this.pendingTheme = "confirm"

    // The theme rides on the triggering element (data-turbo-confirm-theme),
    // but Turbo's confirm method doesn't hand us that element reliably for
    // links. Stash it from the click that precedes the confirm instead.
    document.addEventListener("click", this.onTriggerClick, true)

    const handler = (message) => this.ask(message)

    if (window.Turbo?.config?.forms) {
      window.Turbo.config.forms.confirm = handler
    } else if (window.Turbo?.setConfirmMethod) {
      window.Turbo.setConfirmMethod(handler)
    }
  }

  disconnect() {
    document.removeEventListener("click", this.onTriggerClick, true)
    if (this.opened) this.close(false)
  }

  // onTriggerClick — remember the theme of the [data-turbo-confirm] element
  // the operator is about to trigger (confirm | danger | warn).
  onTriggerClick(event) {
    const el = event.target.closest?.("[data-turbo-confirm]")

    if (el) this.pendingTheme = el.dataset.turboConfirmTheme || "confirm"
  }

  // ask — Turbo's confirm method. Show the dialog with the message + theme,
  // and hand back a Promise that Confirm resolves true / Cancel resolves false.
  ask(message) {
    if (this.hasMessageTarget) this.messageTarget.textContent = message || "Are you sure?"
    if (this.hasDialogTarget) this.dialogTarget.dataset.theme = this.pendingTheme || "confirm"
    this.pendingTheme = "confirm"

    this.open()

    return new Promise((resolve) => { this.resolve = resolve })
  }

  open() {
    this.modalTarget.hidden = false
    this.opened = true
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
    // Capture phase so this fires BEFORE the host modal's (bubble-phase)
    // Escape handler, and stopPropagation keeps it from reaching it — else
    // one Escape closes both the confirm AND the modal underneath it.
    document.addEventListener("keydown", this.onKey, true)

    requestAnimationFrame(() => {
      this.dialogTarget?.querySelector("[data-role='confirm']")?.focus()
    })
  }

  close(result) {
    this.modalTarget.hidden = true
    this.opened = false
    document.body.style.overflow = this.previousBodyOverflow
    document.removeEventListener("keydown", this.onKey, true)

    if (this.resolve) {
      this.resolve(result)
      this.resolve = null
    }
  }

  confirm() {
    this.close(true)
  }

  cancel() {
    this.close(false)
  }

  onKey(event) {
    if (event.key !== "Escape") return

    event.stopPropagation()
    this.cancel()
  }
}
