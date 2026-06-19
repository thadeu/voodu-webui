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
const HAS_FIELD = /@(message|level|stream)\b/i
const HAS_AGG = /\b(count|sum|avg|min|max)\b/i

export default class extends Controller {
  static targets = ["input", "highlight", "error"]
  // submits — whether Cmd/Ctrl+Enter submits the host form. True on Analytics
  // (the editor IS the query form); false in the dashboard builder, where the
  // builder reads the value itself and submitting would save mid-edit.
  static values = { submits: { type: Boolean, default: true } }

  connect() {
    this.shell = this.element.querySelector(".voodu-code")

    this.onScroll = () => {
      this.highlightTarget.scrollTop = this.inputTarget.scrollTop
      this.highlightTarget.scrollLeft = this.inputTarget.scrollLeft
    }

    this.inputTarget.addEventListener("scroll", this.onScroll)
    this.render()
  }

  disconnect() {
    this.inputTarget.removeEventListener("scroll", this.onScroll)
  }

  render() {
    const lines = this.inputTarget.value.split("\n")

    this.highlightTarget.innerHTML = lines
      .map((line) => `<div class="voodu-code__line">${this.paint(line) || "​"}</div>`)
      .join("")

    this.validate()
  }

  // validate — a query is OK when empty, when it's only `limit N` stages (no
  // filter ⇒ no field needed), or when it names a field. Marks the editor
  // invalid, reveals the hint, and disables Run otherwise.
  validate() {
    const value = this.inputTarget.value.trim()
    const withoutLimit = value.replace(/\|?\s*limit\s+\d+/gi, "").trim()
    const valid = value === "" || withoutLimit === "" || HAS_FIELD.test(value) || HAS_AGG.test(value)

    this.shell?.classList.toggle("voodu-code--invalid", !valid)
    if (this.hasErrorTarget) this.errorTarget.classList.toggle("hidden", valid)

    const run = this.inputTarget.form?.querySelector("[data-role='run-query']")

    if (run) run.disabled = !valid

    return valid
  }

  keydown(event) {
    if (event.isComposing) return

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
