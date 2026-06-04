import { Controller } from "@hotwired/stimulus"

// ThemeController — the topbar sun/moon toggle. The initial theme is
// already resolved before first paint by the inline script in
// application.html.erb (localStorage > prefers-color-scheme), which
// sets html[data-theme]. This controller just flips it on click,
// persists the choice, and keeps the <meta theme-color> + the icon in
// sync. Dark is the CSS base (:root); html[data-theme="light"] is the
// only override block, so "dark" simply means no light overrides win.
const STORAGE_KEY = "voodu:theme"
const META = { light: "#ffffff", dark: "#0a0d14" }

export default class extends Controller {
  static targets = ["sun", "moon"]

  connect() {
    // Re-assert the meta on EVERY connect — Turbo navigations re-render
    // the <head> with the static dark theme-color, and the inline head
    // script only runs on a full load. Without this, navigating while in
    // light mode lets the browser chrome drift back to the OS color.
    this.syncMeta()
    this.render()
  }

  toggle() {
    const next = this.current === "light" ? "dark" : "light"

    document.documentElement.dataset.theme = next

    try {
      localStorage.setItem(STORAGE_KEY, next)
    } catch (e) {
      // private mode / storage disabled — the toggle still applies for
      // this session, it just won't persist across reloads.
    }

    this.syncMeta()
    this.render()
  }

  get current() {
    return document.documentElement.dataset.theme === "light" ? "light" : "dark"
  }

  // syncMeta — force <meta theme-color> to the APP's chosen theme, even
  // when it differs from the OS preference (system dark + app light →
  // white chrome, not black).
  syncMeta() {
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta) meta.setAttribute("content", META[this.current])
  }

  // render — show the icon for the theme you'd switch TO (moon while in
  // light, sun while in dark), the conventional toggle affordance.
  render() {
    const light = this.current === "light"

    if (this.hasSunTarget) this.sunTarget.hidden = light
    if (this.hasMoonTarget) this.moonTarget.hidden = !light
  }
}
