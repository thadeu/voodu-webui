import { Controller } from "@hotwired/stimulus"

// ConfirmableController — companion to Components::UI::Confirmable.
//
// Flow:
//   1. User clicks the trigger button → form fires `submit` event
//   2. `prompt(e)` intercepts: preventDefault() + show modal +
//      scroll-lock + bind ESC
//   3a. User clicks Confirm → set `confirmed = true`, call
//       `form.requestSubmit()`. Second submit event fires; `prompt(e)`
//       sees `confirmed` and lets it through (no preventDefault)
//   3b. User clicks Cancel / backdrop / ESC → hide modal + unlock
//       scroll + drop ESC binding. `confirmed` stays false.
//
// Self-contained: no coordination with modal_controller. Each
// Confirmable instance gets its own modal scope so multiple
// confirms on the same page don't interfere.
export default class extends Controller {
  static targets = ["form", "modal", "dialog"]

  connect() {
    this.confirmed = false
    this.onKey = this.onKey.bind(this)
  }

  disconnect() {
    // Defensive — if the element gets removed while the modal is
    // open (turbo navigation, etc.), make sure we don't leave the
    // body permanently scroll-locked.
    if (this.opened) this.close()
  }

  // prompt — submit event handler on the form. The FIRST submit
  // (operator clicked the trigger) shows the modal; the SECOND
  // submit (we re-fired from confirm()) is allowed through.
  prompt(event) {
    if (this.confirmed) {
      // Reset so a future cancel-then-resubmit also confirms again.
      this.confirmed = false

      return
    }

    event.preventDefault()
    this.open()
  }

  // confirm — Confirm button click. Mark the flag and re-fire the
  // form's submit. requestSubmit() (vs submit()) is the modern API
  // that fires the `submit` event again — which we now let through.
  confirm(event) {
    event.preventDefault()
    this.confirmed = true
    this.close()
    // requestSubmit triggers the submit event again. prompt() sees
    // confirmed=true and stops intercepting.
    this.formTarget.requestSubmit()
  }

  cancel(event) {
    event?.preventDefault()
    this.close()
  }

  // open — show the modal, lock body scroll, bind ESC, focus the
  // Confirm button so keyboard users can press Enter to proceed.
  open() {
    this.modalTarget.hidden = false
    this.opened = true

    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    document.addEventListener("keydown", this.onKey)

    // Focus the primary (confirm) button — the LAST button in
    // the footer matches the design's "Enter = proceed" expectation.
    requestAnimationFrame(() => {
      const buttons = this.dialogTarget?.querySelectorAll("button")

      buttons?.[buttons.length - 1]?.focus()
    })
  }

  close() {
    this.modalTarget.hidden = true
    this.opened = false
    document.body.style.overflow = this.previousBodyOverflow
    document.removeEventListener("keydown", this.onKey)
  }

  onKey(event) {
    if (event.key === "Escape") this.close()
  }
}
