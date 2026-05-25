# frozen_string_literal: true

# Components::UI::CommandPalette — ⌘K palette shell.
#
# Renders ONCE in the Dashboard layout. Hidden by default; the
# Stimulus `command-palette` controller toggles visibility on
# Cmd-K / Ctrl-K (global) or when the topbar search button is
# clicked.
#
# Server provides the full command list as JSON inline; the
# controller filters / scores / renders client-side on every
# keystroke. No XHR per keystroke — palette feels instant.
#
# Structure:
#
#   <div data-controller="command-palette"
#        data-command-palette-commands-value='[…json…]'>
#     <div data-command-palette-target="backdrop" hidden></div>
#     <div data-command-palette-target="dialog"   hidden>
#       <input data-command-palette-target="input">
#       <div   data-command-palette-target="results"></div>
#       <footer> kbd hints + result count </footer>
#     </div>
#   </div>
class Components::UI::CommandPalette < Components::Base
  def initialize(commands:, default_suggestion_ids: nil)
    @commands = Array(commands)
    @default_suggestion_ids = Array(default_suggestion_ids)
  end

  def view_template
    div(
      data: {
        controller: "command-palette",
        command_palette_commands_value:    @commands.to_json,
        command_palette_suggestions_value: @default_suggestion_ids.to_json,
        command_palette_csrf_value:        helpers.form_authenticity_token
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
      data: { command_palette_target: "dialog" },
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
      data: { command_palette_target: "results" },
      role: "listbox",
      "aria-label": "Commands",
      class: "flex-1 min-h-0 overflow-auto scrollbar-hidden py-1.5"
    )
  end

  def footer_hints
    div(class: "hidden vmd:flex items-center gap-4 px-3.5 min-h-9 shrink-0 border-t border-voodu-border bg-voodu-bg-2 text-[11px] text-voodu-muted font-voodu-mono") do
      hint_pair("navigate") { render Components::UI::Kbd.new { "↑" }; render Components::UI::Kbd.new { "↓" } }
      hint_pair("select")   { render Components::UI::Kbd.new { "↵" } }
      hint_pair("dismiss")  { render Components::UI::Kbd.new { "esc" } }
      div(class: "flex-1")
      span do
        span(class: "text-voodu-text-2", data: { command_palette_target: "count" }) { @commands.size.to_s }
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
