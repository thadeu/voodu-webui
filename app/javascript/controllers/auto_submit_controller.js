import { Controller } from "@hotwired/stimulus"

// AutoSubmitController — generic "any control change submits the
// form" wiring. Stimulus replacement for inline `onchange=` (Phlex
// rejects on* attrs as XSS-unsafe).
//
// Usage:
//
//   form(data: { controller: "auto-submit" }) do
//     select(data: { action: "change->auto-submit#submit" }) do …
//     # or any other input — `change` events bubble to the form
//   end
//
// The form's `data-turbo-frame` attr (if set) determines whether
// the response lands in a frame or navigates the page — Stimulus
// just calls `form.requestSubmit()` and lets Turbo handle the rest.
//
// Why a controller instead of e.g. `change->form#requestSubmit`:
// Stimulus doesn't ship a `form` controller; rolling our own is
// 5 lines + keeps the call site readable.
export default class extends Controller {
  submit(_event) {
    this.element.requestSubmit()
  }
}
