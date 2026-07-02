import { Controller } from "@hotwired/stimulus"

// call-flow — companion to Components::Hep3::CallFlowModal.
//
// Jobs:
//   1. Arrow selection — click a ladder arrow → select its message + swap the
//      raw-SIP panel. Messages ride in as a Stimulus Array value (instant, no
//      fetch). Opens pre-selected on `focus` and scrolls to it.
//   2. Keyboard nav — while the mouse is over the diagram, ↑/↓ step to the
//      previous/next message.
//   3. Refresh — re-fetch THIS call in place (follow a live call), keeping the
//      current selection; delegates to the page host via datatable:rowaction.
//   4. Collapse / resize the raw panel (persisted).
//
// Selection tint uses inline style.fill (a `fill` presentation attribute
// won't parse the CSS var).
export default class extends Controller {
  static targets = ["arrow", "rawLabel", "rawMeta", "rawBody", "ladder", "rawPanel", "content", "reopen", "resizeHandle", "chevron", "mediaBody", "mediaChevron"]
  static values = { messages: Array, focus: Number, scope: String, name: String, corr: String }

  STORE_W = "voodu:cf:rawwidth"
  STORE_COLLAPSED = "voodu:cf:collapsed"
  MIN_W = 260

  connect() {
    this.currentIndex = this.focusValue || 0
    this.mouseInLadder = false
    this.onKey = this.onKey.bind(this)
    this.onResize = this.onResize.bind(this)
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("resize", this.onResize)

    this.restorePanel()
    this.selectIndex(this.currentIndex)
    requestAnimationFrame(() => {
      this.scrollIndexIntoView(this.currentIndex)
      // Land focus on the diagram (not the modal's close button, which the
      // shared modal_controller would otherwise grab) so ↑/↓ work at once.
      if (this.hasLadderTarget) this.ladderTarget.focus({ preventScroll: true })
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("resize", this.onResize)
  }

  // onResize — keep the raw panel width sane as the window changes live: in
  // row re-clamp a dragged width (no-op if none saved — the CSS clamp() adapts
  // on its own); dropping to column clears the inline width so it goes full.
  onResize() {
    if (!this.hasRawPanelTarget || this.collapsed) return

    if (this.isWide()) {
      this.applySavedWidth()
    } else {
      this.rawPanelTarget.style.width = ""
    }
  }

  // ── selection ─────────────────────────────────────────────────────

  select(event) {
    this.selectIndex(Number(event.currentTarget.dataset.index))
  }

  selectIndex(i) {
    this.currentIndex = i
    this.highlight(i)

    const m = this.messagesValue[i]

    if (!m) return

    if (this.hasRawLabelTarget) this.rawLabelTarget.textContent = m.label || ""
    if (this.hasRawMetaTarget) this.rawMetaTarget.textContent = `${m.ts} · ${m.src} → ${m.dst}`

    if (this.hasRawBodyTarget) {
      this.rawBodyTarget.textContent = m.raw && m.raw.length ? m.raw : "(no raw SIP captured for this message)"
    }
  }

  highlight(i) {
    this.arrowTargets.forEach((g) => {
      const on = Number(g.dataset.index) === i
      const bg = g.querySelector('[data-role="rowbg"]')

      if (bg) bg.style.fill = on ? "var(--voodu-accent-dim)" : "transparent"
    })
  }

  // ── keyboard nav (only while hovering the diagram) ────────────────

  ladderEnter() {
    this.mouseInLadder = true
  }

  ladderLeave() {
    this.mouseInLadder = false
  }

  onKey(event) {
    // Nav when the mouse is over the diagram OR the diagram holds focus
    // (it grabs focus on open) — never globally, so it won't fight ESC/scroll.
    if (!this.mouseInLadder && !this.ladderHasFocus()) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.step(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.step(-1)
    }
  }

  ladderHasFocus() {
    return this.hasLadderTarget &&
      (document.activeElement === this.ladderTarget || this.ladderTarget.contains(document.activeElement))
  }

  // toggleMedia — expand/collapse the "gap" media footer (RTP on off-lifeline
  // hosts). Overlays the diagram; the flow scrolls underneath.
  toggleMedia() {
    if (!this.hasMediaBodyTarget) return

    const open = !this.mediaBodyTarget.classList.toggle("hidden")

    if (this.hasMediaChevronTarget) this.mediaChevronTarget.style.transform = open ? "rotate(180deg)" : ""
  }

  step(delta) {
    const last = this.messagesValue.length - 1

    if (last < 0) return

    const next = Math.max(0, Math.min(last, this.currentIndex + delta))

    this.selectIndex(next)
    this.scrollIndexIntoView(next)
  }

  scrollIndexIntoView(i) {
    if (!this.hasLadderTarget) return

    const g = this.arrowTargets.find((a) => Number(a.dataset.index) === i)

    if (!g) return

    const y = g.getBoundingClientRect().top - this.ladderTarget.getBoundingClientRect().top + this.ladderTarget.scrollTop

    this.ladderTarget.scrollTop = Math.max(0, y - this.ladderTarget.clientHeight / 2)
  }

  // ── refresh (re-fetch this call in place) ─────────────────────────

  refresh() {
    const cur = this.messagesValue[this.currentIndex]

    // Re-dispatch to the page host, which re-fetches + re-injects. Passing the
    // current message id as focus keeps the selection across the refresh.
    window.dispatchEvent(new CustomEvent("datatable:rowaction", {
      detail: {
        event: "callflow",
        scope: this.scopeValue,
        name: this.nameValue,
        value: this.corrValue,
        rowId: cur ? cur.id : "",
      },
    }))
  }

  // ── collapse / expand ─────────────────────────────────────────────
  // The header chevron TOGGLES; behaviour follows the layout:
  //   row    → collapse to a thin left strip (reclaim the diagram's WIDTH)
  //   column → collapse the body, keep the header row (reclaim the diagram's
  //            HEIGHT) — a chevron row like the media footer.

  togglePanel() {
    this.applyCollapsed(!this.collapsed)
    this.persist(this.STORE_COLLAPSED, this.collapsed ? "1" : "0")
  }

  expandPanel() {
    this.applyCollapsed(false)
    this.persist(this.STORE_COLLAPSED, "0")
  }

  applyCollapsed(on) {
    if (!this.hasRawPanelTarget) return

    this.collapsed = on
    const panel = this.rawPanelTarget

    if (on && this.isWide()) {
      panel.style.width = ""
      panel.classList.add("!w-9", "!flex-none")
      if (this.hasContentTarget) this.contentTarget.style.display = "none"
      if (this.hasReopenTarget) this.reopenTarget.style.display = "flex"
      if (this.hasResizeHandleTarget) this.resizeHandleTarget.style.display = "none"
    } else if (on) {
      // column: hide the body, keep the header row; shrink to its height.
      // Chevron up (rotate 180) when collapsed — same convention + alignment
      // as the media footer's chevron.
      panel.classList.add("!flex-none")
      if (this.hasRawBodyTarget) this.rawBodyTarget.style.display = "none"
      if (this.hasChevronTarget) this.chevronTarget.style.transform = "rotate(180deg)"
    } else {
      panel.classList.remove("!w-9", "!flex-none")
      if (this.hasContentTarget) this.contentTarget.style.display = ""
      if (this.hasReopenTarget) this.reopenTarget.style.display = "none"
      if (this.hasResizeHandleTarget) this.resizeHandleTarget.style.display = ""
      if (this.hasRawBodyTarget) this.rawBodyTarget.style.display = ""
      if (this.hasChevronTarget) this.chevronTarget.style.transform = ""
      this.applySavedWidth()
    }
  }

  // ── resize (row layout) ───────────────────────────────────────────

  startResize(event) {
    if (!this.isWide() || !this.hasRawPanelTarget) return

    event.preventDefault()

    const panel = this.rawPanelTarget
    const startX = event.clientX
    const startW = panel.getBoundingClientRect().width
    const maxW = Math.min(window.innerWidth * 0.75, 900)

    const onMove = (e) => {
      const w = Math.max(this.MIN_W, Math.min(maxW, startW + (startX - e.clientX)))

      panel.style.width = `${w}px`
    }

    const onUp = () => {
      document.removeEventListener("pointermove", onMove)
      document.removeEventListener("pointerup", onUp)
      this.persist(this.STORE_W, String(Math.round(panel.getBoundingClientRect().width)))
    }

    document.addEventListener("pointermove", onMove)
    document.addEventListener("pointerup", onUp)
  }

  // ── restore persisted panel state on open ─────────────────────────

  // restorePanel — reapply persisted width (row only) + collapsed state (both
  // layouts — collapse is now a header chevron that works in column too).
  restorePanel() {
    this.applySavedWidth()

    if (localStorage.getItem(this.STORE_COLLAPSED) === "1") this.applyCollapsed(true)
  }

  // applySavedWidth — row layout only, and CLAMPED to half the viewport so a
  // width dragged wide on a big monitor doesn't dominate a smaller screen.
  applySavedWidth() {
    if (!this.hasRawPanelTarget || !this.isWide()) return

    const w = parseInt(localStorage.getItem(this.STORE_W) || "", 10)

    if (w >= this.MIN_W) this.rawPanelTarget.style.width = `${Math.min(w, Math.round(window.innerWidth * 0.5))}px`
  }

  isWide() {
    return window.matchMedia("(min-width: 1100px)").matches
  }

  persist(key, value) {
    try {
      localStorage.setItem(key, value)
    } catch (_e) {
      // storage disabled — state just won't stick across opens.
    }
  }
}
