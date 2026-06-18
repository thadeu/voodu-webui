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
    this.alignToViewport()
    document.addEventListener("click", this.outsideClick)
    document.addEventListener("keydown", this.escapeKey)
  }

  close() {
    this.menuTarget.hidden = true
    this.resetAlignment()
    document.removeEventListener("click", this.outsideClick)
    document.removeEventListener("keydown", this.escapeKey)
  }

  // alignToViewport — if the menu (anchored `left-0` from CSS, so
  // it grows rightward by default) would overflow the window's right
  // edge, flip its anchor to `right: 0` so it grows leftward
  // instead. Same idea Mac menus, dropdowns in Notion, etc. use.
  //
  // We mutate `style.left` / `style.right` inline so the CSS class
  // `left-0` stays the declarative default — operator sees the
  // flip only when geometry actually forces it.
  alignToViewport() {
    const menu = this.menuTarget

    // Reset any previous flip before measuring — otherwise the
    // second open in a session would measure the already-flipped
    // position and never re-evaluate.
    menu.style.left  = ""
    menu.style.right = ""

    const rect = menu.getBoundingClientRect()
    const vw   = window.innerWidth

    // 8px breathing room from the window edge so the menu doesn't
    // butt against the viewport border when geometry is borderline.
    const SAFE_GAP = 8

    if (rect.right > vw - SAFE_GAP) {
      menu.style.left  = "auto"
      menu.style.right = "0"
    }
  }

  resetAlignment() {
    this.menuTarget.style.left  = ""
    this.menuTarget.style.right = ""
  }

  outsideClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  escapeKey(event) {
    if (event.key === "Escape") this.close()
  }
}
