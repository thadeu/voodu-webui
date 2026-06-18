# frozen_string_literal: true

# Components::UI::CommandPalette — ⌘K palette shell.
#
# Renders ONCE in the Dashboard layout. Hidden by default; the
# Stimulus `command-palette` controller toggles visibility on
# Cmd-K / Ctrl-K (global) or when the topbar search button is
# clicked.
#
# Empty shell only — the command list is NOT inlined into the
# page HTML. The JS controller fetches it from /command_palette.json
# on first open and caches it in sessionStorage for 30s. This:
#
#   - Keeps the dashboard layout HTML small (no per-page JSON blob).
#   - Avoids re-serialising the global command set on every
#     ApplicationController render — only paid on first ⌘K.
#   - Removes the "JSON sitting in the DOM" surface the operator
#     flagged as a security smell. Commands now travel via XHR
#     with the standard Rails session cookie auth path.
#
# Structure:
#
#   <div data-controller="command-palette"
#        data-command-palette-endpoint-value="/command_palette.json">
#     <div data-command-palette-target="backdrop" hidden></div>
#     <div data-command-palette-target="dialog"   hidden>
#       <input data-command-palette-target="input">
#       <div   data-command-palette-target="results"></div>
#       <footer> kbd hints + result count </footer>
#     </div>
#   </div>
class Components::UI::CommandPalette < Components::Base
  def view_template
    div(
      data: {
        controller: "command-palette",
        command_palette_endpoint_value: command_palette_path,
        command_palette_csrf_value: form_authenticity_token
      }
    ) do
      backdrop
      dialog
    end
  end

  private

  def backdrop
    div(
      hidden: true,
      data: {
        command_palette_target: "backdrop",
        action: "click->command-palette#close"
      },
      class: "fixed inset-0 z-[65] bg-black/55 backdrop-blur-[3px]"
    )
  end

  def dialog
    div(
      hidden: true,
      data: {command_palette_target: "dialog"},
      role: "dialog",
      "aria-modal": "true",
      "aria-label": "Command palette",
      class: "fixed top-[84px] left-1/2 -translate-x-1/2 z-[70] w-[min(680px,calc(100vw-32px))] max-h-[calc(100vh-160px)] flex flex-col bg-voodu-surface-2 border border-voodu-border-2 shadow-[0_28px_56px_rgba(0,0,0,0.65),0_4px_12px_rgba(0,0,0,0.4)]"
    ) do
      input_row
      results_body
      footer_hints
    end
  end

  # input_row — taller 52px row with the magnifying glass + search
  # input + clear-X (when something's typed) + ESC kbd hint.
  def input_row
    div(class: "flex items-center gap-2.5 px-3.5 h-[52px] shrink-0 border-b border-voodu-border bg-voodu-surface") do
      render Icon::MagnifyingGlassOutline.new(class: "w-4 h-4 text-voodu-muted shrink-0")
      input(
        type: "text",
        placeholder: "Search pods, logs, actions…",
        "aria-label": "Command palette search",
        autocomplete: "off",
        spellcheck: "false",
        data: {
          command_palette_target: "input",
          action: "input->command-palette#filter"
        },
        class: "flex-1 min-w-0 bg-transparent border-0 outline-none text-voodu-text text-[15px] h-full placeholder:text-voodu-muted"
      )
      button(
        hidden: true,
        type: "button",
        "aria-label": "Clear search",
        data: {
          command_palette_target: "clear",
          action: "click->command-palette#clear"
        },
        class: "w-6 h-6 inline-flex items-center justify-center text-voodu-muted hover:text-voodu-text"
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
      render Components::UI::Kbd.new { "esc" }
    end
  end

  # results_body — scrolling container the Stimulus controller
  # writes into. innerHTML replaced on every keystroke.
  def results_body
    div(
      data: {command_palette_target: "results"},
      role: "listbox",
      "aria-label": "Commands",
      class: "flex-1 min-h-0 overflow-auto scrollbar-hidden py-1.5"
    )
  end

  def footer_hints
    div(class: "hidden vmd:flex items-center gap-4 px-3.5 min-h-9 shrink-0 border-t border-voodu-border bg-voodu-bg-2 text-[11px] text-voodu-muted font-voodu-mono") do
      hint_pair("navigate") {
        render Components::UI::Kbd.new { "↑" }
        render Components::UI::Kbd.new { "↓" }
      }
      hint_pair("select") { render Components::UI::Kbd.new { "↵" } }
      hint_pair("dismiss") { render Components::UI::Kbd.new { "esc" } }
      div(class: "flex-1")
      span do
        # Count starts at — and gets filled in by the JS controller
        # after the first fetch resolves. Initial render has no
        # numbers because the command list isn't loaded yet.
        span(class: "text-voodu-text-2", data: {command_palette_target: "count"}) { "—" }
        plain " results"
      end
    end
  end

  def hint_pair(label)
    span(class: "inline-flex items-center gap-1") do
      yield
      span(class: "ml-1") { label }
    end
  end
end
