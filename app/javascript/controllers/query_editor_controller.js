import { Controller } from "@hotwired/stimulus"

// query-editor — the syntax-highlighted editor for the /logs/analytics
// filter DSL (see LogQuery). Same featherweight trick as json-editor: a real
// <textarea> (native caret/selection/undo/form submit) with a highlighted
// <pre> painted behind it. No dependency, no gutter, no JSON ceremony —
// lighter ergonomics tuned for a one-to-few-line query:
//
//   - auto-close ( ) and " " (and step over a closer that's already next)
//   - Enter RUNS the query (Shift+Enter inserts a newline for multi-line)
//   - Cmd/Ctrl+Enter also runs
//
//   <div class="voodu-code voodu-code--query" data-controller="query-editor">
//     <pre class="voodu-code__hl" data-query-editor-target="highlight"></pre>
//     <textarea class="voodu-code__input" name="q"
//       data-query-editor-target="input"
//       data-action="input->query-editor#render keydown->query-editor#keydown"></textarea>
//   </div>
const PAIRS = { '"': '"', "(": ")" }
const CLOSERS = new Set(['"', ")"])

// Token grammar, mirrored from LogQuery. Order matters: strings + regex
// literals first (so a keyword INSIDE /…/ or "…" isn't re-tokenised), then
// fields, the pipeline commands (filter/limit), boolean keywords, the `|`
// pipe, integers (limit arg), operators, parens. `g` to walk the line, `i`
// so commands/keywords highlight regardless of case.
const TOKENS =
  /("(?:[^"\\]|\\.)*")|(\/(?:[^/\\]|\\.)*\/)|(@\w+)|\b(filter|limit)\b|\b(and|or|not|like|count|sum|avg|min|max)\b|(\|)|\b(\d+)\b|(!=|==|=)|([()])/gi

// Every FILTER clause must name a field (matches LogQuery's requirement). A
// cheap "does it reference @message/@level/@stream at all" check blocks the
// field-less case; an agg suffix (| count / | avg / …) relaxes it (you can
// aggregate without a filter). Deeper parse errors still degrade server-side,
// so results never go blank.
const DEFAULT_FIELDS = ["message", "level", "stream"]
const HAS_AGG = /\b(count|sum|avg|min|max)\b/i

const escapeHtml = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")

export default class extends Controller {
  static targets = ["input", "highlight", "error"]
  // submits — whether Cmd/Ctrl+Enter submits the host form. True on Analytics
  // (the editor IS the query form); false in the dashboard builder, where the
  // builder reads the value itself and submitting would save mid-edit.
  // fields — the field names a clause may reference (without the @). Empty
  // → the log defaults (message/level/stream), so existing hosts are
  // unchanged; a data-table host passes its own columns. Each entry is a
  // "name" string OR a { name, hint } object (a host can describe fields).
  // hints — an optional { name: "note" } map, merged onto the suggestions.
  static values = {
    submits: { type: Boolean, default: true },
    fields: { type: Array, default: [] },
    hints: { type: Object, default: {} },
  }

  connect() {
    this.shell = this.element.querySelector(".voodu-code")
    this.fields = this.normalizeFields()
    this.fieldRe = this.buildFieldRegex()

    this.onScroll = () => {
      this.highlightTarget.scrollTop = this.inputTarget.scrollTop
      this.highlightTarget.scrollLeft = this.inputTarget.scrollLeft
    }

    this.buildSuggest()
    this.suggestOpen = false
    this.onCaretMove = () => this.updateSuggest()

    this.onDismiss = (e) => {
      if (this.suggestOpen && !this.suggestBox.contains(e.target) && e.target !== this.inputTarget) this.hideSuggest()
    }

    this.onReflow = () => { if (this.suggestOpen) this.hideSuggest() }

    this.inputTarget.addEventListener("scroll", this.onScroll)
    this.inputTarget.addEventListener("click", this.onCaretMove)
    this.inputTarget.addEventListener("focus", this.onCaretMove)
    this.inputTarget.addEventListener("blur", this.onReflow)
    document.addEventListener("pointerdown", this.onDismiss)
    window.addEventListener("resize", this.onReflow)
    window.addEventListener("scroll", this.onReflow, true)
    this.render()
  }

