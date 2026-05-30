import { Controller } from "@hotwired/stimulus"

// DashboardBuilderController — drives Views::MetricDashboards::Form.
//
// Holds the in-memory list of panels (source + metric pairs) the
// operator assembles, renders them as removable chips, and serializes
// the list to JSON into the hidden `metric_dashboard[panels]` field on
// every change so a plain (data-turbo:false) form submit ships it.
//
// Source + metric are picked from two DS dropdowns (the `dropdown`
// controller owns open/close; this controller owns the SELECTION).
// Picking a source repopulates the metric menu from the catalog —
// a { kind => [spec, …] } map rendered server-side from
// MetricsPageData.metric_catalog_for — so the offered metrics always
// match the chosen source's workload kind.

export default class extends Controller {
  static targets = ["sourceLabel", "metricLabel", "metricMenu", "list", "empty", "hidden"]
  static values  = {
    catalog: Object,
    panels:  Array
  }

  connect() {
    this.panels = Array.isArray(this.panelsValue) ? this.panelsValue.map((p) => ({ ...p })) : []
    this.currentSource = { scope_kind: "host", label: "host" }
    this.currentMetric = null

    this.populateMetrics()
    this.render()
    this.sync()
  }

  // selectSource — operator picked a source row. Update the trigger
  // label + remember the identity, then rebuild the metric menu for
  // this source's kind.
  selectSource(event) {
    const source = this.parse(event.currentTarget.dataset.source)
    if (!source) return

    this.currentSource = source
    if (this.hasSourceLabelTarget) this.sourceLabelTarget.textContent = event.currentTarget.textContent.trim()

    this.populateMetrics()
  }

  selectMetric(event) {
    const spec = this.parse(event.currentTarget.dataset.metric)
    if (!spec) return

    this.currentMetric = spec
    if (this.hasMetricLabelTarget) this.metricLabelTarget.textContent = spec.label
  }

  // populateMetrics — rebuild the metric dropdown's menu from the
  // catalog for the current source's kind, and default-select the
  // first metric so Add always has a valid pair.
  populateMetrics() {
    if (!this.hasMetricMenuTarget) return

    const key   = this.currentSource.scope_kind === "host" ? "host" : (this.currentSource.kind || "pod")
    const specs = (this.catalogValue && this.catalogValue[key]) || []

    this.metricMenuTarget.innerHTML = ""
    specs.forEach((spec) => this.metricMenuTarget.appendChild(this.metricOption(spec)))

    this.currentMetric = specs[0] || null
    if (this.hasMetricLabelTarget) {
      this.metricLabelTarget.textContent = this.currentMetric ? this.currentMetric.label : "Select metric"
    }
  }

  metricOption(spec) {
    const b = document.createElement("button")
    b.type = "button"
    b.className = "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] text-voodu-text hover:bg-[#ffffff08]"
    b.textContent = spec.label
    b.dataset.action = "click->dashboard-builder#selectMetric click->dropdown#close"
    b.dataset.metric = JSON.stringify(spec)

    return b
  }

  add(event) {
    event.preventDefault()
    if (!this.currentSource || !this.currentMetric) return

    this.panels.push(this.buildPanel(this.currentSource, this.currentMetric))
    this.render()
    this.sync()
  }

  remove(event) {
    event.preventDefault()
    const i = Number(event.params.index)
    if (Number.isNaN(i)) return

    this.panels.splice(i, 1)
    this.render()
    this.sync()
  }

  // buildPanel — combine the source identity with the chosen metric
  // spec into a self-contained panel. Label reads "<source> · <metric>"
  // so two CPU panels from different pods stay distinguishable.
  buildPanel(source, spec) {
    const srcLabel = source.label || (source.scope_kind === "host" ? "host" : source.name)

    const panel = {
      scope_kind: source.scope_kind,
      metric:     spec.metric,
      scale:      spec.scale,
      label:      `${srcLabel} · ${spec.label}`,
      color:      spec.color,
      unit:       spec.unit || ""
    }

    if (source.scope_kind === "pod") {
      panel.scope = source.scope
      panel.name  = source.name
      panel.kind  = source.kind
    }

    return panel
  }

  render() {
    if (!this.hasListTarget) return

    this.listTarget.innerHTML = ""
    this.panels.forEach((panel, i) => this.listTarget.appendChild(this.chip(panel, i)))

    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.panels.length > 0
  }

  chip(panel, index) {
    const row = document.createElement("div")
    row.className = "flex items-center gap-2 px-2.5 h-9 border border-voodu-border bg-voodu-surface"

    const dot = document.createElement("span")
    dot.className = "inline-block w-2 h-2 rounded-full shrink-0"
    dot.style.background = panel.color || "var(--voodu-muted)"
    row.appendChild(dot)

    const label = document.createElement("span")
    label.className = "text-[12.5px] text-voodu-text truncate flex-1 min-w-0"
    label.textContent = panel.label
    row.appendChild(label)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-red shrink-0"
    remove.setAttribute("aria-label", `Remove ${panel.label}`)
    remove.dataset.action = "click->dashboard-builder#remove"
    remove.dataset.dashboardBuilderIndexParam = index
    remove.textContent = "✕"
    row.appendChild(remove)

    return row
  }

  sync() {
    if (this.hasHiddenTarget) this.hiddenTarget.value = JSON.stringify(this.panels)
  }

  parse(value) {
    if (!value) return null

    try {
      return JSON.parse(value)
    } catch {
      return null
    }
  }
}
