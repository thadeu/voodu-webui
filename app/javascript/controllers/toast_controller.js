import { Controller } from "@hotwired/stimulus"

// ToastController auto-dismisses its host element after `timeout` ms,
// or immediately when the dismiss action fires (button click).
// Fades out via CSS opacity transition before removing from the DOM
// so the disappearance isn't jarring.
export default class extends Controller {
  static values = { timeout: { type: Number, default: 4000 } }

  connect() {
    if (this.timeoutValue > 0) {
      this.timer = setTimeout(() => this.dismiss(), this.timeoutValue)
    }
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  dismiss() {
    if (!this.element) return
    this.element.style.transition = "opacity 180ms ease-out"
    this.element.style.opacity = "0"
    setTimeout(() => this.element.remove(), 200)
  }
}
