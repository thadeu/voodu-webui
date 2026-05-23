import { Controller } from "@hotwired/stimulus"

// ClipboardController — `copy` action writes a value to the clipboard
// and briefly toggles between idle/done targets for visual feedback.
//
// Markup:
//
//   <button data-controller="clipboard"
//           data-clipboard-value-value="text-to-copy"
//           data-action="click->clipboard#copy">
//     <span data-clipboard-target="idle">📋</span>
//     <span data-clipboard-target="done" hidden>✓</span>
//   </button>
export default class extends Controller {
  static values   = { value: String }
  static targets  = ["idle", "done"]

  async copy(event) {
    event.preventDefault()
    event.stopPropagation()

    try {
      await navigator.clipboard.writeText(this.valueValue)
      this.flash()
    } catch (e) {
      console.error("clipboard copy failed", e)
    }
  }

  flash() {
    if (this.hasIdleTarget) this.idleTarget.hidden = true
    if (this.hasDoneTarget) this.doneTarget.hidden = false

    clearTimeout(this.resetTimer)
    this.resetTimer = setTimeout(() => {
      if (this.hasIdleTarget) this.idleTarget.hidden = false
      if (this.hasDoneTarget) this.doneTarget.hidden = true
    }, 1200)
  }
}
