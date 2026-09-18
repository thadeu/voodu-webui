# frozen_string_literal: true

# Components::LogAnalytics::ScopeGate — THE filter of the analytics page,
# rendered in the results body under the sticky column header. Two lives:
#
#   required — no pod scope chosen yet: it is all the body shows, and no scan
#              has run. It exists because the old first paint scanned EVERY
#              pod's warehouse before anyone asked a question.
#   on demand — a query is on screen: rendered hidden, the toolbar funnel
#              toggles it over the rows (it replaced the old filter drawer, so
#              there is one place to edit scope + query, not two).
#
# Pods → optional query → Apply. The panel owns no form: Apply dispatches
# `log-scope-gate:apply` and the log-analytics controller writes the choice
# into the filter form's hidden fields and submits THAT — so the URL, Refresh
# and the results never disagree about the active scope.
class Components::LogAnalytics::ScopeGate < Components::Base
  SEARCH_THRESHOLD = 8

  def initialize(data:, pods: [])
    @data = data
    @pods = Array(pods)
  end

  def view_template
    div(
      hidden: @data.scope_chosen?,
      class: "@container w-full max-w-[960px] mx-auto px-4 vmd:px-6 py-6 vmd:py-10 flex flex-col gap-5",
      data: {
        controller: "log-scope-gate",
        log_analytics_target: "gate",
        required: (!@data.scope_chosen?).to_s,
        log_scope_gate_storage_key_value: "voodu:logs-analytics-scope:#{@data.server.key}",
        action: "keydown->log-scope-gate#keydown log-scope-gate:apply->log-analytics#applyScope"
      }
    ) do
      intro
      pods_section
      query_section
      gate_footer
    end
  end

  private

  def intro
    div(class: "flex items-start gap-3") do
      span(class: "inline-flex items-center justify-center w-8 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 shrink-0") do
        render Icon::FunnelOutline.new(class: "w-4 h-4")
      end

      div(class: "flex flex-col gap-0.5 min-w-0") do
        h2(class: "m-0 text-[14px] font-semibold text-voodu-text") { "Where do you want to look?" }
        p(class: "m-0 text-[12px] text-voodu-muted leading-relaxed") do
          plain "Select the pods to search. A smaller scope gives a faster answer."
        end
      end
    end
  end

  def pods_section
    div(class: "flex flex-col gap-2.5") do
      div(class: "flex items-center gap-2.5") do
        section_label("Pods")
        section_rule
        pod_search if @pods.size > SEARCH_THRESHOLD
        clear_button
      end

      render Components::LogAnalytics::PodCards.new(pods: @pods, selected: @data.pods, all: @data.scope_all?)

      p(hidden: true, class: "m-0 text-[11.5px] text-voodu-muted", data: {log_scope_gate_target: "noMatch"}) do
        plain "No pod matches this search."
      end
    end
  end

  # pod_search — client-side card filter. Only on a busy server; on a small
  # one it is one more control between the operator and the cards.
  def pod_search
    div(class: "flex items-center gap-1.5 px-2 h-7 w-[150px] vmd:w-[200px] shrink-0 border border-voodu-border bg-voodu-surface focus-within:border-voodu-accent-line") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      input(
        type: "search",
        placeholder: "Find a pod",
        autocomplete: "off",
        "aria-label": "Find a pod",
        data: {log_scope_gate_target: "search", action: "input->log-scope-gate#filterCards"},
        class: "min-w-0 flex-1 bg-transparent outline-none text-[11.5px] text-voodu-text placeholder:text-voodu-muted-2"
      )
    end
  end

  def clear_button
    button(
      type: "button",
      hidden: true,
      data: {log_scope_gate_target: "clear", action: "click->log-scope-gate#clear"},
      class: "shrink-0 text-[10.5px] font-medium text-voodu-accent-2 hover:text-voodu-accent transition-colors"
    ) { "Clear" }
  end

  # query_section — the shared LogQuery editor (highlight, field validation,
  # `@` autocomplete). No `name` + submits:false: the panel hands the text
  # over on Apply instead of posting a second `q`.
  def query_section
    div(class: "flex flex-col gap-2.5") do
      div(class: "flex items-center gap-2.5") do
        section_label("Query")
        span(class: "text-[10px] text-voodu-muted-2 shrink-0") { "optional" }
        section_rule
      end

      render Components::UI::QueryEditor.new(
        value: @data.search,
        placeholder: "filter @message like /timeout/",
        rows: "3",
        min_h: "min-h-[88px]",
        submits: false,
        input_data: {log_scope_gate_target: "query"}
      )
    end
  end

  def gate_footer
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2.5 vmd:gap-3 pt-1") do
      span(class: "text-[11.5px] text-voodu-muted vmd:flex-1 min-w-0", data: {log_scope_gate_target: "count"}) do
        plain "No pod selected"
      end

      span(class: "hidden vmd:inline text-[11px] text-voodu-muted-2 shrink-0") { "⌘/Ctrl + Enter" }
      cancel_button if @data.scope_chosen?
      apply_button
    end
  end

  # cancel_button — back to the results on screen. Absent while the scope is
  # required: there is nothing to go back to.
  def cancel_button
    button(
      type: "button",
      data: {action: "click->log-analytics#closeFilter"},
      class: "inline-flex items-center justify-center px-4 h-9 vmd:h-8 w-full vmd:w-auto shrink-0 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
    ) { "Cancel" }
  end

  # apply_button — accent-dim chrome, like the range popover's Apply (one
  # "execute" look on this page). Disabled while no scope is selected; the controller flips it.
  def apply_button
    button(
      type: "button",
      disabled: true,
      data: {log_scope_gate_target: "apply", action: "click->log-scope-gate#apply"},
      class: "inline-flex items-center justify-center gap-1.5 px-5 h-9 vmd:h-8 w-full vmd:w-auto shrink-0 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
    ) do
      render Icon::PlayOutline.new(class: "w-3.5 h-3.5")
      span { "Apply" }
    end
  end

  def section_label(text)
    span(class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted shrink-0") { text }
  end

  def section_rule
    span(class: "flex-1 h-px bg-gradient-to-r from-voodu-border to-transparent")
  end
end
