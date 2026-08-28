import { Controller } from "@hotwired/stimulus"

// Closes an open <details> on click-outside and on Escape.
//
// Native <details> does neither: once opened it stays open until the summary
// is clicked again, so an account menu left open sits over the page while you
// work. Twenty lines here beats a popover library, and the element keeps its
// native keyboard and screen-reader behaviour.
export default class extends Controller {
  connect() {
    this.onDocumentClick = this.onDocumentClick.bind(this)
    this.onKeydown = this.onKeydown.bind(this)

    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("keydown", this.onKeydown)
  }

  onDocumentClick(event) {
    if (!this.element.open) return
    if (this.element.contains(event.target)) return

    this.element.open = false
  }

  onKeydown(event) {
    if (event.key !== "Escape") return
    if (!this.element.open) return

    this.element.open = false
  }
}
