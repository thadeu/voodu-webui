import { Controller } from "@hotwired/stimulus"

// DropdownController — click-to-open menu with outside-click +
// Escape-to-close.
//
// Markup:
//
//   <div data-controller="dropdown">
//     <button data-action="click->dropdown#toggle">…</button>
//     <div data-dropdown-target="menu" hidden>…items…</div>
//   </div>
export default class extends Controller {
  static targets = ["menu"]

  connect() {
    this.outsideClick = this.outsideClick.bind(this)
    this.escapeKey = this.escapeKey.bind(this)
  }

  toggle(event) {
    event?.preventDefault()
    this.menuTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.menuTarget.hidden = false
    document.addEventListener("click", this.outsideClick)
    document.addEventListener("keydown", this.escapeKey)
  }

  close() {
    this.menuTarget.hidden = true
    document.removeEventListener("click", this.outsideClick)
    document.removeEventListener("keydown", this.escapeKey)
  }

  outsideClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  escapeKey(event) {
    if (event.key === "Escape") this.close()
  }
}
