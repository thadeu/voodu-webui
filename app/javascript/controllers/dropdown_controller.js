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
  // filter/option/empty are OPTIONAL — a menu with a search box at the top
  // (data-dropdown-target="filter") + rows tagged data-dropdown-target="option"
  // becomes type-to-filter; `empty` shows a "no matches" row. Menus without
  // them behave exactly as before.
  static targets = ["menu", "filter", "option", "empty"]

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
    this.resetFilter()
    document.addEventListener("click", this.outsideClick)
    document.addEventListener("keydown", this.escapeKey)
  }

  // resetFilter — each open starts fresh (all rows shown) + focuses the search
  // box so the operator can type immediately.
  resetFilter() {
    if (!this.hasFilterTarget) return

    this.filterTarget.value = ""
    this.applyFilter()
    requestAnimationFrame(() => this.filterTarget.focus())
  }

  filterInput() {
    this.applyFilter()
  }

  // applyFilter — hide option rows whose text doesn't contain the query
  // (case-insensitive, substring). Toggles the empty-state when nothing matches.
  applyFilter() {
    const q = (this.hasFilterTarget ? this.filterTarget.value : "").trim().toLowerCase()
    let shown = 0

    this.optionTargets.forEach((opt) => {
      const match = q === "" || opt.textContent.toLowerCase().includes(q)

      opt.hidden = !match
      if (match) shown++
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
  }

  // onFilterKey — Enter picks the top match (fast keyboard flow); it also stops
  // Enter from submitting the surrounding builder <form>.
  onFilterKey(event) {
    if (event.key !== "Enter") return

    event.preventDefault()
    this.optionTargets.find((o) => !o.hidden)?.click()
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
    menu.style.left   = ""
    menu.style.right  = ""
    menu.style.top    = ""
    menu.style.bottom = ""

    const rect = menu.getBoundingClientRect()
    const vw   = window.innerWidth

    // 8px breathing room from the edge so the menu doesn't butt against the
    // boundary when geometry is borderline.
    const SAFE_GAP = 8

    if (rect.right > vw - SAFE_GAP) {
      menu.style.left  = "auto"
      menu.style.right = "0"
    }

    // Vertical flip — open UPWARD when opening down would spill past the bottom
    // of the nearest scroll container (a modal body is `overflow-auto`, so an
    // absolute menu is clipped there, not at the viewport) AND there's more
    // room above the trigger. Fixes dropdowns on the last field of a modal.
    const bounds = this.clipBounds()
    const trigger = this.element.getBoundingClientRect()
    const overflowsDown = rect.bottom > bounds.bottom - SAFE_GAP
    const roomAbove = trigger.top - bounds.top
    const roomBelow = bounds.bottom - trigger.bottom

    if (overflowsDown && roomAbove > roomBelow) {
      menu.style.top    = "auto"
      menu.style.bottom = "calc(100% + 4px)"
    }
  }

  // clipBounds — the rect that actually clips the menu: the nearest scrollable
  // ancestor (a modal body, a scroll pane), else the viewport.
  clipBounds() {
    let el = this.element.parentElement

    while (el) {
      const oy = getComputedStyle(el).overflowY

      if (oy === "auto" || oy === "scroll") return el.getBoundingClientRect()
      el = el.parentElement
    }

    return { top: 0, bottom: window.innerHeight }
  }

  resetAlignment() {
    this.menuTarget.style.left   = ""
    this.menuTarget.style.right  = ""
    this.menuTarget.style.top    = ""
    this.menuTarget.style.bottom = ""
  }

  outsideClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  escapeKey(event) {
    if (event.key === "Escape") this.close()
  }
}
