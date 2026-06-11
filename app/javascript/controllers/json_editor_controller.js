import { Controller } from "@hotwired/stimulus"

// json-editor — a featherweight JSON editor: a real <textarea> (native
// caret, selection, undo, form submission) with a syntax-highlighted
// layer painted behind it, plus the code-editor ergonomics people
// expect: auto-close pairs, auto-indent on Enter, Tab = 2 spaces, and a
// one-tap Format. No dependency — these behaviours are easy ON A
// TEXTAREA (the hard part CodeJar carries is contenteditable caret
// bookkeeping, which a textarea gives us for free). Every mutation goes
// through execCommand("insertText") so the NATIVE undo stack stays
// intact and `input` fires to repaint the highlight.
//
//   <div class="voodu-code" data-controller="json-editor">
//     <pre class="voodu-code__hl" data-json-editor-target="highlight"></pre>
//     <textarea class="voodu-code__input" data-json-editor-target="input"
//       data-action="input->json-editor#render keydown->json-editor#keydown"></textarea>
//   </div>
const PAIRS = { '"': '"', "{": "}", "[": "]", "(": ")" }
const CLOSERS = new Set(['"', "}", "]", ")"])

export default class extends Controller {
  static targets = ["input", "highlight", "gutter"]

  connect() {
    this.onScroll = () => {
      this.highlightTarget.scrollTop = this.inputTarget.scrollTop
      // The gutter follows vertically only — it stays pinned left.
      if (this.hasGutterTarget) this.gutterTarget.scrollTop = this.inputTarget.scrollTop
    }

    this.inputTarget.addEventListener("scroll", this.onScroll)

    // Re-align the gutter when the editor's width changes (modal resize)
    // — wrapping shifts, so line heights do too.
    this.observer = new ResizeObserver(() => this.alignGutter())
    this.observer.observe(this.inputTarget)

    this.render()
  }

  disconnect() {
    this.inputTarget.removeEventListener("scroll", this.onScroll)
    this.observer?.disconnect()
  }

  render() {
    const lines = this.inputTarget.value.split("\n")

    // One block per logical line so each line's wrapped height is
    // measurable (empty lines get a zero-width char for a line box).
    this.highlightTarget.innerHTML = lines
      .map((line) => `<div class="voodu-code__line">${this.paint(line) || "\u200b"}</div>`)
      .join("")

    if (this.hasGutterTarget) {
      this.gutterTarget.innerHTML = lines
        .map((_, i) => `<div class="voodu-code__gnum">${i + 1}</div>`)
        .join("")
      this.alignGutter()
    }
  }

  // Match the highlight's content width to the textarea (accounting for
  // its scrollbar so both wrap identically), then size each gutter cell
  // to its line's wrapped height so numbers stay on the right rows.
  alignGutter() {
    if (!this.hasGutterTarget) return

    const scrollbar = this.inputTarget.offsetWidth - this.inputTarget.clientWidth
    this.highlightTarget.style.paddingRight = `${12 + scrollbar}px`

    const lines = this.highlightTarget.children
    const cells = this.gutterTarget.children
    const heights = Array.from(lines, (el) => el.offsetHeight)

    for (let i = 0; i < cells.length; i++) cells[i].style.height = `${heights[i] || 0}px`
  }

  // ── editing ────────────────────────────────────────────────────────

