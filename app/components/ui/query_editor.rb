# frozen_string_literal: true

# Components::UI::QueryEditor — the syntax-highlighted editor for the LogQuery
# DSL. A real <textarea> (native caret/undo/selection/form submit) painted by
# a <pre> behind it; the `query-editor` Stimulus controller tokenises the line,
# auto-closes ( ) / " ", and validates that every clause names a field.
#
# Shared by the /logs/analytics filter bar (Components::LogAnalytics::FilterBar)
# and the dashboard log-count panel builder, so both speak the exact same query
# language with the same affordances — an operator prototypes a filter on
# Analytics and pastes it into a panel verbatim.
#
# The root div IS the `query-editor` controller element; its targets (highlight,
# input, error) must live inside it. `submits:` false makes Cmd+Enter validate
# WITHOUT submitting the host form — the builder reads the value itself via its
# own target; only Analytics submits on run.
#
# `fields` drives two things at once: the client-side "every clause names a
# field" validation AND the `@`-autocomplete — typing `@` pops a menu of the
# host's fields (filtered as you type). It's the ONE injected list, so each
# context self-describes: the log filter offers message/level/stream, a HEP3
# table offers its SIP columns. `field_hints` (name → short note) is optional
# label text shown beside each suggestion.
#
# input_data is merged onto the textarea's data attributes so a host controller
# can claim it as its own target too (e.g. the builder's `logQuery`).
class Components::UI::QueryEditor < Components::Base
  def initialize(value: "", name: nil, label: nil,
    placeholder: "filter @message like /timeout/",
    rows: "4", min_h: "min-h-[120px]", grow: false,
    submits: true, show_help: true, show_error: true, help_limit: true, show_stats: false,
    fields: [], field_hints: {}, input_data: {})
    @value = value.to_s
    @name = name
    @label = label
    # fields — field names a clause may reference (client validation + the
    # `@` autocomplete). Empty → the log defaults; a data-table host passes
    # its own columns.
    @fields = Array(fields)
    # field_hints — optional { "to_user" => "SIP To user" } shown as a muted
    # note beside each autocomplete suggestion.
    @field_hints = field_hints.to_h
    @placeholder = placeholder
    @rows = rows
    @min_h = min_h
    # grow — let the shell flex to fill its (flex-col) parent's height instead
    # of sitting at min_h. The host must give this component room to grow.
    @grow = grow
    @submits = submits
    @show_help = show_help
    @show_error = show_error
    @help_limit = help_limit
    @show_stats = show_stats
    @input_data = input_data
  end

  def view_template
    wrapper_data = {controller: "query-editor"}
    # Stimulus value default is true, so only emit the attribute to turn it OFF.
    wrapper_data[:query_editor_submits_value] = "false" unless @submits
    wrapper_data[:query_editor_fields_value] = @fields.to_json if @fields.any?
    wrapper_data[:query_editor_hints_value] = @field_hints.to_json if @field_hints.any?

    div(class: tokens("flex flex-col gap-2", ("flex-1 min-h-0" if @grow)), data: wrapper_data) do
      field_label(@label) if @label
      editor_shell
      error_hint if @show_error
      syntax_help if @show_help
    end
  end

  private

  # editor_shell — the .voodu-code shell. `--query` variant drops the gutter.
  # The textarea is the real field (pre-filled so the highlight paints on
  # connect); resize-y lets the operator grow it for a long pipeline. When
  # `grow`, the shell flexes to fill the parent instead of resting at min_h.
  def editor_shell
    div(class: tokens("voodu-code voodu-code--query relative overflow-hidden resize-y border border-voodu-border bg-voodu-surface", @grow ? "flex-1 min-h-0" : @min_h)) do
      pre(class: "voodu-code__hl", "aria-hidden": "true", data: {query_editor_target: "highlight"})

      textarea(
        name: @name,
        rows: @rows,
        spellcheck: "false",
        autocapitalize: "off",
        autocomplete: "off",
        placeholder: @placeholder,
        class: "voodu-code__input",
        data: {
          query_editor_target: "input",
          action: "input->query-editor#render keydown->query-editor#keydown"
        }.merge(@input_data)
      ) { @value }
    end
  end

  # error_hint — hidden until the query names no field; the controller reveals
  # it (and blocks Run on Analytics) so every filter is field-scoped.
  def error_hint
    p(class: "hidden text-[11px] text-voodu-red", data: {query_editor_target: "error"}) do
      plain "Every filter needs a field — e.g. "
      code(class: "font-voodu-mono") { "@message like /…/" }
    end
  end

  # syntax_help — the cheatsheet as a click POPOVER (not an inline
  # details), so it doesn't push the form around and escapes the modal's
  # overflow clipping (same pattern as the Alerts destination help). `| limit`
  # only makes sense where the result set is paged (Analytics); a count
  # tallies every match, so the builder drops that line via help_limit:false.
  def syntax_help
    div(class: "relative self-start", data: {controller: "popover"}) do
      button(
        type: "button",
        "aria-label": "Query syntax reference",
        data: {action: "click->popover#toggle", popover_target: "trigger", tooltip: "Query syntax"},
        class: "inline-flex items-center gap-1 text-[11.5px] text-voodu-text-2 hover:text-voodu-text"
      ) do
        render Icon::QuestionMarkCircleOutline.new(class: "w-3.5 h-3.5")
        span { "Syntax" }
      end

      # Portaled to the dialog by the popover controller; static content only.
      div(
        hidden: true,
        data: {popover_target: "menu"},
        class: "w-[360px] max-w-[calc(100vw-32px)] overflow-y-auto border border-voodu-border-2 " \
               "bg-voodu-surface shadow-2xl p-3.5 flex flex-col gap-2 text-[11.5px] text-voodu-muted leading-relaxed"
      ) do
        help_line("filter @message like /re/", "regex on the whole line (msg + raw)")
        help_line('@level = "ERROR"', "exact match — @level · @stream")
        help_line("and · or · not · ( )", "combine clauses in one filter")
        help_line("filter … | filter …", "chain filters — each pipe ANDs")
        help_line("| limit 1000", "cap to the newest N matches") if @help_limit

        if @show_stats
          help_line("| count", "current count (latest interval)")
          help_line("| sum", "total over the range")
          help_line("| avg · | min · | max", "stats over the per-interval count")
        end

        div(class: "pt-1 border-t border-voodu-border text-voodu-muted-2") do
          plain "Example: "
          code(class: "font-voodu-mono text-voodu-text-2") { example_query }
        end
      end
    end
  end

  def example_query
    return "@message like /INVITE/ | count" if @show_stats
    return "filter @message like /call-id/ | limit 1000" if @help_limit

    "@message like /INVITE/"
  end

  def help_line(syntax, note)
    div(class: "flex items-baseline gap-2 min-w-0") do
      code(class: "font-voodu-mono text-voodu-text-2 shrink-0") { syntax }
      span(class: "truncate") { note }
    end
  end

  def field_label(text)
    span(class: "text-[10px] font-semibold uppercase tracking-[0.06em] text-voodu-muted-2") { text }
  end
end
