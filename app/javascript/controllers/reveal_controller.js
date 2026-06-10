import { Controller } from "@hotwired/stimulus"

// reveal — toggle a password-style input between hidden and visible
// via an eye icon. Used by the destination form's Webhook URL so the
// operator can peek at a stored (encrypted-at-rest) URL when needed.
//
//   <div data-controller="reveal">
//     <input type="password" data-reveal-target="input" .../>
//     <button data-action="click->reveal#toggle">👁</button>
//   </div>
export default class extends Controller {
  static targets = ["input"]

  toggle(event) {
    event.preventDefault()
    this.inputTarget.type = this.inputTarget.type === "password" ? "text" : "password"
  }
}
