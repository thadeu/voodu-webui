import { Controller } from "@hotwired/stimulus"

// MobileNavController — slides the sidebar in/out on narrow screens.
//
// Markup expectation (rendered in Components::Layouts::Dashboard):
//
//   <div data-controller="mobile-nav">
//     <aside data-mobile-nav-target="sidebar">…</aside>
//     <div   data-mobile-nav-target="backdrop" class="hidden"></div>
//     <header>
//       <button data-action="click->mobile-nav#toggle">☰</button>
//     </header>
//   </div>
//
// Behaviour:
//   - toggle()  flips the sidebar's transform + backdrop visibility
//   - close()   forces shut (escape key, backdrop click, link click)
//   - On md+ widths the sidebar is statically positioned by Tailwind;
//     this controller's classList changes are no-ops there because
//     `md:translate-x-0` outranks them via responsive prefix priority.
export default class extends Controller {
  static targets = ["sidebar", "backdrop"]

  connect() {
    this.escapeKey = this.escapeKey.bind(this)
  }

  toggle(event) {
    event?.preventDefault()

    if (this.sidebarTarget.classList.contains("-translate-x-full")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.sidebarTarget.classList.remove("-translate-x-full")
    this.backdropTarget.classList.remove("hidden")
    document.addEventListener("keydown", this.escapeKey)
    document.body.style.overflow = "hidden"
  }

  close() {
    this.sidebarTarget.classList.add("-translate-x-full")
    this.backdropTarget.classList.add("hidden")
    document.removeEventListener("keydown", this.escapeKey)
    document.body.style.overflow = ""
  }

  escapeKey(e) {
    if (e.key === "Escape") this.close()
  }
}
