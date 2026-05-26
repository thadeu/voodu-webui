import { Controller } from "@hotwired/stimulus"

// SidebarCollapseController — toggles the sidebar between expanded
// (full width, labels visible) and collapsed (~56px, icons-only)
// states on vmd+ viewports. State persists across page loads via
// localStorage so the operator's preference sticks.
//
// Initial render: the server emits the sidebar with `data-collapsed`
// SET by default. This controller's connect() runs as soon as the
// element is parsed and either:
//   - localStorage = "false" → removes the attribute (expand)
//   - localStorage = "true" or null → leaves it (stays collapsed)
//
// Why default-collapsed in HTML: avoids the "page renders expanded
// then visibly closes" flicker on every reload. The opposite jank
// (renders collapsed then expands) is gentler — the eye reads
// "revealing" rather than "hiding". The transition is also disabled
// on the first apply so the snap is instantaneous, not animated.
//
// Two affordances trigger the same toggle action:
//   - The chevron button in the sidebar footer (discoverable)
//   - The thin edge-handle rail on the sidebar's right border
//     (NR / Linear style, with a "Collapse" / "Expand" tooltip)
//
// Below vmd (mobile slide-in mode), both affordances are hidden
// and the `vmd:` prefix on every group-data-[collapsed] variant
// in the markup means the data attribute has no visual effect —
// mobile always shows the full sidebar.
//
// Storage key: voodu:sidebar:collapsed (string "true"/"false").
const STORAGE_KEY = "voodu:sidebar:collapsed"

export default class extends Controller {
  static targets = ["icon"]

  connect() {
    // Suppress transition for the initial state application so the
    // sidebar snaps to the saved state instead of animating from
    // the HTML default. `!important` via `!` prefix to defeat the
    // Tailwind `vmd:transition-[width]` utility on the same element.
    this.element.classList.add("!transition-none")

    // Default = collapsed (matches the HTML). Expand only when
    // localStorage explicitly says "false".
    this.apply(this.read() !== "false")

    // Re-enable transitions next paint so subsequent toggles animate.
    requestAnimationFrame(() => {
      this.element.classList.remove("!transition-none")
    })
  }

  toggle(event) {
    event?.preventDefault()

    const next = this.element.dataset.collapsed !== "true"

    this.apply(next)
    this.write(next)
  }

  apply(collapsed) {
    if (collapsed) {
      this.element.dataset.collapsed = "true"
    } else {
      delete this.element.dataset.collapsed
    }

    // Footer chevron flip: Left-pointing icon flips to point right
    // when sidebar is collapsed, so the affordance always reads
    // "click here to do the opposite of current state".
    if (this.hasIconTarget) {
      this.iconTarget.style.transform = collapsed ? "rotate(180deg)" : ""
    }
  }

  read() {
    try {
      return localStorage.getItem(STORAGE_KEY)
    } catch (_) {
      return null
    }
  }

  write(collapsed) {
    try {
      localStorage.setItem(STORAGE_KEY, collapsed ? "true" : "false")
    } catch (_) { /* private mode — in-memory state still applies */ }
  }
}
