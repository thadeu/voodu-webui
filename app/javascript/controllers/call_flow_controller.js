import { Controller } from "@hotwired/stimulus"

// panStash — carries the canvas pan/zoom across an in-place Refresh (which
// re-injects the modal → a fresh controller). Module-scoped so it survives the
// old controller disconnecting and the new one connecting. A fresh open / F5
// reloads the module → null → fits normally.
let panStash = null

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
  static targets = ["arrow", "rawLabel", "rawMeta", "rawBody", "ladder", "rawPanel", "content", "reopen", "resizeHandle", "chevron", "mediaBody", "mediaChevron", "svg", "canvas"]
  static values = { messages: Array, focus: Number, scope: String, name: String, corr: String }

  STORE_W = "voodu:cf:rawwidth"
  STORE_COLLAPSED = "voodu:cf:collapsed"
  MIN_W = 260
  MIN_K = 0.25
  MAX_K = 4

  connect() {
    this.currentIndex = this.focusValue || 0
    this.mouseInLadder = false
    // pan/zoom state: content group transform = matrix(k,0,0,k,tx,ty).
    this.tx = 0
    this.ty = 0
    this.k = 1
    this.onKey = this.onKey.bind(this)
    this.onResize = this.onResize.bind(this)
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("resize", this.onResize)

    this.restorePanel()
    this.selectIndex(this.currentIndex)

    // The modal is freshly injected — its layout may not be settled on the
    // first frame (and rAF timing is flaky here). A ResizeObserver fires the
    // moment the ladder actually gets a size, so fit-on-open is reliable; it
    // also doubles as the canvas resize handler.
    this.fitted = false
    // The modal is freshly injected: the ladder target + its layout can lag a
    // few frames behind connect(). Poll until it's real, then observe (for
    // resize) and fit. Robust to whatever timing the injection lands with.
    this.setupCanvas()
  }

  setupCanvas(tries = 0) {
    // Wait only for the ladder ELEMENT to exist (fast), then observe it. The
    // ResizeObserver fires whenever it actually gets a size — no time limit —
    // so fit happens however late the injected layout settles (fresh open OR
    // re-inject on Refresh). Gating setup on width>0 could time out and never
    // observe; this doesn't.
    if (!this.hasLadderTarget) {
      if (tries < 60) setTimeout(() => this.setupCanvas(tries + 1), 25)

      return
    }

    if (!this.ro) {
      this.ro = new ResizeObserver(() => this.onLadderResize())
      this.ro.observe(this.ladderTarget)
    }

    this.onLadderResize()
  }

  onLadderResize() {
    this.setViewport()

    if (!this.cw) return

    if (this.fitted) {
      // keep pan/zoom, just resync headers + viewBox
      this.applyTransform()

      return
    }

    this.fitted = true

    if (panStash && panStash.corr === this.corrValue && Date.now() - panStash.ts < 5000) {
      // in-place Refresh: keep the pan/zoom the operator had.
      this.tx = panStash.tx
      this.ty = panStash.ty
      this.k = panStash.k
      panStash = null
      this.applyTransform()
    } else {
      this.fitToView()
      // If opened focused on a specific message, bring it into view (else the
      // fit is top-aligned, which is what you want for the call's start).
      if (this.currentIndex > 0) this.panIndexIntoView(this.currentIndex)
    }

    // Land focus on the diagram (not the modal's close button, which the
    // shared modal_controller would otherwise grab) so ↑/↓ work at once.
    if (this.hasLadderTarget) this.ladderTarget.focus({ preventScroll: true })
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("resize", this.onResize)
    this.ro?.disconnect()
  }

  // onResize — keep the raw panel width sane as the window changes live, and
  // resync the canvas viewport (the SVG viewBox tracks the container px so the
  // header math lines up). Keeps the current pan/zoom (no jarring re-fit).
  onResize() {
    if (this.hasRawPanelTarget && !this.collapsed) {
      if (this.isWide()) this.applySavedWidth()
      else this.rawPanelTarget.style.width = ""
    }

    this.setViewport()
    this.applyTransform()
  }

  // ── pan / zoom canvas ─────────────────────────────────────────────

  // setViewport — the SVG fills the container; make 1 user unit == 1 CSS px so
  // the HTML header chips can be placed at tx + col_x*k.
  setViewport() {
    if (!this.hasLadderTarget) return

    const r = this.ladderTarget.getBoundingClientRect()

    this.cw = r.width
    this.ch = r.height
    if (this.hasSvgTarget) this.svgTarget.setAttribute("viewBox", `0 0 ${this.cw} ${this.ch}`)
  }

  natW() {
    return this.hasSvgTarget ? Number(this.svgTarget.dataset.cfWidth) : 0
  }

  natH() {
    return this.hasSvgTarget ? Number(this.svgTarget.dataset.cfHeight) : 0
  }

  // fitToView — fit the WHOLE diagram (width AND height, like object-fit:
  // contain) so a call opens fully visible instead of width-filled and clipped
  // tall — the operator had to zoom out on every open. The smaller of the two
  // scales binds; floor at MIN_K (a very long call stays pannable) and cap at
  // 1.25 so a short call isn't blown up. Centred when it fits; when the content
  // still overflows (a long call at MIN_K) it pins to the top-left pad, so the
  // call starts at the INVITE.
  fitToView() {
    this.setViewport()

    const w = this.natW()
    const h = this.natH()

    if (!w || !h || !this.cw || !this.ch) return

    const padX = 20
    const padY = 16

    const kFit = Math.min((this.cw - padX * 2) / w, (this.ch - padY * 2) / h)

    this.k = Math.min(Math.max(kFit, this.MIN_K), 1.25)
    this.tx = Math.max(padX, (this.cw - w * this.k) / 2)
    this.ty = Math.max(padY, (this.ch - h * this.k) / 2)
    this.applyTransform()
  }

  applyTransform() {
    if (this.hasCanvasTarget) {
      this.canvasTarget.setAttribute("transform", `matrix(${this.k},0,0,${this.k},${this.tx},${this.ty})`)
    }
  }

  panStart(event) {
    if (event.button !== 0) return

    this.setViewport()
    this.panning = true
    this.moved = 0

    const startX = event.clientX
    const startY = event.clientY
    const startTx = this.tx
    const startTy = this.ty

    this.ladderTarget.style.cursor = "grabbing"

    const onMove = (e) => {
      const dx = e.clientX - startX
      const dy = e.clientY - startY

      this.moved = Math.max(this.moved, Math.abs(dx) + Math.abs(dy))
      this.tx = startTx + dx
      this.ty = startTy + dy
      this.applyTransform()
    }

    const onUp = () => {
      document.removeEventListener("pointermove", onMove)
      document.removeEventListener("pointerup", onUp)
      this.panning = false
      this.ladderTarget.style.cursor = ""

      // A real drag (not a click) must not also select an arrow underneath.
      if (this.moved > 4) {
        this.justDragged = true
        setTimeout(() => { this.justDragged = false }, 0)
      }
    }

    document.addEventListener("pointermove", onMove)
    document.addEventListener("pointerup", onUp)
  }

  onWheel(event) {
    event.preventDefault()
    this.setViewport()

    if (event.ctrlKey || event.metaKey) {
      const r = this.ladderTarget.getBoundingClientRect()

      this.zoomAround(event.clientX - r.left, event.clientY - r.top, Math.exp(-event.deltaY * 0.0015))
    } else {
      this.tx -= event.deltaX
      this.ty -= event.deltaY
      this.applyTransform()
    }
  }

  // zoomAround — scale keeping the point (cx,cy) in container px fixed.
  zoomAround(cx, cy, factor) {
    const newK = Math.min(this.MAX_K, Math.max(this.MIN_K, this.k * factor))

    this.tx = cx - (cx - this.tx) * (newK / this.k)
    this.ty = cy - (cy - this.ty) * (newK / this.k)
    this.k = newK
    this.applyTransform()
  }

  zoomIn() {
    this.setViewport()
    this.zoomAround(this.cw / 2, this.ch / 2, 1.2)
  }

  zoomOut() {
    this.setViewport()
    this.zoomAround(this.cw / 2, this.ch / 2, 1 / 1.2)
  }

  fit() {
    this.fitToView()
  }

  // ── selection ─────────────────────────────────────────────────────

  select(event) {
    // A pan (drag) ends in a click on the arrow underneath — don't select it.
    if (this.justDragged) return

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

    // Keyboard just SELECTS (highlight + raw panel); it must not move the
    // canvas — the operator pans/zooms themselves.
    this.selectIndex(next)
  }

  // panIndexIntoView — vertically pan (keeping zoom + horizontal pan) so the
  // arrow at index i is centred. Uses the arrow's natural y (data-cf-y).
  panIndexIntoView(i) {
    const g = this.arrowTargets.find((a) => Number(a.dataset.index) === i)

    if (!g || !this.ch) return

    this.ty = this.ch / 2 - Number(g.dataset.cfY) * this.k
    this.applyTransform()
  }

  // ── refresh (re-fetch this call in place) ─────────────────────────

  refresh() {
    const cur = this.messagesValue[this.currentIndex]

    // Stash the pan/zoom so the re-injected modal restores it instead of
    // re-fitting (watching a live call shouldn't reset your view).
    panStash = { corr: this.corrValue, tx: this.tx, ty: this.ty, k: this.k, ts: Date.now() }

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