  disconnect() {
    this.inputTarget.removeEventListener("scroll", this.onScroll)
    this.inputTarget.removeEventListener("click", this.onCaretMove)
    this.inputTarget.removeEventListener("focus", this.onCaretMove)
    this.inputTarget.removeEventListener("blur", this.onReflow)
    document.removeEventListener("pointerdown", this.onDismiss)
    window.removeEventListener("resize", this.onReflow)
    window.removeEventListener("scroll", this.onReflow, true)
    this.suggestBox?.remove()
    this.mirror?.remove()
  }

  // fieldsValueChanged / hintsValueChanged — a host (the dashboard builder)
  // can swap the editor's fields at runtime (Table logs ⇄ HEP3); rebuild the
  // suggestion list + validation regex. Guarded until connect wires the shell.
  fieldsValueChanged() {
    this.refreshFields()
  }

  hintsValueChanged() {
    this.refreshFields()
  }

  refreshFields() {
    if (!this.shell) return

    this.fields = this.normalizeFields()
    this.fieldRe = this.buildFieldRegex()
    this.validate()
  }

  render() {
    const lines = this.inputTarget.value.split("\n")

    this.highlightTarget.innerHTML = lines
      .map((line) => `<div class="voodu-code__line">${this.paint(line) || "​"}</div>`)
      .join("")

    this.validate()
    this.updateSuggest()
  }

  // validate — a query is OK when empty, when it's only `limit N` stages (no
  // filter ⇒ no field needed), or when it names a field. Marks the editor
  // invalid, reveals the hint, and disables Run otherwise.
  validate() {
    const value = this.inputTarget.value.trim()
    const withoutLimit = value.replace(/\|?\s*limit\s+\d+/gi, "").trim()
    const valid = value === "" || withoutLimit === "" || this.fieldRe.test(value) || HAS_AGG.test(value)

    this.shell?.classList.toggle("voodu-code--invalid", !valid)
    if (this.hasErrorTarget) this.errorTarget.classList.toggle("hidden", valid)

    const run = this.inputTarget.form?.querySelector("[data-role='run-query']")

    if (run) run.disabled = !valid

    return valid
  }

  // normalizeFields — each `fields` entry is a "name" string or a
  // { name, hint } object; fold in the `hints` map. Empty → log defaults.
  normalizeFields() {
    const raw = this.fieldsValue.length ? this.fieldsValue : DEFAULT_FIELDS

    return raw.map((f) => {
      const name = typeof f === "string" ? f : f.name
      const hint = (typeof f === "object" && f.hint) || this.hintsValue[name] || ""

      return { name, hint }
    })
  }

  // buildFieldRegex — "does the query name one of the allowed fields?" The
  // field names are literal (word chars), so an alternation is safe.
  buildFieldRegex() {
    const names = this.fields.map((f) => f.name)

    return new RegExp(`@(${names.join("|")})\\b`, "i")
  }

  keydown(event) {
    if (event.isComposing) return

    // The `@` menu owns the arrow/enter/tab/escape chords while it's open, so
    // navigating suggestions never inserts a newline or steps over a bracket.
    if (this.suggestOpen && this.handleSuggestKey(event)) return

    const ta = this.inputTarget
    const { selectionStart: s, selectionEnd: e, value: v } = ta
    const multi = s !== e

    // Cmd/Ctrl+Enter runs; plain Enter inserts a newline. CloudWatch-style
    // pipelines read one stage per line (`filter … ⏎ | filter …`), so Enter
    // must stay a newline — running is the deliberate modifier chord.
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.run()

      return
    }

    // Typing a closer that's already the next char → step over it.
    if (!multi && CLOSERS.has(event.key) && v[s] === event.key) {
      event.preventDefault()
      ta.setSelectionRange(s + 1, s + 1)

      return
    }

    // An opener (or quote) → auto-close, or wrap the selection.
    if (PAIRS[event.key]) {
      event.preventDefault()
      this.pair(event.key, PAIRS[event.key])

      return
    }

