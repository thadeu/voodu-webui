import { Controller } from "@hotwired/stimulus"

// PatRevealController — toggle a password-style input between
// hidden and visible. Used by the Add server modal (and any
// future PAT-edit surface).
//
// Markup:
//
//   <div data-controller="pat-reveal">
//     <input type="password" data-pat-reveal-target="input" .../>
//     <button data-action="click->pat-reveal#toggle"
//             data-pat-reveal-target="btn">show</button>
//   </div>
export default class extends Controller {
  static targets = ["input", "btn"]

  toggle(event) {
    event.preventDefault()
    const showing = this.inputTarget.type === "text"
    this.inputTarget.type = showing ? "password" : "text"
    this.btnTarget.textContent = showing ? "show" : "hide"
  }
}
