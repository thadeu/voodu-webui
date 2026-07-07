# frozen_string_literal: true

# Components::Metrics::ChartModal — the SHARED modal scaffold for
# expand-chart on /metrics. Rendered ONCE at the bottom of
# Views::Metrics::Index, hidden by default. The maximize button on
# each ChartCard triggers /metrics/chart, whose turbo_stream
# response targets this modal's inner slots:
#
#   turbo_stream.update("chart-modal-title", new label)
#   turbo_stream.replace("chart-modal-body",  new ChartModalBody)
#   turbo_stream.action(:chart_modal_open)
#
# This replaces the previous per-card pattern (8 duplicate hidden
# overlays + JS portal hack + per-metric turbo-frame ids) — see
# the older chart_expand_controller history if curious. The
# refactor is net negative LOC AND removes three workarounds we
# had to comment around.
#
# Lifecycle hooks live on `data-controller="chart-modal"` (see
# chart_modal_controller.js): ESC key, backdrop click, body
# scroll-lock, and parent polling pause are all owned there.
class Components::Metrics::ChartModal < Components::Base
  def view_template
    div(
      id: "chart-modal",
      hidden: true,
      data: {controller: "chart-modal"},
      class: "fixed inset-0 z-[65] flex items-center justify-center"
    ) do
      backdrop
      dialog
    end
  end

  private

  def backdrop
    div(
      "aria-hidden": "true",
      data: {action: "click->chart-modal#backdropClick", chart_modal_target: "backdrop"},
      class: "absolute inset-0 bg-black/55 backdrop-blur-[3px]"
    )
  end

  def dialog
    div(
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "chart-modal-title",
      data: {chart_modal_target: "dialog"},
      class: tokens(
        "relative z-[1]",
        "w-[min(1600px,calc(100vw-48px))] max-h-[calc(100vh-48px)]",
        "flex flex-col min-h-0",
        "bg-voodu-surface-2 border border-voodu-border-2",
        "shadow-[0_28px_56px_rgba(0,0,0,0.65),0_4px_12px_rgba(0,0,0,0.4)]"
      )
    ) do
      modal_header
      modal_body
    end
  end

  # modal_header — the title is a turbo_stream UPDATE target
  # (id="chart-modal-title") so the metric label swaps on every
  # open without needing to refactor the whole header. Close
  # button is a static `<button data-action>` resolved by the
  # chart-modal Stimulus controller.
  def modal_header
    header(
      class: "flex items-center gap-2.5 px-4 py-3 border-b border-voodu-border bg-voodu-surface"
    ) do
      h2(
        id: "chart-modal-title",
        class: "m-0 text-[13px] font-semibold uppercase tracking-[0.05em] font-voodu-mono text-voodu-muted"
      ) { "" }

      div(class: "flex-1")

      button(
        type: "button",
        "aria-label": "Close",
        data: {action: "click->chart-modal#close"},
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2"
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  # modal_body — the turbo_stream REPLACE target. The endpoint's
  # response replaces this whole element with a fresh
  # ChartModalBody every time the operator opens, switches pod,
  # or switches range. No turbo-frame id contortions: the server
  # always targets the same well-known id.
  def modal_body
    div(
      id: "chart-modal-body",
      class: "flex flex-col overflow-auto min-h-0"
    ) do
      # Empty placeholder. First open swaps in the real content.
      # If operator somehow opens via ESC/backdrop before any
      # fetch happened, they see a blank dialog and close it —
      # benign.
    end
  end
end