  keydown(event) {
    if (event.isComposing) return

    const ta = this.inputTarget
    const { selectionStart: s, selectionEnd: e, value: v } = ta
    const multi = s !== e

    if (event.key === "Tab") {
      event.preventDefault()

      if (multi && v.slice(s, e).includes("\n")) this.reindent(event.shiftKey ? -1 : 1)
      else if (event.shiftKey) this.outdentLine()
      else this.setText("  ")

      return
    }

    if (event.key === "Enter" && !multi) {
      event.preventDefault()
      this.newline()

      return
    }

    // Typing a closer that's already the next char → step over it.
    if (!multi && CLOSERS.has(event.key) && v[s] === event.key) {
      event.preventDefault()
      ta.setSelectionRange(s + 1, s + 1)

      return
    }

    // An opener (or a quote) → auto-close, or wrap the selection.
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

  newline() {
    const ta = this.inputTarget
    const { selectionStart: s, value: v } = ta
    const lineStart = v.lastIndexOf("\n", s - 1) + 1
    const indent = v.slice(lineStart).match(/^[ \t]*/)[0]
    const before = v[s - 1]

    // Between a bracket pair → open a fresh indented line, caret on it.
    if (before && PAIRS[before] && before !== '"' && v[s] === PAIRS[before]) {
      const inner = `${indent}  `
      this.setText(`\n${inner}\n${indent}`, s, s)
      ta.setSelectionRange(s + 1 + inner.length, s + 1 + inner.length)
    } else {
      this.setText(`\n${indent}`, s, s)
    }
  }

  // Indent (+1) / outdent (-1) every line touched by the selection.
  reindent(dir) {
    const ta = this.inputTarget
    const { selectionStart: s, selectionEnd: e, value: v } = ta
    const start = v.lastIndexOf("\n", s - 1) + 1
    const block = v.slice(start, e)
    const next = dir > 0 ? block.replace(/^/gm, "  ") : block.replace(/^ {1,2}/gm, "")

    this.setText(next, start, e)
    ta.setSelectionRange(start, start + next.length)
  }

  outdentLine() {
    const ta = this.inputTarget
    const { selectionStart: s, value: v } = ta
    const lineStart = v.lastIndexOf("\n", s - 1) + 1
    const removed = (v.slice(lineStart).match(/^ {1,2}/) || [""])[0].length

    if (!removed) return

    this.setText("", lineStart, lineStart + removed)
    const caret = Math.max(lineStart, s - removed)
    ta.setSelectionRange(caret, caret)
  }

  format() {
    let pretty

    try {
      pretty = JSON.stringify(JSON.parse(this.inputTarget.value), null, 2)
    } catch (_) {
      this.flashInvalid()

      return
    }

    this.setText(pretty, 0, this.inputTarget.value.length)
    this.inputTarget.setSelectionRange(0, 0)
  }

  flashInvalid() {
    this.element.classList.add("voodu-code--invalid")
    setTimeout(() => this.element.classList.remove("voodu-code--invalid"), 700)
  }

  // Replace [start, end) with text, undo-preserving (execCommand), and
  // let the resulting `input` event repaint the highlight.
  setText(text, start = this.inputTarget.selectionStart, end = this.inputTarget.selectionEnd) {
    const ta = this.inputTarget

    ta.focus()
    ta.setSelectionRange(start, end)

    if (!document.execCommand("insertText", false, text)) {
      ta.setRangeText(text, start, end, "end")
      ta.dispatchEvent(new Event("input", { bubbles: true }))
    }
  }

  // ── highlighter ─────────────────────────────────────────────────────

  paint(code) {
    const esc = code.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

    return esc.replace(
      /("(?:[^"\\]|\\.)*")(\s*:)?|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([{}[\],:])/g,
      (match, str, colon, lit, num, punc) => {
        if (str !== undefined) {
          const cls = colon ? "tok-key" : "tok-str"
          const tail = colon ? `<span class="tok-punc">${colon}</span>` : ""

          return `<span class="${cls}">${this.vars(str)}</span>${tail}`
        }

        if (lit !== undefined) return `<span class="tok-lit">${lit}</span>`
        if (num !== undefined) return `<span class="tok-num">${num}</span>`
        if (punc !== undefined) return `<span class="tok-punc">${punc}</span>`

        return match
      }
    )
  }

  // Highlight our {{token}} / {{token | filter}} markers inside a string.
  vars(str) {
    return str.replace(/\{\{[^{}]+\}\}/g, (m) => `<span class="tok-var">${m}</span>`)
  }
}