    // Backspace between an empty pair → delete both halves.
    if (event.key === "Backspace" && !multi && s > 0 && PAIRS[v[s - 1]] === v[s]) {
      event.preventDefault()
      this.setText("", s - 1, s + 1)
    }
  }

  // run — submit the host form (only when the query is valid AND this editor
  // owns submission). Turbo swaps just the results frame (the form targets it +
  // advances the URL), so the drawer stays open and the table updates behind
  // it. In a non-submitting host (the builder) run() just validates.
  run() {
    if (!this.validate()) return
    if (this.submitsValue) this.inputTarget.form?.requestSubmit()
  }

  pair(open, close) {
    const ta = this.inputTarget
    const { selectionStart: s, selectionEnd: e } = ta

    if (s !== e) {
      const sel = ta.value.slice(s, e)

      this.setText(open + sel + close, s, e)
      ta.setSelectionRange(s + 1, s + 1 + sel.length)
    } else {
      this.setText(open + close, s, e)
      ta.setSelectionRange(s + 1, s + 1)
    }
  }

  // Replace [start, end) undo-preservingly (execCommand), letting the
  // resulting `input` event repaint the highlight.
  setText(text, start = this.inputTarget.selectionStart, end = this.inputTarget.selectionEnd) {
    const ta = this.inputTarget

    ta.focus()
    ta.setSelectionRange(start, end)

    if (!document.execCommand("insertText", false, text)) {
      ta.setRangeText(text, start, end, "end")
      ta.dispatchEvent(new Event("input", { bubbles: true }))
    }
  }

  // ── `@` field autocomplete ──────────────────────────────────────────
  // The menu is a body-level element (position:fixed) so the drawer/modal's
  // overflow never clips it; it's driven entirely off `this.fields`.

  handleSuggestKey(event) {
    // Enter accepts the highlighted field — but Cmd/Ctrl+Enter still runs the
    // query (falls through to the run chord in keydown).
    const enterAccepts = event.key === "Enter" && !event.metaKey && !event.ctrlKey

    const action =
      event.key === "ArrowDown" ? () => this.moveActive(1) :
      event.key === "ArrowUp" ? () => this.moveActive(-1) :
      event.key === "Escape" ? () => this.hideSuggest() :
      event.key === "Tab" || enterAccepts ? () => this.acceptSuggest(this.activeIndex) :
      null

    if (!action) return false

    event.preventDefault()
    action()

    return true
  }

  // tokenUnderCaret — is the caret sitting inside an `@field` token? Returns
  // { start, partial } (start = index of `@`) or null. Walks left over word
  // chars from a collapsed caret; the run must be anchored by an `@`.
  tokenUnderCaret() {
    const ta = this.inputTarget

    if (ta.selectionStart !== ta.selectionEnd) return null

    const caret = ta.selectionStart
    const v = ta.value
    let i = caret

    while (i > 0 && /\w/.test(v[i - 1])) i--

    if (i > 0 && v[i - 1] === "@") return { start: i - 1, partial: v.slice(i, caret) }

    return null
  }

  // updateSuggest — recompute the menu for the caret's current `@` token.
  // Prefix matches sort ahead of mid-word matches; no token / no match closes.
  updateSuggest() {
    const tok = this.tokenUnderCaret()

    if (!tok) return this.hideSuggest()

    const q = tok.partial.toLowerCase()
    const matches = this.fields
      .filter((f) => f.name.toLowerCase().includes(q))
      .sort((a, b) => Number(b.name.toLowerCase().startsWith(q)) - Number(a.name.toLowerCase().startsWith(q)))

    if (!matches.length) return this.hideSuggest()

    this.matches = matches
    this.tokenStart = tok.start
    this.activeIndex = 0
    this.renderSuggest()
    this.positionSuggest()
    this.showSuggest()
  }

  renderSuggest() {
    this.suggestBox.innerHTML = this.matches
      .map((f, idx) => {
        const active = idx === this.activeIndex
        const hint = f.hint ? `<span class="text-[11px] text-voodu-muted truncate">${escapeHtml(f.hint)}</span>` : ""

        return `<div role="option" data-idx="${idx}" aria-selected="${active}" ` +
          `class="flex items-baseline gap-2 px-2.5 py-1.5 cursor-pointer ${active ? "bg-voodu-accent-dim text-voodu-accent-2" : "hover:bg-voodu-hover"}">` +
          `<span class="font-voodu-mono text-[12px]">@${escapeHtml(f.name)}</span>${hint}</div>`
      })
      .join("")
  }

  moveActive(delta) {
    const n = this.matches.length

    this.activeIndex = (this.activeIndex + delta + n) % n
    this.renderSuggest()
    this.suggestBox.querySelector(`[data-idx="${this.activeIndex}"]`)?.scrollIntoView({ block: "nearest" })
  }

  // acceptSuggest — swap the typed `@partial` for the chosen field, then a
  // trailing space (unless one's already there) so the operator flows into
  // the operator/value. setText fires `input` → repaint + close.
  acceptSuggest(idx) {
    const f = this.matches?.[idx]

    if (!f) return

    const ta = this.inputTarget
    const caret = ta.selectionStart
    const insert = `@${f.name}${ta.value[caret] === " " ? "" : " "}`

    this.hideSuggest()
    this.setText(insert, this.tokenStart, caret)
  }

  buildSuggest() {
    const box = document.createElement("div")

    box.className = "hidden fixed z-[1000] min-w-[190px] max-w-[320px] max-h-[240px] overflow-y-auto " +
      "border border-voodu-border-2 bg-voodu-surface shadow-2xl py-1 scrollbar-hidden"
    box.setAttribute("role", "listbox")

    // pointerdown must not blur the textarea (which would close the menu
    // before the click lands); accept on click via the delegated handler.
    box.addEventListener("pointerdown", (e) => e.preventDefault())
    box.addEventListener("click", (e) => {
      const item = e.target.closest("[data-idx]")

      if (item) this.acceptSuggest(Number(item.dataset.idx))
    })

    document.body.appendChild(box)
    this.suggestBox = box
  }

  showSuggest() {
    this.suggestBox.classList.remove("hidden")
    this.suggestOpen = true
  }

  hideSuggest() {
    this.suggestBox?.classList.add("hidden")
    this.suggestOpen = false
  }

  // positionSuggest — anchor the menu just below the caret. Measures the
  // caret with a mirror div (below), flips above / clamps to the viewport.
  positionSuggest() {
    const { top, left, lineH } = this.caretRect()
    const box = this.suggestBox

    box.style.visibility = "hidden"
    box.style.left = "0px"
    box.style.top = "0px"
    box.classList.remove("hidden")

    const w = box.offsetWidth
    const h = box.offsetHeight
    const x = Math.min(left, window.innerWidth - w - 8)
    const below = top + 2
    const y = below + h > window.innerHeight - 8 ? top - lineH - h - 4 : below

    box.style.left = `${Math.max(8, x)}px`
    box.style.top = `${Math.max(8, y)}px`
    box.style.visibility = ""
  }

  // caretRect — viewport coords of the caret, via a hidden mirror div that
  // clones the textarea's box + text up to the caret (textarea has no native
  // caret-rect API). Returns the caret's baseline y/x + the line height.
  caretRect() {
    const ta = this.inputTarget
    const style = getComputedStyle(ta)
    const div = (this.mirror ||= this.buildMirror())

    const props = [
      "boxSizing", "width", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
      "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
      "fontFamily", "fontSize", "fontWeight", "fontStyle", "letterSpacing",
      "lineHeight", "textTransform", "textIndent", "whiteSpace", "wordWrap", "tabSize",
    ]

    props.forEach((p) => { div.style[p] = style[p] })

    const caret = ta.selectionStart

    div.textContent = ta.value.slice(0, caret)

    const marker = document.createElement("span")

    marker.textContent = ta.value.slice(caret) || "."
    div.appendChild(marker)

    const rect = ta.getBoundingClientRect()
    const lineH = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4
    const top = rect.top + (marker.offsetTop - ta.scrollTop) + lineH
    const left = rect.left + (marker.offsetLeft - ta.scrollLeft)

    return { top, left, lineH }
  }

  buildMirror() {
    const div = document.createElement("div")

    div.style.position = "absolute"
    div.style.visibility = "hidden"
    div.style.top = "0"
    div.style.left = "-9999px"
    div.style.whiteSpace = "pre-wrap"
    div.style.wordWrap = "break-word"
    div.style.overflow = "hidden"
    document.body.appendChild(div)

    return div
  }

  paint(code) {
    const esc = code.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

    return esc.replace(TOKENS, (match, str, re, field, cmd, kw, pipe, num, op, paren) => {
      if (str !== undefined) return `<span class="tok-str">${str}</span>`
      if (re !== undefined) return `<span class="tok-re">${re}</span>`
      if (field !== undefined) return `<span class="tok-var">${field}</span>`
      if (cmd !== undefined) return `<span class="tok-cmd">${cmd}</span>`
      if (kw !== undefined) return `<span class="tok-key">${kw}</span>`
      if (pipe !== undefined) return `<span class="tok-cmd">${pipe}</span>`
      if (num !== undefined) return `<span class="tok-num">${num}</span>`
      if (op !== undefined) return `<span class="tok-punc">${op}</span>`
      if (paren !== undefined) return `<span class="tok-punc">${paren}</span>`

      return match
    })
  }
}
