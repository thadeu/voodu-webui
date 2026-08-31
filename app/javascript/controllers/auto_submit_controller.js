import { Controller } from "@hotwired/stimulus"

// Submits the form when a control inside it changes.
//
// The form works without this — it has a submit button inside a <noscript>, so
// a select still applies when the bundle has not landed. This only removes the
// second click when it has.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
