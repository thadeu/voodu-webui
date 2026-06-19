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
# input_data is merged onto the textarea's data attributes so a host controller
# can claim it as its own target too (e.g. the builder's `logQuery`).
class Components::UI::QueryEditor < Components::Base
  def initialize(value: "", name: nil, label: nil,
    placeholder: "filter @message like /timeout/",
    rows: "4", min_h: "min-h-[120px]",
    submits: true, show_help: true, show_error: true, help_limit: true,
    input_data: {})
    @value = value.to_s
    @name = name
    @label = label
    @placeholder = placeholder
    @rows = rows
    @min_h = min_h
    @submits = submits
    @show_help = show_help
    @show_error = show_error
    @help_limit = help_limit
    @input_data = input_data
  end

  def view_template
    wrapper_data = {controller: "query-editor"}
    # Stimulus value default is true, so only emit the attribute to turn it OFF.
    wrapper_data[:query_editor_submits_value] = "false" unless @submits

    div(class: "flex flex-col gap-2", data: wrapper_data) do
      field_label(@label) if @label
      editor_shell
      error_hint if @show_error
      syntax_help if @show_help
    end
  end

  private

  # editor_shell — the .voodu-code shell. `--query` variant drops the gutter.
  # The textarea is the real field (pre-filled so the highlight paints on
  # connect); resize-y lets the operator grow it for a long pipeline.
  def editor_shell
    div(class: "voodu-code voodu-code--query relative overflow-hidden resize-y #{@min_h} border border-voodu-border bg-voodu-surface") do
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

  # syntax_help — collapsed cheatsheet. `| limit` only makes sense where the
  # result set is paged (Analytics); a count tallies every match, so the
  # builder drops the limit line via help_limit:false.
  def syntax_help
    details(class: "group text-[11.5px] text-voodu-muted") do
      summary(class: "cursor-pointer select-none text-voodu-text-2 hover:text-voodu-text") { "Syntax" }
      div(class: "mt-2 flex flex-col gap-2 leading-relaxed") do
        help_line("filter @message like /re/", "regex on the whole line (msg + raw)")
        help_line('@level = "ERROR"', "exact match — @level · @stream")
        help_line("and · or · not · ( )", "combine clauses in one filter")
        help_line("filter … | filter …", "chain filters — each pipe ANDs")
        help_line("| limit 1000", "cap to the newest N matches") if @help_limit

        div(class: "pt-1 border-t border-voodu-border text-voodu-muted-2") do
          plain "Example: "
          code(class: "font-voodu-mono text-voodu-text-2") do
            @help_limit ? "filter @message like /call-id/ | limit 1000" : "@message like /INVITE/"
          end
        end
      end
    end
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
