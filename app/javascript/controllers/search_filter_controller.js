import { Controller } from "@hotwired/stimulus"

// search-filter — a text box that re-queries as you type, inside a turbo-frame.
//
// TWO PROBLEMS, and the second is the one that makes this a controller rather
// than a data-action.
//
// 1. Debounce. One request per keystroke is a request per keystroke.
//
// 2. Focus. Submitting reloads the frame, and the frame REPLACES its contents —
//    including this input. The operator types "run", the results land, and the
//    caret is gone: the next character goes nowhere. Every "search box that
//    loses focus" bug is this one.
//
// The flag lives in the module rather than on the element or in storage,
// because it has to survive the element being destroyed and is meaningless
// beyond the next render. It is deliberately not per-instance: a page with two
// of these would need a key, and there is one.
let refocusAfterRender = false

export default class extends Controller {
  static values = { delay: { type: Number, default: 350 } }

  connect() {
    if (!refocusAfterRender) return

    refocusAfterRender = false

    // Caret to the end, not to position 0 — the operator was typing forward.
    const value = this.element.value

    this.element.focus()
    this.element.setSelectionRange(value.length, value.length)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  search() {
    clearTimeout(this.timer)

    this.timer = setTimeout(() => {
      refocusAfterRender = true
      this.element.form?.requestSubmit()
    }, this.delayValue)
  }

  // Enter applies immediately: waiting out a debounce after an explicit submit
  // reads as the box ignoring you.
  submitNow(event) {
    if (event.key !== "Enter") return

    event.preventDefault()
    clearTimeout(this.timer)
    refocusAfterRender = true
    this.element.form?.requestSubmit()
  }
}
