import { Controller } from "@hotwired/stimulus"

// ModalController — companion to Components::UI::Modal.
//
// Responsibilities (everything the Phlex component CAN'T do, since
// it's pure server-render):
//
//   1. Body scroll-lock — prevents the page underneath from
//      scrolling while the modal is up.
//   2. ESC keydown — closes the modal (respects closable_value).
//   3. Backdrop click — closes the modal (delegated by the
//      backdrop element's data-action).
//   4. Initial focus — first interactive element inside the dialog
//      gets focus on connect, so keyboard users land in the right
//      place.
//
// Open/close semantics:
//
//   The component is currently rendered as a FULL PAGE — there's no
//   "show / hide" toggle, the modal IS the page. So `close()` either:
//     - navigates to `data-modal-close-to-value` (anchor passes the
//       URL via its own href), OR
//     - in a future overlay mode (component mounted on an existing
//       page), sets `hidden = true` on the wrapper element.
//
//   For now (M-1), close() emits a `modal:close` event the host
//   can listen for; if `closeToValue` is set we navigate there.
//   The dialog's own anchor X already handles the navigation;
//   this is the fallback path for ESC + backdrop.
export default class extends Controller {
  static targets = ["backdrop", "dialog"]
  
  static values = {
    closable: { type: Boolean, default: true },
    closeTo:  { type: String,  default: "" }
  }

  connect() {
    this.onKey = this.onKey.bind(this)
    document.addEventListener("keydown", this.onKey)

    // Scroll-lock the body. Stash the previous value so disconnect
    // restores it (important if the page wasn't `overflow: visible`
    // to begin with).
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    // Initial focus — first focusable element inside dialog.
    // requestAnimationFrame so the input is mounted and visible.
    requestAnimationFrame(() => {
      const focusable = this.dialogTarget?.querySelector(
        "input:not([type='hidden']):not([disabled]), textarea, select, button:not([disabled]), [href], [tabindex]:not([tabindex='-1'])"
      )

      focusable?.focus()
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    document.body.style.overflow = this.previousBodyOverflow
  }

  // backdropClick — fired by the backdrop element's data-action.
  // Identical to close() but separately routed so individual modals
  // can disable backdrop dismiss without disabling ESC if needed.
  backdropClick(event) {
    if (!this.closableValue) return
    this.close(event)
  }

  close(event) {
    if (!this.closableValue) return
    event?.preventDefault()

    // Tell the host something closed. Used by overlay-mode (future)
    // to remove the modal from DOM, or by analytics.
    this.element.dispatchEvent(new CustomEvent("modal:close", { bubbles: true }))

    if (this.closeToValue) {
      window.location.href = this.closeToValue
    }
  }

  onKey(event) {
    if (event.key === "Escape") this.close(event)
  }
}
