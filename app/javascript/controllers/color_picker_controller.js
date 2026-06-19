import { Controller } from "@hotwired/stimulus"

// ColorPickerController — DS colour picker (spectrum + hue rail + hex),
// ported from Stella's color-picker.tsx. Self-contained: drag the spectrum
// for saturation/value, the hue rail for hue, or type a hex. Every change
// dispatches a bubbling `color-picker:change` CustomEvent { color, name } the
// host (dashboard-builder) listens for. No <input type="color">.
export default class extends Controller {
  static targets = ["spectrum", "spectrumThumb", "hue", "hueThumb", "preview", "hex"]
  static values = { color: { type: String, default: "#8b6cff" }, name: { type: String, default: "" } }

  connect() {
    this.hsv = hexToHsv(isValidHex(this.colorValue) ? this.colorValue : "#8b6cff")
    this.onMove = this.onMove.bind(this)
    this.onUp = this.onUp.bind(this)

    // rAF so the canvases are laid out before the first draw.
    requestAnimationFrame(() => {
      this.drawHue()
      this.drawSpectrum()
      this.syncThumbs()
      this.preview(hsvToHex(...this.hsv))
      if (this.hasHexTarget) this.hexTarget.value = hsvToHex(...this.hsv).slice(1).toUpperCase()
    })
  }

  disconnect() {
    this.stopDrag()
  }

  spectrumDown(event) {
    this.dragging = "spectrum"
    this.startDrag()
    this.spectrumAt(event)
  }

  hueDown(event) {
    this.dragging = "hue"
    this.startDrag()
    this.hueAt(event)
  }

  startDrag() {
    window.addEventListener("mousemove", this.onMove)
    window.addEventListener("mouseup", this.onUp)
  }

  stopDrag() {
    window.removeEventListener("mousemove", this.onMove)
    window.removeEventListener("mouseup", this.onUp)
    this.dragging = null
  }

  onMove(event) {
    if (this.dragging === "spectrum") this.spectrumAt(event)
    else if (this.dragging === "hue") this.hueAt(event)
  }

  onUp() {
    this.stopDrag()
  }

  spectrumAt(event) {
    const r = this.spectrumTarget.getBoundingClientRect()
    const x = clamp01((event.clientX - r.left) / r.width)
    const y = clamp01((event.clientY - r.top) / r.height)

    this.hsv = [this.hsv[0], x, 1 - y]
    this.commit()
  }

  hueAt(event) {
    const r = this.hueTarget.getBoundingClientRect()
    const x = clamp01((event.clientX - r.left) / r.width)

    this.hsv = [Math.round(x * 360), this.hsv[1], this.hsv[2]]
    this.drawSpectrum()
    this.commit()
  }

  onHex(event) {
    const raw = event.target.value.replace(/[^0-9a-fA-F]/g, "").slice(0, 6)

    event.target.value = raw.toUpperCase()
    const norm = normalizeHex(raw)

    if (!norm) return

    this.hsv = hexToHsv(norm)
    this.drawSpectrum()
    this.syncThumbs()
    this.preview(norm)
    this.emit(norm)
  }

  commit() {
    const hex = hsvToHex(...this.hsv)

    if (this.hasHexTarget) this.hexTarget.value = hex.slice(1).toUpperCase()
    this.syncThumbs()
    this.preview(hex)
    this.emit(hex)
  }

  emit(hex) {
    this.colorValue = hex
    this.dispatch("change", { prefix: "color-picker", bubbles: true, detail: { color: hex, name: this.nameValue } })
  }

  preview(hex) {
    if (this.hasPreviewTarget) this.previewTarget.style.background = hex
  }

  syncThumbs() {
    if (this.hasSpectrumThumbTarget) {
      this.spectrumThumbTarget.style.left = `${this.hsv[1] * 100}%`
      this.spectrumThumbTarget.style.top = `${(1 - this.hsv[2]) * 100}%`
      this.spectrumThumbTarget.style.background = hsvToHex(...this.hsv)
    }

    if (this.hasHueThumbTarget) {
      this.hueThumbTarget.style.left = `${(this.hsv[0] / 360) * 100}%`
      this.hueThumbTarget.style.background = `hsl(${this.hsv[0]},100%,50%)`
    }
  }

  drawSpectrum() {
    const c = this.spectrumTarget
    const ctx = c.getContext("2d")
    const { width, height } = c

    let g = ctx.createLinearGradient(0, 0, width, 0)

    g.addColorStop(0, "#ffffff")
    g.addColorStop(1, hsvToHex(this.hsv[0], 1, 1))
    ctx.fillStyle = g
    ctx.fillRect(0, 0, width, height)

    g = ctx.createLinearGradient(0, 0, 0, height)
    g.addColorStop(0, "rgba(0,0,0,0)")
    g.addColorStop(1, "rgba(0,0,0,1)")
    ctx.fillStyle = g
    ctx.fillRect(0, 0, width, height)
  }

  drawHue() {
    const c = this.hueTarget
    const ctx = c.getContext("2d")
    const { width, height } = c
    const g = ctx.createLinearGradient(0, 0, width, 0)

    ;[0, 60, 120, 180, 240, 300, 360].forEach((d) => g.addColorStop(d / 360, `hsl(${d},100%,50%)`))
    ctx.fillStyle = g
    ctx.fillRect(0, 0, width, height)
  }
}

// ── Colour math (ported from color-picker.tsx) ──────────────────────────────

function hexToHsv(hex) {
  const r = parseInt(hex.slice(1, 3), 16) / 255
  const g = parseInt(hex.slice(3, 5), 16) / 255
  const b = parseInt(hex.slice(5, 7), 16) / 255
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const d = max - min
  let h = 0

  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h = Math.round(h * 60)
    if (h < 0) h += 360
  }

  return [h, max === 0 ? 0 : d / max, max]
}

function hsvToHex(h, s, v) {
  const c = v * s
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = v - c
  let r = 0, g = 0, b = 0

  if (h < 60) { r = c; g = x }
  else if (h < 120) { r = x; g = c }
  else if (h < 180) { g = c; b = x }
  else if (h < 240) { g = x; b = c }
  else if (h < 300) { r = x; b = c }
  else { r = c; b = x }

  const toHex = (n) => Math.round((n + m) * 255).toString(16).padStart(2, "0")

  return `#${toHex(r)}${toHex(g)}${toHex(b)}`
}

function isValidHex(s) {
  return /^#[0-9a-fA-F]{6}$/.test(String(s))
}

function normalizeHex(raw) {
  const s = raw.startsWith("#") ? raw : `#${raw}`

  if (/^#[0-9a-fA-F]{6}$/.test(s)) return s
  if (/^#[0-9a-fA-F]{3}$/.test(s)) return `#${s[1]}${s[1]}${s[2]}${s[2]}${s[3]}${s[3]}`

  return null
}

function clamp01(n) {
  return Math.max(0, Math.min(1, n))
}
